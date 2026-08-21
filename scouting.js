import { supabase, initGlobal } from "./global.js";
import { initGpslInfoTips, tipAttrs } from "./gpsl_info_tips.js";
import { formatMoney } from "./competition.js";
import { loadClubsMap, fullClubName, displayClubName } from "./clubs_lookup.js";
import {
  loadPlayerValueTables,
  formatRatingWithPotential,
} from "./player_economics.js";
import { playerThumbLinkHtml, playerNameLinkHtml } from "./player_links.js";
import {
  SCOUTING_TIER_LABELS,
  isScoutingAvailable,
  scoutingSetupHint,
  loadScoutingTargets,
  setScoutingTargetTier,
  setScoutingActiveTarget,
  toggleScoutingTarget,
  loadScoutingPlannerState,
  saveScoutingPlanner,
  ensureScoutingBoards,
  renameScoutingBoard,
  getStoredScoutingBoardNo,
  setStoredScoutingBoardNo,
  loadScoutingPlannerPlayerBoards,
} from "./scouting_targets.js?v=20260821-board-filter";
import { initMatchdaySquadPanel } from "./matchday_squad.js?v=20260821-autofill";
import { autoFillScoutingBoard } from "./scouting_autofill.js?v=20260821-autofill";
import {
  loadScoutingDraftContext,
  buildPlayerDraftUiState,
  renderDraftManageCell,
  submitScoutingDraftBid,
} from "./scouting_draft_actions.js?v=20260811-draft-list-fix";
import {
  confirmSquadRulesBeforeBid,
  analyseSquadComposition,
  isHomeGrownPlayer,
  isUnder21,
  isGoalkeeper,
  MIN_HOME_GROWN,
  MIN_UNDER_21,
  MIN_GOALKEEPERS,
  MIN_SQUAD_SIZE,
  SQUAD_SIZE,
} from "./squad_rules.js";
import {
  loadSquadDesignationsState,
  playerEligibleStar,
  playerEligibleOoo,
  DESIGNATION_OOO,
} from "./squad_designations.js";

/** Compact HG / ★ / U21 markers for scouting name cells. */
function scoutingPlayerBadgesHtml(player) {
  if (!player) return "";
  const minStar = Number(squadDesignationsState?.star_min_rating ?? 79);
  const bits = [];
  if (isHomeGrownPlayer(player, clubNation)) {
    bits.push(
      `<span class="scout-badge scout-badge-hg" title="Home-grown (Nation matches your club)">HG</span>`
    );
  }
  if (playerEligibleStar(player, minStar)) {
    bits.push(
      `<span class="scout-badge scout-badge-star" title="Star-rated (${minStar}+)">★</span>`
    );
  }
  if (isUnder21(player)) {
    bits.push(
      `<span class="scout-badge scout-badge-u21" title="Under-21 (age 21 or younger)">U21</span>`
    );
  }
  if (!bits.length) return "";
  return ` <span class="scout-badges">${bits.join("")}</span>`;
}
import { mountAdvisoryTransferBudget } from "./club_bank_balance_ui.js?v=20260811-budget-refresh";

const PLAYER_COLUMNS =
  "Konami_ID, Name, Nation, Position, Rating, Potential, Calc_Potential, Age, market_value, Playstyle, Contracted_Team";

const PLAYER_COLUMNS_LEGACY =
  "Konami_ID, Name, Nation, Position, Rating, Age, market_value, Playstyle, Contracted_Team";

const SQUAD_REG_COLUMNS = "Konami_ID, Nation, Position, Rating, Age";

let clubShort = null;
let clubNation = null;
let scoutingRows = [];
let scoutingPlayers = [];
let playerMapCache = new Map();
let draftUiByPlayerCache = new Map();
let draftContext = null;
let plannerApi = null;
/** Planner-local One of our Own (planning only — excludes that player from ★ count). */
let plannerOooPlayerId = null;
/** Nation used for HG / OooO on this tactic board (planning for a club). */
let plannerPlanNation = null;
/** Distinct club nations for the board nation picker. */
let plannerNationOptions = [];
/** @type {{ board_no: number, name: string }[]} */
let scoutingBoards = [];
let activeBoardNo = getStoredScoutingBoardNo();
/** Target-list filter: "all" or board number string "1"…"4". */
let listBoardFilter = "all";
/** @type {Map<string, Set<number>>} */
let playerBoardMap = new Map();
let multiBoardEnabled = true;
/** @type {object[]|null} */
let ownedSquadPlayers = null;
/** @type {object|null} */
let squadDesignationsState = null;

function activeTargetBudgetForPlayer(pid) {
  const p = playerMapCache.get(String(pid));
  const ui = draftUiByPlayerCache.get(String(pid));
  if (ui?.budgetAmount != null && Number.isFinite(Number(ui.budgetAmount))) {
    return Number(ui.budgetAmount);
  }
  return Number(p?.market_value) || 0;
}

function activeTargetBudgetTitle(pid) {
  const ui = draftUiByPlayerCache.get(String(pid));
  const amt = formatMoney(activeTargetBudgetForPlayer(pid));
  if (ui?.budgetKind === "leading") {
    return `Active target: your leading bid ${amt}`;
  }
  if (ui?.budgetKind === "to_overtake") {
    return `Active target: next bid to lead ${amt}`;
  }
  return `Active target: market value ${amt}`;
}

function sumActiveTargetsBudget() {
  let total = 0;
  let count = 0;
  for (const row of scoutingRows) {
    if (!row.is_active_target) continue;
    total += activeTargetBudgetForPlayer(row.player_id);
    count += 1;
  }
  return { total, count };
}

function updateActiveTargetsHeader() {
  const totalEl = document.getElementById("scoutActiveTotal");
  const metaEl = document.getElementById("scoutActiveMeta");
  if (!totalEl) return;
  const { total, count } = sumActiveTargetsBudget();
  totalEl.textContent = formatMoney(total);
  totalEl.classList.toggle("is-over", false);
  if (metaEl) {
    metaEl.textContent = count > 0 ? `(${count})` : "";
  }
  updateRegistrationStrip();
}

function countStarEligible(players, minRating, oooId) {
  const ooo = oooId != null ? String(oooId) : null;
  let n = 0;
  for (const p of players || []) {
    if (ooo && String(p.Konami_ID) === ooo) continue;
    if (playerEligibleStar(p, minRating)) n += 1;
  }
  return n;
}

