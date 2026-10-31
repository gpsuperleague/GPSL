import { initGlobal, supabase } from "./global.js";
import { formatMoney, leagueTierForDivision } from "./competition.js";
import { gpdbPlayerUrl } from "./player_links.js";
import {
  loadHandpickBasketState,
  setHandpickBasketPlayer,
  setHandpickManager,
  clearHandpickBasket,
} from "./handpick_basket.js?v=20261031-mgr-tag";
import {
  MIN_GOALKEEPERS,
  MIN_HOME_GROWN,
  MIN_SQUAD_SIZE,
  MIN_UNDER_21,
  SQUAD_SIZE,
  isHomeGrownPlayer,
  isUnder21,
  isGoalkeeper,
} from "./squad_rules.js";
import {
  loadSquadDesignationsState,
  playerEligibleOoo,
} from "./squad_designations.js";
import { loadWagePercentages, wageFromMarketValue } from "./wages.js";

/** @type {Map<string, object>} */
const basket = new Map();
/** @type {object|null} */
let pickedManager = null;
/** @type {object|null} */
let clubContext = null;
/** @type {boolean} */
let isAdmin = false;
/** @type {string} */
let activeClub = "";
/** @type {string} */
let activeClubName = "";
/** @type {object|null} */
let designations = null;
/** Planned OooO player id (preview only) — sticky in localStorage per club */
let plannedOooId = "";
/** @type {{ superleague: number, championship: number }} */
let wagePctSettings = { superleague: 5, championship: 4 };
/** @type {'superleague'|'championship'} */
let wageTier = "championship";

/** Catalogue wage if set, else division % of market value (same idea as Scouting). */
function playerSeasonWage(player) {
  if (!player) return 0;
  const stored = Number(player.contract_wage);
  if (Number.isFinite(stored) && stored > 0) return stored;
  const mv = Number(player.market_value) || 0;
  if (!mv) return 0;
  return wageFromMarketValue(mv, wageTier, wagePctSettings);
}

function oooStorageKey(club) {
  const c = String(club || "").trim().toUpperCase();
  return c ? `gpsl_handpick_ooo_${c}` : "";
}

function readStickyOoo(club) {
  const key = oooStorageKey(club);
  if (!key) return "";
  try {
    return String(localStorage.getItem(key) || "").trim();
  } catch {
    return "";
  }
}

function writeStickyOoo(club, playerId) {
  const key = oooStorageKey(club);
  if (!key) return;
  try {
    const id = String(playerId || "").trim();
    if (id) localStorage.setItem(key, id);
    else localStorage.removeItem(key);
  } catch {
    /* ignore */
  }
}

function clubFromUrl() {
  return String(new URLSearchParams(window.location.search).get("club") || "")
    .trim()
    .toUpperCase();
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function setPageStatus(msg, isError = false) {
  const el = document.getElementById("pageStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.classList.toggle("err", !!isError);
  el.classList.toggle("ok", !!msg && !isError);
}

function taxPct() {
  return Number(clubContext?.income_tax_pct) || 0;
}

function estCost(mv) {
  const fee = Number(mv) || 0;
  return fee + Math.round((fee * taxPct()) / 100 * 100) / 100;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  wireUi();
  await boot();
});

function wireUi() {
  document.getElementById("submitBtn")?.addEventListener("click", () => submitWishlist());
  document.getElementById("clearBtn")?.addEventListener("click", async () => {
    try {
      if (activeClub) await clearHandpickBasket(supabase, activeClub);
    } catch (err) {
      console.warn("handpick_basket_clear", err);
    }
    basket.clear();
    pickedManager = null;
    renderBasket();
    renderManager();
    setPageStatus("Basket and manager tag cleared.");
  });
  document.getElementById("clubSelect")?.addEventListener("change", async () => {
    activeClub = document.getElementById("clubSelect")?.value || "";
    basket.clear();
    pickedManager = null;
    await loadContext();
  });
  document.getElementById("plannedOooSelect")?.addEventListener("change", (e) => {
    plannedOooId = e.target?.value || "";
    writeStickyOoo(activeClub, plannedOooId);
    renderBuildPanel();
  });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible" || !activeClub) return;
    void (async () => {
      await hydrateBasketFromDb();
      renderBasket();
      renderManager();
      renderBuildPanel();
      await loadSubmissions();
    })();
  });
}

