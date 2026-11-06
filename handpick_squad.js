import { initGlobal, supabase } from "./global.js";
import { formatMoney, leagueTierForDivision } from "./competition.js";
import { gpdbPlayerUrl } from "./player_links.js";
import {
  loadHandpickBasketState,
  setHandpickBasketPlayer,
  setHandpickManager,
  clearHandpickBasket,
} from "./handpick_basket.js?v=20261106-exclusive-tag";
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
import { stadiumImageUrl } from "./stadium_images.js";
import {
  applyClubDashboardTheme,
  loadClubDashboardTheme,
} from "./club_theme_common.js?v=20261104-hp-theme";

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
/** @type {string} Owner Discord tag / display name for admin chrome */
let activeOwnerTag = "";
/** @type {object|null} */
let designations = null;
/** Planned OooO player id (preview only) — sticky in localStorage per club */
let plannedOooId = "";
/** @type {{ superleague: number, championship: number }} */
let wagePctSettings = { superleague: 5, championship: 4 };
/** @type {'superleague'|'championship'} */
let wageTier = "championship";
let adminApprovalsScrolled = false;
/** @type {"admin"|"owner"} Admin UI tab — owners never use tabs. */
let adminUiTab = "admin";

function readAdminTabFromUrl() {
  const v = String(new URLSearchParams(window.location.search).get("view") || "")
    .trim()
    .toLowerCase();
  return v === "owner" ? "owner" : "admin";
}

function setAdminUiTab(tab, { updateUrl = true } = {}) {
  adminUiTab = tab === "owner" ? "owner" : "admin";
  document.body.classList.toggle("hp-tab-admin", isAdmin && adminUiTab === "admin");
  document.body.classList.toggle("hp-tab-owner", isAdmin && adminUiTab === "owner");

  const btnAdmin = document.getElementById("hpTabAdmin");
  const btnOwner = document.getElementById("hpTabOwner");
  if (btnAdmin) {
    btnAdmin.classList.toggle("is-active", adminUiTab === "admin");
    btnAdmin.setAttribute("aria-selected", adminUiTab === "admin" ? "true" : "false");
  }
  if (btnOwner) {
    btnOwner.classList.toggle("is-active", adminUiTab === "owner");
    btnOwner.setAttribute("aria-selected", adminUiTab === "owner" ? "true" : "false");
  }

  const hint = document.getElementById("hpTabHint");
  if (hint) {
    hint.innerHTML =
      adminUiTab === "owner"
        ? `Previewing the <b>owner handpick page</b> for the selected club (checklist, basket, GPDB/MGDB). Switch back to <b>Admin approvals</b> to sign wishlists.`
        : `Approve pending wishlists here. Switch to <b>Owner view</b> to see the selected club’s handpick UI.`;
  }

  const previewBanner = document.getElementById("ownerPreviewBanner");
  if (previewBanner) previewBanner.hidden = !(isAdmin && adminUiTab === "owner");

  if (isAdmin && updateUrl) {
    try {
      const url = new URL(window.location.href);
      if (adminUiTab === "owner") url.searchParams.set("view", "owner");
      else url.searchParams.delete("view");
      history.replaceState({}, "", url);
    } catch {
      /* ignore */
    }
  }
}

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
    const url = new URL(window.location.href);
    if (activeClub) url.searchParams.set("club", activeClub);
    else url.searchParams.delete("club");
    history.replaceState({}, "", url);
    await loadContext();
  });
  document.getElementById("hpTabAdmin")?.addEventListener("click", () => {
    if (!isAdmin) return;
    setAdminUiTab("admin");
    void loadSubmissions();
  });
  document.getElementById("hpTabOwner")?.addEventListener("click", () => {
    if (!isAdmin) return;
    setAdminUiTab("owner");
    void (async () => {
      if (activeClub) {
        await hydrateBasketFromDb();
        renderBasket();
        renderManager();
        renderBuildPanel();
      }
      await loadSubmissions();
    })();
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
    document.body.classList.add("hp-admin-mode");
    const chrome = document.getElementById("adminChrome");
    if (chrome) chrome.hidden = false;
    const adminBanner = document.getElementById("adminBanner");
    if (adminBanner) adminBanner.hidden = false;
    const adminSection = document.getElementById("adminApprovalsSection");
    if (adminSection) adminSection.hidden = false;
    const pageH1 = document.querySelector(".hp-wrap > h1");
    if (pageH1) pageH1.textContent = "Handpick (admin)";
    setAdminUiTab(readAdminTabFromUrl(), { updateUrl: false });
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
      setAdminUiTab("admin");
      gate.className = "gate-box warn";
      gate.textContent =
        "No club in handpick intake right now — pending approvals (if any) still listed below. Turn Handpick on from the Season owner board to preview a club.";
      app.hidden = false;
      await loadSubmissions();
      return;
    }
  } else {
    // Owners: single page only — never show admin chrome/tabs
    document.body.classList.remove("hp-admin-mode", "hp-tab-admin", "hp-tab-owner");
    const chrome = document.getElementById("adminChrome");
    if (chrome) chrome.hidden = true;
    const adminBanner = document.getElementById("adminBanner");
    if (adminBanner) adminBanner.hidden = true;
    const adminSection = document.getElementById("adminApprovalsSection");
    if (adminSection) adminSection.hidden = true;
    const previewBanner = document.getElementById("ownerPreviewBanner");
    if (previewBanner) previewBanner.hidden = true;
    // Owner: prefer ?club= from claim redirect, else RPC resolves my_club
    activeClub = qClub || "";
  }

  await loadContext();
}

function clubHasOwner(c) {
  if (!c || typeof c !== "object") return false;
  if (c.owner_id) return true;
  const tag = String(c.owner ?? "").trim();
  return !!tag;
}

function setAdminOwnerLine(ownerTag, { vacant = false } = {}) {
  const el = document.getElementById("adminOwnerLine");
  if (!el) return;
  if (!isAdmin) {
    el.hidden = true;
    return;
  }
  el.hidden = false;
  const tag = String(ownerTag || "").trim();
  if (vacant || !tag) {
    el.innerHTML = `Owner: <span class="vacant">vacant — no owner assigned</span>`;
    return;
  }
  el.innerHTML = `Owner: <span>${escapeHtml(tag)}</span> <span class="muted">· selected club</span>`;
}