function activeTargetPlayersNotOwned() {
  const owned = new Set(
    (ownedSquadPlayers || []).map((p) => String(p.Konami_ID))
  );
  const out = [];
  for (const row of scoutingRows) {
    if (!row.is_active_target) continue;
    const pid = String(row.player_id);
    if (owned.has(pid)) continue;
    const p = playerMapCache.get(pid);
    if (p) out.push(p);
  }
  return out;
}

function tallyAdds(players, nation) {
  let gk = 0;
  let hg = 0;
  let u21 = 0;
  for (const p of players) {
    if (isGoalkeeper(p)) gk += 1;
    if (isHomeGrownPlayer(p, nation)) hg += 1;
    if (isUnder21(p)) u21 += 1;
  }
  return { gk, hg, u21, n: players.length };
}

/**
 * Compact chip: owned (+adds) → proj vs target.
 * @param {"min"|"max"|"range"} mode
 */
function regChip(label, owned, add, target, mode, title) {
  const proj = owned + add;
  let ok;
  let targetTxt;
  if (mode === "min") {
    ok = proj >= target;
    targetTxt = `≥${target}`;
  } else if (mode === "max") {
    ok = proj <= target;
    targetTxt = `≤${target}`;
  } else {
    const [lo, hi] = target;
    ok = proj >= lo && proj <= hi;
    targetTxt = `${lo}–${hi}`;
  }
  const addBit = add > 0 ? `+${add}` : "";
  const cls = ok ? "ok" : mode === "max" && proj > (Array.isArray(target) ? target[1] : target) ? "bad" : "short";
  return `<span class="scout-reg-chip ${cls}" title="${title}">${label} <b>${owned}${addBit}→${proj}</b> <i>${targetTxt}</i></span>`;
}

function updateRegistrationStrip() {
  const el = document.getElementById("scoutRegStrip");
  if (!el) return;

  if (!clubShort) {
    el.hidden = true;
    el.innerHTML = "";
    return;
  }

  if (!ownedSquadPlayers) {
    el.hidden = false;
    el.innerHTML = `<span class="scout-reg-muted">Squad registration…</span>`;
    return;
  }

  const nation = clubNation;
  const owned = analyseSquadComposition(ownedSquadPlayers, nation);
  const adds = activeTargetPlayersNotOwned();
  const addT = tallyAdds(adds, nation);
  const minStar = Number(squadDesignationsState?.star_min_rating ?? 79);
  const starCap = Number(squadDesignationsState?.star_cap ?? 2);
  const oooId =
    squadDesignationsState?.one_of_our_own_player_id ??
    Object.entries(squadDesignationsState?.designations || {}).find(
      ([, d]) => d === DESIGNATION_OOO
    )?.[0] ??
    null;

  // Prefer live designation count when available; else count eligible on squad
  const ownedStars =
    squadDesignationsState?.star_count != null
      ? Number(squadDesignationsState.star_count)
      : countStarEligible(ownedSquadPlayers, minStar, oooId);
  const addStars = countStarEligible(adds, minStar, null);

  const tip =
    "Squad now → if you signed all Active Targets (not already owned). Green = registration OK. Sq 24–28 · ≥1 GK · ≥8 HG · ≥5 U21 · star cap (SL 3 / Champ 2).";

  el.hidden = false;
  el.innerHTML = `
    <span${tipAttrs(tip, "scout-reg-label")}>Reg:</span>
    ${regChip("Sq", owned.total, addT.n, [MIN_SQUAD_SIZE, SQUAD_SIZE], "range", `Squad size: owned ${owned.total}, active +${addT.n} → ${owned.total + addT.n} (need ${MIN_SQUAD_SIZE}–${SQUAD_SIZE})`)}
    ${regChip("GK", owned.goalkeepers, addT.gk, MIN_GOALKEEPERS, "min", `Goalkeepers: owned ${owned.goalkeepers}, active +${addT.gk}`)}
    ${regChip("HG", owned.homeGrown, addT.hg, MIN_HOME_GROWN, "min", `Home-grown (Nation match): owned ${owned.homeGrown}, active +${addT.hg}`)}
    ${regChip("U21", owned.under21, addT.u21, MIN_UNDER_21, "min", `Under-21: owned ${owned.under21}, active +${addT.u21}`)}
    ${regChip("★", ownedStars, addStars, starCap, "max", `Stars (rating ${minStar}+, OooO excluded): owned ${ownedStars}, active +${addStars}, cap ${starCap}`)}
  `;
}

async function loadOwnedSquadForReg() {
  if (!clubShort) {
    ownedSquadPlayers = [];
    squadDesignationsState = null;
    return;
  }

  const [squadRes, desig] = await Promise.all([
    supabase
      .from("Players")
      .select(SQUAD_REG_COLUMNS)
      .eq("Contracted_Team", clubShort),
    loadSquadDesignationsState(supabase, clubShort),
  ]);

  if (squadRes.error) {
    console.warn("scouting squad load:", squadRes.error);
    ownedSquadPlayers = [];
  } else {
    ownedSquadPlayers = squadRes.data || [];
  }
  squadDesignationsState = desig;
  if (desig?.club_nation && !clubNation) {
    clubNation = desig.club_nation;
  }
}

async function refreshAdvisoryBudgetBadge() {
  const card = document.getElementById("scoutAdvisoryCard");
  const el = document.getElementById("scoutAdvisoryBudget");
  if (!el) return;
  if (!clubShort) {
    if (card) card.hidden = true;
    el.hidden = true;
    el.innerHTML = "";
    return;
  }
  if (card) card.hidden = false;
  el.hidden = false;
  await mountAdvisoryTransferBudget(el, {
    clubShortName: clubShort,
    href: "finances.html",
    hideIfUnknown: false,
  });
}

const SCOUTING_POSITION_ORDER = [
  "GK",
  "LB",
  "CB",
  "RB",
  "DMF",
  "LMF",
  "CMF",
  "RMF",
  "AMF",
  "LWF",
  "SS",
  "RWF",
  "CF",
];

/** Same groups as squad.html — used inside each scouting tier. */
const SCOUTING_POSITION_GROUPS = {
  Goalkeepers: ["GK"],
  Defenders: ["LB", "CB", "RB"],
  Midfielders: ["DMF", "LMF", "CMF", "RMF", "AMF"],
  Attackers: ["LW", "LWF", "SS", "RW", "RWF", "CF"],
};

const SCOUTING_POSITION_ALIASES = {
  LW: "LWF",
  RW: "RWF",
};

function normalizeScoutingPosition(position) {
  const p = String(position || "").trim().toUpperCase();
  return SCOUTING_POSITION_ALIASES[p] || p;
}