async function detectAdmin() {
  // Prefer explicit is_gpsl_admin(); fall back to admin-only map RPC.
  try {
    const { data, error } = await supabase.rpc("is_gpsl_admin");
    if (!error && data === true) return true;
  } catch {
    /* ignore */
  }
  const mapRes = await supabase.rpc("admin_handpick_intake_map");
  return !mapRes.error;
}

async function boot() {
  const gate = document.getElementById("gateBox");
  const app = document.getElementById("handpickApp");
  const qClub = clubFromUrl();

  isAdmin = await detectAdmin();
  const mapRes = isAdmin
    ? await supabase.rpc("admin_handpick_intake_map")
    : { data: {}, error: null };

  if (isAdmin) {
    document.getElementById("clubSelectWrap").hidden = false;
    const adminBanner = document.getElementById("adminBanner");
    if (adminBanner) adminBanner.hidden = false;
    const subTitle = document.getElementById("submissionsTitle");
    if (subTitle) subTitle.textContent = "Pending approvals (admin)";
    await loadAdminClubs(mapRes.data || {});
    const sel = document.getElementById("clubSelect");
    if (qClub && [...sel.options].some((o) => o.value === qClub)) {
      sel.value = qClub;
    } else if (qClub) {
      // Claimed club may be the only option of interest — keep URL club even if map lag
      const opt = document.createElement("option");
      opt.value = qClub;
      opt.textContent = `${qClub} (from link)`;
      sel.appendChild(opt);
      sel.value = qClub;
    }
    activeClub = sel?.value || qClub || "";
    if (!activeClub) {
      // Still show the page so admin can see pending approvals even with no intake club
      gate.className = "gate-box warn";
      gate.textContent =
        "No club in handpick intake right now — pending approvals (if any) still listed below. Turn Handpick on from the Season owner board to preview a club.";
      app.hidden = false;
      await loadSubmissions();
      return;
    }
  } else {
    // Owner: prefer ?club= from claim redirect, else RPC resolves my_club
    activeClub = qClub || "";
  }

  await loadContext();
}

async function loadAdminClubs(handpickMap) {
  const sel = document.getElementById("clubSelect");
  const keys = Object.keys(handpickMap || {}).filter(Boolean).sort();
  if (!keys.length) {
    sel.innerHTML = `<option value="">No handpick clubs</option>`;
    return;
  }
  const { data: clubs } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .in("ShortName", keys)
    .order("Club");
  const rows = Array.isArray(clubs) ? clubs : keys.map((k) => ({ ShortName: k, Club: k }));
  sel.innerHTML = rows
    .map(
      (c) =>
        `<option value="${escapeHtml(c.ShortName)}">${escapeHtml(c.Club || c.ShortName)} (${escapeHtml(
          c.ShortName
        )})</option>`
    )
    .join("");
}