async function renderClubHero(clubShort, { clubName = "", nation = "", ownerTag = "" } = {}) {
  const club = String(clubShort || "").trim().toUpperCase();
  const titleEl = document.getElementById("clubTitle");
  const codeEl = document.getElementById("clubCodeLine");
  const metaEl = document.getElementById("clubMeta");
  const badgeEl = document.getElementById("clubBadge");
  const stadiumWrap = document.getElementById("clubStadiumWrap");

  const displayName = clubName || club || "—";
  if (titleEl) titleEl.textContent = displayName;
  if (codeEl) codeEl.textContent = club ? club : "";

  let stadiumName = "";
  let capacity = null;
  if (club) {
    try {
      const { data: row } = await supabase
        .from("Clubs")
        .select("Stadium, Capacity, Nation, Club")
        .eq("ShortName", club)
        .maybeSingle();
      if (row?.Club && titleEl && !clubName) titleEl.textContent = row.Club;
      stadiumName = String(row?.Stadium || "").trim();
      const cap = Number(row?.Capacity);
      capacity = Number.isFinite(cap) && cap > 0 ? cap : null;
      if (!nation) nation = String(row?.Nation || "").trim();
    } catch (err) {
      console.warn("renderClubHero club row", err);
    }
  }

  const metaBits = [];
  if (nation) metaBits.push(`<b>Nation</b> ${escapeHtml(nation)}`);
  if (stadiumName) metaBits.push(`<b>Stadium</b> ${escapeHtml(stadiumName)}`);
  if (capacity != null) {
    metaBits.push(`<b>Capacity</b> ${escapeHtml(capacity.toLocaleString("en-GB"))}`);
  }
  if (isAdmin) {
    metaBits.push(
      ownerTag
        ? `<b>Owner</b> ${escapeHtml(ownerTag)}`
        : `<b>Owner</b> vacant`
    );
  }
  if (metaEl) metaEl.innerHTML = metaBits.join(" · ") || "—";

  if (badgeEl) {
    if (club) {
      badgeEl.hidden = false;
      badgeEl.alt = `${displayName} badge`;
      badgeEl.src = `images/club_badges/${encodeURIComponent(club)}.png`;
      badgeEl.onerror = () => {
        badgeEl.hidden = true;
      };
    } else {
      badgeEl.hidden = true;
    }
  }

  if (stadiumWrap) {
    const src = club ? stadiumImageUrl(club) : null;
    if (src) {
      stadiumWrap.classList.remove("is-missing");
      stadiumWrap.innerHTML = `<img src="${escapeHtml(src)}" alt="${escapeHtml(
        stadiumName || displayName + " stadium"
      )}" loading="lazy"><div class="cap">${escapeHtml(
        stadiumName || "Stadium"
      )}${capacity != null ? ` · ${capacity.toLocaleString("en-GB")}` : ""}</div>`;
      const img = stadiumWrap.querySelector("img");
      if (img) {
        img.onerror = () => {
          stadiumWrap.classList.add("is-missing");
          stadiumWrap.textContent = stadiumName
            ? `${stadiumName}${capacity != null ? ` · ${capacity.toLocaleString("en-GB")}` : ""}`
            : "Stadium photo unavailable";
        };
      }
    } else {
      stadiumWrap.classList.add("is-missing");
      stadiumWrap.textContent = "Stadium photo";
    }
  }
}