function scoutingPositionSortIndex(position) {
  const p = normalizeScoutingPosition(position);
  const i = SCOUTING_POSITION_ORDER.indexOf(p);
  return i >= 0 ? i : 999;
}

function scoutingPositionGroupName(position) {
  const raw = String(position || "").trim().toUpperCase();
  const norm = normalizeScoutingPosition(raw);
  for (const [groupName, positions] of Object.entries(SCOUTING_POSITION_GROUPS)) {
    if (positions.includes(raw) || positions.includes(norm)) return groupName;
  }
  return "Other";
}

function sortScoutingRowsByPosition(rows, playerMap) {
  return [...rows].sort((a, b) => {
    const pa = playerMap.get(String(a.player_id));
    const pb = playerMap.get(String(b.player_id));
    const pos =
      scoutingPositionSortIndex(pa?.Position) -
      scoutingPositionSortIndex(pb?.Position);
    if (pos !== 0) return pos;
    return String(pa?.Name || "").localeCompare(String(pb?.Name || ""), "en", {
      sensitivity: "base",
    });
  });
}

function sortPlayersByScoutingPosition(players) {
  return [...players].sort((a, b) => {
    const pos =
      scoutingPositionSortIndex(a?.Position) -
      scoutingPositionSortIndex(b?.Position);
    if (pos !== 0) return pos;
    return String(a?.Name || "").localeCompare(String(b?.Name || ""), "en", {
      sensitivity: "base",
    });
  });
}

function tierBalanceSummary(tierRows, playerMap) {
  const counts = {
    Goalkeepers: 0,
    Defenders: 0,
    Midfielders: 0,
    Attackers: 0,
    Other: 0,
  };
  for (const row of tierRows) {
    const p = playerMap.get(String(row.player_id));
    const g = scoutingPositionGroupName(p?.Position);
    counts[g] = (counts[g] || 0) + 1;
  }
  const parts = [
    `GK ${counts.Goalkeepers}`,
    `Def ${counts.Defenders}`,
    `Mid ${counts.Midfielders}`,
    `Att ${counts.Attackers}`,
  ];
  if (counts.Other) parts.push(`Other ${counts.Other}`);
  return parts.join(" · ");
}

function groupTierRowsByPosition(tierRows, playerMap) {
  const grouped = Object.fromEntries(
    Object.keys(SCOUTING_POSITION_GROUPS).map((name) => [name, []])
  );
  grouped.Other = [];

  for (const row of tierRows) {
    const p = playerMap.get(String(row.player_id));
    const g = scoutingPositionGroupName(p?.Position);
    if (!grouped[g]) grouped[g] = [];
    grouped[g].push(row);
  }

  for (const name of Object.keys(grouped)) {
    grouped[name] = sortScoutingRowsByPosition(grouped[name], playerMap);
  }
  return grouped;
}

function renderTierByPositionGroups(tier, tierRows, playerMap, draftUiByPlayer) {
  if (!tierRows.length) {
    return `<p class="scout-empty">No players — star targets in GPDB (☆).</p>`;
  }

  const grouped = groupTierRowsByPosition(tierRows, playerMap);
  const groupNames = [...Object.keys(SCOUTING_POSITION_GROUPS), "Other"];

  return groupNames
    .filter((name) => name !== "Other" || (grouped.Other || []).length)
    .map((groupName) => {
      const rows = grouped[groupName] || [];
      return `
        <div class="scout-pos-group" data-pos-group="${groupName}">
          <h4 class="scout-pos-heading">${groupName} (${rows.length})</h4>
          ${
            rows.length
              ? renderTierTable(tier, rows, playerMap, draftUiByPlayer)
              : `<p class="scout-empty scout-pos-empty">None in this tier</p>`
          }
        </div>`;
    })
    .join("");
}

function parseBidAmount(raw) {
  const n = Number(String(raw || "").replace(/[^\d]/g, ""));
  return Number.isFinite(n) ? n : 0;
}