async function loadContext() {
  const gate = document.getElementById("gateBox");
  const app = document.getElementById("handpickApp");
  const club = activeClub || document.getElementById("clubSelect")?.value || "";

  const { data, error } = await supabase.rpc("handpick_club_context", {
    p_club_short_name: club || null,
  });

  if (error) {
    gate.className = "gate-box warn";
    gate.textContent = error.message;
    app.hidden = true;
    return;
  }

  clubContext = data;
  // Never downgrade: map / is_gpsl_admin already decided; context may omit is_admin
  if (data?.is_admin) isAdmin = true;
  activeClub = String(data?.club || club || "").toUpperCase();
  activeClubName = String(data?.club_name || "").trim();

  const adminBanner = document.getElementById("adminBanner");
  if (adminBanner) adminBanner.hidden = !isAdmin;
  const clubSelectWrap = document.getElementById("clubSelectWrap");
  if (clubSelectWrap && isAdmin) clubSelectWrap.hidden = false;
  const subTitle = document.getElementById("submissionsTitle");
  if (subTitle) {
    subTitle.textContent = isAdmin
      ? "Pending approvals (admin)"
      : "Submissions";
  }

  if (!data?.ok) {
    gate.className = "gate-box warn";
    gate.textContent = data?.reason || "Could not load club.";
    app.hidden = true;
    return;
  }

  if (!activeClubName && activeClub) {
    const { data: clubRow } = await supabase
      .from("Clubs")
      .select("Club, ShortName")
      .eq("ShortName", activeClub)
      .maybeSingle();
    activeClubName = String(clubRow?.Club || "").trim();
  }

  const clubLabel = activeClubName
    ? `${activeClubName} (${activeClub})`
    : activeClub || "—";

  const titleEl = document.getElementById("clubTitle");
  if (titleEl) titleEl.textContent = clubLabel;

  const gpdb = document.getElementById("gpdbLink");
  if (gpdb) {
    gpdb.href = "GPDB.html";
    gpdb.textContent = "Open GPDB — handpick / temp-tag players";
  }
  const mgdbHref = activeClub
    ? `MGDB.html?club=${encodeURIComponent(activeClub)}`
    : "MGDB.html";
  const mgdb = document.getElementById("mgdbLink");
  if (mgdb) mgdb.href = mgdbHref;
  const mgdbInline = document.getElementById("mgdbLinkInline");
  if (mgdbInline) mgdbInline.href = mgdbHref;

  // Keep URL in sync so refresh / share keeps the chosen club
  if (activeClub && clubFromUrl() !== activeClub) {
    const url = new URL(window.location.href);
    url.searchParams.set("club", activeClub);
    window.history.replaceState({}, "", url);
  }

  if (!data.handpick_intake && !isAdmin) {
    gate.className = "gate-box warn";
    gate.textContent =
      "Your club is not in handpick intake. Ask an admin to enable Handpick on the Season owner board.";
    app.hidden = true;
    return;
  }

  if (!data.handpick_intake && isAdmin) {
    gate.className = "gate-box warn";
    gate.innerHTML = `Club <b>${escapeHtml(clubLabel)}</b> is not in handpick intake. Enable it on the Season owner board before approving wishlists.`;
  } else if (isAdmin) {
    gate.className = "gate-box ok";
    gate.innerHTML = `<b>Admin review</b> for <b>${escapeHtml(
      clubLabel
    )}</b> · balance ${escapeHtml(formatMoney(Number(data.balance) || 0))} · tax ${escapeHtml(
      String(data.income_tax_pct ?? 0)
    )}% · use <b>Pending approvals</b> below to Preview / Approve &amp; sign (you are not claiming this club).`;
  } else {
    gate.className = "gate-box ok";
    gate.innerHTML = `Handpick open for <b>${escapeHtml(clubLabel)}</b> · balance ${escapeHtml(
      formatMoney(Number(data.balance) || 0)
    )} (mid-season takeover: starting balance − Club takeover Fee) · tax ${escapeHtml(
      String(data.income_tax_pct ?? 0)
    )}%`;
  }

  app.hidden = false;
  document.getElementById("clubMeta").textContent = data.club_nation
    ? `Home nation: ${data.club_nation}`
    : "";

  try {
    designations = await loadSquadDesignationsState(supabase, activeClub);
  } catch (err) {
    console.warn("handpick designations", err);
    designations = null;
  }
  plannedOooId = readStickyOoo(activeClub);
  try {
    wagePctSettings = await loadWagePercentages(supabase);
  } catch (err) {
    console.warn("handpick wage pct", err);
  }
  try {
    const { data: reg } = await supabase
      .from("competition_club_season_public")
      .select("division")
      .eq("club_short_name", activeClub)
      .maybeSingle();
    const tier = leagueTierForDivision(reg?.division);
    wageTier = tier === "superleague" ? "superleague" : "championship";
  } catch {
    wageTier = "championship";
  }
  await hydrateBasketFromDb();
  renderBasket();
  renderManager();
  renderBuildPanel();
  await loadSubmissions();
}

function basketPlayerAsSquadShape(p) {
  return {
    Konami_ID: String(p.player_id || ""),
    Name: p.player_name,
    Nation: p.nation,
    Position: p.position,
    Rating: p.rating,
    Age: p.age,
    market_value: Number(p.market_value) || 0,
    contract_wage: Number(p.contract_wage) || 0,
  };
}

function projectedSquadPlayers() {
  const owned = Array.isArray(clubContext?.players) ? clubContext.players : [];
  const ownedIds = new Set(owned.map((p) => String(p.player_id || "")));
  const fromOwned = owned.map((p) => ({
    Konami_ID: String(p.player_id || ""),
    Name: p.player_name,
    Nation: p.nation,
    Position: p.position,
    Rating: p.rating,
    Age: p.age,
    market_value: Number(p.market_value) || 0,
    contract_wage: Number(p.contract_wage) || 0,
    from_basket: false,
  }));
  const fromBasket = [...basket.values()]
    .filter((p) => !ownedIds.has(String(p.player_id)))
    .map((p) => ({ ...basketPlayerAsSquadShape(p), from_basket: true }));
  return [...fromOwned, ...fromBasket];
}

