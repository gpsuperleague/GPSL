import { initGlobal, supabase } from "./global.js";
import { formatMoney } from "./competition.js";
import { gpdbPlayerUrl } from "./player_links.js";
import {
  loadHandpickBasketState,
  setHandpickBasketPlayer,
  clearHandpickBasket,
} from "./handpick_basket.js?v=20261031-handpick-tag";
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
import { loadSquadDesignationsState } from "./squad_designations.js";

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
/** Planned OooO player id (preview only) */
let plannedOooId = "";

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
  document.getElementById("searchBtn")?.addEventListener("click", () => runPlayerSearch());
  document.getElementById("searchQ")?.addEventListener("keydown", (e) => {
    if (e.key === "Enter") runPlayerSearch();
  });
  document.getElementById("mgrSearchBtn")?.addEventListener("click", () => runManagerSearch());
  document.getElementById("mgrSearchQ")?.addEventListener("keydown", (e) => {
    if (e.key === "Enter") runManagerSearch();
  });
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
    setPageStatus("Basket cleared.");
  });
  document.getElementById("clubSelect")?.addEventListener("change", async () => {
    activeClub = document.getElementById("clubSelect")?.value || "";
    basket.clear();
    pickedManager = null;
    plannedOooId = "";
    await loadContext();
  });
  document.getElementById("plannedOooSelect")?.addEventListener("change", (e) => {
    plannedOooId = e.target?.value || "";
    try {
      if (activeClub) {
        sessionStorage.setItem(`gpsl_handpick_ooo_${activeClub}`, plannedOooId);
      }
    } catch {
      /* ignore */
    }
    renderBuildPanel();
  });
}

async function boot() {
  const gate = document.getElementById("gateBox");
  const app = document.getElementById("handpickApp");
  const qClub = clubFromUrl();

  // Probe admin via map RPC (admin-only); owners get an error — that's fine.
  const mapRes = await supabase.rpc("admin_handpick_intake_map");
  isAdmin = !mapRes.error;

  if (isAdmin) {
    document.getElementById("clubSelectWrap").hidden = false;
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
      gate.className = "gate-box warn";
      gate.textContent =
        "No club in handpick intake. Turn Handpick on from the Season owner board first.";
      app.hidden = true;
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
  isAdmin = !!data?.is_admin;
  activeClub = String(data?.club || club || "").toUpperCase();
  activeClubName = String(data?.club_name || "").trim();

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

  fillNations(data.fa_nations || [], data.club_nation || "");
  try {
    designations = await loadSquadDesignationsState(supabase, activeClub);
  } catch (err) {
    console.warn("handpick designations", err);
    designations = null;
  }
  try {
    plannedOooId =
      sessionStorage.getItem(`gpsl_handpick_ooo_${activeClub}`) || "";
  } catch {
    plannedOooId = "";
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
  let stars = 0;
  let u21 = 0;
  let hg = 0;
  let gk = 0;
  let wages = 0;
  for (const p of players) {
    const rating = Number(
      String(p.Rating ?? p.rating ?? "").replace(/[^\d.]/g, "")
    );
    if (Number.isFinite(rating) && rating >= starMin) stars += 1;
    if (isUnder21(p)) u21 += 1;
    if (isHomeGrownPlayer(p, clubNation)) hg += 1;
    if (isGoalkeeper(p)) gk += 1;
    wages += Number(p.contract_wage) || 0;
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
      <div class="stat ${starCls}"><div class="lbl">Stars</div><div class="val">${counts.stars}</div><div class="lim">cap ${starCap} (≥${starMin})</div></div>
      <div class="stat ${u21Cls}"><div class="lbl">U21</div><div class="val">${counts.u21}</div><div class="lim">min ${minU21}</div></div>
      <div class="stat ${hgCls}"><div class="lbl">Home grown</div><div class="val">${counts.hg}</div><div class="lim">min ${minHg}${clubNation ? ` · ${escapeHtml(clubNation)}` : ""}</div></div>
      <div class="stat ${gkCls}"><div class="lbl">GK</div><div class="val">${counts.gk}</div><div class="lim">min ${minGk}</div></div>`;
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
      <div class="finance-row"><span>Est. catalogue wages</span><b>${escapeHtml(formatMoney(counts.wages))}</b></div>
      <div class="finance-row ${after < 0 ? "neg" : "pos"}"><span>Balance after signings</span><b>${escapeHtml(formatMoney(after))}</b></div>
      <p class="hint" style="margin-top:8px;">Wages are catalogue estimates — final wages apply when admin approves. Tagged players also appear as ghosts on Squad.</p>`;
  }

  const oooSel = document.getElementById("plannedOooSelect");
  if (oooSel) {
    const hgEligible = players.filter((p) => isHomeGrownPlayer(p, clubNation));
    const opts = [`<option value="">— none yet —</option>`].concat(
      hgEligible.map((p) => {
        const id = String(p.Konami_ID || "");
        const mark = p.from_basket ? " (wishlist)" : "";
        return `<option value="${escapeHtml(id)}"${
          id && id === plannedOooId ? " selected" : ""
        }>${escapeHtml(p.Name || id)}${mark}</option>`;
      })
    );
    oooSel.innerHTML = opts.join("");
    if (plannedOooId && ![...oooSel.options].some((o) => o.value === plannedOooId)) {
      plannedOooId = "";
    }
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
  } catch (err) {
    console.warn("hydrateBasketFromDb", err);
  }
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
    btn.addEventListener("click", () => {
      const id = btn.getAttribute("data-id");
      const row = rows.find((r) => String(r.manager_id) === id);
      if (!row) return;
      pickedManager = row;
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
  document.getElementById("clearMgrBtn")?.addEventListener("click", () => {
    pickedManager = null;
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
  for (const r of rows) {
    const mv = Number(r.market_value) || 0;
    fees += mv;
    tax += Math.round(((mv * taxPct()) / 100) * 100) / 100;
  }
  const mgrFee = pickedManager ? Number(pickedManager.market_value) || 0 : 0;

  box.innerHTML = rows.length
    ? `<table class="sign-table"><thead><tr>
        <th>Player</th><th>Pos</th><th class="num">OVR</th><th class="num">MV</th><th class="num">Est.</th><th></th>
      </tr></thead><tbody>
      ${rows
        .map((r) => {
          const id = String(r.player_id);
          const mv = Number(r.market_value) || 0;
          return `<tr>
            <td><a href="${escapeHtml(gpdbPlayerUrl(id))}" target="_blank" rel="noopener" style="color:#e8c84a;">${escapeHtml(
              r.player_name
            )}</a></td>
            <td>${escapeHtml(r.position || "—")}</td>
            <td class="num">${r.rating ?? "—"}</td>
            <td class="num">${escapeHtml(formatMoney(mv))}</td>
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
        ? ` · manager <b>${escapeHtml(formatMoney(mgrFee))}</b>`
        : ""
    }
    · est. total <b>${escapeHtml(formatMoney(fees + tax + mgrFee))}</b>
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
    box.innerHTML = `<p class="empty">No submissions.</p>`;
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