function setPlannerStatus(msg, isError = false) {
  const el = document.getElementById("plannerStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.classList.toggle("err", isError);
}

async function fetchPlayersByIds(ids) {
  const numericIds = [
    ...new Set(
      ids
        .map((id) => Number(id))
        .filter((n) => Number.isFinite(n))
    ),
  ];
  if (!numericIds.length) return new Map();

  let { data, error } = await supabase
    .from("Players")
    .select(PLAYER_COLUMNS)
    .in("Konami_ID", numericIds);

  if (error?.message?.toLowerCase().includes("potential")) {
    ({ data, error } = await supabase
      .from("Players")
      .select(PLAYER_COLUMNS_LEGACY)
      .in("Konami_ID", numericIds));
  }

  if (error) throw error;

  const map = new Map();
  for (const p of data || []) {
    map.set(String(p.Konami_ID), p);
  }
  return map;
}

function playersForPlanner() {
  return sortPlayersByScoutingPosition(scoutingPlayers).map((p) => ({
    Konami_ID: p.Konami_ID,
    Name: p.Name,
    Nation: p.Nation,
    Position: p.Position,
    Rating: p.Rating,
    Age: p.Age,
    market_value: p.market_value,
    Playstyle: p.Playstyle,
  }));
}

function playersOnPlannerBoard(state) {
  const out = [];
  if (!state?.pitch) return out;
  for (const p of state.pitch.values()) {
    if (p) out.push(p);
  }
  for (const p of state.bench || []) {
    if (p) out.push(p);
  }
  return out;
}

function extractPlannerOooFromLayout(layout) {
  if (!layout || typeof layout !== "object") return null;
  const id = layout.scouting_ooo_player_id;
  return id != null && String(id).trim() !== "" ? String(id).trim() : null;
}

function extractPlannerNationFromLayout(layout) {
  if (!layout || typeof layout !== "object") return null;
  const n = layout.scouting_plan_nation;
  return n != null && String(n).trim() !== "" ? String(n).trim() : null;
}

function pitchLayoutWithPlannerMeta(layout, { oooId = null, planNation = null } = {}) {
  const base =
    layout && typeof layout === "object" && !Array.isArray(layout)
      ? { ...layout }
      : {};
  if (oooId) base.scouting_ooo_player_id = String(oooId);
  else delete base.scouting_ooo_player_id;
  if (planNation) base.scouting_plan_nation = String(planNation);
  else delete base.scouting_plan_nation;
  return base;
}

/** @deprecated use pitchLayoutWithPlannerMeta */
function pitchLayoutWithPlannerOoo(layout, oooId) {
  return pitchLayoutWithPlannerMeta(layout, {
    oooId,
    planNation: plannerPlanNation,
  });
}

async function loadPlannerNationOptions() {
  const set = new Set();
  const add = (n) => {
    const t = String(n || "").trim();
    if (t) set.add(t);
  };
  add(clubNation);
  add(squadDesignationsState?.club_nation);
  for (const p of scoutingPlayers || []) add(p.Nation);

  try {
    const { data, error } = await supabase
      .from("Clubs")
      .select("Nation")
      .neq("ShortName", "FOREIGN");
    if (!error) {
      for (const row of data || []) add(row.Nation);
    }
  } catch (err) {
    console.warn("planner nation options:", err);
  }

  plannerNationOptions = [...set].sort((a, b) =>
    a.localeCompare(b, undefined, { sensitivity: "base" })
  );
}

function effectivePlannerNation() {
  return (
    plannerPlanNation ||
    clubNation ||
    squadDesignationsState?.club_nation ||
    null
  );
}

function boardChip(label, value, target, mode, title) {
  let ok;
  let targetTxt;
  if (mode === "min") {
    ok = value >= target;
    targetTxt = `≥${target}`;
  } else if (mode === "max") {
    ok = value <= target;
    targetTxt = `≤${target}`;
  } else {
    const [lo, hi] = target;
    ok = value >= lo && value <= hi;
    targetTxt = `${lo}–${hi}`;
  }
  const cls =
    ok
      ? "ok"
      : mode === "max" && value > (Array.isArray(target) ? target[1] : target)
        ? "bad"
        : "short";
  return `<span class="scout-reg-chip ${cls}" title="${title}">${label} <b>${value}</b> <i>${targetTxt}</i></span>`;
}

function updatePlannerCompositionStrip(state) {
  const el = document.getElementById("scoutPlannerComp");
  if (!el) return;

  const players = playersOnPlannerBoard(state);
  const onBoardIds = new Set(players.map((p) => String(p.Konami_ID)));

  if (plannerOooPlayerId && !onBoardIds.has(String(plannerOooPlayerId))) {
    plannerOooPlayerId = null;
  }

  const minStar = Number(squadDesignationsState?.star_min_rating ?? 79);
  const starCap = Number(squadDesignationsState?.star_cap ?? 2);
  const nation = effectivePlannerNation();
  const totals = tallyAdds(players, nation);
  const stars = countStarEligible(players, minStar, plannerOooPlayerId);
  let mvTotal = 0;
  for (const p of players) {
    const mv = Number(p.market_value);
    if (Number.isFinite(mv) && mv > 0) mvTotal += mv;
  }

  const oooOptions = players
    .filter((p) => playerEligibleOoo(p, nation, minStar))
    .sort((a, b) =>
      String(a.Name || "").localeCompare(String(b.Name || ""), undefined, {
        sensitivity: "base",
      })
    );

  const nationOptions = [...plannerNationOptions];
  if (nation && !nationOptions.includes(nation)) {
    nationOptions.unshift(nation);
  }

  const tip =
    "Counts players currently on this tactic board (pitch + bench). Pick the club nation you are planning for — HG and OooO use that nation. ★ excludes your planned One of our Own. MV = sum of market values on the board.";

  el.hidden = false;
  el.innerHTML = `
    <span${tipAttrs(tip, "scout-reg-label")}>Board:</span>
    ${boardChip("Sq", totals.n, [MIN_SQUAD_SIZE, SQUAD_SIZE], "range", `On board: ${totals.n} (need ${MIN_SQUAD_SIZE}–${SQUAD_SIZE} when registered)`)}
    ${boardChip("GK", totals.gk, MIN_GOALKEEPERS, "min", `Goalkeepers on board: ${totals.gk}`)}
    ${boardChip("HG", totals.hg, MIN_HOME_GROWN, "min", `Home-grown vs ${nation || "—"}: ${totals.hg}`)}
    ${boardChip("U21", totals.u21, MIN_UNDER_21, "min", `Under-21 on board: ${totals.u21}`)}
    ${boardChip("★", stars, starCap, "max", `Stars on board (rating ${minStar}+, planned OooO excluded): ${stars} / cap ${starCap}`)}
    <span class="scout-reg-chip scout-planner-mv" title="Sum of market values for players on this board (pitch + bench). Approximate minimum cost if all were signed at MV.">MV <b>${formatMoney(
      mvTotal
    )}</b></span>
    <div class="scout-planner-ooo">
      <label for="scoutPlannerNationSelect">Plan nation</label>
      <select id="scoutPlannerNationSelect" title="Nation of the club you are planning this board for (drives HG / OooO)">
        <option value="">— Select nation —</option>
        ${nationOptions
          .map((n) => {
            const sel =
              nation && String(n) === String(nation) ? " selected" : "";
            return `<option value="${escapeHtml(n)}"${sel}>${escapeHtml(
              n
            )}</option>`;
          })
          .join("")}
      </select>
      <label for="scoutPlannerOooSelect">One of our Own</label>
      <select id="scoutPlannerOooSelect" title="Planning only — excludes this player from the ★ count on this board">
        <option value="">— None —</option>
        ${oooOptions
          .map((p) => {
            const id = String(p.Konami_ID);
            const sel = plannerOooPlayerId === id ? " selected" : "";
            return `<option value="${escapeHtml(id)}"${sel}>${escapeHtml(
              p.Name || id
            )} (${escapeHtml(String(p.Rating ?? ""))})</option>`;
          })
          .join("")}
      </select>
      <span class="scout-ooo-hint">Per board · HG uses plan nation · OooO reduces ★</span>
    </div>
  `;
}

function wirePlannerCompositionStrip() {
  const el = document.getElementById("scoutPlannerComp");
  if (!el || el.dataset.oooWired === "1") return;
  el.dataset.oooWired = "1";
  el.addEventListener("change", (e) => {
    const nationSel = e.target?.closest?.("#scoutPlannerNationSelect");
    if (nationSel) {
      plannerPlanNation = nationSel.value ? String(nationSel.value) : null;
      // OooO may no longer be HG for the new nation
      const st = plannerApi?.getState?.() || null;
      const onBoard = playersOnPlannerBoard(st);
      if (
        plannerOooPlayerId &&
        !onBoard.some(
          (p) =>
            String(p.Konami_ID) === String(plannerOooPlayerId) &&
            playerEligibleOoo(
              p,
              plannerPlanNation,
              Number(squadDesignationsState?.star_min_rating ?? 79)
            )
        )
      ) {
        plannerOooPlayerId = null;
      }
      updatePlannerCompositionStrip(st);
      return;
    }
    const sel = e.target?.closest?.("#scoutPlannerOooSelect");
    if (!sel) return;
    plannerOooPlayerId = sel.value ? String(sel.value) : null;
    updatePlannerCompositionStrip(plannerApi?.getState?.() || null);
  });
}


function canUseDraftBidding() {
  return Boolean(clubShort);
}

function renderTierTable(tier, rows, playerMap, draftUiByPlayer) {
  if (!rows.length) {
    return `<p class="scout-empty">No players — star targets in GPDB (☆).</p>`;
  }

  const showDraft = canUseDraftBidding();

  return `
    <table class="scout-table">
      <thead>
        <tr>
          <th></th>
          <th class="name">Name</th>
          <th>Nation</th>
          <th>Pos</th>
          <th>Age</th>
          <th>Rating</th>
          <th>MV</th>
          <th>Playstyle</th>
          <th>Club</th>
          ${showDraft ? "<th>Draft</th><th>Leading</th><th>Your bid</th><th>Manage bid</th>" : ""}
          <th title="Count toward Active Targets budget total">Active Targets</th>
          <th>Tier</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((row) => {
            const p = playerMap.get(String(row.player_id));
            const pid = String(row.player_id);
            const name = p?.Name || `Player ${pid}`;
            const rating = p
              ? formatRatingWithPotential(p.Rating, p.Potential, p.Calc_Potential)
              : "—";
            const mv =
              p?.market_value != null && p.market_value !== ""
                ? formatMoney(Number(p.market_value))
                : "—";
            const club = p?.Contracted_Team
              ? displayClubName(p.Contracted_Team)
              : "Free agent";
            const draftUi = draftUiByPlayer.get(pid) || {
              status: "—",
              leadingText: "—",
              yourBidText: "—",
              playerId: pid,
              canBidInline: false,
              minBid: null,
              playerPageUrl: null,
              isLeading: false,
              budgetAmount: Number(p?.market_value) || 0,
              budgetKind: "mv",
            };
            const yourBidClass = draftUi.isLeading ? "scout-leading-bid" : "";
            const draftCells = showDraft
              ? `<td class="scout-draft-status">${draftUi.status}</td>
            <td>${draftUi.leadingText}</td>
            <td class="${yourBidClass}">${draftUi.yourBidText}</td>
            <td>${renderDraftManageCell(draftUi)}</td>`
              : "";
            const isActive = row.is_active_target === true;
            const activeTitle = activeTargetBudgetTitle(pid);

            return `
          <tr data-player-id="${pid}" class="${isActive ? "scout-active-row" : ""}">
            <td>${playerThumbLinkHtml(pid, { className: "scout-thumb", alt: name })}</td>
            <td class="name">${playerNameLinkHtml(pid, name)}${scoutingPlayerBadgesHtml(p)}</td>
            <td>${p?.Nation || "—"}</td>
            <td>${p?.Position || "—"}</td>
            <td>${p?.Age ?? "—"}</td>
            <td>${rating}</td>
            <td>${mv}</td>
            <td>${p?.Playstyle || "—"}</td>
            <td>${club}</td>
            ${draftCells}
            <td>
              <input type="checkbox" class="scout-active-check" data-player-id="${pid}"
                ${isActive ? "checked" : ""} title="${activeTitle}"
                aria-label="Active target for ${name}">
            </td>
            <td>
              <select class="scout-tier-select" data-player-id="${pid}" aria-label="Tier for ${name}">
                ${[1, 2, 3, 4]
                  .map(
                    (t) =>
                      `<option value="${t}"${Number(row.tier) === t ? " selected" : ""}>${SCOUTING_TIER_LABELS[t]}</option>`
                  )
                  .join("")}
              </select>
            </td>
            <td>
              <button type="button" class="scout-remove" data-player-id="${pid}" title="Remove from scouting">✕</button>
            </td>
          </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;
}

async function buildDraftUiMap(playerMap) {
  const draftUiByPlayer = new Map();
  if (!draftContext) return draftUiByPlayer;

  for (const p of playerMap.values()) {
    const ui = await buildPlayerDraftUiState(draftContext, p);
    draftUiByPlayer.set(String(p.Konami_ID), ui);
  }
  return draftUiByPlayer;
}

function wireDraftActions(wrap) {
  wrap.querySelectorAll(".scout-bid-submit").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const pid = btn.dataset.playerId;
      const player = playerMapCache.get(pid);
      const input = wrap.querySelector(`.scout-bid-input[data-player-id="${pid}"]`);
      if (!player || !input) return;

      const offer = parseBidAmount(input.value);
      if (offer <= 0) {
        alert("Enter a valid bid amount.");
        return;
      }

      if (
        !(await confirmSquadRulesBeforeBid(
          supabase,
          clubShort,
          clubNation,
          player
        ))
      ) {
        return;
      }

      btn.disabled = true;
      try {
        const result = await submitScoutingDraftBid(supabase, {
          player,
          offerAmount: offer,
          buyerShortName: clubShort,
          draftAuctionStartTime: draftContext?.draftStart,
        });
        if (!result.ok) {
          alert(result.msg || "Bid failed.");
          return;
        }
        await renderScoutingLists();
      } catch (err) {
        alert(err?.message || "Bid failed.");
      } finally {
        btn.disabled = false;
      }
    });
  });
}