async function loadClubOwnerTag(clubShort) {
  const club = String(clubShort || "").trim().toUpperCase();
  if (!club) {
    activeOwnerTag = "";
    return "";
  }
  try {
    const { data: clubRow } = await supabase
      .from("Clubs")
      .select("owner, owner_id")
      .eq("ShortName", club)
      .maybeSingle();
    let tag = String(clubRow?.owner || "").trim();
    const oid = clubRow?.owner_id || null;
    if (!tag && oid) {
      const { data: reg } = await supabase
        .from("gpsl_owner_registry")
        .select("owner_tag")
        .eq("owner_id", oid)
        .maybeSingle();
      tag = String(reg?.owner_tag || "").trim();
    }
    activeOwnerTag = tag;
    return tag;
  } catch (err) {
    console.warn("loadClubOwnerTag", err);
    activeOwnerTag = "";
    return "";
  }
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
    .select("ShortName, Club, owner, owner_id")
    .in("ShortName", keys)
    .order("Club");
  const rows = Array.isArray(clubs) ? clubs : keys.map((k) => ({ ShortName: k, Club: k }));
  // Vacant first, then owned — easier for handpick admin triage
  rows.sort((a, b) => {
    const av = clubHasOwner(a) ? 1 : 0;
    const bv = clubHasOwner(b) ? 1 : 0;
    if (av !== bv) return av - bv;
    return String(a.Club || a.ShortName).localeCompare(String(b.Club || b.ShortName), undefined, {
      sensitivity: "base",
    });
  });
  sel.innerHTML = rows
    .map((c) => {
      const vacant = !clubHasOwner(c);
      const label = vacant
        ? `○ ${c.Club || c.ShortName} (${c.ShortName}) — vacant`
        : `${c.Club || c.ShortName} (${c.ShortName})`;
      const style = vacant ? ' style="color:#f0a060;font-weight:600;"' : ' style="color:#c8c8c8;"';
      const cls = vacant ? ' class="hp-club-vacant"' : ' class="hp-club-owned"';
      return `<option value="${escapeHtml(c.ShortName)}"${cls}${style}>${escapeHtml(label)}</option>`;
    })
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

  document.body.classList.toggle("hp-admin-mode", !!isAdmin);
  const chrome = document.getElementById("adminChrome");
  if (chrome) chrome.hidden = !isAdmin;
  const adminBanner = document.getElementById("adminBanner");
  if (adminBanner) adminBanner.hidden = !isAdmin;
  const adminSection = document.getElementById("adminApprovalsSection");
  if (adminSection) adminSection.hidden = !isAdmin;
  if (isAdmin) {
    setAdminUiTab(adminUiTab || readAdminTabFromUrl(), { updateUrl: false });
  } else {
    document.body.classList.remove("hp-tab-admin", "hp-tab-owner");
    const previewBanner = document.getElementById("ownerPreviewBanner");
    if (previewBanner) previewBanner.hidden = true;
  }
  const subTitle = document.getElementById("submissionsTitle");
  if (subTitle) subTitle.textContent = "Submissions";
  const subHint = document.getElementById("submissionsHint");
  if (subHint) {
    subHint.textContent = isAdmin
      ? "Wishlists submitted for this club (owner view)."
      : "Your submitted wishlists for this club.";
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

  const ownerTag = isAdmin ? await loadClubOwnerTag(activeClub) : "";
  setAdminOwnerLine(ownerTag, { vacant: !ownerTag });

  const clubLabel = activeClubName
    ? `${activeClubName} (${activeClub})`
    : activeClub || "—";
  const ownerLabel = ownerTag || "vacant";

  await renderClubHero(activeClub, {
    clubName: activeClubName,
    nation: data?.club_nation || "",
    ownerTag: isAdmin ? ownerTag : "",
  });

  const gpdb = document.getElementById("gpdbLink");
  if (gpdb) {
    gpdb.href = "GPDB.html";
    gpdb.textContent = "Open GPDB — tag players";
  }
  const mgdbHref = activeClub
    ? `MGDB.html?club=${encodeURIComponent(activeClub)}`
    : "MGDB.html";
  const mgdb = document.getElementById("mgdbLink");
  if (mgdb) {
    mgdb.href = mgdbHref;
    mgdb.textContent = "Open MGDB — tag manager";
  }
  const mgdbInline = document.getElementById("mgdbLinkInline");
  if (mgdbInline) mgdbInline.href = mgdbHref;

  const finances = document.getElementById("financesLink");
  if (finances) {
    finances.href = activeClub
      ? `finances.html?club=${encodeURIComponent(activeClub)}`
      : "finances.html";
    finances.textContent = "Club Finances";
  }
  const squad = document.getElementById("squadLink");
  if (squad) {
    squad.href = activeClub
      ? `squad.html?club=${encodeURIComponent(activeClub)}`
      : "squad.html";
    squad.textContent = "Current squad";
  }
  const handbook = document.getElementById("handbookLink");
  if (handbook) {
    handbook.href = "learning_gpsl.html";
    handbook.textContent = "GPSL Handbook";
  }

  try {
    const theme = await loadClubDashboardTheme(supabase, activeClub);
    applyClubDashboardTheme(theme, { pageKey: "handpick_squad" });
  } catch (themeErr) {
    console.warn("handpick club theme", themeErr);
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
    gate.innerHTML = `Club <b>${escapeHtml(clubLabel)}</b> · owner <b>${escapeHtml(
      ownerLabel
    )}</b> is not in handpick intake. Enable it on the Season owner board before approving wishlists.`;
  } else if (isAdmin) {
    gate.className = "gate-box ok";
    gate.innerHTML = `<b>Admin review</b> for <b>${escapeHtml(
      clubLabel
    )}</b> · owner <b>${escapeHtml(ownerLabel)}</b> · balance ${escapeHtml(
      formatMoney(Number(data.balance) || 0)
    )} · tax ${escapeHtml(
      String(data.income_tax_pct ?? 0)
    )}% · use <b>Pending approvals</b> / <b>Owner view</b> (you are not claiming this club).`;
  } else {
    gate.className = "gate-box ok";
    gate.innerHTML = `Handpick open for <b>${escapeHtml(clubLabel)}</b> · balance ${escapeHtml(
      formatMoney(Number(data.balance) || 0)
    )} (mid-season takeover: starting balance − Club takeover Fee) · tax ${escapeHtml(
      String(data.income_tax_pct ?? 0)
    )}%`;
  }

  app.hidden = false;

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

/** Max star-rated players that may be tagged in the handpick basket at once. */
const HANDPICK_STAR_TAG_CAP = 3;
/** Lowest allowed projected cash after wishlist fees + tax. */
const HANDPICK_OVERDRAFT_FLOOR = -50_000_000;

function playerIsStarRated(p, starMin) {
  const rating = Number(
    String(p?.Rating ?? p?.rating ?? "").replace(/[^\d.]/g, "")
  );
  return Number.isFinite(rating) && rating >= starMin;
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
    // Same as scouting: planned OooO does not count toward the star cap
    if (playerIsStarRated(p, starMin) && !(ooo && id === ooo)) {
      stars += 1;
    }
    if (isUnder21(p)) u21 += 1;
    if (isHomeGrownPlayer(p, clubNation)) hg += 1;
    if (isGoalkeeper(p)) gk += 1;
    wages += playerSeasonWage(p);
  }
  return { total: players.length, stars, u21, hg, gk, wages };
}

function countBasketStarsOnly() {
  const starMin = Number(designations?.star_min_rating ?? clubContext?.star_min_rating ?? 79);
  let n = 0;
  for (const p of basket.values()) {
    if (playerIsStarRated(p, starMin)) n += 1;
  }
  return n;
}

function wishlistFinance() {
  const balance = Number(clubContext?.balance) || 0;
  const taxRate = taxPct();
  let fees = 0;
  for (const p of basket.values()) fees += Number(p.market_value) || 0;
  const mgrFee = pickedManager ? Number(pickedManager.market_value) || 0 : 0;
  const tax = Math.round(((fees + mgrFee) * taxRate) / 100 * 100) / 100;
  const totalCost = fees + mgrFee + tax;
  const after = balance - totalCost;
  return {
    balance,
    taxRate,
    fees: fees + mgrFee,
    tax,
    totalCost,
    after,
    withinOverdraft: after >= HANDPICK_OVERDRAFT_FLOOR,
  };
}

function handpickHardBlocks(counts, fin) {
  const starTagCap = HANDPICK_STAR_TAG_CAP;
  const basketStars = countBasketStarsOnly();
  const maxSquad = Number(clubContext?.max_squad_size) || SQUAD_SIZE;
  const blocks = [];
  if (basketStars > starTagCap) {
    blocks.push(`Too many stars tagged (${basketStars}/${starTagCap}). Untag a star.`);
  }
  if (counts.total > maxSquad) {
    blocks.push(`Squad over max (${counts.total}/${maxSquad}).`);
  }
  if (!fin.withinOverdraft) {
    blocks.push(
      `More than ₿50m overdrawn after fees+tax (${formatMoney(fin.after)}). Untag or pick cheaper.`
    );
  }
  return blocks;
}

function renderBuildPanel() {
  const players = projectedSquadPlayers();
  const counts = countProjected(players);
  const regStarCap = Number(designations?.star_cap ?? clubContext?.star_cap ?? 2);
  const starTagCap = HANDPICK_STAR_TAG_CAP;
  const starMin = Number(designations?.star_min_rating ?? clubContext?.star_min_rating ?? 79);
  const basketStars = countBasketStarsOnly();
  const minHg = Number(clubContext?.min_home_grown) || MIN_HOME_GROWN;
  const minU21 = Number(clubContext?.min_under_21) || MIN_UNDER_21;
  const minGk = Number(clubContext?.min_goalkeepers) || MIN_GOALKEEPERS;
  const minSquad = Number(clubContext?.min_squad_size) || MIN_SQUAD_SIZE;
  const maxSquad = Number(clubContext?.max_squad_size) || SQUAD_SIZE;
  const clubNation = clubContext?.club_nation || "";
  const fin = wishlistFinance();
  const hardBlocks = handpickHardBlocks(counts, fin);

  const squadCls =
    counts.total > maxSquad ? "bad" : counts.total >= minSquad ? "ok" : "warn";
  const tagStarCls =
    basketStars > starTagCap ? "bad" : basketStars === starTagCap ? "warn" : "ok";
  const regStarCls = counts.stars > regStarCap ? "bad" : counts.stars === regStarCap ? "warn" : "ok";
  const u21Cls = counts.u21 >= minU21 ? "ok" : "warn";
  const hgCls = counts.hg >= minHg ? "ok" : "warn";
  const gkCls = counts.gk >= minGk ? "ok" : "warn";
  const mgrCls = pickedManager ? "ok" : "warn";
  const odCls = fin.withinOverdraft ? (fin.after < 0 ? "warn" : "ok") : "bad";

  const checklist = document.getElementById("checklistBox");
  if (checklist) {
    const row = (cls, mark, title, sub) =>
      `<li class="${cls}"><span class="mark">${mark}</span><span class="body"><b>${title}</b><span class="sub">${sub}</span></span></li>`;
    checklist.innerHTML = [
      row(
        squadCls,
        squadCls === "ok" ? "Met" : squadCls === "bad" ? "Over" : "Need",
        `Squad size ${counts.total}`,
        `Aim for ${minSquad}–${maxSquad} players once approved.`
      ),
      row(
        tagStarCls,
        tagStarCls === "ok" ? "Ok" : tagStarCls === "bad" ? "Over" : "At cap",
        `Stars tagged ${basketStars} / ${starTagCap}`,
        `Handpick wishlist max ${starTagCap} players rated ≥${starMin}. Extra tags are blocked.`
      ),
      row(
        regStarCls,
        regStarCls === "ok" ? "Ok" : "Over",
        `Registration stars ${counts.stars} / ${regStarCap}`,
        plannedOooId
          ? `After approval, star cap is ${regStarCap} (planned OooO excluded from the count).`
          : `After approval, star cap is ${regStarCap}. Pick a home-grown ★ as OooO to excuse one.`
      ),
      row(
        hgCls,
        hgCls === "ok" ? "Met" : "Need",
        `Home grown ${counts.hg} / ${minHg}`,
        clubNation
          ? `Need ≥${minHg} ${escapeHtml(clubNation)} nationals.`
          : `Need ≥${minHg} home-grown players.`
      ),
      row(
        u21Cls,
        u21Cls === "ok" ? "Met" : "Need",
        `Under-21 ${counts.u21} / ${minU21}`,
        `Need ≥${minU21} players aged 21 or younger.`
      ),
      row(
        gkCls,
        gkCls === "ok" ? "Met" : "Need",
        `Goalkeepers ${counts.gk} / ${minGk}`,
        `Need ≥${minGk} GK.`
      ),
      row(
        mgrCls,
        mgrCls === "ok" ? "Met" : "Need",
        pickedManager
          ? `Manager: ${escapeHtml(pickedManager.manager_name || "#" + pickedManager.manager_id)}`
          : "Manager not tagged",
        "Tag one free-agent manager in MGDB before submit (recommended)."
      ),
      row(
        odCls,
        odCls === "ok" ? "Ok" : odCls === "bad" ? "Blocked" : "Overdraft",
        `Cash after wishlist ${escapeHtml(formatMoney(fin.after))}`,
        `Fees + tax vs club balance. Hard floor ${escapeHtml(
          formatMoney(HANDPICK_OVERDRAFT_FLOOR)
        )} — cannot tag or submit deeper.`
      ),
    ].join("");
  }

  const limits = document.getElementById("limitsBox");
  if (limits) {
    limits.innerHTML = `
      <div class="stat ${squadCls}"><div class="lbl">Squad</div><div class="val">${counts.total}</div><div class="lim">min ${minSquad} · max ${maxSquad}</div></div>
      <div class="stat ${tagStarCls}"><div class="lbl">Stars tagged</div><div class="val">${basketStars}</div><div class="lim">wishlist max ${starTagCap} (≥${starMin})</div></div>
      <div class="stat ${regStarCls}"><div class="lbl">Reg. stars</div><div class="val">${counts.stars}</div><div class="lim">cap ${regStarCap}${plannedOooId ? " · OooO out" : ""}</div></div>
      <div class="stat ${u21Cls}"><div class="lbl">U21</div><div class="val">${counts.u21}</div><div class="lim">min ${minU21}</div></div>
      <div class="stat ${hgCls}"><div class="lbl">Home grown</div><div class="val">${counts.hg}</div><div class="lim">min ${minHg}${clubNation ? ` · ${escapeHtml(clubNation)}` : ""}</div></div>
      <div class="stat ${gkCls}"><div class="lbl">GK</div><div class="val">${counts.gk}</div><div class="lim">min ${minGk}</div></div>
      <div class="stat ok"><div class="lbl">Wages</div><div class="val" style="font-size:14px;">${escapeHtml(formatMoney(counts.wages))}</div><div class="lim">est. season</div></div>`;
  }

  const finance = document.getElementById("financeBox");
  if (finance) {
    finance.innerHTML = `
      <div class="finance-row"><span>Balance</span><b>${escapeHtml(formatMoney(fin.balance))}</b></div>
      <div class="finance-row"><span>Wishlist fees</span><b>${escapeHtml(formatMoney(fin.fees))}</b></div>
      <div class="finance-row"><span>Est. income tax (${fin.taxRate}%)</span><b>${escapeHtml(formatMoney(fin.tax))}</b></div>
      <div class="finance-row"><span>Est. season wages (${wageTier === "superleague" ? "SL" : "Champ"} %)</span><b>${escapeHtml(formatMoney(counts.wages))}</b></div>
      <div class="finance-row ${fin.after < 0 ? "neg" : "pos"}"><span>Balance after signings</span><b>${escapeHtml(formatMoney(fin.after))}</b></div>
      <div class="finance-row ${fin.withinOverdraft ? "pos" : "neg"}"><span>Overdraft floor</span><b>${escapeHtml(formatMoney(HANDPICK_OVERDRAFT_FLOOR))}</b></div>
      <p class="hint" style="margin-top:8px;">Wage = stored contract wage when set, otherwise ${wageTier === "superleague" ? "SuperLeague" : "Championship"} % of MV. Final wages apply when admin approves. Tagged players also appear as ghosts on Squad.${
        hardBlocks.length
          ? ` <b style="color:#f88;">Blocked:</b> ${escapeHtml(hardBlocks.join(" "))}`
          : ""
      }</p>`;
  }

  const submitBtn = document.getElementById("submitBtn");
  if (submitBtn) {
    const empty = basket.size === 0 && !pickedManager;
    submitBtn.disabled = empty || hardBlocks.length > 0;
    submitBtn.title = empty
      ? "Tag at least one player or a manager first"
      : hardBlocks.length
        ? hardBlocks.join(" ")
        : "Submit wishlist for admin approval";
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
      const held = !!r.held_by_other && !inBasket;
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
          inBasket || held ? "disabled" : ""
        } title="${
          held
            ? "Another handpick club has this player tagged"
            : ""
        }">${inBasket ? "Added" : held ? "Held" : "Add"}</button></td>
      </tr>`;
    })
    .join("")}
  </tbody></table>`;

  box.querySelectorAll(".add-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = btn.getAttribute("data-id");
      const row = rows.find((r) => String(r.player_id) === id);
      if (!row) return;
      const starMin = Number(
        designations?.star_min_rating ?? clubContext?.star_min_rating ?? 79
      );
      if (
        playerIsStarRated(row, starMin) &&
        countBasketStarsOnly() >= HANDPICK_STAR_TAG_CAP
      ) {
        setPageStatus(
          `Handpick allows at most ${HANDPICK_STAR_TAG_CAP} star players (≥${starMin}) tagged at once. Untag a star first.`,
          true
        );
        return;
      }
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
    p_club_short_name: activeClub,
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
      const held = !!r.held_by_other && !selected;
      return `<tr>
        <td>${escapeHtml(r.manager_name)}</td>
        <td>${escapeHtml(r.nation || "—")}</td>
        <td class="num">${r.rating ?? "—"}</td>
        <td class="num">${escapeHtml(formatMoney(Number(r.market_value) || 0))}</td>
        <td><button type="button" class="button mgr-btn" data-id="${escapeHtml(id)}" ${
          held ? "disabled" : ""
        } title="${
          held ? "Another handpick club has this manager tagged" : ""
        }">${selected ? "Selected" : held ? "Held" : "Select"}</button></td>
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
  const counts = countProjected(projectedSquadPlayers());
  const fin = wishlistFinance();
  const hardBlocks = handpickHardBlocks(counts, fin);
  if (hardBlocks.length) {
    setPageStatus(hardBlocks[0], true);
    return;
  }
  const soft = [];
  const minHg = Number(clubContext?.min_home_grown) || MIN_HOME_GROWN;
  const minU21 = Number(clubContext?.min_under_21) || MIN_UNDER_21;
  const minGk = Number(clubContext?.min_goalkeepers) || MIN_GOALKEEPERS;
  const minSquad = Number(clubContext?.min_squad_size) || MIN_SQUAD_SIZE;
  if (counts.total < minSquad) soft.push(`squad ${counts.total}/${minSquad}`);
  if (counts.hg < minHg) soft.push(`HG ${counts.hg}/${minHg}`);
  if (counts.u21 < minU21) soft.push(`U21 ${counts.u21}/${minU21}`);
  if (counts.gk < minGk) soft.push(`GK ${counts.gk}/${minGk}`);
  if (!pickedManager) soft.push("no manager");
  const softNote = soft.length
    ? `\n\nStill short of expectations: ${soft.join(", ")}.\nYou can still submit — admin may reject incomplete wishlists.`
    : "";
  if (
    !confirm(
      `Submit wishlist for ${club}?\n\n${ids.length} player(s)` +
        (pickedManager ? ` + manager ${pickedManager.manager_name}` : "") +
        `\nProjected cash after fees+tax: ${formatMoney(fin.after)}` +
        softNote +
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
    setPageStatus(data?.detail || data?.reason || "Submit failed", true);
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

/** Usual pitch order (Match Day / Squad style). */
const HANDPICK_POSITION_ORDER = [
  "GK",
  "LB",
  "LWB",
  "CB",
  "RB",
  "RWB",
  "DMF",
  "LMF",
  "CMF",
  "RMF",
  "AMF",
  "LWF",
  "LW",
  "SS",
  "RWF",
  "RW",
  "CF",
];

function normalizePosCode(position) {
  return String(position || "").trim().toUpperCase();
}

function positionSortIndex(position) {
  const i = HANDPICK_POSITION_ORDER.indexOf(normalizePosCode(position));
  return i >= 0 ? i : 999;
}

function positionBand(position) {
  const p = normalizePosCode(position);
  if (p === "GK") return "GK";
  if (["LB", "LWB", "CB", "RB", "RWB"].includes(p)) return "DEF";
  if (["DMF", "LMF", "CMF", "RMF", "AMF"].includes(p)) return "MID";
  if (["LWF", "LW", "SS", "RWF", "RW", "CF"].includes(p)) return "FWD";
  return "OTHER";
}

function sortPlayersByPosition(players) {
  return [...players].sort((a, b) => {
    const d = positionSortIndex(a.position) - positionSortIndex(b.position);
    if (d) return d;
    const ra = Number(String(a.rating ?? "").replace(/[^\d.]/g, "")) || 0;
    const rb = Number(String(b.rating ?? "").replace(/[^\d.]/g, "")) || 0;
    if (rb !== ra) return rb - ra;
    return String(a.player_name || "").localeCompare(String(b.player_name || ""), undefined, {
      sensitivity: "base",
    });
  });
}

function formatWishlistPlayerLine(p) {
  return `${escapeHtml(p.player_name)} (${escapeHtml(p.position || "?")}) · OVR ${escapeHtml(
    String(p.rating ?? "—")
  )} · ${escapeHtml(formatMoney(Number(p.market_value) || 0))}${
    p.is_fa === false ? " · <span style='color:#f88'>not FA</span>" : ""
  }`;
}

function renderGroupedWishlistPlayers(players) {
  const sorted = sortPlayersByPosition(players);
  if (!sorted.length) return "<span class='empty'>No players</span>";
  const bandOrder = ["GK", "DEF", "MID", "FWD", "OTHER"];
  const bandLabels = {
    GK: "Goalkeepers",
    DEF: "Defenders",
    MID: "Midfielders",
    FWD: "Forwards",
    OTHER: "Other",
  };
  const chunks = [];
  for (const band of bandOrder) {
    const group = sorted.filter((p) => positionBand(p.position) === band);
    if (!group.length) continue;
    chunks.push(
      `<div class="hp-pos-band"><div class="hp-pos-band-label">${bandLabels[band]} (${group.length})</div>${group
        .map((p) => `<div class="hp-pos-line">${formatWishlistPlayerLine(p)}</div>`)
        .join("")}</div>`
    );
  }
  return chunks.join("");
}

function renderAdminEmptyGhost() {
  return `<article class="hp-approve-card is-ghost" aria-disabled="true">
    <div class="hp-approve-head">
      <div>
        <p class="hp-approve-title">Club name (CODE)</p>
        <div class="hp-approve-meta">Pending · owner — · submission #— · waiting for owner submit</div>
      </div>
      <div class="hp-approve-actions">
        <button type="button" class="button appr-go is-ghost" disabled tabindex="-1">Approve &amp; sign</button>
        <button type="button" class="button appr-preview is-ghost" disabled tabindex="-1">Preview</button>
        <button type="button" class="button rej-btn is-ghost" disabled tabindex="-1">Reject</button>
      </div>
    </div>
    <div class="hp-approve-summary">
      <span>Players <b>—</b></span>
      <span>Fees <b>—</b></span>
      <span>Est. tax <b>—</b></span>
      <span>Manager <b>—</b></span>
      <span>Est. total <b>—</b></span>
    </div>
    <p class="hint" style="margin:8px 0 0;">
      No pending wishlists yet. When an owner clicks <b>Submit for approval</b>, a live card appears here with these actions at the top.
      Tags alone are not a submission.
    </p>
  </article>`;
}

function renderSubmissionCards(rows, { adminLayout }) {
  return rows
    .map((s) => {
      const players = sortPlayersByPosition(
        Array.isArray(s.players) ? s.players : []
      );
      let fees = 0;
      for (const p of players) fees += Number(p.market_value) || 0;
      const mgrFee = Number(s.manager_market_value) || 0;
      const tax = Math.round((((fees + mgrFee) * taxPct()) / 100) * 100) / 100;
      const playerLines = adminLayout
        ? renderGroupedWishlistPlayers(players)
        : players.map((p) => formatWishlistPlayerLine(p)).join("<br>");

      if (adminLayout && s.status === "pending") {
        const ids = (Array.isArray(s.player_ids) ? s.player_ids : players.map((p) => p.player_id))
          .map((x) => String(x || "").trim())
          .filter(Boolean);
        return `<article class="hp-approve-card" data-sub-id="${s.id}"
          data-club="${escapeHtml(s.club_short_name || "")}"
          data-manager-id="${s.manager_id != null ? escapeHtml(String(s.manager_id)) : ""}"
          data-player-ids="${escapeHtml(ids.join(","))}">
          <div class="hp-approve-head">
            <div>
              <p class="hp-approve-title">${escapeHtml(s.club_name || s.club_short_name)} (${escapeHtml(
                s.club_short_name || ""
              )})</p>
              <div class="hp-approve-meta">
                Pending · owner ${escapeHtml(s.owner_tag || "—")} · submission #${s.id}
                · ${escapeHtml(new Date(s.submitted_at).toLocaleString())}
              </div>
            </div>
            <div class="hp-approve-actions">
              <button type="button" class="button appr-btn appr-go" data-id="${s.id}" data-dry="0">
                Approve &amp; sign
              </button>
              <button type="button" class="button appr-btn appr-preview" data-id="${s.id}" data-dry="1">
                Preview
              </button>
              <button type="button" class="button rej-btn" data-id="${s.id}">Reject</button>
            </div>
          </div>
          <div class="hp-approve-summary">
            <span>Players <b>${players.length}</b></span>
            <span>Fees <b>${escapeHtml(formatMoney(fees))}</b></span>
            <span>Est. tax <b>${escapeHtml(formatMoney(tax))}</b></span>
            <span>Manager <b>${
              s.manager_id
                ? `${escapeHtml(s.manager_name || s.manager_id)} · ${escapeHtml(formatMoney(mgrFee))}`
                : "—"
            }</b></span>
            <span>Est. total <b>${escapeHtml(formatMoney(fees + mgrFee + tax))}</b></span>
          </div>
          <div id="subProgress${s.id}" class="hp-sign-progress" hidden>
            <div id="subProgressLabel${s.id}">Preparing…</div>
            <div class="hp-bar"><i id="subProgressBar${s.id}"></i></div>
            <pre class="hp-log" id="subProgressLog${s.id}"></pre>
          </div>
          <details open>
            <summary style="cursor:pointer;color:#9ab;font-size:13px;margin-bottom:6px;">
              Wishlist players (${players.length})
            </summary>
            <div class="hp-approve-players">${playerLines}</div>
          </details>
          <pre class="hint" id="subOut${s.id}" style="white-space:pre-wrap;margin-top:10px;"></pre>
        </article>`;
      }

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
        <pre class="hint" id="subOut${s.id}" style="white-space:pre-wrap;margin-top:6px;"></pre>
      </div>`;
    })
    .join("");
}

