import { supabase, initGlobal } from "./global.js";
import { initGpslInfoTips, tipAttrs } from "./gpsl_info_tips.js";
import { formatMoney } from "./competition.js";
import { loadClubsMap, fullClubName, displayClubName } from "./clubs_lookup.js";
import {
  loadPlayerValueTables,
  formatRatingWithPotential,
} from "./player_economics.js";
import { playerThumbLinkHtml, playerNameLinkHtml, gpdbPlayerUrl } from "./player_links.js";
import {
  SCOUTING_TIER_LABELS,
  SCOUTING_NEST_TIER_LABELS,
  isScoutingAvailable,
  scoutingSetupHint,
  loadScoutingTargets,
  setScoutingTargetAnchor,
  promoteScoutingToFirstTarget,
  setScoutingActiveTarget,
  setScoutingActiveTargetsBulk,
  toggleScoutingTarget,
  loadScoutingPlannerState,
  saveScoutingPlanner,
  ensureScoutingBoards,
  renameScoutingBoard,
  getStoredScoutingBoardNo,
  setStoredScoutingBoardNo,
  loadScoutingPlannerPlayerBoards,
} from "./scouting_targets.js?v=20260909-nested-backups";
import { initMatchdaySquadPanel, buildSlotsPayload, buildPitchLayoutPayload } from "./matchday_squad.js?v=20260909-nested-backups";
import { autoFillScoutingBoard } from "./scouting_autofill.js?v=20260821-autofill";
import {
  loadScoutingDraftContext,
  buildPlayerDraftUiState,
  renderDraftManageCell,
  submitScoutingDraftBid,
} from "./scouting_draft_actions.js?v=20260811-draft-list-fix";
import {
  confirmSquadRulesBeforeBid,
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
} from "./squad_designations.js";

