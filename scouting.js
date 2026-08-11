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
} from "./scouting_targets.js?v=20260811-scout-reg";
import { initMatchdaySquadPanel } from "./matchday_squad.js";
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
    Playstyle: p.Playstyle,
  }));
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

  wrap.innerHTML = [1, 2, 3, 4]
    .map((tier) => {
      const tierRows = sortScoutingRowsByPosition(
        scoutingRows.filter((r) => Number(r.tier) === tier),
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

  if (clubShort) {
    await loadOwnedSquadForReg();
  } else {
    ownedSquadPlayers = [];
    squadDesignationsState = null;
  }

  updateActiveTargetsHeader();
  await refreshAdvisoryBudgetBadge();

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

async function initPlanner() {
  const root = document.getElementById("scoutingPlannerRoot");
  if (!root || !isScoutingAvailable()) return;

  if (!scoutingPlayers.length) {
    root.innerHTML =
      '<p class="scout-empty">Add scouting targets in GPDB first, then plan a lineup here.</p>';
    return;
  }

  const { pitchLayout, rows } = await loadScoutingPlannerState(supabase, clubShort);

  plannerApi = initMatchdaySquadPanel({
    root,
    allPlayers: playersForPlanner(),
    savedRows: rows,
    savedPitchLayout: pitchLayout,
    savedFormations: [],
    onChange: () => {},
    onSave: async (slots, pitchLayoutFromPanel) => {
      try {
        await saveScoutingPlanner(supabase, slots, pitchLayoutFromPanel);
        setPlannerStatus("Tactic board saved.");
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

  const saveBtn = root.querySelector("#squadSaveBtn");
  if (saveBtn) saveBtn.textContent = "Save tactic board";

  const formBar = root.querySelector(".squad-formations-bar");
  if (formBar) {
    const savedRow = formBar.querySelector(".formation-section-row:nth-child(2)");
    if (savedRow) savedRow.style.display = "none";
  }

  const hint = root.querySelector(".squad-hint");
  if (hint) {
    hint.innerHTML =
      "Drag <b>scouting targets</b> onto the pitch (11) and bench (12) to plan a potential lineup. " +
      "Click position labels to change roles. This is for planning only — not your matchday squad.";
  }
}

function wireTabs() {
  document.querySelectorAll(".scout-tabs button[data-tab]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const tab = btn.dataset.tab;
      document.querySelectorAll(".scout-tabs button").forEach((b) => {
        b.classList.toggle("active", b.dataset.tab === tab);
      });
      document.querySelectorAll(".scout-tab-panel").forEach((panel) => {
        panel.classList.toggle("active", panel.id === `tab-${tab}`);
      });
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
        "Targets and the tactic board are saved to <b>you</b> — they stay with you when you get a club. " +
        "Draft bidding unlocks after you are assigned a club.";
    }
  }

  await renderScoutingLists();
  await initPlanner();
});