function wireSubmissionActions(root) {
  if (!root) return;
  root.querySelectorAll(".appr-btn").forEach((btn) => {
    btn.addEventListener("click", () =>
      approveSubmission(Number(btn.dataset.id), btn.dataset.dry === "1")
    );
  });
  root.querySelectorAll(".rej-btn").forEach((btn) => {
    btn.addEventListener("click", () => rejectSubmission(Number(btn.dataset.id)));
  });
}

async function loadSubmissions() {
  const ownerBox = document.getElementById("pendingBox");
  const adminSection = document.getElementById("adminApprovalsSection");
  const adminBox = document.getElementById("adminPendingBox");

  document.body.classList.toggle("hp-admin-mode", !!isAdmin);
  if (adminSection) adminSection.hidden = !isAdmin;
  const chrome = document.getElementById("adminChrome");
  if (chrome) chrome.hidden = !isAdmin;
  if (!isAdmin) {
    document.body.classList.remove("hp-tab-admin", "hp-tab-owner");
  }

  // Admin approvals list (all pending)
  if (isAdmin && adminBox) {
    const { data, error } = await supabase.rpc("handpick_list_submissions", {
      p_status: "pending",
      p_club_short_name: null,
    });
    if (error) {
      adminBox.innerHTML = `<p class="empty">${escapeHtml(error.message)}</p>`;
    } else {
      const rows = Array.isArray(data) ? data : [];
      adminBox.innerHTML = rows.length
        ? renderSubmissionCards(rows, { adminLayout: true })
        : renderAdminEmptyGhost();
      if (rows.length) wireSubmissionActions(adminBox);
      if (adminUiTab === "admin" && rows.length && !adminApprovalsScrolled) {
        adminApprovalsScrolled = true;
        document.getElementById("adminApprovalsSection")?.scrollIntoView({
          behavior: "smooth",
          block: "start",
        });
      }
    }
  }

  // Owner panel: this club only (real owners + admin owner-preview tab)
  if (ownerBox) {
    const { data, error } = await supabase.rpc("handpick_list_submissions", {
      p_status: "all",
      p_club_short_name: activeClub || null,
    });
    if (error) {
      ownerBox.innerHTML = `<p class="empty">${escapeHtml(error.message)}</p>`;
    } else {
      const rows = Array.isArray(data) ? data : [];
      const clubRows = activeClub
        ? rows.filter(
            (r) =>
              String(r.club_short_name || "").toUpperCase() ===
              String(activeClub).toUpperCase()
          )
        : rows;
      ownerBox.innerHTML = clubRows.length
        ? renderSubmissionCards(clubRows, { adminLayout: false })
        : `<p class="empty">No submissions yet.</p>`;
      if (clubRows.length) wireSubmissionActions(ownerBox);
    }
  }
}