/** Compact HG / ★ / U21 markers for scouting name cells. */
function scoutingPlayerBadgesHtml(player) {
  if (!player) return "";
  const minStar = Number(squadDesignationsState?.star_min_rating ?? 79);
  const badgeNation = effectiveListNation();
  const bits = [];
  if (isHomeGrownPlayer(player, badgeNation)) {
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
const LIST_BOARD_FILTER_KEY = "gpsl_scouting_list_board_filter";

function getStoredListBoardFilter() {
  try {
    const raw = String(localStorage.getItem(LIST_BOARD_FILTER_KEY) || "all").trim();
    if (raw === "all") return "all";
    const n = Number(raw);
    if (Number.isFinite(n) && n >= 1 && n <= 4) return String(Math.trunc(n));
  } catch {
    /* ignore */
  }
  return "all";
}

function setStoredListBoardFilter(value) {
  const next = String(value || "all");
  const stored =
    next === "all"
      ? "all"
      : Number.isFinite(Number(next)) && Number(next) >= 1 && Number(next) <= 4
        ? String(Math.trunc(Number(next)))
        : "all";
  try {
    localStorage.setItem(LIST_BOARD_FILTER_KEY, stored);
  } catch {
    /* ignore */
  }
  return stored;
}

let listBoardFilter = getStoredListBoardFilter();
/** @type {Map<string, Set<number>>} */
let playerBoardMap = new Map();
let multiBoardEnabled = true;
/** @type {object[]|null} */
let ownedSquadPlayers = null;
/** @type {object|null} */
let squadDesignationsState = null;
const SCOUTING_ALL_VIEW_ACTIVE_KEY = "gpsl_scouting_active_targets_all";
/** @type {Map<string, { activeIds: string[], planNation: string|null, hydrated: boolean }>} */
let boardViewStateCache = new Map();
/** Debounced auto-save after tactic-board placements. */
let plannerAutoSaveTimer = null;
let plannerPromoteBusy = false;
let plannerAutoSaveEnabled = false;
let plannerBaselineSlotsKey = "";

function plannerSlotsKey(slots) {
  try {
    return JSON.stringify(slots || []);
  } catch {
    return "";
  }
}

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

function isOwnedByMyClub(player) {
  return !!(
    clubShort &&
    player?.Contracted_Team &&
    String(player.Contracted_Team) === String(clubShort)
  );
}

function activeRowsForCurrentView() {
  return rowsForListFilter(scoutingRows).filter((row) => row.is_active_target);
}

function sumActiveTargetsBudget() {
  let total = 0;
  let count = 0;
  for (const row of activeRowsForCurrentView()) {
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

function currentActiveTargetIds() {
  return scoutingRows
    .filter((row) => row.is_active_target)
    .map((row) => String(row.player_id));
}

function currentVisiblePlayerIds() {
  return new Set(rowsForListFilter(scoutingRows).map((row) => String(row.player_id)));
}

function currentViewActiveTargetIds() {
  const visible = currentVisiblePlayerIds();
  return currentActiveTargetIds().filter((id) => visible.has(String(id)));
}

function effectiveListNation() {
  if (listBoardFilter !== "all") {
    const state = boardViewStateCache.get(String(listBoardFilter));
    if (state?.planNation) return state.planNation;
  }
  return clubNation || squadDesignationsState?.club_nation || null;
}

function readAllViewActiveIds() {
  try {
    const raw = JSON.parse(localStorage.getItem(SCOUTING_ALL_VIEW_ACTIVE_KEY) || "[]");
    return Array.isArray(raw) ? raw.map((x) => String(x || "").trim()).filter(Boolean) : [];
  } catch {
    return [];
  }
}

function writeAllViewActiveIds(ids) {
  try {
    localStorage.setItem(
      SCOUTING_ALL_VIEW_ACTIVE_KEY,
      JSON.stringify([...new Set((ids || []).map((x) => String(x || "").trim()).filter(Boolean))])
    );
  } catch {
    /* ignore */
  }
}

function plannerLayoutWithListMeta(layout, { activeIds = null, planNation } = {}) {
  const next = layout && typeof layout === "object" && !Array.isArray(layout)
    ? { ...layout }
    : {};
  if (activeIds) next.scouting_active_target_ids = [...new Set(activeIds.map((x) => String(x).trim()).filter(Boolean))];
  else delete next.scouting_active_target_ids;
  if (planNation) next.scouting_plan_nation = String(planNation).trim();
  else delete next.scouting_plan_nation;
  return next;
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

function activeTargetPlayers() {
  const out = [];
  for (const row of activeRowsForCurrentView()) {
    const p = playerMapCache.get(String(row.player_id));
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

  const nation = effectiveListNation();
  const activePlayers = activeTargetPlayers();
  const totals = tallyAdds(activePlayers, nation);
  const minStar = Number(squadDesignationsState?.star_min_rating ?? 79);
  const starCap = Number(squadDesignationsState?.star_cap ?? 2);
  const activeStars = countStarEligible(activePlayers, minStar, null);
  const activeLabel =
    listBoardFilter === "all"
      ? "Active targets (all views)"
      : `Active targets on ${boardLabel(listBoardFilter)}`;
  const tip =
    "Counts only the players currently ticked as Active Targets for this view. Targets already bought stay in the set. Sq 24–28 · ≥1 GK · ≥8 HG · ≥5 U21 · star cap.";

  el.hidden = false;
  el.innerHTML = `
    <span${tipAttrs(tip, "scout-reg-label")}>${escapeHtml(activeLabel)}:</span>
    ${boardChip("Sq", totals.n, [MIN_SQUAD_SIZE, SQUAD_SIZE], "range", `Active targets selected: ${totals.n} (need ${MIN_SQUAD_SIZE}–${SQUAD_SIZE})`)}
    ${boardChip("GK", totals.gk, MIN_GOALKEEPERS, "min", `Goalkeepers in active targets: ${totals.gk}`)}
    ${boardChip("HG", totals.hg, MIN_HOME_GROWN, "min", `Home-grown in active targets vs ${nation || "—"}: ${totals.hg}`)}
    ${boardChip("U21", totals.u21, MIN_UNDER_21, "min", `Under-21 in active targets: ${totals.u21}`)}
    ${boardChip("★", activeStars, starCap, "max", `Stars in active targets (rating ${minStar}+): ${activeStars} / cap ${starCap}`)}
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

function scoutingGroupSortIndex(groupName) {
  const names = [...Object.keys(SCOUTING_POSITION_GROUPS), "Other"];
  const idx = names.indexOf(groupName);
  return idx >= 0 ? idx : 999;
}

function sortScoutingRowsByPosition(rows, playerMap) {
  return [...rows].sort((a, b) => {
    const pa = playerMap.get(String(a.player_id));
    const pb = playerMap.get(String(b.player_id));
    const orderDiff = (Number(a.sort_order) || 0) - (Number(b.sort_order) || 0);
    if (orderDiff !== 0) return orderDiff;
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

function renderTierByPositionGroups(tier, tierRows, playerMap, draftUiByPlayer, allFilteredRows) {
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
              ? renderTierTable(
                  tier,
                  groupName,
                  rows,
                  playerMap,
                  draftUiByPlayer,
                  allFilteredRows
                )
              : `<p class="scout-empty scout-pos-empty">None in this group</p>`
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

function renderScoutPlayerRow({
  row,
  playerMap,
  draftUiByPlayer,
  showDraft,
  tier,
  groupName,
  idx,
  rowsLength,
  nested = false,
  nestChildrenHtml = "",
  nestChildIndex = 0,
  nestChildCount = 0,
}) {
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
  const isOwned = isOwnedByMyClub(p);
  const isLockedActive = isActive && isOwned;
  const hasYourBid = !!draftUi.yourBidText && draftUi.yourBidText !== "—";
  const activeTitle = activeTargetBudgetTitle(pid);
  const hasNests = !nested && nestChildCount > 0;
  const isLastNest = nested && nestChildIndex === nestChildCount - 1;
  const rowClass = [
    nested ? "scout-nested-row" : "scout-top-row",
    hasNests ? "scout-has-nests" : "",
    isLastNest ? "scout-nest-last" : "",
    isActive ? "scout-active-row" : "",
    hasYourBid ? "scout-bid-owned-row" : "",
    isLockedActive ? "scout-active-owned-row" : "",
  ]
    .filter(Boolean)
    .join(" ");

  const nestLabel = nested
    ? `<span class="scout-nest-label">${escapeHtml(
        SCOUTING_NEST_TIER_LABELS[Number(row.tier)] || `Tier ${row.tier}`
      )}</span>`
    : "";

  const nestCount = nested
    ? 0
    : nestChildCount || nestedRowsForAnchor(pid).length;
  const canAddNest = !nested && Number(tier) === 1 && nestCount < 3;
  const tierCell = nested
    ? `<td class="scout-nest-actions">
              <button type="button" class="scout-unlink-nest" data-player-id="${pid}" title="Unlink — become a top target again">Unlink</button>
            </td>`
    : `<td class="scout-nest-actions">
              <button type="button" class="scout-add-nest" data-anchor-id="${pid}" ${
                canAddNest ? "" : "disabled"
              } title="Add Backup / 3rd / 4th under this target">+</button>
              <span class="scout-nest-count">${nestCount}/3</span>
            </td>`;

  const moveCell = nested
    ? `<td></td>`
    : `<td>
              <button type="button" class="scout-move-btn" data-player-id="${pid}" data-tier="${tier}" data-group="${escapeHtml(
                groupName
              )}" data-dir="up" ${idx === 0 ? "disabled" : ""} title="Move up">▲</button>
              <button type="button" class="scout-move-btn" data-player-id="${pid}" data-tier="${tier}" data-group="${escapeHtml(
                groupName
              )}" data-dir="down" ${
                idx === rowsLength - 1 ? "disabled" : ""
              } title="Move down">▼</button>
            </td>`;

  const photoCell = nested
    ? `<td class="scout-photo"></td>`
    : `<td class="scout-photo">${playerThumbLinkHtml(pid, {
        className: "scout-thumb",
        alt: name,
      })}</td>`;

  return `
          <tr data-player-id="${pid}" class="${rowClass}">
            <td class="scout-nest-tree" aria-hidden="true"></td>
            ${photoCell}
            <td class="name">${nestLabel}${playerNameLinkHtml(
              pid,
              name
            )} <a href="${gpdbPlayerUrl(
              pid
            )}" class="gpsl-link" style="color:#ff9900;">GPDB</a>${scoutingPlayerBadgesHtml(
              p
            )}</td>
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
                ${isActive ? "checked" : ""} ${
                  isLockedActive ? "disabled" : ""
                } title="${
                  isLockedActive
                    ? "Already bought by your club - fixed active target"
                    : activeTitle
                }"
                aria-label="Active target for ${name}">
            </td>
            ${tierCell}
            ${moveCell}
            <td>
              <button type="button" class="scout-remove" data-player-id="${pid}" title="Remove from scouting">✕</button>
            </td>
          </tr>${nestChildrenHtml}`;
}

function renderTierTable(tier, groupName, rows, playerMap, draftUiByPlayer, allFilteredRows) {
  if (!rows.length) {
    return `<p class="scout-empty">No players — star targets in GPDB (☆).</p>`;
  }

  const showDraft = canUseDraftBidding();
  const nestSource = allFilteredRows || rowsForListFilter(scoutingRows);

  return `
    <table class="scout-table">
      <thead>
        <tr>
          <th class="scout-nest-tree-col" aria-hidden="true"></th>
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
          <th>Nest</th>
          <th>Move</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((row, idx) => {
            const pid = String(row.player_id);
            const children =
              Number(tier) === 1
                ? nestedRowsForAnchor(pid, nestSource)
                : [];
            const nestChildrenHtml = children
              .map((child, childIdx) =>
                renderScoutPlayerRow({
                  row: child,
                  playerMap,
                  draftUiByPlayer,
                  showDraft,
                  tier: Number(child.tier),
                  groupName,
                  idx: 0,
                  rowsLength: 1,
                  nested: true,
                  nestChildIndex: childIdx,
                  nestChildCount: children.length,
                })
              )
              .join("");
            return renderScoutPlayerRow({
              row,
              playerMap,
              draftUiByPlayer,
              showDraft,
              tier,
              groupName,
              idx,
              rowsLength: rows.length,
              nested: false,
              nestChildrenHtml,
              nestChildCount: children.length,
            });
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
    await loadPlannerNationOptions();
    renderListNationPicker();
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
  await loadPlannerNationOptions();

  paintScoutingLists(wrap, playerMap, draftUiByPlayer);
  renderListNationPicker();
  updateActiveTargetsHeader();
  await refreshAdvisoryBudgetBadge();
  wireScoutingListActions(wrap);
}

function isTopTargetRow(row) {
  return Number(row?.tier) === 1 && !row?.anchor_player_id;
}

function nestedRowsForAnchor(anchorId, rows = scoutingRows) {
  const aid = String(anchorId);
  return rows
    .filter((r) => String(r.anchor_player_id || "") === aid)
    .sort((a, b) => Number(a.tier) - Number(b.tier));
}

/** Scrollable nest picker — returns player_id or null if cancelled. */
function openNestPlayerPicker({ anchorName, rows }) {
  return new Promise((resolve) => {
    const byPos = [...rows].sort((a, b) => {
      const pa = playerMapCache.get(String(a.player_id));
      const pb = playerMapCache.get(String(b.player_id));
      const pos =
        scoutingPositionSortIndex(pa?.Position) -
        scoutingPositionSortIndex(pb?.Position);
      if (pos !== 0) return pos;
      const rating = (Number(pb?.Rating) || 0) - (Number(pa?.Rating) || 0);
      if (rating !== 0) return rating;
      return String(pa?.Name || "").localeCompare(String(pb?.Name || ""), "en", {
        sensitivity: "base",
      });
    });

    const overlay = document.createElement("div");
    overlay.className = "scout-nest-picker-overlay";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.setAttribute("aria-label", "Select nested target");

    const groups = groupTierRowsByPosition(byPos, playerMapCache);
    const groupNames = [...Object.keys(SCOUTING_POSITION_GROUPS), "Other"].filter(
      (name) => (groups[name] || []).length
    );

    const sortPickerGroup = (groupRows) =>
      [...groupRows].sort((a, b) => {
        const pa = playerMapCache.get(String(a.player_id));
        const pb = playerMapCache.get(String(b.player_id));
        const pos =
          scoutingPositionSortIndex(pa?.Position) -
          scoutingPositionSortIndex(pb?.Position);
        if (pos !== 0) return pos;
        const rating = (Number(pb?.Rating) || 0) - (Number(pa?.Rating) || 0);
        if (rating !== 0) return rating;
        return String(pa?.Name || "").localeCompare(String(pb?.Name || ""), "en", {
          sensitivity: "base",
        });
      });

    const listHtml = groupNames
      .map((groupName) => {
        const groupRows = sortPickerGroup(groups[groupName] || []);
        const items = groupRows
          .map((row) => {
            const pid = String(row.player_id);
            const p = playerMapCache.get(pid);
            const name = p?.Name || `Player ${pid}`;
            const rating = p
              ? formatRatingWithPotential(p.Rating, p.Potential, p.Calc_Potential)
              : "—";
            const note = row.anchor_player_id
              ? "Currently nested elsewhere"
              : Number(row.tier) > 1
                ? SCOUTING_NEST_TIER_LABELS[Number(row.tier)] || "Backup"
                : "";
            return `
              <button type="button" class="scout-nest-picker-item" data-player-id="${escapeHtml(
                pid
              )}">
                <span class="np-name">${escapeHtml(name)}${
                  note ? `<span class="np-note">${escapeHtml(note)}</span>` : ""
                }</span>
                <span class="np-pos">${escapeHtml(p?.Position || "—")}</span>
                <span class="np-rating">${escapeHtml(String(rating))}</span>
                <span class="np-muted">${escapeHtml(p?.Nation || "—")}</span>
                <span class="np-muted">${escapeHtml(
                  p?.Age != null ? String(p.Age) : "—"
                )}</span>
                <span class="np-muted">${escapeHtml(p?.Playstyle || "—")}</span>
              </button>`;
          })
          .join("");
        return `<div class="scout-nest-picker-group">${escapeHtml(
          groupName
        )}</div>${items}`;
      })
      .join("");

    overlay.innerHTML = `
      <div class="scout-nest-picker">
        <div class="scout-nest-picker-head">
          <h3>Add nested target</h3>
          <p>Under <b>${escapeHtml(
            anchorName || "top target"
          )}</b> — click a player (sorted GK → defence → midfield → attack).</p>
        </div>
        <div class="scout-nest-picker-list" tabindex="-1">
          <div class="scout-nest-picker-item scout-nest-picker-cols" aria-hidden="true">
            <span>Name</span><span>Pos</span><span>Rat</span><span>Nation</span><span>Age</span><span>Playstyle</span>
          </div>
          ${listHtml}
        </div>
        <div class="scout-nest-picker-foot">
          <button type="button" class="scout-nest-picker-cancel">Cancel</button>
        </div>
      </div>`;

    const finish = (value) => {
      document.removeEventListener("keydown", onKey);
      overlay.remove();
      resolve(value);
    };
    const onKey = (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        finish(null);
      }
    };

    overlay.addEventListener("click", (e) => {
      if (e.target === overlay) finish(null);
    });
    overlay
      .querySelector(".scout-nest-picker-cancel")
      ?.addEventListener("click", () => finish(null));
    overlay.querySelectorAll(".scout-nest-picker-item[data-player-id]").forEach((el) => {
      el.addEventListener("click", () => {
        finish(String(el.dataset.playerId || "") || null);
      });
    });

    document.addEventListener("keydown", onKey);
    document.body.appendChild(overlay);
    overlay.querySelector(".scout-nest-picker-list")?.focus?.();
  });
}