async function renderScoutingLists() {
  const wrap = document.getElementById("scoutingListsWrap");
  if (!wrap) return;

  if (!isScoutingAvailable()) {
    wrap.innerHTML = `<p style="color:#c96;">${scoutingSetupHint()}</p>`;
    return;
  }

  if (!scoutingBoards.length) {
    try {
      scoutingBoards = await ensureScoutingBoards(supabase);
      multiBoardEnabled = true;
    } catch {
      scoutingBoards = [{ board_no: 1, name: "Board 1" }];
    }
  }
  renderListBoardFilter();
  wireListBoardFilter();

  try {
    playerBoardMap = await loadScoutingPlannerPlayerBoards(supabase);
  } catch {
    playerBoardMap = new Map();
  }

  scoutingRows = await loadScoutingTargets(supabase, clubShort);

  if (!scoutingRows.length) {
    wrap.innerHTML =
      '<p class="scout-empty">No scouting targets yet. Open <a href="GPDB.html" style="color:#ff9900;">GPDB</a> and click ☆ on players to add them.</p>';
    scoutingPlayers = [];
    draftUiByPlayerCache = new Map();
    if (clubShort) await loadOwnedSquadForReg();
    else {
      ownedSquadPlayers = [];
      squadDesignationsState = null;
    }
    updateActiveTargetsHeader();
    await refreshAdvisoryBudgetBadge();
    return;
  }

  const playerMap = await fetchPlayersByIds(scoutingRows.map((r) => r.player_id));
  playerMapCache = playerMap;
  scoutingPlayers = sortPlayersByScoutingPosition(
    scoutingRows
      .map((r) => playerMap.get(String(r.player_id)))
      .filter(Boolean)
  );

  draftContext = canUseDraftBidding()
    ? await loadScoutingDraftContext(
        supabase,
        clubShort,
        scoutingRows.map((r) => r.player_id)
      )
    : null;
  const draftUiByPlayer = await buildDraftUiMap(playerMap);
  draftUiByPlayerCache = draftUiByPlayer;

  if (clubShort) {
    await loadOwnedSquadForReg();
  } else {
    ownedSquadPlayers = [];
    squadDesignationsState = null;
  }

  paintScoutingLists(wrap, playerMap, draftUiByPlayer);
  updateActiveTargetsHeader();
  await refreshAdvisoryBudgetBadge();
  wireScoutingListActions(wrap);
}