const SIGN_BATCH_SIZE = 5;

function chunkIds(ids, size) {
  const out = [];
  for (let i = 0; i < ids.length; i += size) out.push(ids.slice(i, i + size));
  return out;
}

function setApproveProgress(id, { pct, label, logLine, show = true }) {
  const wrap = document.getElementById(`subProgress${id}`);
  const bar = document.getElementById(`subProgressBar${id}`);
  const lab = document.getElementById(`subProgressLabel${id}`);
  const log = document.getElementById(`subProgressLog${id}`);
  if (wrap) wrap.hidden = !show;
  if (lab && label != null) lab.textContent = label;
  if (bar && pct != null) bar.style.width = `${Math.max(0, Math.min(100, pct))}%`;
  if (log && logLine) {
    log.textContent = `${log.textContent ? `${log.textContent}\n` : ""}${logLine}`;
    log.scrollTop = log.scrollHeight;
  }
}

function formatSignSummary(signParts, mgr) {
  const signed = [];
  const skipped = [];
  let fees = 0;
  let tax = 0;
  for (const part of signParts) {
    for (const p of part?.signed || []) {
      signed.push(p);
      fees += Number(p.market_value) || 0;
      tax += Number(p.est_income_tax) || 0;
    }
    for (const p of part?.skipped || []) skipped.push(p);
  }
  const lines = [
    `Signed ${signed.length} player(s) · skipped ${skipped.length}`,
    `Fees ${formatMoney(fees)} + tax ${formatMoney(tax)} = ${formatMoney(fees + tax)}`,
  ];
  if (mgr?.ok === false) {
    lines.push(`Manager failed: ${mgr.error || mgr.reason || "unknown"}`);
  } else if (mgr?.manager_id || mgr?.ok) {
    lines.push(
      mgr?.dry_run
        ? `Manager preview fee ${formatMoney(mgr.est_fee)}`
        : `Manager assigned`
    );
  }
  if (skipped.length) {
    lines.push(
      "Skipped: " +
        skipped
          .slice(0, 12)
          .map((p) => `${p.player_name || p.player_id} (${p.reason})`)
          .join("; ") +
        (skipped.length > 12 ? "…" : "")
    );
  }
  return { lines: lines.join("\n"), signedCount: signed.length, skippedCount: skipped.length };
}