function firstTargetPlayersForAutofill() {
  const firstIds = new Set(
    scoutingRows.filter(isTopTargetRow).map((r) => String(r.player_id))
  );
  return playersForPlanner().filter((p) => firstIds.has(String(p.Konami_ID)));
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

  const topRows = sortScoutingRowsByPosition(
    filteredRows.filter(isTopTargetRow),
    playerMap
  );
  const topIds = new Set(topRows.map((r) => String(r.player_id)));
  const orphanRows = sortScoutingRowsByPosition(
    filteredRows.filter((r) => {
      if (!r.anchor_player_id && Number(r.tier) > 1) return true;
      // Nested under a missing / non-top anchor after list edits
      if (r.anchor_player_id && !topIds.has(String(r.anchor_player_id))) {
        // Still show under parent if parent is in filtered set as nested itself — skip
        const parentOnList = filteredRows.some(
          (p) => String(p.player_id) === String(r.anchor_player_id)
        );
        return !parentOnList;
      }
      return false;
    }),
    playerMap
  );
  const balance = topRows.length
    ? `<div class="scout-tier-balance">${tierBalanceSummary(topRows, playerMap)}</div>`
    : "";

  let html = `
    <div class="tier-block" data-tier="1">
      <h3>${SCOUTING_TIER_LABELS[1]} (${topRows.length})</h3>
      <p class="scout-tier-hint">Use <b>+</b> under a top target to add Backup / 3rd / 4th. Nested players stay in the squad pool until you place them on the board — then they become top targets (the previous first target returns to the pool).</p>
      ${balance}
      ${
        topRows.length
          ? renderTierByPositionGroups(1, topRows, playerMap, draftUiByPlayer, filteredRows)
          : '<p class="scout-empty">No top targets — star players in GPDB (☆), or promote a nested backup onto the tactic board.</p>'
      }
    </div>`;

  if (orphanRows.length) {
    html += `
      <div class="tier-block" data-tier="orphan">
        <h3>Unlinked backups (${orphanRows.length})</h3>
        <p class="scout-tier-hint">Older Backup / 3rd / 4th rows without a top-target link. Use a top target’s <b>+</b> to nest them, or leave them as independent pool options.</p>
        ${renderTierByPositionGroups("orphan", orphanRows, playerMap, draftUiByPlayer, filteredRows)}
      </div>`;
  }

  wrap.innerHTML = html;
}