function paintScoutingLists(wrap, playerMap, draftUiByPlayer) {
  const filteredRows = rowsForListFilter(scoutingRows);
  if (!filteredRows.length) {
    const label =
      listBoardFilter === "all"
        ? "targets"
        : boardLabel(listBoardFilter);
    wrap.innerHTML =
      listBoardFilter === "all"
        ? '<p class="scout-empty">No scouting targets yet.</p>'
        : `<p class="scout-empty">No targets placed on <b>${escapeHtml(label)}</b>. Switch to Show all, or place players on that tactic board.</p>`;
    return;
  }

  wrap.innerHTML = [1, 2, 3, 4]
    .map((tier) => {
      const tierRows = sortScoutingRowsByPosition(
        filteredRows.filter((r) => Number(r.tier) === tier),
        playerMap
      );
      const balance = tierRows.length
        ? `<div class="scout-tier-balance">${tierBalanceSummary(tierRows, playerMap)}</div>`
        : "";
      return `
        <div class="tier-block" data-tier="${tier}">
          <h3>${SCOUTING_TIER_LABELS[tier]} (${tierRows.length})</h3>
          ${balance}
          ${renderTierByPositionGroups(tier, tierRows, playerMap, draftUiByPlayer)}
        </div>`;
    })
    .join("");
}

function renderScoutingListsFromCache() {
  const wrap = document.getElementById("scoutingListsWrap");
  if (!wrap || !scoutingRows.length) return;
  paintScoutingLists(wrap, playerMapCache, draftUiByPlayerCache);
  wireScoutingListActions(wrap);
}

function wireScoutingListActions(wrap) {
  wireDraftActions(wrap);

  wrap.querySelectorAll(".scout-active-check").forEach((cb) => {
    cb.addEventListener("change", async () => {
      const pid = cb.dataset.playerId;
      const active = cb.checked;
      const row = scoutingRows.find((r) => String(r.player_id) === String(pid));
      if (row) row.is_active_target = active;
      wrap.querySelectorAll(`tr[data-player-id="${pid}"]`).forEach((tr) => {
        tr.classList.toggle("scout-active-row", active);
      });
      updateActiveTargetsHeader();
      try {
        await setScoutingActiveTarget(supabase, pid, active);
      } catch (err) {
        if (row) row.is_active_target = !active;
        cb.checked = !active;
        wrap.querySelectorAll(`tr[data-player-id="${pid}"]`).forEach((tr) => {
          tr.classList.toggle("scout-active-row", !active);
        });
        updateActiveTargetsHeader();
        alert(err?.message || "Could not update Active Target.");
      }
    });
  });

  wrap.querySelectorAll(".scout-tier-select").forEach((sel) => {
    sel.addEventListener("change", async () => {
      const pid = sel.dataset.playerId;
      const tier = Number(sel.value);
      try {
        await setScoutingTargetTier(supabase, pid, tier);
        await renderScoutingLists();
        if (document.getElementById("tab-planner")?.classList.contains("active")) {
          await initPlanner();
        }
      } catch (err) {
        alert(err?.message || "Could not change tier.");
      }
    });
  });

  wrap.querySelectorAll(".scout-remove").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const pid = btn.dataset.playerId;
      try {
        await toggleScoutingTarget(supabase, pid);
        await renderScoutingLists();
        if (document.getElementById("tab-planner")?.classList.contains("active")) {
          await initPlanner();
        }
      } catch (err) {
        alert(err?.message || "Could not remove target.");
      }
    });
  });
}

function boardLabel(boardNo) {
  const row = scoutingBoards.find((b) => Number(b.board_no) === Number(boardNo));
  const name = row?.name || `Board ${boardNo}`;
  return name;
}

function renderBoardPicker() {
  const sel = document.getElementById("scoutBoardSelect");
  const bar = document.getElementById("scoutBoardBar");
  if (!sel || !bar) return;

  if (!multiBoardEnabled) {
    bar.hidden = true;
    return;
  }

  bar.hidden = false;
  const boards =
    scoutingBoards.length > 0
      ? scoutingBoards
      : [1, 2, 3, 4].map((n) => ({ board_no: n, name: `Board ${n}` }));

  sel.innerHTML = boards
    .map(
      (b) =>
        `<option value="${b.board_no}">${escapeHtml(b.name || `Board ${b.board_no}`)}</option>`
    )
    .join("");
  sel.value = String(activeBoardNo);
  renderCopyFromPicker(boards);
}

function renderCopyFromPicker(boards) {
  const copySel = document.getElementById("scoutBoardCopyFrom");
  const copyBtn = document.getElementById("scoutBoardCopyBtn");
  if (!copySel) return;

  const list =
    boards ||
    (scoutingBoards.length > 0
      ? scoutingBoards
      : [1, 2, 3, 4].map((n) => ({ board_no: n, name: `Board ${n}` })));

  const others = list.filter((b) => Number(b.board_no) !== Number(activeBoardNo));
  const prev = copySel.value;
  copySel.innerHTML = others.length
    ? others
        .map(
          (b) =>
            `<option value="${b.board_no}">${escapeHtml(b.name || `Board ${b.board_no}`)}</option>`
        )
        .join("")
    : `<option value="">No other boards</option>`;

  if (others.some((b) => String(b.board_no) === String(prev))) {
    copySel.value = String(prev);
  }
  if (copyBtn) copyBtn.disabled = others.length === 0;
}