function countProjected(players) {
  const clubNation = clubContext?.club_nation || "";
  const starMin = Number(designations?.star_min_rating ?? clubContext?.star_min_rating ?? 79);
  const ooo = plannedOooId ? String(plannedOooId) : "";
  let stars = 0;
  let u21 = 0;
  let hg = 0;
  let gk = 0;
  let wages = 0;
  for (const p of players) {
    const id = String(p.Konami_ID || p.player_id || "");
    const rating = Number(
      String(p.Rating ?? p.rating ?? "").replace(/[^\d.]/g, "")
    );
    // Same as scouting: planned OooO does not count toward the star cap
    if (Number.isFinite(rating) && rating >= starMin && !(ooo && id === ooo)) {
      stars += 1;
    }
    if (isUnder21(p)) u21 += 1;
    if (isHomeGrownPlayer(p, clubNation)) hg += 1;
    if (isGoalkeeper(p)) gk += 1;
    wages += playerSeasonWage(p);
  }
  return { total: players.length, stars, u21, hg, gk, wages };
}

function renderBuildPanel() {
  const players = projectedSquadPlayers();
  const counts = countProjected(players);
  const starCap = Number(designations?.star_cap ?? clubContext?.star_cap ?? 2);
  const starMin = Number(designations?.star_min_rating ?? clubContext?.star_min_rating ?? 79);
  const minHg = Number(clubContext?.min_home_grown) || MIN_HOME_GROWN;
  const minU21 = Number(clubContext?.min_under_21) || MIN_UNDER_21;
  const minGk = Number(clubContext?.min_goalkeepers) || MIN_GOALKEEPERS;
  const minSquad = Number(clubContext?.min_squad_size) || MIN_SQUAD_SIZE;
  const maxSquad = Number(clubContext?.max_squad_size) || SQUAD_SIZE;
  const clubNation = clubContext?.club_nation || "";

  const limits = document.getElementById("limitsBox");
  if (limits) {
    const squadCls =
      counts.total > maxSquad ? "bad" : counts.total >= minSquad ? "ok" : "warn";
    const starCls =
      counts.stars > starCap ? "bad" : counts.stars === starCap ? "warn" : "ok";
    const u21Cls = counts.u21 >= minU21 ? "ok" : "bad";
    const hgCls = counts.hg >= minHg ? "ok" : "bad";
    const gkCls = counts.gk >= minGk ? "ok" : "bad";
    limits.innerHTML = `
      <div class="stat ${squadCls}"><div class="lbl">Squad</div><div class="val">${counts.total}</div><div class="lim">min ${minSquad} · max ${maxSquad}</div></div>
      <div class="stat ${starCls}"><div class="lbl">Stars</div><div class="val">${counts.stars}</div><div class="lim">cap ${starCap} (≥${starMin}${plannedOooId ? ", OooO excl." : ""})</div></div>
      <div class="stat ${u21Cls}"><div class="lbl">U21</div><div class="val">${counts.u21}</div><div class="lim">min ${minU21}</div></div>
      <div class="stat ${hgCls}"><div class="lbl">Home grown</div><div class="val">${counts.hg}</div><div class="lim">min ${minHg}${clubNation ? ` · ${escapeHtml(clubNation)}` : ""}</div></div>
      <div class="stat ${gkCls}"><div class="lbl">GK</div><div class="val">${counts.gk}</div><div class="lim">min ${minGk}</div></div>
      <div class="stat ok"><div class="lbl">Wages</div><div class="val" style="font-size:14px;">${escapeHtml(formatMoney(counts.wages))}</div><div class="lim">est. season</div></div>`;
  }

  const balance = Number(clubContext?.balance) || 0;
  const taxRate = taxPct();
  let fees = 0;
  for (const p of basket.values()) fees += Number(p.market_value) || 0;
  const mgrFee = pickedManager ? Number(pickedManager.market_value) || 0 : 0;
  const tax = Math.round(((fees + mgrFee) * taxRate) / 100 * 100) / 100;
  const totalCost = fees + mgrFee + tax;
  const after = balance - totalCost;
  const finance = document.getElementById("financeBox");
  if (finance) {
    finance.innerHTML = `
      <div class="finance-row"><span>Balance</span><b>${escapeHtml(formatMoney(balance))}</b></div>
      <div class="finance-row"><span>Wishlist fees</span><b>${escapeHtml(formatMoney(fees + mgrFee))}</b></div>
      <div class="finance-row"><span>Est. income tax (${taxRate}%)</span><b>${escapeHtml(formatMoney(tax))}</b></div>
      <div class="finance-row"><span>Est. season wages (${wageTier === "superleague" ? "SL" : "Champ"} %)</span><b>${escapeHtml(formatMoney(counts.wages))}</b></div>
      <div class="finance-row ${after < 0 ? "neg" : "pos"}"><span>Balance after signings</span><b>${escapeHtml(formatMoney(after))}</b></div>
      <p class="hint" style="margin-top:8px;">Wage = stored contract wage when set, otherwise ${wageTier === "superleague" ? "SuperLeague" : "Championship"} % of MV. Final wages apply when admin approves. Tagged players also appear as ghosts on Squad.</p>`;
  }

  const oooSel = document.getElementById("plannedOooSelect");
  if (oooSel) {
    // OooO = home-grown for this club's nation AND star-rated (same as Squad / Scouting)
    const oooEligible = players
      .filter((p) => playerEligibleOoo(p, clubNation, starMin))
      .sort((a, b) =>
        String(a.Name || "").localeCompare(String(b.Name || ""), undefined, {
          sensitivity: "base",
        })
      );
    if (
      plannedOooId &&
      !oooEligible.some((p) => String(p.Konami_ID) === plannedOooId)
    ) {
      // Drop sticky pick if no longer a HG star in the projected squad
      plannedOooId = "";
      writeStickyOoo(activeClub, "");
    }
    const emptyLabel = clubNation
      ? `— none yet (need HG ★ ≥${starMin} · ${clubNation}) —`
      : `— none yet (need HG ★ ≥${starMin}) —`;
    const opts = [`<option value="">${escapeHtml(emptyLabel)}</option>`].concat(
      oooEligible.map((p) => {
        const id = String(p.Konami_ID || "");
        const mark = p.from_basket ? " (wishlist)" : "";
        return `<option value="${escapeHtml(id)}"${
          id && id === plannedOooId ? " selected" : ""
        }>${escapeHtml(p.Name || id)} (${escapeHtml(String(p.Rating ?? "—"))})${mark}</option>`;
      })
    );
    oooSel.innerHTML = opts.join("");
  }
}