async function approveSubmission(id, dryRun) {
  const card = document.querySelector(`[data-sub-id="${id}"]`);
  const out = document.getElementById(`subOut${id}`);
  const club =
    card?.getAttribute("data-club") ||
    activeClub ||
    "";
  const playerIds = String(card?.getAttribute("data-player-ids") || "")
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean);

  if (
    !dryRun &&
    !confirm(
      `Approve submission #${id} and sign at market value?\n\n${playerIds.length} player(s)` +
        (card?.getAttribute("data-manager-id") ? " + manager" : "") +
        `\nThis spends club cash.`
    )
  ) {
    return;
  }

  card?.querySelectorAll("button").forEach((b) => {
    b.disabled = true;
  });

  // Preview: single dry-run RPC (fast)
  if (dryRun) {
    setPageStatus("Previewing…");
    setApproveProgress(id, {
      show: true,
      pct: 15,
      label: "Running dry-run preview…",
      logLine: "Preview (no cash spent)…",
    });
    const { data, error } = await supabase.rpc("admin_handpick_approve_submission", {
      p_submission_id: id,
      p_dry_run: true,
    });
    if (error) {
      setPageStatus(error.message, true);
      setApproveProgress(id, { pct: 100, label: "Preview failed", logLine: error.message });
      card?.querySelectorAll("button").forEach((b) => {
        b.disabled = false;
      });
      return;
    }
    const players = data?.players || {};
    setApproveProgress(id, {
      pct: 100,
      label: `Preview: would sign ${players.signed_count ?? 0}, skip ${players.skipped_count ?? 0}`,
      logLine: JSON.stringify(
        {
          signed_count: players.signed_count,
          skipped_count: players.skipped_count,
          fees_total: players.fees_total,
          est_income_tax_total: players.est_income_tax_total,
          manager: data?.manager,
        },
        null,
        2
      ),
    });
    if (out) out.textContent = "";
    setPageStatus(
      `Preview #${id}: would sign ${players.signed_count ?? "?"} · skip ${players.skipped_count ?? 0}`,
      !data?.ok
    );
    card?.querySelectorAll("button").forEach((b) => {
      b.disabled = false;
    });
    return;
  }

  // Live approve: sign in batches (same as admin Sign FA) so progress is visible
  setPageStatus("Signing wishlist…");
  const batches = playerIds.length ? chunkIds(playerIds, SIGN_BATCH_SIZE) : [];
  const signParts = [];
  const totalSteps = Math.max(1, batches.length + 1); // + finalize/manager
  let step = 0;

  setApproveProgress(id, {
    show: true,
    pct: 0,
    label: `Signing ${playerIds.length} player(s) in ${batches.length || 1} batch(es)…`,
    logLine: `Club ${club} · ${playerIds.length} players`,
  });
  if (out) out.textContent = "";

  for (let i = 0; i < batches.length; i++) {
    const batch = batches[i];
    step += 1;
    setApproveProgress(id, {
      pct: Math.round((step / totalSteps) * 90),
      label: `Signing batch ${i + 1}/${batches.length} (${batch.length} player(s))…`,
      logLine: `Batch ${i + 1}: ${batch.join(", ")}`,
    });
    const { data, error } = await supabase.rpc("admin_sign_free_agents_at_mv", {
      p_club_short_name: club,
      p_player_ids: batch,
      p_dry_run: false,
    });
    if (error) {
      setApproveProgress(id, {
        pct: 100,
        label: `Stopped on batch ${i + 1}: ${error.message}`,
        logLine: error.message,
      });
      setPageStatus(error.message, true);
      card?.querySelectorAll("button").forEach((b) => {
        b.disabled = false;
      });
      return;
    }
    if (!data?.ok) {
      setApproveProgress(id, {
        pct: 100,
        label: `Batch ${i + 1} failed: ${data?.reason || "sign_failed"}`,
        logLine: JSON.stringify(data, null, 2),
      });
      setPageStatus(data?.reason || "Sign batch failed", true);
      card?.querySelectorAll("button").forEach((b) => {
        b.disabled = false;
      });
      return;
    }
    signParts.push(data);
    const names = (data.signed || []).map((p) => p.player_name).filter(Boolean);
    setApproveProgress(id, {
      logLine: `  ✓ signed ${data.signed_count || 0}${
        names.length ? `: ${names.join(", ")}` : ""
      }${data.skipped_count ? ` · skipped ${data.skipped_count}` : ""}`,
    });
  }

  setApproveProgress(id, {
    pct: 92,
    label: "Finalising submission (manager + mark approved)…",
    logLine: "Calling admin_handpick_approve_submission…",
  });
  // Players already signed in batches above — skip re-sign (avoids batch_too_large on 9+).
  const finalizeArgs = {
    p_submission_id: id,
    p_dry_run: false,
    p_skip_player_sign: signParts.length > 0,
  };
  let { data: finalData, error: finalErr } = await supabase.rpc(
    "admin_handpick_approve_submission",
    finalizeArgs
  );
  // Older DB without p_skip_player_sign: retry 2-arg (server must batch internally).
  if (
    finalErr &&
    /p_skip_player_sign|could not find|schema cache|function/i.test(
      String(finalErr.message || "")
    )
  ) {
    setApproveProgress(id, {
      logLine: "Retry finalize without skip flag (apply handpick_approve_sign_batches SQL)…",
    });
    ({ data: finalData, error: finalErr } = await supabase.rpc(
      "admin_handpick_approve_submission",
      { p_submission_id: id, p_dry_run: false }
    ));
  }
  if (finalErr) {
    setApproveProgress(id, {
      pct: 100,
      label: `Players may be signed, but finalise failed: ${finalErr.message}`,
      logLine: finalErr.message,
    });
    setPageStatus(finalErr.message, true);
    card?.querySelectorAll("button").forEach((b) => {
      b.disabled = false;
    });
    return;
  }

  // Prefer batch sign counts; finalize may report skips for already-signed
  const summary = formatSignSummary(
    signParts.length ? signParts : [finalData?.players].filter(Boolean),
    finalData?.manager
  );
  setApproveProgress(id, {
    pct: 100,
    label: finalData?.ok
      ? `Done — ${summary.signedCount} signed, ${summary.skippedCount} skipped`
      : `Finished with errors: ${finalData?.reason || "unknown"}`,
    logLine: summary.lines,
  });
  setPageStatus(
    finalData?.ok
      ? `Approved #${id}: signed ${summary.signedCount}, skipped ${summary.skippedCount}.`
      : finalData?.reason || "Approve failed",
    !finalData?.ok
  );

  if (finalData?.ok) {
    // Approved clubs leave handpick_intake — refresh admin dropdown
    if (isAdmin) {
      const mapRes = await supabase.rpc("admin_handpick_intake_map");
      if (!mapRes.error) {
        await loadAdminClubs(mapRes.data || {});
        const sel = document.getElementById("clubSelect");
        const stillThere =
          sel &&
          club &&
          [...sel.options].some(
            (o) => String(o.value).toUpperCase() === String(club).toUpperCase()
          );
        if (sel && !stillThere) {
          activeClub = sel.value || "";
          if (activeClub) {
            const url = new URL(window.location.href);
            url.searchParams.set("club", activeClub);
            history.replaceState({}, "", url);
          } else {
            const url = new URL(window.location.href);
            url.searchParams.delete("club");
            history.replaceState({}, "", url);
          }
        }
      }
    }
    await loadContext();
    await loadSubmissions();
  } else {
    card?.querySelectorAll("button").forEach((b) => {
      b.disabled = false;
    });
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