/** Convert saved planner rows into club_save_scouting_planner slot payload. */
function plannerRowsToSlots(rows) {
  return (rows || [])
    .filter((r) => {
      const kind = String(r.slot_kind || "").toLowerCase();
      return r.player_id && (kind === "pitch" || kind === "bench");
    })
    .map((r) => {
      const kind = String(r.slot_kind).toLowerCase();
      return {
        player_id: String(r.player_id),
        slot_kind: kind,
        pitch_slot: kind === "pitch" ? r.pitch_slot || null : null,
        sort_order: Number(r.sort_order) || 0,
      };
    });
}

function renderListBoardFilter() {
  const sel = document.getElementById("scoutListBoardFilter");
  if (!sel) return;

  const boards =
    scoutingBoards.length > 0
      ? scoutingBoards
      : [1, 2, 3, 4].map((n) => ({ board_no: n, name: `Board ${n}` }));

  const prev = listBoardFilter;
  sel.innerHTML =
    `<option value="all">Show all</option>` +
    boards
      .map(
        (b) =>
          `<option value="${b.board_no}">${escapeHtml(b.name || `Board ${b.board_no}`)}</option>`
      )
      .join("");

  const valid =
    prev === "all" || boards.some((b) => String(b.board_no) === String(prev));
  listBoardFilter = valid ? String(prev) : "all";
  sel.value = listBoardFilter;
}

function rowsForListFilter(rows) {
  if (listBoardFilter === "all") return rows;
  const boardNo = Number(listBoardFilter);
  return rows.filter((r) =>
    playerBoardMap.get(String(r.player_id))?.has(boardNo)
  );
}

function wireListBoardFilter() {
  const sel = document.getElementById("scoutListBoardFilter");
  if (!sel || sel.dataset.wired === "1") return;
  sel.dataset.wired = "1";
  sel.addEventListener("change", () => {
    listBoardFilter = String(sel.value || "all");
    renderScoutingListsFromCache();
  });
}