async function hydrateBasketFromDb() {
  if (!activeClub || !clubContext?.handpick_intake) return;
  try {
    const hp = await loadHandpickBasketState(supabase, activeClub);
    basket.clear();
    for (const p of hp.players || []) {
      const id = String(p.player_id || "").trim();
      if (!id) continue;
      // Skip anyone no longer FA (signed elsewhere / already contracted)
      if (p.contracted_team) continue;
      basket.set(id, {
        player_id: id,
        player_name: p.player_name,
        position: p.position,
        rating: p.rating,
        nation: p.nation,
        age: p.age,
        market_value: p.market_value,
        contract_wage: p.contract_wage,
      });
    }
    if (hp.manager?.manager_id != null && !hp.manager.contracted_club) {
      pickedManager = {
        manager_id: hp.manager.manager_id,
        manager_name: hp.manager.manager_name,
        rating: hp.manager.rating,
        nation: hp.manager.nation,
        market_value: hp.manager.market_value,
      };
    } else {
      pickedManager = null;
    }
  } catch (err) {
    console.warn("hydrateBasketFromDb", err);
  }
}

async function persistPickedManager(rowOrNull) {
  const club = activeClub;
  if (!club) return;
  if (!rowOrNull) {
    if (pickedManager?.manager_id != null) {
      await setHandpickManager(supabase, pickedManager.manager_id, false, club);
    }
    pickedManager = null;
    return;
  }
  const res = await setHandpickManager(
    supabase,
    rowOrNull.manager_id,
    true,
    club
  );
  if (!res?.ok) {
    setPageStatus(res?.detail || res?.reason || "Could not tag manager", true);
    return false;
  }
  pickedManager = rowOrNull;
  return true;
}