function renderScoutingListsFromCache() {
  const wrap = document.getElementById("scoutingListsWrap");
  if (!wrap || !scoutingRows.length) return;
  paintScoutingLists(wrap, playerMapCache, draftUiByPlayerCache);
  renderListNationPicker();
  wireScoutingListActions(wrap);
}

async function saveTierGroupOrder(tier, groupName, orderedIds) {
  const updates = orderedIds.map((pid, idx) =>
    supabase
      .from("owner_scouting_targets")
      .update({ sort_order: (scoutingGroupSortIndex(groupName) + 1) * 1000 + idx })
      .eq("player_id", String(pid))
  );
  const results = await Promise.all(updates);
  const err = results.find((r) => r.error)?.error;
  if (err) throw err;

  const rank = new Map(orderedIds.map((pid, idx) => [String(pid), idx]));
  scoutingRows.forEach((row) => {
    const pid = String(row.player_id);
    if (!rank.has(pid)) return;
    const player = playerMapCache.get(pid);
    if (scoutingPositionGroupName(player?.Position) !== groupName) return;
    row.sort_order = (scoutingGroupSortIndex(groupName) + 1) * 1000 + rank.get(pid);
  });
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
        if (listBoardFilter === "all") {
          writeAllViewActiveIds(currentActiveTargetIds());
        } else {
          await saveBoardViewState(Number(listBoardFilter), {
            activeIds: currentViewActiveTargetIds(),
          });
        }
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

  wrap.querySelectorAll(".scout-add-nest").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const anchorId = String(btn.dataset.anchorId || "");
      if (!anchorId) return;
      const taken = new Set(
        nestedRowsForAnchor(anchorId).map((r) => String(r.player_id))
      );
      const candidateRows = scoutingRows.filter((r) => {
        const pid = String(r.player_id);
        if (pid === anchorId) return false;
        if (taken.has(pid)) return false;
        return true;
      });

      if (!candidateRows.length) {
        alert("No other scouting targets available to nest. Star more players in GPDB first.");
        return;
      }

      const anchorPlayer = playerMapCache.get(anchorId);
      const pickId = await openNestPlayerPicker({
        anchorName: anchorPlayer?.Name || `Player ${anchorId}`,
        rows: candidateRows,
      });
      if (!pickId) return;

      btn.disabled = true;
      try {
        await setScoutingTargetAnchor(supabase, pickId, anchorId);
        await renderScoutingLists();
        if (document.getElementById("tab-planner")?.classList.contains("active")) {
          await initPlanner();
        }
      } catch (err) {
        alert(err?.message || "Could not add nested target.");
      } finally {
        btn.disabled = false;
      }
    });
  });

  wrap.querySelectorAll(".scout-unlink-nest").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const pid = btn.dataset.playerId;
      try {
        await promoteScoutingToFirstTarget(supabase, pid);
        await renderScoutingLists();
        if (document.getElementById("tab-planner")?.classList.contains("active")) {
          await initPlanner();
        }
      } catch (err) {
        alert(err?.message || "Could not unlink nested target.");
      }
    });
  });

  wrap.querySelectorAll(".scout-move-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const pid = String(btn.dataset.playerId || "");
      const tier = btn.dataset.tier;
      const groupName = String(btn.dataset.group || "");
      const dir = String(btn.dataset.dir || "");
      if (!pid || !groupName || !dir) return;

      const groupRows = sortScoutingRowsByPosition(
        rowsForListFilter(scoutingRows).filter((row) => {
          if (!isTopTargetRow(row) && String(tier) !== "orphan") return false;
          if (String(tier) === "orphan") {
            if (row.anchor_player_id || Number(row.tier) <= 1) return false;
          } else if (!isTopTargetRow(row)) {
            return false;
          }
          const player = playerMapCache.get(String(row.player_id));
          return scoutingPositionGroupName(player?.Position) === groupName;
        }),
        playerMapCache
      );
      const ids = groupRows.map((row) => String(row.player_id));
      const index = ids.indexOf(pid);
      const swap = dir === "up" ? index - 1 : index + 1;
      if (index < 0 || swap < 0 || swap >= ids.length) return;

      [ids[index], ids[swap]] = [ids[swap], ids[index]];
      btn.disabled = true;
      try {
        await saveTierGroupOrder(tier === "orphan" ? 2 : 1, groupName, ids);
        renderScoutingListsFromCache();
      } catch (err) {
        alert(err?.message || "Could not move target.");
      } finally {
        btn.disabled = false;
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

function normalizePlannerSlots(slots) {
  return (slots || [])
    .map((s) => ({
      player_id: String(s.player_id || "").trim(),
      slot_kind: String(s.slot_kind || "").trim().toLowerCase(),
      pitch_slot: s.pitch_slot ? String(s.pitch_slot).trim() : null,
      sort_order: Number(s.sort_order) || 0,
    }))
    .filter((s) => s.player_id && (s.slot_kind === "pitch" || s.slot_kind === "bench"))
    .sort((a, b) => {
      const kind = String(a.slot_kind).localeCompare(String(b.slot_kind));
      if (kind !== 0) return kind;
      const slot = String(a.pitch_slot || "").localeCompare(String(b.pitch_slot || ""));
      if (slot !== 0) return slot;
      const order = a.sort_order - b.sort_order;
      if (order !== 0) return order;
      return a.player_id.localeCompare(b.player_id);
    });
}

function plannerSlotsEqual(a, b) {
  return JSON.stringify(normalizePlannerSlots(a)) === JSON.stringify(normalizePlannerSlots(b));
}

async function loadBoardViewState(boardNo) {
  const key = String(boardNo);
  const cached = boardViewStateCache.get(key);
  if (cached?.hydrated) return cached;

  const state = await loadScoutingPlannerState(supabase, clubShort, Number(boardNo));
  const boardPlayerIds = [...new Set((state.rows || []).map((r) => String(r.player_id || "").trim()).filter(Boolean))];
  const boardPlayerSet = new Set(boardPlayerIds);
  const savedActiveIds = Array.isArray(state.pitchLayout?.scouting_active_target_ids)
    ? state.pitchLayout.scouting_active_target_ids.map((x) => String(x || "").trim()).filter(Boolean)
    : null;
  const next = {
    activeIds: (savedActiveIds && savedActiveIds.length ? savedActiveIds : boardPlayerIds)
      .filter((id) => boardPlayerSet.has(id)),
    planNation: extractPlannerNationFromLayout(state.pitchLayout) || clubNation || null,
    hydrated: true,
  };
  boardViewStateCache.set(key, next);
  return next;
}

async function saveBoardViewState(boardNo, patch = {}) {
  const state = await loadScoutingPlannerState(supabase, clubShort, Number(boardNo));
  const boardPlayerSet = new Set(
    (state.rows || []).map((r) => String(r.player_id || "").trim()).filter(Boolean)
  );
  const prev = boardViewStateCache.get(String(boardNo)) || {
    activeIds: [],
    planNation: extractPlannerNationFromLayout(state.pitchLayout) || null,
    hydrated: true,
  };
  const next = {
    activeIds: (Array.isArray(patch.activeIds) ? patch.activeIds : prev.activeIds)
      .map((x) => String(x || "").trim())
      .filter((id) => boardPlayerSet.has(id)),
    planNation: Object.prototype.hasOwnProperty.call(patch, "planNation")
      ? (patch.planNation || null)
      : prev.planNation,
    hydrated: true,
  };

  const { error } = await supabase.rpc("scouting_set_board_meta", {
    p_board_no: Number(boardNo),
    p_pitch_layout: plannerLayoutWithListMeta(state.pitchLayout, {
      activeIds: next.activeIds,
      planNation: next.planNation,
    }),
  });
  if (error) {
    if (
      error.code === "PGRST202" ||
      String(error.message || "").includes("scouting_set_board_meta")
    ) {
      throw new Error(
        "Run supabase/sql/patches/owner_scouting_board_meta_20260907.sql in the Supabase SQL Editor, then reload."
      );
    }
    throw error;
  }

  boardViewStateCache.set(String(boardNo), next);
  return next;
}

async function applyActiveTargetSet(activeIds) {
  const wanted = new Set((activeIds || []).map((x) => String(x || "").trim()).filter(Boolean));
  scoutingRows.forEach((row) => {
    row.is_active_target = wanted.has(String(row.player_id));
  });
  renderScoutingListsFromCache();
  updateActiveTargetsHeader();
  await setScoutingActiveTargetsBulk(supabase, [...wanted]);
}

function renderListNationPicker() {
  const label = document.getElementById("scoutListNationLabel");
  const sel = document.getElementById("scoutListNationSelect");
  if (!label || !sel) return;

  if (listBoardFilter === "all") {
    label.hidden = true;
    sel.hidden = true;
    return;
  }

  const state = boardViewStateCache.get(String(listBoardFilter)) || null;
  const nation = state?.planNation || "";
  const nationOptions = [...plannerNationOptions];
  if (nation && !nationOptions.includes(nation)) nationOptions.unshift(nation);
  sel.innerHTML =
    `<option value="">— Select nation —</option>` +
    nationOptions
      .map((n) => `<option value="${escapeHtml(n)}"${n === nation ? " selected" : ""}>${escapeHtml(n)}</option>`)
      .join("");
  label.hidden = false;
  sel.hidden = false;
}

async function syncListFilterState(force = false) {
  if (!scoutingRows.length) {
    renderListNationPicker();
    return;
  }

  if (listBoardFilter === "all") {
    if (force) {
      const saved = readAllViewActiveIds();
      const ids = saved.length ? saved : currentActiveTargetIds();
      await applyActiveTargetSet(ids);
    }
    renderListNationPicker();
    return;
  }

  const state = await loadBoardViewState(Number(listBoardFilter));
  renderListNationPicker();
  if (force) {
    await applyActiveTargetSet(state.activeIds);
  }
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
  listBoardFilter = setStoredListBoardFilter(valid ? String(prev) : "all");
  sel.value = listBoardFilter;
}

function rowsForListFilter(rows) {
  if (listBoardFilter === "all") return rows;
  const boardNo = Number(listBoardFilter);
  const onBoard = new Set();
  for (const r of rows) {
    if (playerBoardMap.get(String(r.player_id))?.has(boardNo)) {
      onBoard.add(String(r.player_id));
    }
  }
  // Keep nested backups/3rd/4th visible under top targets on this board,
  // even when those nested players are not placed on the board themselves.
  return rows.filter((r) => {
    const pid = String(r.player_id);
    if (onBoard.has(pid)) return true;
    const anchor = r.anchor_player_id ? String(r.anchor_player_id) : "";
    return Boolean(anchor && onBoard.has(anchor));
  });
}

function wireListBoardFilter() {
  const sel = document.getElementById("scoutListBoardFilter");
  if (!sel || sel.dataset.wired === "1") return;
  sel.dataset.wired = "1";
  sel.addEventListener("change", async () => {
    const prev = listBoardFilter;
    const next = String(sel.value || "all");
    try {
      if (prev === "all") {
        writeAllViewActiveIds(currentActiveTargetIds());
      } else {
        await saveBoardViewState(Number(prev), {
          activeIds: currentViewActiveTargetIds(),
        });
      }
      listBoardFilter = setStoredListBoardFilter(next);
      await syncListFilterState(true);
    } catch (err) {
      listBoardFilter = prev;
      sel.value = prev;
      alert(err?.message || "Could not switch target view.");
    }
  });

  const nationSel = document.getElementById("scoutListNationSelect");
  nationSel?.addEventListener("change", async () => {
    if (listBoardFilter === "all") return;
    const planNation = nationSel.value ? String(nationSel.value) : null;
    try {
      await saveBoardViewState(Number(listBoardFilter), {
        activeIds: currentViewActiveTargetIds(),
        planNation,
      });
      if (Number(listBoardFilter) === Number(activeBoardNo)) {
        plannerPlanNation = planNation;
        updatePlannerCompositionStrip(plannerApi?.getState?.() || null);
      }
      renderScoutingListsFromCache();
      updateActiveTargetsHeader();
    } catch (err) {
      alert(err?.message || "Could not save board nation.");
      renderListNationPicker();
    }
  });
}

function escapeHtml(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * When a nested backup is placed on XI / subs / fillers, promote them to a top
 * target. The displaced previous first target is already returned to the pool by
 * placePlayer — owner decides what to do with them from there.
 */
async function promoteOnBoardPlayers(panelState) {
  const onBoard = playersOnPlannerBoard(panelState);
  const toPromote = [];
  for (const p of onBoard) {
    const pid = String(p?.Konami_ID || "");
    if (!pid) continue;
    const row = scoutingRows.find((r) => String(r.player_id) === pid);
    if (!row) continue;
    if (Number(row.tier) !== 1 || row.anchor_player_id) {
      toPromote.push(pid);
    }
  }
  if (!toPromote.length) return false;

  for (const pid of toPromote) {
    await promoteScoutingToFirstTarget(supabase, pid);
    const row = scoutingRows.find((r) => String(r.player_id) === pid);
    if (row) {
      row.tier = 1;
      row.anchor_player_id = null;
    }
  }
  renderScoutingListsFromCache();
  return true;
}

async function persistPlannerBoard(slots, pitchLayoutFromPanel, { remount = false, quiet = false } = {}) {
  let baseLayout = pitchLayoutFromPanel;
  if (baseLayout == null) {
    const meta = plannerApi?.getFormationMeta?.() || {};
    baseLayout = buildPitchLayoutPayload(
      meta.positions || {},
      meta.labels || {},
      meta.formationId
    );
  }
  const layoutPayload = pitchLayoutWithPlannerMeta(baseLayout, {
    oooId: plannerOooPlayerId,
    planNation: plannerPlanNation,
  });

  await saveScoutingPlanner(supabase, slots, layoutPayload, activeBoardNo);
  const persisted = await loadScoutingPlannerState(
    supabase,
    clubShort,
    activeBoardNo
  );
  if (!plannerSlotsEqual(slots, plannerRowsToSlots(persisted.rows))) {
    await saveScoutingPlanner(supabase, slots, layoutPayload, activeBoardNo);
  }
  try {
    playerBoardMap = await loadScoutingPlannerPlayerBoards(supabase);
  } catch {
    /* keep prior map */
  }
  const prevBoardState = boardViewStateCache.get(String(activeBoardNo));
  boardViewStateCache.set(String(activeBoardNo), {
    activeIds: prevBoardState?.activeIds || currentActiveTargetIds(),
    planNation: plannerPlanNation,
    hydrated: true,
  });
  if (listBoardFilter !== "all") {
    renderScoutingListsFromCache();
  }
  const label = boardLabel(activeBoardNo);
  setPlannerStatus(
    quiet
      ? multiBoardEnabled
        ? `Auto-saved “${label}”.`
        : "Tactic board auto-saved."
      : multiBoardEnabled
        ? `Saved “${label}”.`
        : "Tactic board saved."
  );
  if (remount) {
    await initPlanner();
  }
}

function schedulePlannerPromoteAndAutoSave(panelState, slots) {
  if (!plannerAutoSaveEnabled) return;
  const key = plannerSlotsKey(slots);
  if (key && key === plannerBaselineSlotsKey) return;

  if (plannerAutoSaveTimer) {
    clearTimeout(plannerAutoSaveTimer);
    plannerAutoSaveTimer = null;
  }
  plannerAutoSaveTimer = setTimeout(async () => {
    plannerAutoSaveTimer = null;
    try {
      if (!plannerPromoteBusy) {
        plannerPromoteBusy = true;
        try {
          await promoteOnBoardPlayers(panelState);
        } finally {
          plannerPromoteBusy = false;
        }
      }
      const payload =
        slots ||
        (panelState ? buildSlotsPayload(panelState) : null);
      if (!payload) return;
      await persistPlannerBoard(payload, null, { remount: false, quiet: true });
      plannerBaselineSlotsKey = plannerSlotsKey(payload);
    } catch (err) {
      setPlannerStatus(err?.message || "Auto-save failed.", true);
    }
  }, 450);
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

function runScoutingAutofill({ pool, maxBench, maxSquad, labels }) {
  const budgetRaw = document.getElementById("scoutAutofillBudget")?.value;
  const budgetNum = Number(budgetRaw);
  const minStars = Number(
    document.getElementById("scoutAutofillMinStars")?.value || 0
  );
  // Autofill only uses top targets — nested backups stay in the pool until placed manually.
  const firstPool = firstTargetPlayersForAutofill();
  const { state, summary } = autoFillScoutingBoard({
    allPlayers: firstPool.length ? firstPool : pool,
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
  // Keep nested / non-selected targets available in the pool on the full shortlist.
  if (firstPool.length && Array.isArray(pool) && state?.pool) {
    const used = new Set();
    for (const p of state.pitch?.values?.() || []) {
      if (p) used.add(String(p.Konami_ID));
    }
    for (const p of state.bench || []) {
      if (p) used.add(String(p.Konami_ID));
    }
    state.pool = pool
      .filter((p) => !used.has(String(p.Konami_ID)))
      .map((p) => ({ ...p }));
  }
  setPlannerStatus(summary);
  return state;
}

function wireAutofillBar() {
  const btn = document.getElementById("scoutAutofillRunBtn");
  if (!btn || btn.dataset.wired === "1") return;
  btn.dataset.wired = "1";
  btn.addEventListener("click", () => {
    const hidden = document.querySelector(
      "#scoutingPlannerRoot #squadAutoFillBtn"
    );
    if (hidden) {
      hidden.click();
      return;
    }
    // Fallback if panel not ready
    if (!plannerApi?.applyState) {
      setPlannerStatus("Open the tactic board first.", true);
      return;
    }
    const meta = plannerApi.getFormationMeta?.() || {};
    const next = runScoutingAutofill({
      pool: playersForPlanner(),
      maxBench: 17,
      maxSquad: 28,
      labels: meta.labels || {},
    });
    plannerApi.applyState(next);
    updatePlannerCompositionStrip(plannerApi.getState?.() || next);
  });
}

async function initPlanner() {
  let root = document.getElementById("scoutingPlannerRoot");
  if (!root || !isScoutingAvailable()) return;

  if (plannerAutoSaveTimer) {
    clearTimeout(plannerAutoSaveTimer);
    plannerAutoSaveTimer = null;
  }
  plannerAutoSaveEnabled = false;

  // Drop any prior matchday_squad root listeners before re-mounting this board.
  const freshRoot = root.cloneNode(false);
  root.replaceWith(freshRoot);
  root = freshRoot;

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
  const existingBoardState = boardViewStateCache.get(String(activeBoardNo));
  boardViewStateCache.set(String(activeBoardNo), {
    activeIds: existingBoardState?.activeIds?.length
      ? existingBoardState.activeIds
      : (
          Array.isArray(pitchLayout?.scouting_active_target_ids)
            ? pitchLayout.scouting_active_target_ids
            : rows.map((r) => String(r.player_id || "").trim()).filter(Boolean)
        ),
    planNation: plannerPlanNation,
    hydrated: true,
  });
  await loadPlannerNationOptions();
  wirePlannerCompositionStrip();
  wireAutofillBar();

  plannerApi = initMatchdaySquadPanel({
    root,
    allPlayers: playersForPlanner(),
    savedRows: rows,
    savedPitchLayout: pitchLayout,
    savedFormations: [],
    maxBench: 17,
    benchSubSlots: 12,
    maxSquad: 28,
    showGpdbLink: true,
    autoFillButtonLabel: "Autofill board",
    customAutoFill: ({ allPlayers: pool, maxBench, maxSquad, labels }) => {
      return runScoutingAutofill({ pool, maxBench, maxSquad, labels });
    },
    onChange: (_slots, panelState) => {
      updatePlannerCompositionStrip(panelState);
      schedulePlannerPromoteAndAutoSave(panelState, _slots);
    },
    onSave: async (slots, pitchLayoutFromPanel) => {
      try {
        await persistPlannerBoard(slots, pitchLayoutFromPanel, { remount: true });
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
  plannerBaselineSlotsKey = plannerSlotsKey(
    buildSlotsPayload(plannerApi?.getState?.() || { pitch: new Map(), bench: [], pool: [] })
  );
  // Allow auto-save after the initial mount onChange has settled.
  queueMicrotask(() => {
    plannerAutoSaveEnabled = true;
  });

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
      ? "Drag <b>scouting targets</b> onto the pitch (11), <b>subs (12-23)</b>, and <b>squad fillers (24-28)</b>. " +
        "Drag a player onto another to <b>swap</b>. Use <b>✕</b> to send them back to the pool. " +
        "You have <b>4 named tactic boards</b> sharing one shortlist — switch boards above. " +
        "Planning only — not your matchday squad."
      : "Drag <b>scouting targets</b> onto the pitch (11), <b>subs (12-23)</b>, and <b>squad fillers (24-28)</b>. " +
        "Drag onto another player to <b>swap</b>. Use <b>✕</b> to return to the pool. " +
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
      boardViewStateCache.delete(String(activeBoardNo));
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