function escapeHtml(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function refreshBoardList() {
  try {
    scoutingBoards = await ensureScoutingBoards(supabase);
    multiBoardEnabled = true;
  } catch (err) {
    const msg = String(err?.message || err);
    if (/owner_scouting_multi_boards/i.test(msg)) {
      multiBoardEnabled = false;
      scoutingBoards = [{ board_no: 1, name: "Board 1" }];
      setPlannerStatus(msg, true);
    } else {
      throw err;
    }
  }
  if (!scoutingBoards.some((b) => Number(b.board_no) === activeBoardNo)) {
    activeBoardNo = 1;
  }
  setStoredScoutingBoardNo(activeBoardNo);
  renderBoardPicker();
  renderListBoardFilter();
}

async function initPlanner() {
  const root = document.getElementById("scoutingPlannerRoot");
  if (!root || !isScoutingAvailable()) return;

  await refreshBoardList();

  if (!scoutingPlayers.length) {
    root.innerHTML =
      '<p class="scout-empty">Add scouting targets in GPDB first, then plan a lineup here.</p>';
    const comp = document.getElementById("scoutPlannerComp");
    if (comp) {
      comp.hidden = true;
      comp.innerHTML = "";
    }
    return;
  }

  const state = await loadScoutingPlannerState(
    supabase,
    clubShort,
    activeBoardNo
  );
  if (state.multiBoard === false) {
    multiBoardEnabled = false;
    renderBoardPicker();
  }
  const { pitchLayout, rows } = state;
  plannerOooPlayerId = extractPlannerOooFromLayout(pitchLayout);
  plannerPlanNation =
    extractPlannerNationFromLayout(pitchLayout) ||
    clubNation ||
    squadDesignationsState?.club_nation ||
    null;
  await loadPlannerNationOptions();
  wirePlannerCompositionStrip();

  plannerApi = initMatchdaySquadPanel({
    root,
    allPlayers: playersForPlanner(),
    savedRows: rows,
    savedPitchLayout: pitchLayout,
    savedFormations: [],
    maxBench: 17,
    benchSubSlots: 12,
    maxSquad: 28,
    autoFillButtonLabel: "Autofill board",
    customAutoFill: ({ allPlayers: pool, maxBench, maxSquad, labels }) => {
      const budgetRaw = document.getElementById("scoutAutofillBudget")?.value;
      const budgetNum = Number(budgetRaw);
      const minStars = Number(
        document.getElementById("scoutAutofillMinStars")?.value || 0
      );
      const { state, summary } = autoFillScoutingBoard({
        allPlayers: pool,
        slotLabels: labels,
        maxBench,
        maxSquad,
        budget: Number.isFinite(budgetNum) && budgetNum > 0 ? budgetNum : null,
        planNation: plannerPlanNation || clubNation,
        minGk: MIN_GOALKEEPERS,
        minHg: MIN_HOME_GROWN,
        minU21: MIN_UNDER_21,
        minStars,
        minSquad: MIN_SQUAD_SIZE,
        starCap: Number(squadDesignationsState?.star_cap ?? 3),
        minStarRating: Number(squadDesignationsState?.star_min_rating ?? 79),
      });
      setPlannerStatus(summary);
      return state;
    },
    onChange: (_slots, panelState) => {
      updatePlannerCompositionStrip(panelState);
    },
    onSave: async (slots, pitchLayoutFromPanel) => {
      try {
        await saveScoutingPlanner(
          supabase,
          slots,
          pitchLayoutWithPlannerMeta(pitchLayoutFromPanel, {
            oooId: plannerOooPlayerId,
            planNation: plannerPlanNation,
          }),
          activeBoardNo
        );
        try {
          playerBoardMap = await loadScoutingPlannerPlayerBoards(supabase);
        } catch {
          /* keep prior map */
        }
        if (listBoardFilter !== "all") {
          renderScoutingListsFromCache();
        }
        const label = boardLabel(activeBoardNo);
        setPlannerStatus(
          multiBoardEnabled
            ? `Saved “${label}”.`
            : "Tactic board saved."
        );
      } catch (err) {
        setPlannerStatus(err?.message || "Save failed.", true);
        throw err;
      }
    },
    onSaveFormation: async () => {
      throw new Error("Custom formations are not saved on the scouting board.");
    },
    onLoadFormation: async () => null,
    onDeleteFormation: async () => null,
  });

  updatePlannerCompositionStrip(plannerApi?.getState?.() || null);

  const saveBtn = root.querySelector("#squadSaveBtn");
  if (saveBtn) {
    saveBtn.textContent = multiBoardEnabled
      ? `Save “${boardLabel(activeBoardNo)}”`
      : "Save tactic board";
  }

  const formBar = root.querySelector(".squad-formations-bar");
  if (formBar) {
    const savedRow = formBar.querySelector(".formation-section-row:nth-child(2)");
    if (savedRow) savedRow.style.display = "none";
  }

  const hint = root.querySelector(".squad-hint");
  if (hint) {
    hint.innerHTML = multiBoardEnabled
      ? "Drag <b>scouting targets</b> onto the pitch (11), <b>subs (1–12)</b>, and <b>squad fillers (13–17)</b>. " +
        "You have <b>4 named tactic boards</b> sharing one shortlist — switch boards above. " +
        "Planning only — not your matchday squad."
      : "Drag <b>scouting targets</b> onto the pitch (11), <b>subs (1–12)</b>, and <b>squad fillers (13–17)</b> to plan a potential lineup. " +
        "Click position labels to change roles. This is for planning only — not your matchday squad.";
  }
}

function wireBoardControls() {
  const sel = document.getElementById("scoutBoardSelect");
  const renameBtn = document.getElementById("scoutBoardRenameBtn");
  const copyBtn = document.getElementById("scoutBoardCopyBtn");

  sel?.addEventListener("change", async () => {
    activeBoardNo = setStoredScoutingBoardNo(sel.value);
    setPlannerStatus("");
    renderCopyFromPicker();
    try {
      await initPlanner();
    } catch (err) {
      setPlannerStatus(err?.message || "Could not load board.", true);
    }
  });

  renameBtn?.addEventListener("click", async () => {
    if (!multiBoardEnabled) {
      alert(
        "Run supabase/sql/patches/owner_scouting_multi_boards_20260813.sql first."
      );
      return;
    }
    const current = boardLabel(activeBoardNo);
    const next = prompt("Name for this tactic board:", current);
    if (next == null) return;
    const trimmed = String(next).trim();
    if (!trimmed) {
      alert("Name cannot be empty.");
      return;
    }
    try {
      await renameScoutingBoard(supabase, activeBoardNo, trimmed);
      await refreshBoardList();
      const saveBtn = document.querySelector("#scoutingPlannerRoot #squadSaveBtn");
      if (saveBtn) saveBtn.textContent = `Save “${boardLabel(activeBoardNo)}”`;
      setPlannerStatus(`Renamed to “${boardLabel(activeBoardNo)}”.`);
    } catch (err) {
      alert(err?.message || "Could not rename board.");
    }
  });

  copyBtn?.addEventListener("click", async () => {
    if (!multiBoardEnabled) {
      alert(
        "Run supabase/sql/patches/owner_scouting_multi_boards_20260813.sql first."
      );
      return;
    }
    const copySel = document.getElementById("scoutBoardCopyFrom");
    const fromNo = Number(copySel?.value || 0);
    if (!fromNo || fromNo === Number(activeBoardNo)) {
      alert("Pick a different board to copy from.");
      return;
    }

    const fromLabel = boardLabel(fromNo);
    const toLabel = boardLabel(activeBoardNo);
    if (
      !confirm(
        `Copy “${fromLabel}” onto “${toLabel}”?\n\nThis replaces the lineup, formation, plan nation, and planned OooO on “${toLabel}”. The board name stays the same.`
      )
    ) {
      return;
    }

    copyBtn.disabled = true;
    setPlannerStatus(`Copying from “${fromLabel}”…`);
    try {
      const source = await loadScoutingPlannerState(supabase, clubShort, fromNo);
      const slots = plannerRowsToSlots(source.rows);
      await saveScoutingPlanner(
        supabase,
        slots,
        source.pitchLayout || {},
        activeBoardNo
      );
      try {
        playerBoardMap = await loadScoutingPlannerPlayerBoards(supabase);
      } catch {
        /* keep prior map */
      }
      if (listBoardFilter !== "all") {
        renderScoutingListsFromCache();
      }
      await initPlanner();
      setPlannerStatus(`Copied “${fromLabel}” onto “${toLabel}”.`);
    } catch (err) {
      setPlannerStatus(err?.message || "Copy failed.", true);
      alert(err?.message || "Could not copy board.");
    } finally {
      copyBtn.disabled = false;
      renderCopyFromPicker();
    }
  });
}

function wireTabs() {
  document.querySelectorAll(".scout-tabs button[data-tab]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const tab = btn.dataset.tab;
      document.querySelectorAll(".scout-tabs button").forEach((b) => {
        b.classList.toggle("active", b.dataset.tab === tab);
      });
      document.querySelectorAll(".scout-tab-panel").forEach((panel) => {
        panel.classList.toggle("active", panel.id === `tab-${tab}`);
      });
      if (tab === "planner") {
        try {
          await initPlanner();
        } catch (err) {
          setPlannerStatus(err?.message || "Could not load tactic board.", true);
        }
      }
    });
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  initGpslInfoTips();
  await initGlobal();
  await loadPlayerValueTables();
  wireTabs();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  document.getElementById("userEmail").textContent = user.email;

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club, Nation")
    .eq("owner_id", user.id)
    .maybeSingle();

  clubShort = club?.ShortName || null;
  clubNation = club?.Nation || null;
  await loadClubsMap();

  const badgeEl = document.getElementById("clubBadgeHeader");
  const titleEl = document.getElementById("pageTitle");
  const metaEl = document.getElementById("scoutingPageMeta");

  if (clubShort) {
    const fullName = fullClubName(clubShort) || club.Club || clubShort;
    titleEl.textContent = `${fullName} — Scouting`;
    if (badgeEl) {
      badgeEl.src = `images/club_badges/${clubShort}.png`;
      badgeEl.alt = fullName;
      badgeEl.hidden = false;
    }
  } else {
    titleEl.textContent = "Your scouting board";
    if (badgeEl) {
      badgeEl.hidden = true;
      badgeEl.removeAttribute("src");
    }
    if (metaEl) {
      metaEl.innerHTML =
        "Star players in <a href=\"GPDB.html\" style=\"color:#ff9900;\">GPDB</a> (☆ column) to add them here. " +
        "Targets and up to <b>4 named tactic boards</b> are saved to <b>you</b> — they stay with you when you get a club. " +
        "Draft bidding unlocks after you are assigned a club.";
    }
  }

  wireBoardControls();
  await renderScoutingLists();
  await initPlanner();
});