function fillNations(list, home) {
  const sel = document.getElementById("nationSelect");
  if (!sel) return;
  const nations = Array.isArray(list) ? list.filter(Boolean) : [];
  const opts = [`<option value="">Any nation</option>`].concat(
    nations.map((n) => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`)
  );
  sel.innerHTML = opts.join("");
  if (home && nations.includes(home)) sel.value = home;
}

async function runPlayerSearch() {
  const club = activeClub;
  const q = document.getElementById("searchQ")?.value || "";
  const nation = document.getElementById("nationSelect")?.value || "";
  const box = document.getElementById("searchResults");
  box.innerHTML = `<p class="empty">Searching…</p>`;

  const { data, error } = await supabase.rpc("handpick_search_free_agents", {
    p_query: q,
    p_limit: 40,
    p_nation: nation || null,
    p_club_short_name: club,
  });

  if (error) {
    box.innerHTML = `<p class="empty">${escapeHtml(error.message)}</p>`;
    return;
  }

  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    box.innerHTML = `<p class="empty">No free agents matched.</p>`;
    return;
  }

  box.innerHTML = `<table class="sign-table"><thead><tr>
    <th>Player</th><th>Pos</th><th>Nat</th><th class="num">OVR</th><th class="num">MV</th><th></th>
  </tr></thead><tbody>
  ${rows
    .map((r) => {
      const id = String(r.player_id || "");
      const inBasket = basket.has(id);
      const gpdbHref = gpdbPlayerUrl(id);
      return `<tr>
        <td><a href="${escapeHtml(gpdbHref)}" target="_blank" rel="noopener" style="color:#e8c84a;">${escapeHtml(
          r.player_name
        )}</a></td>
        <td>${escapeHtml(r.position || "—")}</td>
        <td>${escapeHtml(r.nation || "—")}</td>
        <td class="num">${r.rating ?? "—"}</td>
        <td class="num">${escapeHtml(formatMoney(Number(r.market_value) || 0))}</td>
        <td><button type="button" class="button add-btn" data-id="${escapeHtml(id)}" ${
          inBasket ? "disabled" : ""
        }>${inBasket ? "Added" : "Add"}</button></td>
      </tr>`;
    })
    .join("")}
  </tbody></table>`;

  box.querySelectorAll(".add-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = btn.getAttribute("data-id");
      const row = rows.find((r) => String(r.player_id) === id);
      if (!row) return;
      btn.disabled = true;
      const res = await setHandpickBasketPlayer(supabase, id, true, club);
      if (!res?.ok) {
        btn.disabled = false;
        setPageStatus(res?.detail || res?.reason || "Could not tag", true);
        return;
      }
      basket.set(id, row);
      renderBasket();
      btn.textContent = "Added";
    });
  });
}

async function runManagerSearch() {
  const q = document.getElementById("mgrSearchQ")?.value || "";
  const box = document.getElementById("mgrResults");
  box.innerHTML = `<p class="empty">Searching…</p>`;

  const { data, error } = await supabase.rpc("handpick_search_managers", {
    p_query: q,
    p_limit: 20,
  });

  if (error) {
    box.innerHTML = `<p class="empty">${escapeHtml(error.message)}</p>`;
    return;
  }

  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    box.innerHTML = `<p class="empty">No free-agent managers matched.</p>`;
    return;
  }

  box.innerHTML = `<table class="sign-table"><thead><tr>
    <th>Manager</th><th>Nat</th><th class="num">OVR</th><th class="num">MV</th><th></th>
  </tr></thead><tbody>
  ${rows
    .map((r) => {
      const id = String(r.manager_id);
      const selected = pickedManager && String(pickedManager.manager_id) === id;
      return `<tr>
        <td>${escapeHtml(r.manager_name)}</td>
        <td>${escapeHtml(r.nation || "—")}</td>
        <td class="num">${r.rating ?? "—"}</td>
        <td class="num">${escapeHtml(formatMoney(Number(r.market_value) || 0))}</td>
        <td><button type="button" class="button mgr-btn" data-id="${escapeHtml(id)}">${
          selected ? "Selected" : "Select"
        }</button></td>
      </tr>`;
    })
    .join("")}
  </tbody></table>`;

  box.querySelectorAll(".mgr-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = btn.getAttribute("data-id");
      const row = rows.find((r) => String(r.manager_id) === id);
      if (!row) return;
      btn.disabled = true;
      const ok = await persistPickedManager(row);
      if (ok === false) {
        btn.disabled = false;
        return;
      }
      renderManager();
      renderBasket();
      runManagerSearch();
    });
  });
}

function renderManager() {
  const box = document.getElementById("managerPicked");
  if (!pickedManager) {
    box.hidden = true;
    box.innerHTML = "";
    renderBuildPanel();
    return;
  }
  box.hidden = false;
  box.innerHTML = `Manager: <b>${escapeHtml(pickedManager.manager_name)}</b> · ${escapeHtml(
    formatMoney(Number(pickedManager.market_value) || 0)
  )}
    <button type="button" class="button" id="clearMgrBtn" style="margin-left:8px;">Clear</button>`;
  document.getElementById("clearMgrBtn")?.addEventListener("click", async () => {
    await persistPickedManager(null);
    renderManager();
    renderBasket();
  });
  renderBuildPanel();
}

function renderBasket() {
  const box = document.getElementById("basketBox");
  const totals = document.getElementById("totalsBox");
  const rows = [...basket.values()];

  if (!rows.length && !pickedManager) {
    box.innerHTML = `<p class="empty">No players selected yet.</p>`;
    totals.hidden = true;
    renderBuildPanel();
    return;
  }

  let fees = 0;
  let tax = 0;
  let wages = 0;
  for (const r of rows) {
    const mv = Number(r.market_value) || 0;
    fees += mv;
    tax += Math.round(((mv * taxPct()) / 100) * 100) / 100;
    wages += playerSeasonWage(r);
  }
  const mgrFee = pickedManager ? Number(pickedManager.market_value) || 0 : 0;

  box.innerHTML = rows.length
    ? `<table class="sign-table"><thead><tr>
        <th>Player</th><th>Pos</th><th class="num">OVR</th><th class="num">MV</th><th class="num">Wage</th><th class="num">Fee+tax</th><th></th>
      </tr></thead><tbody>
      ${rows
        .map((r) => {
          const id = String(r.player_id);
          const mv = Number(r.market_value) || 0;
          const wage = playerSeasonWage(r);
          return `<tr>
            <td><a href="${escapeHtml(gpdbPlayerUrl(id))}" target="_blank" rel="noopener" style="color:#e8c84a;">${escapeHtml(
              r.player_name
            )}</a></td>
            <td>${escapeHtml(r.position || "—")}</td>
            <td class="num">${r.rating ?? "—"}</td>
            <td class="num">${escapeHtml(formatMoney(mv))}</td>
            <td class="num">${escapeHtml(formatMoney(wage))}</td>
            <td class="num">${escapeHtml(formatMoney(estCost(mv)))}</td>
            <td><button type="button" class="button rm-btn" data-id="${escapeHtml(id)}">Remove</button></td>
          </tr>`;
        })
        .join("")}
      </tbody></table>`
    : `<p class="empty">No players — manager only.</p>`;

  totals.hidden = false;
  totals.innerHTML = `Players <b>${rows.length}</b> · fees <b>${escapeHtml(
    formatMoney(fees)
  )}</b> + est. tax <b>${escapeHtml(formatMoney(tax))}</b>
    ${
      mgrFee
        ? ` · manager fee <b>${escapeHtml(formatMoney(mgrFee))}</b>`
        : ""
    }
    · wages <b>${escapeHtml(formatMoney(wages))}</b>
    · est. total fees <b>${escapeHtml(formatMoney(fees + tax + mgrFee))}</b>
    · balance <b>${escapeHtml(formatMoney(Number(clubContext?.balance) || 0))}</b>`;

  box.querySelectorAll(".rm-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = btn.getAttribute("data-id");
      await setHandpickBasketPlayer(supabase, id, false, activeClub);
      basket.delete(id);
      renderBasket();
    });
  });
  renderBuildPanel();
}

async function submitWishlist() {
  const club = activeClub;
  const ids = [...basket.keys()];
  if (!club) {
    setPageStatus("No club selected.", true);
    return;
  }
  if (!ids.length && !pickedManager) {
    setPageStatus("Add at least one player or a manager.", true);
    return;
  }
  if (
    !confirm(
      `Submit wishlist for ${club}?\n\n${ids.length} player(s)` +
        (pickedManager ? ` + manager ${pickedManager.manager_name}` : "") +
        `\n\nAdmin must approve before anyone is signed.`
    )
  ) {
    return;
  }

  setPageStatus("Submitting…");
  const { data, error } = await supabase.rpc("handpick_submit_wishlist", {
    p_club_short_name: club,
    p_player_ids: ids,
    p_manager_id: pickedManager?.manager_id ?? null,
    p_note: null,
  });

  if (error) {
    setPageStatus(error.message, true);
    return;
  }
  if (!data?.ok) {
    setPageStatus(data?.reason || "Submit failed", true);
    document.getElementById("resultBox").textContent = JSON.stringify(data, null, 2);
    return;
  }

  setPageStatus(`Submitted (#${data.submission_id}). Waiting for admin approval.`);
  document.getElementById("resultBox").textContent = JSON.stringify(data, null, 2);
  basket.clear();
  pickedManager = null;
  renderBasket();
  renderManager();
  await loadSubmissions();
}

async function loadSubmissions() {
  const box = document.getElementById("pendingBox");
  const { data, error } = await supabase.rpc("handpick_list_submissions", {
    p_status: isAdmin ? "pending" : "all",
    p_club_short_name: isAdmin ? null : activeClub,
  });

  if (error) {
    box.innerHTML = `<p class="empty">${escapeHtml(error.message)}</p>`;
    return;
  }

  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    box.innerHTML = isAdmin
      ? `<p class="empty">No pending wishlists. Owner must tag in GPDB/MGDB then click <b>Submit for approval</b> on Handpick Squad — tags alone do not create a submission.</p>`
      : `<p class="empty">No submissions yet.</p>`;
    return;
  }

  box.innerHTML = rows
    .map((s) => {
      const players = Array.isArray(s.players) ? s.players : [];
      const playerLines = players
        .map(
          (p) =>
            `${escapeHtml(p.player_name)} (${escapeHtml(p.position || "?")}) ${escapeHtml(
              formatMoney(Number(p.market_value) || 0)
            )}${p.is_fa === false ? " · not FA" : ""}`
        )
        .join("<br>");
      const adminBtns =
        isAdmin && s.status === "pending"
          ? `<div class="actions" style="margin-top:8px;">
              <button type="button" class="button appr-btn" data-id="${s.id}" data-dry="1">Preview approve</button>
              <button type="button" class="button appr-btn" data-id="${s.id}" data-dry="0" style="background:#446633;">Approve &amp; sign</button>
              <button type="button" class="button rej-btn" data-id="${s.id}">Reject</button>
            </div>`
          : "";
      return `<div style="padding:10px;border-bottom:1px solid #2a2a2a;">
        <div><b>${escapeHtml(s.club_name || s.club_short_name)}</b>
          · ${escapeHtml(s.status)}
          · ${escapeHtml(s.owner_tag || "")}
          · #${s.id}</div>
        <div class="hint">${new Date(s.submitted_at).toLocaleString()}</div>
        <div style="margin-top:6px;">${playerLines || "<span class='muted'>No players</span>"}</div>
        ${
          s.manager_id
            ? `<div style="margin-top:4px;">Manager: <b>${escapeHtml(
                s.manager_name || s.manager_id
              )}</b> · ${escapeHtml(formatMoney(Number(s.manager_market_value) || 0))}</div>`
            : ""
        }
        ${adminBtns}
        <pre class="hint" id="subOut${s.id}" style="white-space:pre-wrap;margin-top:6px;"></pre>
      </div>`;
    })
    .join("");

  box.querySelectorAll(".appr-btn").forEach((btn) => {
    btn.addEventListener("click", () =>
      approveSubmission(Number(btn.dataset.id), btn.dataset.dry === "1")
    );
  });
  box.querySelectorAll(".rej-btn").forEach((btn) => {
    btn.addEventListener("click", () => rejectSubmission(Number(btn.dataset.id)));
  });
}

async function approveSubmission(id, dryRun) {
  if (
    !dryRun &&
    !confirm(`Approve submission #${id} and sign at market value?\n\nThis spends club cash.`)
  ) {
    return;
  }
  setPageStatus(dryRun ? "Previewing…" : "Approving…");
  const { data, error } = await supabase.rpc("admin_handpick_approve_submission", {
    p_submission_id: id,
    p_dry_run: dryRun,
  });
  const out = document.getElementById(`subOut${id}`);
  if (error) {
    setPageStatus(error.message, true);
    if (out) out.textContent = error.message;
    return;
  }
  if (out) out.textContent = JSON.stringify(data, null, 2);
  setPageStatus(
    dryRun
      ? `Preview #${id}: would sign ${data?.players?.signed_count ?? "?"} player(s).`
      : `Approved #${id}.`,
    !data?.ok
  );
  if (!dryRun && data?.ok) {
    await loadContext();
    await loadSubmissions();
  } else if (dryRun) {
    /* keep preview JSON on card */
  } else {
    await loadSubmissions();
  }
}

async function rejectSubmission(id) {
  const note = window.prompt("Reject reason (optional):", "") ?? "";
  if (note === null) return;
  const { data, error } = await supabase.rpc("admin_handpick_reject_submission", {
    p_submission_id: id,
    p_review_note: note || null,
  });
  if (error) {
    setPageStatus(error.message, true);
    return;
  }
  setPageStatus(data?.ok ? `Rejected #${id}.` : data?.reason || "Reject failed", !data?.ok);
  await loadSubmissions();
}
