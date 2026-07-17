// squad.js — CLEAN, FIXED, MODERN VERSION WITH TRANSFER WINDOW LOGIC

import { fullClubName } from "./clubs_lookup.js";
import {
  computeStandardListingEndTime,
  initGlobal,
  refreshNavClubListingState,
  refreshNavListingIndicators,
  supabase,
} from "./global.js";
import {
  loadPlayerSeasonStatsForSquad,
  statsMapByPlayerId,
} from "./competition.js";
import {
  analyseSquadComposition,
  analyseSquadCompositionProjected,
  playerSquadQualificationBadges,
  squadComplianceRuleRows,
  shortComplianceRequirement,
  shortComplianceStatus,
  complianceRowTooltip,
} from "./squad_rules.js";
import {
  loadSquadGhostAcquisitions,
  formatGhostPlayerNameCell,
  formatGhostStatusHtml,
} from "./squad_ghost_acquisitions.js";
import {
  loadPlayerValueTables,
  formatRatingWithPotential,
} from "./player_economics.js";
import {
  loadTransferStatusState,
  resolvePlayerTransferStatus,
  formatSquadStatusHtml,
} from "./player_transfer_status.js";
import {
  loadActiveSuspensions,
  suspensionsByPlayerId,
  formatSuspensionStatusHtml,
  loadClubSquadDiscipline,
  cardsByPlayerId,
  injuriesByPlayerId,
  formatInjuryStatusHtml,
  formatCardsStatusHtml,
} from "./player_discipline.js?v=20260714-injury-status-copy";
import {
  loadCurrentGpslSeasonLabel,
  playerBlockedSameSeasonTransfer,
  playerBlockedFromTransferMarket,
  SAME_SEASON_TRANSFER_MESSAGE,
  FINAL_YEAR_TRANSFER_MESSAGE,
} from "./player_season_transfer.js";
import {
  formatSquadContractCell,
  squadContractActionOptionsHtml,
  isContractFinalYear,
} from "./player_contracts.js";
import { isHgContractProtected } from "./squad_rules.js";
import { formatWage } from "./wages.js";
import {
  escapeHtml,
  formatForeignTrackingMessage,
  foreignSaleOptionsHtml,
  parseForeignSaleAction,
} from "./foreign_interest.js";
import {
  MAX_VOLUNTARY_CONTRACT_RELEASES,
  VOLUNTARY_RELEASE_ACTION,
  calculateVoluntaryReleaseCost,
  normalizeVoluntaryReleasesRemaining,
  voluntaryReleaseOptionLabel,
} from "./voluntary_contract_release.js";
import {
  MAX_NEW_OWNER_RELEASES,
  NEW_OWNER_RELEASE_ACTION,
  NEW_OWNER_LIST_ACTION,
  normalizeNewOwnerReleasesRemaining,
  newOwnerReleaseOptionLabel,
  newOwnerListOptionLabel,
  newOwnerSlotBadgeText,
} from "./new_owner_release.js";
import {
  loadSquadDesignationsState,
  setSquadDesignation,
  squadRoleActionOptionsHtml,
  designationForPlayer,
  designationRoleBadge,
  playerEligibleStar,
  starComplianceRow,
  oooComplianceRow,
  DESIGNATION_STAR,
  DESIGNATION_OOO,
} from "./squad_designations.js";
import {
  loadActiveSeasonLoanPlayerIds,
  loadClubSquadMinimumStatus,
  seasonLoanBadgeHtml,
  seasonLoanTerminateOptionHtml,
  TERMINATE_SEASON_LOAN_ACTION,
  terminateSeasonLoan,
} from "./season_loan.js";
import {
  playerThumbLinkHtml,
  playerNameLinkHtml,
  pesdbPlayerUrl,
} from "./player_links.js";

window.supabase = supabase;

/** Columns needed for squad table + list modal (avoid select *). */
const SQUAD_PLAYER_COLUMNS =
  "Konami_ID, Name, Nation, Position, Rating, Potential, Calc_Potential, Age, market_value, Playstyle, Maximum_Reserve_Price, Contracted_Team, Season_Signed, contract_seasons_remaining, contract_wage";

const SQUAD_PLAYER_COLUMNS_LEGACY =
  "Konami_ID, Name, Nation, Position, Rating, Age, market_value, Playstyle, Maximum_Reserve_Price, Contracted_Team, Season_Signed, contract_seasons_remaining, contract_wage";

const SQUAD_TABLE_COLS = 15;

const SQUAD_COLUMN_HEADER_CELLS = [
  ["squad-col-thumb", ""],
  ["squad-col-player", "Player"],
  ["squad-col-nation", "Nation"],
  ["squad-col-position", "Pos"],
  ["squad-col-age", "Age"],
  ["squad-col-rating", "Rating (Pot.)"],
  ["squad-col-stat", "Apps"],
  ["squad-col-stat", "G"],
  ["squad-col-stat", "A"],
  ["squad-col-stat", "Avg"],
  ["squad-col-playstyle", "Playstyle"],
  ["squad-col-value", "Market Value"],
  ["squad-col-contract", "Contract"],
  ["squad-col-status", "Status"],
  ["squad-col-action", "Action"],
];

let squadColumnWidthResizeTimer = null;

function createSquadSectionColumnHeaderRow() {
  const tr = document.createElement("tr");
  tr.className = "squad-section-cols-row";
  tr.innerHTML = SQUAD_COLUMN_HEADER_CELLS.map(
    ([cls, label]) => `<th scope="col" class="${cls}">${label}</th>`
  ).join("");
  return tr;
}

function appendSquadSectionHeader(tbody, groupName, { ghost = false } = {}) {
  const titleRow = document.createElement("tr");
  titleRow.className = ghost
    ? "squad-section-row squad-section-row--ghost"
    : "squad-section-row";
  titleRow.innerHTML = `<td colspan="${SQUAD_TABLE_COLS}" class="squad-section-title">${groupName}</td>`;
  tbody.appendChild(titleRow);
  tbody.appendChild(createSquadSectionColumnHeaderRow());
}

function isMissingEconomicsColumnError(error) {
  const msg = String(error?.message || "").toLowerCase();
  return msg.includes("potential") || msg.includes("calc_potential");
}

// STATE
let userObj = null;
let userId = null;
let currentUserShort = null;
let clubNation = null;
let selectedPlayerForListing = null;

// ⭐ NEW: Transfer window state
let transferWindowOpen = true;
let transferStatusState = null;
/** @type {Map<string, any[]>} */
let squadSuspensionsByPlayer = new Map();
/** @type {Map<string, any[]>} */
let squadInjuriesByPlayer = new Map();
/** @type {Map<string, { yellows: number, reds: number }>} */
let squadCardsByPlayer = new Map();
/** Tokens / appeal cards available for squad Action menu */
let squadRewardCtx = {
  hasDoctor: false,
  specialistTokens: 0,
  specialistTier: 2,
  prizeMedical: [],
  appealCards: [],
  /** @type {Map<string, any>} */
  appealableByPlayer: new Map(),
};
let currentGpslSeasonLabel = "";

const MAX_FOREIGN_INTEREST = 3;
let foreignInterestRemaining = MAX_FOREIGN_INTEREST;
/** Fictional clubs currently tracking (same length as interest slots). */
let foreignTrackingTeams = [];
let voluntaryReleasesRemaining = MAX_VOLUNTARY_CONTRACT_RELEASES;
let newOwnerReleaseState = {
  remaining: 0,
  firstSeason: false,
  windowOpen: false,
  availableNow: false,
  listAvailableNow: false,
  activeListings: 0,
};
let squadManagerState = {
  loaded: false,
  managerId: null,
  managerName: null,
  managerRating: null,
  marketValue: 0,
  sacksRemaining: 0,
  sackWindowOpen: false,
};
let playerPurchaseFeeById = new Map();
let squadDesignationsState = null;
let squadMinimumStatus = null;
/** @type {Set<string>} */
let seasonLoanPlayerIds = new Set();
/** @type {object[]} */
let squadGhostPlayers = [];

// ENTRY POINT
document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadPlayerValueTables();

  const { data: { user } } = await supabase.auth.getUser();

  if (!user) {
    window.location = "login.html";
    return;
  }

  userObj = user;
  userId = user.id;

  document.getElementById("userEmail").textContent = user.email;

  // Load club
  let club = null;
  let clubErr = null;

  const clubRes = await supabase
    .from("Clubs")
    .select(
      "ShortName, Club, Nation, foreign_interest_remaining, voluntary_contract_releases_remaining"
    )
    .eq("owner_id", user.id)
    .single();

  club = clubRes.data;
  clubErr = clubRes.error;

  if (clubErr?.code === "42703") {
    const fallback = await supabase
      .from("Clubs")
      .select("ShortName, Club, Nation, foreign_interest_remaining")
      .eq("owner_id", user.id)
      .single();
    club = fallback.data;
    clubErr = fallback.error;
  }

  if (clubErr || !club) {
    alert("No club assigned to this account.");
    return;
  }

  currentUserShort = club.ShortName;
  clubNation = club.Nation ?? null;
  window.GPSL_CLUB_SHORTNAME = currentUserShort;

  document.getElementById("dashboardTitle").textContent = `${club.Club} Squad`;
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${currentUserShort}.png`;

  foreignInterestRemaining = normalizeForeignInterest(
    club.foreign_interest_remaining
  );
  voluntaryReleasesRemaining = normalizeVoluntaryReleasesRemaining(
    club.voluntary_contract_releases_remaining
  );
  await Promise.all([
    loadForeignInterestState(),
    loadVoluntaryReleaseState(),
    loadNewOwnerReleaseState(),
    loadSquadManagerState(),
  ]);
  renderForeignInterestBadge();
  renderVoluntaryReleaseBadge();
  renderNewOwnerReleaseBadge();
  renderSquadManagerBadge();
  applyForeignSaleOptionState();
  applyVoluntaryReleaseOptionState();

  wireButtons();
  wireSquadTable();

  await loadTransferWindowStatus();
  applyNewOwnerReleaseOptionState();
  await loadSquad();

  setInterval(async () => {
    await loadTransferWindowStatus();
    await loadNewOwnerReleaseState();
    syncNewOwnerListAvailability();
    renderNewOwnerReleaseBadge();
    applyNewOwnerReleaseOptionState();
    await loadSquad();
  }, 30000);
});

// ⭐ NEW: Load transfer window status
async function loadTransferWindowStatus() {
  const { data, error } = await supabase
    .from("global_settings_public")
    .select("transfer_window_open")
    .eq("id", 1)
    .single();

  if (error) {
    console.error("Failed to load transfer window status:", error);
    transferWindowOpen = true; // fail-safe
    return;
  }

  transferWindowOpen = data?.transfer_window_open === true;
  syncNewOwnerListAvailability();
}

function syncNewOwnerListAvailability() {
  newOwnerReleaseState.listAvailableNow =
    newOwnerReleaseState.availableNow &&
    newOwnerReleaseState.remaining > 0 &&
    transferWindowOpen;
}

// ⭐ NEW: Apply UI rules when window is closed
function normalizeForeignInterest(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return MAX_FOREIGN_INTEREST;
  return Math.max(0, Math.min(MAX_FOREIGN_INTEREST, Math.trunc(n)));
}

async function loadForeignInterestState() {
  const { data, error } = await supabase.rpc("club_foreign_interest_state");

  if (error) {
    const msg = String(error.message || "").toLowerCase();
    if (
      msg.includes("club_foreign_interest_state") ||
      msg.includes("foreign_tracking") ||
      error.code === "42883"
    ) {
      foreignTrackingTeams = [];
      return;
    }
    console.warn("club_foreign_interest_state:", error);
    foreignTrackingTeams = [];
    return;
  }

  if (data?.foreign_interest_remaining != null) {
    foreignInterestRemaining = normalizeForeignInterest(
      data.foreign_interest_remaining
    );
  }
  foreignTrackingTeams = Array.isArray(data?.tracking_teams)
    ? data.tracking_teams.map((t) => String(t))
    : [];
}

function renderForeignInterestBadge() {
  const el = document.getElementById("foreignInterestBadge");
  if (!el) return;

  const teams = foreignTrackingTeams.filter(Boolean);
  const n = teams.length || foreignInterestRemaining;
  el.classList.toggle("foreign-interest-badge--empty", n <= 0);

  if (n <= 0) {
    el.textContent = "No foreign clubs interested in your players";
    return;
  }

  const main =
    teams.length > 0
      ? formatForeignTrackingMessage(teams)
      : `${n} foreign ${n === 1 ? "club" : "clubs"} interested in your players`;

  el.innerHTML = `
    <span class="foreign-interest-main">${escapeHtml(main)}</span><span class="foreign-interest-hint"> · Sell via Action at market value</span>`;
}

function voluntaryReleaseOptionHtml(player) {
  const cost = calculateVoluntaryReleaseCost(
    player?.contract_wage,
    player?.contract_seasons_remaining
  );
  if (voluntaryReleasesRemaining <= 0) {
    return `<option value="" disabled>${voluntaryReleaseOptionLabel(0, cost)}</option>`;
  }
  return `<option value="${VOLUNTARY_RELEASE_ACTION}">${voluntaryReleaseOptionLabel(
    voluntaryReleasesRemaining,
    cost
  )}</option>`;
}

function newOwnerReleaseOptionHtml(player) {
  if (!newOwnerReleaseState.firstSeason && !newOwnerReleaseState.availableNow) {
    return "";
  }

  const pid = String(player?.Konami_ID ?? "");
  const fee = playerPurchaseFeeById.has(pid)
    ? playerPurchaseFeeById.get(pid)
    : null;
  const remaining = newOwnerReleaseState.remaining;
  const availableNow = newOwnerReleaseState.availableNow;
  const eligibleFee = fee != null && fee > 0;

  if (!newOwnerReleaseState.firstSeason) {
    return "";
  }

  if (remaining <= 0) {
    return `<option value="" disabled>${newOwnerReleaseOptionLabel(0, fee, {
      firstSeason: true,
      availableNow: false,
    })}</option>`;
  }

  if (!availableNow) {
    return `<option value="" disabled>${newOwnerReleaseOptionLabel(remaining, fee, {
      firstSeason: true,
      availableNow: false,
    })}</option>`;
  }

  if (!eligibleFee) {
    return `<option value="" disabled>${newOwnerReleaseOptionLabel(remaining, fee, {
      firstSeason: true,
      availableNow: true,
    })}</option>`;
  }

  return `<option value="${NEW_OWNER_RELEASE_ACTION}">${newOwnerReleaseOptionLabel(
    remaining,
    fee,
    { firstSeason: true, availableNow: true }
  )}</option>`;
}

function newOwnerListOptionHtml(player) {
  if (!newOwnerReleaseState.firstSeason) {
    return "";
  }

  const remaining = newOwnerReleaseState.remaining;
  const availableNow = newOwnerReleaseState.availableNow;
  const listNow = newOwnerReleaseState.listAvailableNow;
  const blockedReason = newOwnerListBlockedReason(player);

  if (remaining <= 0) {
    return `<option value="" disabled>${newOwnerListOptionLabel(remaining, {
      firstSeason: true,
      availableNow: false,
      transferWindowOpen: transferWindowOpen,
    })}</option>`;
  }

  if (!availableNow) {
    return `<option value="" disabled>${newOwnerListOptionLabel(remaining, {
      firstSeason: true,
      availableNow: false,
      transferWindowOpen: transferWindowOpen,
    })}</option>`;
  }

  if (blockedReason) {
    return `<option value="" disabled>${newOwnerListOptionLabel(remaining, {
      firstSeason: true,
      availableNow: true,
      transferWindowOpen: transferWindowOpen,
    })} — ${blockedReason}</option>`;
  }

  if (!listNow) {
    return `<option value="" disabled>${newOwnerListOptionLabel(remaining, {
      firstSeason: true,
      availableNow: true,
      transferWindowOpen: false,
    })}</option>`;
  }

  return `<option value="${NEW_OWNER_LIST_ACTION}">${newOwnerListOptionLabel(remaining, {
    firstSeason: true,
    availableNow: true,
    transferWindowOpen: true,
  })}</option>`;
}

function squadBestMedicalConsult() {
  const rows = squadRewardCtx.prizeMedical || [];
  if (!rows.length) return null;
  return rows[0];
}

function squadRewardActionOptionsHtml(player) {
  const pid = String(player?.Konami_ID ?? "");
  const opts = [];

  const injRows = squadInjuriesByPlayer.get(pid) || [];
  const consult = squadBestMedicalConsult();
  const canMedical =
    squadRewardCtx.hasDoctor &&
    (!!consult || squadRewardCtx.specialistTokens > 0);
  if (canMedical) {
    for (const inj of injRows) {
      if (inj.token_used) continue;
      const iid = inj.injury_id ?? inj.id;
      if (!iid) continue;
      const out = Number(inj.matches_out_remaining) || 0;
      const rec = Number(inj.recovery_remaining) || 0;
      if (out <= 0 && rec <= 0) continue;
      const tier =
        Number(consult?.param_int ?? consult?.matches_removed) ||
        squadRewardCtx.specialistTier ||
        2;
      const who =
        consult?.label ||
        consult?.consultancy_label ||
        `Specialist consult −${tier}`;
      const injLabel = inj.label ? ` (${inj.label})` : "";
      opts.push(
        `<option value="medical:${iid}">${who} (−${tier})${injLabel}</option>`
      );
    }
  }

  const appeal = squadRewardCtx.appealableByPlayer.get(pid);
  if (appeal && squadRewardCtx.appealCards.length) {
    const left = appeal.pending_matches != null ? ` (${appeal.pending_matches} left)` : "";
    opts.push(
      `<option value="appeal:${appeal.suspension_id}">Appeal red card ban${left}</option>`
    );
  }

  return opts.join("\n");
}

function squadActionOptionsHtml(player) {
  const pid = String(player?.Konami_ID ?? "");
  if (seasonLoanPlayerIds.has(pid)) {
    return seasonLoanTerminateOptionHtml(
      !!squadMinimumStatus?.can_terminate_loans
    );
  }

  const rewardOpts = squadRewardActionOptionsHtml(player);
  const releaseOpt = voluntaryReleaseOptionHtml(player);
  const newOwnerOpt = newOwnerReleaseOptionHtml(player);
  const newOwnerListOpt = newOwnerListOptionHtml(player);
  const releaseGroup = `${releaseOpt}${newOwnerOpt}${newOwnerListOpt}`;
  const contractOpts = squadContractActionOptionsHtml(player, clubNation, {
    optionHtml: `${rewardOpts}${releaseGroup}`,
  });
  if (contractOpts) return contractOpts;

  if (!playerCanListOrSellLocal(player)) {
    if (isContractFinalYear(player)) {
      return `${rewardOpts}<option value="" disabled>Final contract year</option>${releaseGroup}`;
    }
    return `${rewardOpts}${releaseGroup}
            <option value="" disabled>Signed this season</option>`;
  }
  const foreignOpts =
    foreignTrackingTeams.length > 0
      ? foreignSaleOptionsHtml(foreignTrackingTeams)
      : `<option value="foreign">Sell to foreign club</option>`;

  return `
            ${rewardOpts}
            <option value="list">Transfer List</option>
            ${foreignOpts}
            ${releaseGroup}`;
}

function playerCanListOrSellLocal(player) {
  return playerBlockedFromTransferMarket(player, currentGpslSeasonLabel) === false;
}

/** New Owner transfer list bypasses the same-season signing lock. */
function newOwnerListBlockedReason(player) {
  if (isContractFinalYear(player)) {
    return "final contract year";
  }
  return null;
}

async function loadVoluntaryReleaseState() {
  const { data, error } = await supabase.rpc(
    "club_voluntary_contract_release_state"
  );

  if (error) {
    const msg = String(error.message || "").toLowerCase();
    if (
      msg.includes("club_voluntary_contract_release_state") ||
      msg.includes("voluntary_contract_releases") ||
      error.code === "42883"
    ) {
      return;
    }
    console.warn("club_voluntary_contract_release_state:", error);
    return;
  }

  if (data?.voluntary_contract_releases_remaining != null) {
    voluntaryReleasesRemaining = normalizeVoluntaryReleasesRemaining(
      data.voluntary_contract_releases_remaining
    );
  }
}

function renderVoluntaryReleaseBadge() {
  const el = document.getElementById("voluntaryReleaseBadge");
  if (!el) return;

  const n = voluntaryReleasesRemaining;
  el.classList.toggle("foreign-interest-badge--empty", n <= 0);
  if (n <= 0) {
    el.textContent = "No voluntary releases left (0/3)";
    return;
  }

  el.innerHTML = `
    <span class="foreign-interest-main">${n} voluntary ${n === 1 ? "release" : "releases"} left · max 3/season</span><span class="foreign-interest-hint"> · Pays wages · out until next season</span>`;
}

async function loadNewOwnerReleaseState() {
  const { data, error } = await supabase.rpc("club_new_owner_release_state");

  if (error) {
    const msg = String(error.message || "").toLowerCase();
    if (
      msg.includes("club_new_owner_release_state") ||
      msg.includes("new_owner_releases") ||
      error.code === "42883"
    ) {
      newOwnerReleaseState = {
        remaining: 0,
        firstSeason: false,
        windowOpen: false,
        availableNow: false,
        listAvailableNow: false,
        activeListings: 0,
      };
      return;
    }
    console.warn("club_new_owner_release_state:", error);
    return;
  }

  newOwnerReleaseState = {
    remaining: normalizeNewOwnerReleasesRemaining(
      data?.new_owner_slots_remaining ?? data?.new_owner_releases_remaining
    ),
    firstSeason: Boolean(data?.first_season_at_club),
    windowOpen: Boolean(data?.window_open),
    availableNow: Boolean(data?.available_now),
    listAvailableNow: Boolean(data?.list_available_now),
    activeListings: Number(data?.active_new_owner_listings) || 0,
  };
}

function renderNewOwnerReleaseBadge() {
  const el = document.getElementById("newOwnerReleaseBadge");
  if (!el) return;

  if (!newOwnerReleaseState.firstSeason) {
    el.hidden = true;
    el.textContent = "";
    return;
  }

  el.hidden = false;
  const n = newOwnerReleaseState.remaining;
  el.classList.toggle("foreign-interest-badge--empty", n <= 0);

  const { main, hint } = newOwnerSlotBadgeText(n, {
    windowOpen: newOwnerReleaseState.windowOpen,
  });
  el.innerHTML = `
    <span class="foreign-interest-main">${main}</span><span class="foreign-interest-hint">${hint}</span>`;
}

async function loadSquadManagerState() {
  const badge = document.getElementById("managerBadge");
  if (!badge || !currentUserShort) return;

  const [{ data: mgr, error: mgrErr }, { data: sackOpen, error: winErr }] =
    await Promise.all([
      supabase
        .from("manager_club_status_public")
        .select(
          "manager_id, manager_name, manager_rating, market_value, manager_sacks_remaining"
        )
        .eq("club_short_name", currentUserShort)
        .maybeSingle(),
      supabase.rpc("manager_sack_window_open"),
    ]);

  if (mgrErr) {
    const msg = String(mgrErr.message || "");
    if (!msg.includes("manager_club_status")) {
      console.warn("manager_club_status_public:", mgrErr);
    }
    badge.hidden = true;
    return;
  }

  squadManagerState = {
    loaded: true,
    managerId: mgr?.manager_id ?? null,
    managerName: mgr?.manager_name ?? null,
    managerRating: mgr?.manager_rating ?? null,
    marketValue: Number(mgr?.market_value) || 0,
    sacksRemaining: Number(mgr?.manager_sacks_remaining) || 0,
    sackWindowOpen: winErr ? newOwnerReleaseState.windowOpen : Boolean(sackOpen),
  };

  renderSquadManagerBadge();
}

function renderSquadManagerBadge() {
  const badge = document.getElementById("managerBadge");
  const mainEl = document.getElementById("managerBadgeMain");
  const sackBtn = document.getElementById("sackManagerBtn");
  if (!badge || !mainEl) return;

  const hasManager =
    squadManagerState.managerId != null &&
    String(squadManagerState.managerName || "").trim() !== "";

  if (!hasManager) {
    badge.hidden = true;
    mainEl.textContent = "";
    if (sackBtn) {
      sackBtn.hidden = true;
      sackBtn.disabled = true;
    }
    return;
  }

  badge.hidden = false;
  const mv = formatMoney(squadManagerState.marketValue);
  const rating = squadManagerState.managerRating ?? "—";
  mainEl.textContent = `Manager: ${squadManagerState.managerName} (rating ${rating}) · MV ${mv}`;

  if (!sackBtn) return;

  const canSack =
    squadManagerState.sackWindowOpen && squadManagerState.sacksRemaining > 0;
  sackBtn.hidden = !canSack;
  sackBtn.disabled = !canSack;
}

async function loadSquadPurchaseFees(playerIds) {
  playerPurchaseFeeById = new Map();
  const ids = [...new Set((playerIds || []).map((id) => String(id)).filter(Boolean))];
  if (!ids.length || !currentUserShort || !newOwnerReleaseState.firstSeason) {
    return;
  }

  const { data, error } = await supabase
    .from("Transfer_History")
    .select("player_id, fee, transfer_time")
    .eq("buyer_club_id", currentUserShort)
    .in("player_id", ids)
    .gt("fee", 0)
    .order("transfer_time", { ascending: false });

  if (error) {
    console.warn("Transfer_History purchase fees:", error.message);
    return;
  }

  for (const row of data || []) {
    const pid = String(row.player_id);
    if (playerPurchaseFeeById.has(pid)) continue;
    const fee = Number(row.fee);
    if (Number.isFinite(fee) && fee > 0) {
      playerPurchaseFeeById.set(pid, fee);
    }
  }
}

function applyVoluntaryReleaseOptionState() {
  const allow = voluntaryReleasesRemaining > 0;
  document.querySelectorAll("select.squad-action-select").forEach((sel) => {
    const releaseOpt = sel.querySelector(
      `option[value="${VOLUNTARY_RELEASE_ACTION}"]`
    );
    const disabledRelease = sel.querySelector(
      'option[value=""][disabled]'
    );
    if (releaseOpt) {
      releaseOpt.disabled = !allow;
    }
    if (
      disabledRelease &&
      disabledRelease.textContent.includes("voluntary")
    ) {
      disabledRelease.disabled = true;
    }
  });
}

function applyForeignSaleOptionState() {
  const allowForeign =
    foreignInterestRemaining > 0 && foreignTrackingTeams.length > 0;
  document.querySelectorAll("select.squad-action-select").forEach((sel) => {
    const pid = sel.dataset.playerId;
    const row = sel.closest("tr[data-konami-id]");
    const blocked = pid && !playerCanListOrSellLocal({
      Season_Signed: row?.dataset.seasonSigned,
      contract_seasons_remaining: row?.dataset.contractSeasons,
    });

    const listOpt = sel.querySelector('option[value="list"]');
    const foreignOpts = sel.querySelectorAll(
      'option[value="foreign"], option[value^="foreign:"]'
    );

    if (blocked) {
      if (listOpt) listOpt.disabled = true;
      foreignOpts.forEach((opt) => {
        opt.disabled = true;
        if (opt.value === "foreign") {
          opt.textContent = "Signed this season";
        }
      });
      return;
    }

    if (listOpt) {
      listOpt.disabled = !transferWindowOpen;
      listOpt.textContent = transferWindowOpen
        ? "Transfer List"
        : "Transfer Window Shut";
    }

    const finalYear = row?.dataset.contractSeasons === "1";
    foreignOpts.forEach((opt) => {
      opt.disabled = !allowForeign || finalYear;
    });

    const legacyForeign = sel.querySelector('option[value="foreign"]');
    if (legacyForeign && foreignTrackingTeams.length === 0) {
      legacyForeign.disabled = !allowForeign || finalYear;
      legacyForeign.textContent = finalYear
        ? "Final contract year"
        : allowForeign
          ? "Sell to foreign club"
          : "No foreign interest left";
    }
  });
}

function applyNewOwnerReleaseOptionState() {
  document.querySelectorAll("select.squad-action-select").forEach((sel) => {
    const releaseOpt = sel.querySelector(
      `option[value="${NEW_OWNER_RELEASE_ACTION}"]`
    );
    const listOpt = sel.querySelector(`option[value="${NEW_OWNER_LIST_ACTION}"]`);
    const allowRelease =
      newOwnerReleaseState.availableNow && newOwnerReleaseState.remaining > 0;
    const allowList =
      newOwnerReleaseState.listAvailableNow &&
      newOwnerReleaseState.remaining > 0;
    if (releaseOpt) releaseOpt.disabled = !allowRelease;
    if (listOpt) listOpt.disabled = !allowList;
  });
}

function applyTransferWindowRules() {
  const msg = document.getElementById("windowClosedMessage");
  if (msg) msg.style.display = transferWindowOpen ? "none" : "block";
  applyForeignSaleOptionState();
  applyVoluntaryReleaseOptionState();
  applyNewOwnerReleaseOptionState();
}

async function loadFreshTransferStatusState() {
  return loadTransferStatusState(supabase);
}

// LOAD SQUAD — render actions ASAP; patch stats/listings without rebuilding dropdowns
async function loadSquad() {
  const tbody = document.getElementById("squad-body");
  const hadSquad = !!tbody?.querySelector("tr[data-konami-id]");

  if (tbody && !hadSquad) {
    tbody.innerHTML =
      '<tr data-squad-loading><td colspan="' +
      SQUAD_TABLE_COLS +
      '" style="color:#888;padding:16px;">Loading squad…</td></tr>';
  }

  let { data: players, error } = await supabase
    .from("Players")
    .select(SQUAD_PLAYER_COLUMNS)
    .eq("Contracted_Team", currentUserShort);

  if (error && isMissingEconomicsColumnError(error)) {
    ({ data: players, error } = await supabase
      .from("Players")
      .select(SQUAD_PLAYER_COLUMNS_LEGACY)
      .eq("Contracted_Team", currentUserShort));
  }

  currentGpslSeasonLabel = await loadCurrentGpslSeasonLabel(supabase);

  if (error) {
    console.error("Squad load error", error);
    if (tbody) {
      tbody.innerHTML =
        '<tr><td colspan="' +
        SQUAD_TABLE_COLS +
        '" style="color:#f88;">Failed to load squad.</td></tr>';
    }
    return;
  }

  const list = players || [];
  const playerIds = list.map((p) => String(p.Konami_ID));

  squadGhostPlayers = await loadSquadGhostAcquisitions(supabase, currentUserShort);
  const ghostIds = squadGhostPlayers.map((g) => String(g.Konami_ID));
  const idsKey = [...playerIds, ...ghostIds].sort().join(",");

  squadDesignationsState = await loadSquadDesignationsState(
    supabase,
    currentUserShort
  );
  [squadMinimumStatus, seasonLoanPlayerIds] = await Promise.all([
    loadClubSquadMinimumStatus(supabase, currentUserShort),
    loadActiveSeasonLoanPlayerIds(supabase, currentUserShort),
  ]);
  await loadSquadPurchaseFees(playerIds);

  renderSquadCompliance(list, squadDesignationsState, squadGhostPlayers);

  const [state, seasonStats, suspensionList, discipline] = await Promise.all([
    loadFreshTransferStatusState(),
    loadPlayerSeasonStatsForSquad(supabase, playerIds, currentUserShort),
    loadActiveSuspensions(supabase, { club: currentUserShort }),
    loadClubSquadDiscipline(supabase, currentUserShort),
  ]);
  transferStatusState = state;
  squadSuspensionsByPlayer = suspensionsByPlayerId(suspensionList);
  squadInjuriesByPlayer = injuriesByPlayerId(discipline.injuries);
  squadCardsByPlayer = cardsByPlayerId(discipline.cards);
  await loadSquadRewardContext();
  if (!transferStatusState.currentSeasonLabel && currentGpslSeasonLabel) {
    transferStatusState.currentSeasonLabel = currentGpslSeasonLabel;
  } else if (transferStatusState.currentSeasonLabel) {
    currentGpslSeasonLabel = transferStatusState.currentSeasonLabel;
  }

  const statsMap = statsMapByPlayerId(seasonStats);
  if (!hadSquad || tbody?.dataset.squadIds !== idsKey) {
    renderSquad(
      list,
      transferStatusState,
      statsMap,
      squadDesignationsState,
      squadGhostPlayers
    );
    if (tbody) tbody.dataset.squadIds = idsKey;
  } else {
    patchSquadEnrichment(transferStatusState, statsMap);
  }
}

function refreshSquadDesignationSelects(players, state) {
  document.querySelectorAll("select.squad-action-select").forEach((sel) => {
    const pid = sel.dataset.playerId;
    const player = players.find((p) => String(p.Konami_ID) === String(pid));
    if (!player) return;
    sel.innerHTML = `
            <option value="">Action</option>
            ${squadRoleActionOptionsHtml(player, state, clubNation)}
            ${squadActionOptionsHtml(player)}`;
    sel.value = "";
  });
  applyTransferWindowRules();
  applyForeignSaleOptionState();
  applyVoluntaryReleaseOptionState();
  applyNewOwnerReleaseOptionState();
}

async function loadSquadRewardContext() {
  squadRewardCtx = {
    hasDoctor: false,
    specialistTokens: 0,
    specialistTier: 2,
    prizeMedical: [],
    appealCards: [],
    appealableByPlayer: new Map(),
  };

  const [medRes, prizeTokRes, invRes, appealRes] = await Promise.all([
    supabase.rpc("medical_room_state", { p_club: null }),
    supabase.rpc("medical_room_prize_tokens", { p_club: null }),
    supabase.rpc("club_prize_inventory_state"),
    supabase.rpc("club_appealable_red_suspensions"),
  ]);

  if (!medRes.error && medRes.data?.ok) {
    squadRewardCtx.hasDoctor = !!medRes.data.has_doctor;
    squadRewardCtx.specialistTokens = Number(medRes.data.specialist_tokens) || 0;
    squadRewardCtx.specialistTier =
      Number(medRes.data.specialist_matches_removed) || 2;
    // Prefer token_used from medical room when discipline SQL lacks it
    for (const inj of medRes.data.active_injuries || []) {
      if (!inj?.token_used || !inj.injury_id) continue;
      const pid = String(inj.player_id || "");
      const rows = squadInjuriesByPlayer.get(pid) || [];
      for (const row of rows) {
        if (Number(row.injury_id ?? row.id) === Number(inj.injury_id)) {
          row.token_used = true;
        }
      }
    }
  }

  if (!prizeTokRes.error && Array.isArray(prizeTokRes.data)) {
    // Unified named consults (vault + prize), strongest first
    squadRewardCtx.prizeMedical = prizeTokRes.data.slice().sort((a, b) => {
      const tb = Number(b.param_int ?? b.matches_removed) || 0;
      const ta = Number(a.param_int ?? a.matches_removed) || 0;
      return tb - ta || (Number(a.consult_id) || 0) - (Number(b.consult_id) || 0);
    });
    if (squadRewardCtx.prizeMedical.length) {
      squadRewardCtx.specialistTokens = squadRewardCtx.prizeMedical.length;
    }
  }

  const items = invRes.data?.items || [];
  squadRewardCtx.appealCards = items.filter(
    (i) => i.prize_type === "appeal_card" && i.status === "available"
  );

  const appeals = Array.isArray(appealRes.data) ? appealRes.data : [];
  for (const s of appeals) {
    if (s?.player_id != null && s?.suspension_id != null) {
      squadRewardCtx.appealableByPlayer.set(String(s.player_id), s);
    }
  }
}

async function applySquadMedicalToken(injuryId) {
  const consult = squadBestMedicalConsult();
  const tier =
    Number(consult?.param_int ?? consult?.matches_removed) ||
    squadRewardCtx.specialistTier ||
    2;
  const who =
    consult?.label ||
    consult?.consultancy_label ||
    `Specialist consult (−${tier})`;
  if (
    !confirm(
      `Doctor refers this injury to:\n${who}\n\n(−${tier} matches; one consult per injury.)`
    )
  ) {
    return;
  }
  const payload = { p_injury_id: Number(injuryId) };
  if (consult?.consult_id != null) payload.p_consult_id = Number(consult.consult_id);
  else if (consult?.inventory_id != null)
    payload.p_inventory_id = Number(consult.inventory_id);
  else if (consult?.id != null) payload.p_inventory_id = Number(consult.id);
  else payload.p_prefer_specialist = true;
  const { data, error } = await supabase.rpc(
    "medical_apply_specialist_token",
    payload
  );
  if (error) {
    alert(error.message || "Could not apply specialist consult.");
    return;
  }
  alert(
    `${data?.label || who}: removed ${data?.matches_removed ?? 0} match(es).`
  );
  await loadSquad();
}

async function applySquadAppeal(suspensionId) {
  const card = squadRewardCtx.appealCards[0];
  if (!card?.id) {
    alert("No appeal cards available. Check Rewards Centre.");
    return;
  }
  const note = window.prompt("Optional note for the appeal review:", "") || null;
  if (
    !confirm(
      "Submit a red-card appeal? This spends one appeal card and goes to admin review."
    )
  ) {
    return;
  }
  const { error } = await supabase.rpc("prize_submit_suspension_appeal", {
    p_suspension_id: Number(suspensionId),
    p_inventory_id: card.id,
    p_owner_note: note,
  });
  if (error) {
    alert(error.message || "Could not submit appeal.");
    return;
  }
  alert("Appeal submitted — pending admin review.");
  await loadSquad();
}

function renderSquadCompliance(players, designationsState, ghostPlayers = []) {
  const el = document.getElementById("squadCompliancePanel");
  if (!el) return;

  const c = analyseSquadComposition(players, clubNation);
  const rows = squadComplianceRuleRows(c, clubNation, squadMinimumStatus);
  if (designationsState) {
    rows.push(starComplianceRow(designationsState));
    rows.push(oooComplianceRow(designationsState));
  }

  const ghosts = ghostPlayers || [];
  const hasGhosts = ghosts.length > 0;
  const projected = hasGhosts
    ? analyseSquadCompositionProjected(players, ghosts, clubNation)
    : null;
  const projectedRows = hasGhosts
    ? squadComplianceRuleRows(projected, clubNation, squadMinimumStatus)
    : [];
  const projectedByRule = new Map(projectedRows.map((r) => [r.rule, r]));

  const preAugust = !squadMinimumStatus?.punishments_active;
  const registrationOk = c.compliant && c.minSquadOk;
  const panelClass = registrationOk
    ? "squad-rules-panel squad-rules-panel--ok squad-rules-panel--compact"
    : "squad-rules-panel squad-rules-panel--warn squad-rules-panel--compact";

  const tableRows = rows
    .map((r) => {
      const rowOk = r.ok;
      const proj = projectedByRule.get(r.rule);
      const projCount =
        proj && typeof proj.count === "number" ? proj.count : null;
      const statusText =
        r.rule === "Minimum squad" && !r.ok
          ? preAugust
            ? `−${c.minSquadShort} pre-Aug`
            : shortComplianceStatus(r)
          : shortComplianceStatus(r);
      const projCell =
        hasGhosts && projCount != null
          ? `<td class="squad-rules-count squad-rules-count--ghost" title="If ${ghosts.length} pending bid${ghosts.length === 1 ? "" : "s"} complete"><strong>${projCount}</strong></td>`
          : hasGhosts
            ? `<td class="squad-rules-count squad-rules-count--ghost muted">—</td>`
            : "";
      const projHint =
        proj && !proj.ok && rowOk
          ? ` → ${shortComplianceStatus(proj)} if won`
          : "";

      return `
    <tr class="${rowOk ? "squad-rules-row--ok" : "squad-rules-row--fail"}">
      <th scope="row" title="${escapeHtml(complianceRowTooltip(r))}">${r.rule}</th>
      <td class="squad-rules-req-compact" title="${escapeHtml(complianceRowTooltip(r))}">${shortComplianceRequirement(r)}</td>
      <td class="squad-rules-count"><strong>${r.count}</strong></td>
      ${projCell}
      <td class="squad-rules-status-compact">
        <span class="squad-rules-mark ${rowOk ? "squad-rules-mark--ok" : "squad-rules-mark--fail"}">${rowOk ? "✓" : "✗"}</span>
        <span class="squad-rules-status-text">${statusText}${projHint}</span>
      </td>
    </tr>`;
    })
    .join("");

  const failCount = rows.filter((r) => !r.ok).length;

  let footnote = "";
  if (hasGhosts) {
    footnote = `<p class="squad-rules-footnote">👻 <strong>If won</strong> includes ${ghosts.length} player${ghosts.length === 1 ? "" : "s"} you lead on market/draft — not contracted yet (ghost rows below).</p>`;
  }
  if (failCount > 0) {
    const issues = c.issues
      .map((i) => i.replace(/^[^:]+:\s*/, "").replace(/\.$/, ""))
      .slice(0, 3)
      .join(" · ");
    footnote += `<p class="squad-rules-footnote squad-rules-footnote--warn">${failCount} rule${failCount === 1 ? "" : "s"} not met${issues ? `: ${issues}` : ""}.</p>`;
  } else if (!hasGhosts) {
    footnote = `<p class="squad-rules-footnote squad-rules-footnote--ok">All registration rules met.</p>`;
  } else if (projected?.compliant) {
    footnote += `<p class="squad-rules-footnote squad-rules-footnote--ok">All rules would be met if pending signings complete.</p>`;
  }

  el.innerHTML = `
    <section class="${panelClass}" aria-label="Squad registration requirements">
      <header class="squad-rules-header squad-rules-header--compact">
        <h2 class="squad-rules-title">Registration</h2>
        <p class="squad-rules-intro squad-rules-intro--compact">
          Contracted squad · min 24 from Aug · max 28
        </p>
      </header>
      <table class="squad-rules-table squad-rules-table--compact">
        <thead>
          <tr>
            <th scope="col">Rule</th>
            <th scope="col">Req</th>
            <th scope="col">Now</th>
            ${hasGhosts ? '<th scope="col" title="If pending winning bids complete">If won</th>' : ""}
            <th scope="col">Status</th>
          </tr>
        </thead>
        <tbody>${tableRows}</tbody>
      </table>
      ${footnote}
    </section>
  `;
}

// RENDER SQUAD
function formatSeasonStat(row, key, fallback = "—") {
  if (!row) return fallback;
  const v = row[key];
  if (v == null || v === "") return fallback;
  return v;
}

function renderSquad(players, transferState, statsByPlayer = new Map(), designationsState = null, ghostPlayers = []) {
  const tbody = document.getElementById("squad-body");
  if (!tbody) return;

  tbody.innerHTML = "";

  const groups = {
    "Goalkeepers": ["GK"],
    "Defenders": ["LB", "CB", "RB"],
    "Midfielders": ["DMF", "LMF", "CMF", "RMF", "AMF"],
    "Attackers": ["LW", "LWF", "SS", "RW", "RWF", "CF"]
  };

  const ghosts = ghostPlayers || [];

  for (const [groupName, positions] of Object.entries(groups)) {
    const groupPlayers = players
      .filter(p => positions.includes(p.Position))
      .sort((a, b) => b.market_value - a.market_value);

    const groupGhosts = ghosts
      .filter((p) => positions.includes(p.Position))
      .sort((a, b) => (b.market_value || 0) - (a.market_value || 0));

    if (!groupPlayers.length && !groupGhosts.length) continue;

    appendSquadSectionHeader(tbody, groupName);

    groupPlayers.forEach(p => {
      const pid = String(p.Konami_ID);
      const suspRows = squadSuspensionsByPlayer.get(pid) || [];
      const injuryRows = squadInjuriesByPlayer.get(pid) || [];
      const cardRow = squadCardsByPlayer.get(pid) || null;
      const suspHtml = formatSuspensionStatusHtml(suspRows);
      const injuryHtml = formatInjuryStatusHtml(injuryRows);
      const cardsHtml = formatCardsStatusHtml(cardRow);
      const statusRow = transferState
        ? resolvePlayerTransferStatus({
            konamiId: p.Konami_ID,
            contractedTeam: p.Contracted_Team || currentUserShort,
            viewerClubShort: currentUserShort,
            state: transferState,
            seasonSigned: p.Season_Signed,
            contractSeasonsRemaining: p.contract_seasons_remaining,
          })
        : {
            label: "—",
            pillClass: "status-not-listed",
          };
      const status = `${injuryHtml}${suspHtml}${cardsHtml}${formatSquadStatusHtml(statusRow)}`;

      const tr = document.createElement("tr");
      tr.dataset.konamiId = p.Konami_ID;
      tr.dataset.contractedTeam = p.Contracted_Team || currentUserShort;
      tr.dataset.seasonSigned = p.Season_Signed ?? "";
      tr.dataset.contractSeasons =
        p.contract_seasons_remaining != null
          ? String(p.contract_seasons_remaining)
          : "";
      if (suspRows.length) tr.classList.add("squad-row-suspended");
      if (injuryRows.some((i) => (Number(i.matches_out_remaining) || 0) > 0 || i.phase === "out")) {
        tr.classList.add("squad-row-injured");
      } else if (injuryRows.length) {
        tr.classList.add("squad-row-recovery");
      }
      tr.style.cursor = "pointer";
      const st = statsByPlayer.get(pid);
      const avg =
        st?.avg_rating != null ? Number(st.avg_rating).toFixed(2) : "—";
      const yCount = cardRow?.yellows || 0;

      const qualBadges = playerSquadQualificationBadges(p, clubNation);
      const roleBadge = roleBadgeForPlayer(p, designationsState);
      const loanBadge = seasonLoanPlayerIds.has(pid)
        ? seasonLoanBadgeHtml()
        : "";
      const ycBadge =
        yCount > 0
          ? `<span class="squad-yc-badge${yCount >= 6 ? " warn" : ""}${yCount >= 8 ? " ban" : ""}" title="Season yellow cards">YC ${yCount}/8</span>`
          : "";

      tr.innerHTML = `
        <td class="squad-col-thumb">${playerThumbLinkHtml(p.Konami_ID, { alt: p.Name })}</td>
        <td class="squad-col-player">${playerNameLinkHtml(p.Konami_ID, p.Name)}${loanBadge}${roleBadge}${qualBadges}${ycBadge}</td>
        <td class="squad-col-nation">${p.Nation || "-"}</td>
        <td class="squad-col-position">${p.Position}</td>
        <td class="num squad-col-age">${p.Age != null && p.Age !== "" ? p.Age : "—"}</td>
        <td class="num squad-col-rating">${formatRatingWithPotential(p)}</td>
        <td class="num squad-col-apps">${formatSeasonStat(st, "appearances", "0")}</td>
        <td class="num squad-col-goals">${formatSeasonStat(st, "goals", "0")}</td>
        <td class="num squad-col-assists">${formatSeasonStat(st, "assists", "0")}</td>
        <td class="num squad-col-avg">${avg}</td>
        <td class="squad-col-playstyle">${p.Playstyle || "-"}</td>
        <td class="squad-col-value"><span class="money">₿ ${Number(p.market_value).toLocaleString("en-GB")}</span></td>
        <td class="squad-col-contract">${formatSquadContractCell(p)}</td>
        <td class="squad-col-status">
          <div class="squad-status-stack">
            ${status}
          </div>
        </td>
        <td class="squad-col-action">
          <select class="squad-action-select" data-player-id="${pid}">
            <option value="">Action</option>
            ${squadRoleActionOptionsHtml(p, designationsState, clubNation)}
            ${squadActionOptionsHtml(p)}
          </select>
        </td>
      `;

      tbody.appendChild(tr);
    });

    groupGhosts.forEach((p) => {
      const tr = document.createElement("tr");
      tr.classList.add("squad-row-ghost");
      tr.dataset.konamiId = p.Konami_ID;
      tr.dataset.ghostPlayer = "1";

      const qualBadges = playerSquadQualificationBadges(p, clubNation);
      const playerCell = formatGhostPlayerNameCell(p, qualBadges);

      tr.innerHTML = `
        <td class="squad-col-thumb">${playerThumbLinkHtml(p.Konami_ID, { alt: p.Name })}</td>
        <td class="squad-col-player">${playerCell}</td>
        <td class="squad-col-nation">${p.Nation || "-"}</td>
        <td class="squad-col-position">${p.Position}</td>
        <td class="num squad-col-age">${p.Age != null && p.Age !== "" ? p.Age : "—"}</td>
        <td class="num squad-col-rating">${formatRatingWithPotential(p)}</td>
        <td class="num squad-col-apps squad-ghost-muted">—</td>
        <td class="num squad-col-goals squad-ghost-muted">—</td>
        <td class="num squad-col-assists squad-ghost-muted">—</td>
        <td class="num squad-col-avg squad-ghost-muted">—</td>
        <td class="squad-col-playstyle">${p.Playstyle || "-"}</td>
        <td class="squad-col-value"><span class="money squad-ghost-muted">₿ ${Number(p.market_value || 0).toLocaleString("en-GB")}</span></td>
        <td class="squad-col-contract squad-ghost-muted" title="Not contracted yet">If won</td>
        <td class="squad-col-status">${formatGhostStatusHtml(p)}</td>
        <td class="squad-col-action">
          <a href="${p.ghostHref}" class="squad-ghost-action-link">View bid${p.ghostBidAmount != null ? ` · ₿${Number(p.ghostBidAmount).toLocaleString("en-GB")}` : ""}</a>
        </td>
      `;

      tbody.appendChild(tr);
    });
  }

  if (ghosts.length) {
    const orphanGhosts = ghosts.filter((g) => {
      const pos = g.Position;
      return !Object.values(groups).some((arr) => arr.includes(pos));
    });
    if (orphanGhosts.length) {
      appendSquadSectionHeader(tbody, "Pending acquisitions", { ghost: true });
      orphanGhosts.forEach((p) => {
        const tr = document.createElement("tr");
        tr.classList.add("squad-row-ghost");
        tr.dataset.konamiId = p.Konami_ID;
        tr.dataset.ghostPlayer = "1";

        const qualBadges = playerSquadQualificationBadges(p, clubNation);
        const playerCell = formatGhostPlayerNameCell(p, qualBadges);

        tr.innerHTML = `
        <td class="squad-col-thumb">${playerThumbLinkHtml(p.Konami_ID, { alt: p.Name })}</td>
        <td class="squad-col-player">${playerCell}</td>
        <td class="squad-col-nation">${p.Nation || "-"}</td>
        <td class="squad-col-position">${p.Position}</td>
        <td class="num squad-col-age">${p.Age != null && p.Age !== "" ? p.Age : "—"}</td>
        <td class="num squad-col-rating">${formatRatingWithPotential(p)}</td>
        <td class="num squad-col-apps squad-ghost-muted">—</td>
        <td class="num squad-col-goals squad-ghost-muted">—</td>
        <td class="num squad-col-assists squad-ghost-muted">—</td>
        <td class="num squad-col-avg squad-ghost-muted">—</td>
        <td class="squad-col-playstyle">${p.Playstyle || "-"}</td>
        <td class="squad-col-value"><span class="money squad-ghost-muted">₿ ${Number(p.market_value || 0).toLocaleString("en-GB")}</span></td>
        <td class="squad-col-contract squad-ghost-muted" title="Not contracted yet">If won</td>
        <td class="squad-col-status">${formatGhostStatusHtml(p)}</td>
        <td class="squad-col-action">
          <a href="${p.ghostHref}" class="squad-ghost-action-link">View bid${p.ghostBidAmount != null ? ` · ₿${Number(p.ghostBidAmount).toLocaleString("en-GB")}` : ""}</a>
        </td>
      `;
        tbody.appendChild(tr);
      });
    }
  }

  applyTransferWindowRules();
  applyForeignSaleOptionState();
  applyVoluntaryReleaseOptionState();
  ensureSquadTableColumnWidthSync();
  syncSquadTableColumnWidths();
}

/** Measure cell content width for tight column sizing. */
function measureSquadTableCellWidth(cell) {
  const prevWs = cell.style.whiteSpace;
  const prevOv = cell.style.overflow;
  cell.style.whiteSpace = "nowrap";
  cell.style.overflow = "visible";
  const w = Math.ceil(cell.getBoundingClientRect().width);
  cell.style.whiteSpace = prevWs;
  cell.style.overflow = prevOv;
  return w;
}

function syncSquadTableColumnWidths() {
  const table = document.querySelector("table.gpsl-table.squad-table");
  if (!table) return;

  const cols = table.querySelectorAll("colgroup col");
  const sectionColRows = table.querySelectorAll("tr.squad-section-cols-row");
  if (!cols.length || !sectionColRows.length) return;
  const thCount = sectionColRows[0].querySelectorAll("th").length;
  if (thCount !== cols.length) return;

  cols.forEach((col) => {
    col.style.width = "";
    col.style.minWidth = "";
    col.style.maxWidth = "";
  });
  table.style.width = "";
  table.style.tableLayout = "auto";

  const widths = Array.from({ length: thCount }, () => 0);

  const measureCell = (cell, i) => {
    if (!cell || i >= widths.length || cell.colSpan > 1) return;
    widths[i] = Math.max(widths[i], measureSquadTableCellWidth(cell));
  };

  table.querySelectorAll("tr.squad-section-cols-row").forEach((row) => {
    row.querySelectorAll("th").forEach((th, i) => measureCell(th, i));
  });
  table.querySelectorAll("tbody tr[data-konami-id]").forEach((row) => {
    row.querySelectorAll("td").forEach((td, i) => measureCell(td, i));
  });

  let total = 0;
  cols.forEach((col, i) => {
    if (widths[i] > 0) {
      const w = widths[i];
      col.style.width = `${w}px`;
      col.style.minWidth = `${w}px`;
      col.style.maxWidth = `${w}px`;
      total += w;
    }
  });

  table.style.tableLayout = "fixed";
  table.style.width = total > 0 ? `${total}px` : "max-content";
}

function ensureSquadTableColumnWidthSync() {
  if (window.__squadColumnWidthSyncBound) return;
  window.__squadColumnWidthSyncBound = true;
  window.addEventListener("resize", () => {
    clearTimeout(squadColumnWidthResizeTimer);
    squadColumnWidthResizeTimer = setTimeout(syncSquadTableColumnWidths, 120);
  });
}

/** Update stats + listing pills only — keeps action dropdowns mounted and clickable. */
function patchSquadEnrichment(transferState, statsByPlayer) {
  const tbody = document.getElementById("squad-body");
  if (!tbody) return;

  tbody.querySelectorAll("tr[data-konami-id]:not([data-ghost-player])").forEach((row) => {
    const id = String(row.dataset.konamiId);
    const st = statsByPlayer.get(id);
    const apps = row.querySelector(".squad-col-apps");
    const goals = row.querySelector(".squad-col-goals");
    const assists = row.querySelector(".squad-col-assists");
    const avg = row.querySelector(".squad-col-avg");
    const status = row.querySelector(".squad-col-status");

    if (apps) apps.textContent = formatSeasonStat(st, "appearances", "0");
    if (goals) goals.textContent = formatSeasonStat(st, "goals", "0");
    if (assists) assists.textContent = formatSeasonStat(st, "assists", "0");
    if (avg) {
      avg.textContent =
        st?.avg_rating != null ? Number(st.avg_rating).toFixed(2) : "—";
    }
    if (status && transferState) {
      const seasonsRaw = row.dataset.contractSeasons;
      const suspRows = squadSuspensionsByPlayer.get(id) || [];
      const injuryRows = squadInjuriesByPlayer.get(id) || [];
      const cardRow = squadCardsByPlayer.get(id) || null;
      const suspHtml = formatSuspensionStatusHtml(suspRows);
      const injuryHtml = formatInjuryStatusHtml(injuryRows);
      const cardsHtml = formatCardsStatusHtml(cardRow);
      const statusRow = resolvePlayerTransferStatus({
        konamiId: id,
        contractedTeam:
          row.dataset.contractedTeam || currentUserShort,
        viewerClubShort: currentUserShort,
        state: transferState,
        seasonSigned: row.dataset.seasonSigned ?? null,
        contractSeasonsRemaining:
          seasonsRaw !== undefined && seasonsRaw !== ""
            ? Number(seasonsRaw)
            : null,
      });
      status.innerHTML = `${injuryHtml}${suspHtml}${cardsHtml}${formatSquadStatusHtml(statusRow)}`;
      row.classList.toggle("squad-row-suspended", suspRows.length > 0);
      const injuredOut = injuryRows.some(
        (i) => (Number(i.matches_out_remaining) || 0) > 0 || i.phase === "out"
      );
      row.classList.toggle("squad-row-injured", injuredOut);
      row.classList.toggle(
        "squad-row-recovery",
        !injuredOut && injuryRows.length > 0
      );
    }
  });
}

function resetActionSelect(selectEl) {
  if (selectEl) selectEl.value = "";
}

function formatMoney(amount) {
  return `₿ ${Number(amount || 0).toLocaleString("en-GB")}`;
}

/** Matches DB/GPDB: NULL or blank = free agent. */
function playerContractClubKey(contractedTeam) {
  if (contractedTeam == null) return null;
  const t = String(contractedTeam).trim();
  return t === "" ? null : t;
}

function wireSquadTable() {
  const tbody = document.getElementById("squad-body");
  if (!tbody || tbody.dataset.squadTableWired === "1") return;
  tbody.dataset.squadTableWired = "1";

  tbody.addEventListener("mousedown", (e) => {
    if (e.target.closest("select.squad-action-select")) {
      e.stopPropagation();
    }
  });

  tbody.addEventListener("click", (e) => {
    if (e.target.closest("a.squad-player-link")) {
      return;
    }

    const sel = e.target.closest("select.squad-action-select");
    if (sel) {
      e.stopPropagation();
      return;
    }

    if (
      e.target.closest("button") ||
      e.target.closest(".decision-buttons") ||
      e.target.closest("a")
    ) {
      return;
    }

    const row = e.target.closest("tr[data-konami-id]");
    if (!row?.dataset.konamiId) return;
    if (row.dataset.ghostPlayer) return;

    window.open(pesdbPlayerUrl(row.dataset.konamiId), "_blank", "noopener");
  });

  tbody.addEventListener("change", (e) => {
    const sel = e.target.closest("select.squad-action-select");
    if (!sel) return;
    e.stopPropagation();
    void handlePlayerAction(sel.dataset.playerId, sel.value, sel);
  });
}

/** Star badge for 79+ players (automatic); OOO badge for the nominee. */
function roleBadgeForPlayer(player, state) {
  const role = designationForPlayer(state, player?.Konami_ID);
  if (role === DESIGNATION_OOO) return designationRoleBadge(DESIGNATION_OOO);
  const min = Number(state?.star_min_rating ?? 79);
  if (state && playerEligibleStar(player, min)) {
    return designationRoleBadge(DESIGNATION_STAR);
  }
  return "";
}

/** Reload squad + re-render compliance, action menus and role badges. */
async function refreshAfterDesignationChange() {
  const { data: squadRows } = await supabase
    .from("Players")
    .select(SQUAD_PLAYER_COLUMNS)
    .eq("Contracted_Team", currentUserShort);
  const rows = squadRows || [];
  renderSquadCompliance(rows, squadDesignationsState, squadGhostPlayers);
  refreshSquadDesignationSelects(rows, squadDesignationsState);
  const byId = new Map(rows.map((p) => [String(p.Konami_ID), p]));
  document.querySelectorAll("tr[data-konami-id]:not([data-ghost-player])").forEach((row) => {
    const player = byId.get(String(row.dataset.konamiId));
    const nameCell = row.querySelector("td.squad-col-player");
    if (!nameCell || !player) return;
    const loanBadge = seasonLoanPlayerIds.has(String(player.Konami_ID))
      ? seasonLoanBadgeHtml()
      : "";
    const roleBadge = roleBadgeForPlayer(player, squadDesignationsState);
    const qualBadges = playerSquadQualificationBadges(player, clubNation);
    nameCell.innerHTML = `${playerNameLinkHtml(player.Konami_ID, player.Name)}${loanBadge}${roleBadge}${qualBadges}`;
  });
}

// Blocks listing when transfer window is closed
async function handlePlayerAction(playerId, action, selectEl) {
  if (!action) {
    resetActionSelect(selectEl);
    return;
  }

  if (action.startsWith("role:")) {
    resetActionSelect(selectEl);
    const designation = action.slice("role:".length) || null;
    try {
      squadDesignationsState = await setSquadDesignation(
        supabase,
        playerId,
        designation
      );
      await refreshAfterDesignationChange();
    } catch (err) {
      console.error("Designation update failed:", err);
      alert(err.message || "Could not update squad role.");
    }
    return;
  }

  if (action.startsWith("medical:")) {
    resetActionSelect(selectEl);
    await applySquadMedicalToken(action.slice("medical:".length));
    return;
  }

  if (action.startsWith("appeal:")) {
    resetActionSelect(selectEl);
    await applySquadAppeal(action.slice("appeal:".length));
    return;
  }

  try {
    if (action === "list") {
      if (!transferWindowOpen) {
        resetActionSelect(selectEl);
        return;
      }
      resetActionSelect(selectEl);
      const { data: pRow } = await supabase
        .from("Players")
        .select("Konami_ID, Name, market_value, Maximum_Reserve_Price, Season_Signed")
        .eq("Konami_ID", playerId)
        .maybeSingle();
      if (!playerCanListOrSellLocal(pRow)) {
        alert(
          isContractFinalYear(pRow)
            ? FINAL_YEAR_TRANSFER_MESSAGE
            : SAME_SEASON_TRANSFER_MESSAGE
        );
        return;
      }
      await openListPlayerModalByID(pRow || { Konami_ID: playerId });
      return;
    }

    const foreignIdx = parseForeignSaleAction(action);
    if (action === "foreign" || foreignIdx != null) {
      resetActionSelect(selectEl);
      if (foreignInterestRemaining <= 0 || foreignTrackingTeams.length === 0) {
        alert("No foreign clubs are interested in your players (limit reached).");
        return;
      }
      const teamName =
        foreignIdx != null ? foreignTrackingTeams[foreignIdx] : null;
      if (foreignIdx != null && !teamName) {
        alert("That club is no longer tracking your players.");
        await loadForeignInterestState();
        renderForeignInterestBadge();
        applyForeignSaleOptionState();
        return;
      }
      await sellPlayerToForeignClub(playerId, teamName);
      return;
    }

    if (action === VOLUNTARY_RELEASE_ACTION) {
      resetActionSelect(selectEl);
      await releasePlayerFromContract(playerId);
      return;
    }

    if (action === NEW_OWNER_RELEASE_ACTION) {
      resetActionSelect(selectEl);
      await releasePlayerNewOwner(playerId);
      return;
    }

    if (action === NEW_OWNER_LIST_ACTION) {
      resetActionSelect(selectEl);
      await listPlayerNewOwner(playerId);
      return;
    }

    if (action === TERMINATE_SEASON_LOAN_ACTION) {
      resetActionSelect(selectEl);
      await terminateSeasonLoanPlayer(playerId);
      return;
    }

    if (action === "renew") {
      resetActionSelect(selectEl);
      await renewPlayerContract(playerId);
      return;
    }

    if (action === "expire") {
      resetActionSelect(selectEl);
      await expirePlayerContract(playerId);
    }
  } catch (err) {
    console.error("Squad action failed:", err);
    alert("Action failed. Please try again.");
    resetActionSelect(selectEl);
  }
}

async function renewPlayerContract(playerId) {
  const { data: player, error: loadErr } = await supabase
    .from("Players")
    .select(
      "Konami_ID, Name, contract_wage, contract_seasons_remaining, Age, Nation"
    )
    .eq("Konami_ID", playerId)
    .single();

  if (loadErr || !player) {
    alert("Could not load player.");
    return;
  }

  if (!isContractFinalYear(player)) {
    alert("Renewal is only available in the final contract year.");
    return;
  }

  const hg = isHgContractProtected(player, clubNation);
  let wage = Number(player.contract_wage) || 0;

  if (!hg) {
    const raw = window.prompt(
      `Renew ${player.Name} for 3 seasons.\nMinimum wage: ${formatWage(wage)}\nEnter wage (₿):`,
      String(wage)
    );
    if (raw == null) return;
    wage = Number(String(raw).replace(/[^\d.]/g, ""));
    if (!Number.isFinite(wage) || wage < Number(player.contract_wage)) {
      alert(`Wage must be at least ${formatWage(player.contract_wage)}.`);
      return;
    }
  } else if (
    !window.confirm(
      `Renew ${player.Name} for 3 seasons at the same wage (${formatWage(wage)})?`
    )
  ) {
    return;
  }

  const { data, error } = await supabase.rpc("player_contract_renew", {
    p_player_id: String(playerId),
    p_wage: wage,
  });

  if (error) {
    alert(error.message || "Renewal failed.");
    return;
  }

  alert(
    `${player.Name} renewed — 3 seasons at ${formatWage(data?.contract_wage ?? wage)}.`
  );
  await loadSquad();
}

async function expirePlayerContract(playerId) {
  const { data: player, error: loadErr } = await supabase
    .from("Players")
    .select("Konami_ID, Name, market_value, contract_seasons_remaining")
    .eq("Konami_ID", playerId)
    .single();

  if (loadErr || !player) {
    alert("Could not load player.");
    return;
  }

  if (!isContractFinalYear(player)) {
    alert("Expiry is only available in the final contract year.");
    return;
  }

  const mv = Number(player.market_value) || 0;
  if (
    !window.confirm(
      `Allow ${player.Name}'s contract to expire?\n\n` +
        `They become a free agent. Your club receives ${formatMoney(mv)} (market value).`
    )
  ) {
    return;
  }

  const { data, error } = await supabase.rpc("player_contract_expire", {
    p_player_id: String(playerId),
  });

  if (error) {
    alert(error.message || "Could not expire contract.");
    return;
  }

  alert(
    `${data?.player_name || player.Name} released. ` +
      `Fee received: ${formatMoney(data?.fee ?? mv)}.`
  );
  await loadSquad();
}

async function releasePlayerFromContract(playerId) {
  const { data: player, error: loadErr } = await supabase
    .from("Players")
    .select(
      "Konami_ID, Name, contract_wage, contract_seasons_remaining, Contracted_Team"
    )
    .eq("Konami_ID", playerId)
    .single();

  if (loadErr || !player) {
    alert("Could not load player.");
    return;
  }

  const contracted = playerContractClubKey(player.Contracted_Team);
  if (contracted !== currentUserShort) {
    alert("This player is not at your club.");
    return;
  }

  if (voluntaryReleasesRemaining <= 0) {
    alert("No voluntary contract releases remaining this season (maximum 3).");
    await loadVoluntaryReleaseState();
    renderVoluntaryReleaseBadge();
    applyVoluntaryReleaseOptionState();
    return;
  }

  const seasons = Number(player.contract_seasons_remaining) || 0;
  const wage = Number(player.contract_wage) || 0;
  const cost = calculateVoluntaryReleaseCost(wage, seasons);

  if (cost <= 0) {
    alert("Could not calculate contract buy-out for this player.");
    return;
  }

  const unlockNote =
    "They become a free agent in GPDB but cannot be signed until next season (contract paid up).";
  const confirmed = window.confirm(
    `Release ${player.Name} from their contract?\n\n` +
      `No market value received.\n` +
      `Buy-out cost: ${formatMoney(cost)} (${seasons} season${seasons === 1 ? "" : "s"} × ${formatWage(wage)}).\n\n` +
      `${unlockNote}\n\n` +
      `${voluntaryReleasesRemaining - 1} voluntary release(s) will remain this season.`
  );

  if (!confirmed) return;

  const { data, error } = await supabase.rpc("player_voluntary_contract_release", {
    p_player_id: String(playerId),
  });

  if (error) {
    alert(error.message || "Could not release player from contract.");
    return;
  }

  voluntaryReleasesRemaining = normalizeVoluntaryReleasesRemaining(
    data?.voluntary_contract_releases_remaining
  );
  renderVoluntaryReleaseBadge();
  applyVoluntaryReleaseOptionState();

  alert(
    `${data?.player_name || player.Name} released.\n\n` +
      `Buy-out paid: ${formatMoney(data?.buyout_cost ?? cost)}.\n` +
      `Unavailable until ${data?.unavailable_until_season || "next season"}.`
  );
  await loadSquad();
}

async function releasePlayerNewOwner(playerId) {
  const { data: player, error: loadErr } = await supabase
    .from("Players")
    .select("Konami_ID, Name, Contracted_Team")
    .eq("Konami_ID", playerId)
    .single();

  if (loadErr || !player) {
    alert("Could not load player.");
    return;
  }

  const contracted = playerContractClubKey(player.Contracted_Team);
  if (contracted !== currentUserShort) {
    alert("This player is not at your club.");
    return;
  }

  await loadNewOwnerReleaseState();
  renderNewOwnerReleaseBadge();

  if (!newOwnerReleaseState.firstSeason) {
    alert("New Owner releases are only available in your first season in charge of this club.");
    return;
  }
  if (!newOwnerReleaseState.windowOpen) {
    alert("New Owner releases are only available in the pre-season window or the January transfer window.");
    return;
  }
  if (newOwnerReleaseState.remaining <= 0) {
    alert("No first-season slots remaining (maximum 3 release or transfer list actions).");
    return;
  }

  const { data: preview, error: previewError } = await supabase.rpc(
    "player_new_owner_release_preview",
    { p_player_id: String(playerId) }
  );

  if (previewError) {
    alert(previewError.message || "Could not preview New Owner release.");
    return;
  }

  const fee = Number(preview?.fee);
  if (!preview?.eligible_player || !Number.isFinite(fee) || fee <= 0) {
    alert(
      "No purchase fee found for this player at your club. New Owner release only applies to players the club paid a transfer fee for."
    );
    return;
  }

  const confirmed = window.confirm(
    `New Owner release for ${player.Name}?\n\n` +
      `Club is refunded the purchase fee: ${formatMoney(fee)} from the Central Bank.\n` +
      `The original transfer history fee is left unchanged.\n` +
      `Player becomes a free agent but cannot be signed until next season.\n\n` +
      `${newOwnerReleaseState.remaining - 1} first-season slot(s) will remain.`
  );

  if (!confirmed) return;

  const { data, error } = await supabase.rpc("player_new_owner_release", {
    p_player_id: String(playerId),
  });

  if (error) {
    alert(error.message || "Could not complete New Owner release.");
    return;
  }

  newOwnerReleaseState.remaining = normalizeNewOwnerReleasesRemaining(
    data?.new_owner_slots_remaining ?? data?.new_owner_releases_remaining
  );
  newOwnerReleaseState.availableNow =
    newOwnerReleaseState.firstSeason &&
    newOwnerReleaseState.windowOpen &&
    newOwnerReleaseState.remaining > 0;
  syncNewOwnerListAvailability();
  renderNewOwnerReleaseBadge();
  applyNewOwnerReleaseOptionState();

  alert(
    `${data?.player_name || player.Name} released (New Owner).\n\n` +
      `Central Bank refund: ${formatMoney(data?.refund ?? data?.fee ?? fee)}.\n` +
      `Unavailable until ${data?.unavailable_until_season || "next season"}.`
  );
  await loadSquad();
}

async function listPlayerNewOwner(playerId) {
  const { data: player, error: loadErr } = await supabase
    .from("Players")
    .select(
      "Konami_ID, Name, Contracted_Team, market_value, Season_Signed, contract_seasons_remaining"
    )
    .eq("Konami_ID", playerId)
    .single();

  if (loadErr || !player) {
    alert("Could not load player.");
    return;
  }

  const contracted = playerContractClubKey(player.Contracted_Team);
  if (contracted !== currentUserShort) {
    alert("This player is not at your club.");
    return;
  }

  await loadNewOwnerReleaseState();
  syncNewOwnerListAvailability();
  renderNewOwnerReleaseBadge();

  if (!newOwnerReleaseState.firstSeason) {
    alert("New Owner actions are only available in your first season in charge of this club.");
    return;
  }
  if (!newOwnerReleaseState.windowOpen) {
    alert("New Owner actions are only available in the pre-season window or the January transfer window.");
    return;
  }
  if (!transferWindowOpen) {
    alert("Transfer window is closed — listings are disabled.");
    return;
  }
  if (newOwnerReleaseState.remaining <= 0) {
    alert("No first-season slots remaining (maximum 3 release or transfer list actions).");
    return;
  }
  const blockedReason = newOwnerListBlockedReason(player);
  if (blockedReason) {
    alert(
      blockedReason === "final contract year"
        ? FINAL_YEAR_TRANSFER_MESSAGE
        : "This player cannot be New Owner transfer listed."
    );
    return;
  }

  const { data: preview, error: previewError } = await supabase.rpc(
    "player_new_owner_list_preview",
    { p_player_id: String(playerId) }
  );

  if (previewError) {
    alert(previewError.message || "Could not preview New Owner transfer list.");
    return;
  }

  if (!preview?.ok) {
    alert(
      preview?.message ||
        "This player cannot be transfer listed under New Owner rules."
    );
    return;
  }

  const mv = Number(preview?.market_value ?? player.market_value) || 0;

  const confirmed = window.confirm(
    `New Owner transfer list for ${player.Name}?\n\n` +
      `Standard listing at market value: ${formatMoney(mv)} reserve.\n` +
      `Uses 1 of your ${newOwnerReleaseState.remaining} first-season slot(s).\n` +
      `Same-season signings can be listed here (normal transfer rules do not apply).\n` +
      `If the listing expires unsold, the slot is returned and you may release them instead (Central Bank refund of purchase fee).\n` +
      `If sold, the slot is used permanently.`
  );

  if (!confirmed) return;

  const { data, error } = await supabase.rpc("player_new_owner_transfer_list", {
    p_player_id: String(playerId),
  });

  if (error) {
    alert(error.message || "Could not create New Owner transfer listing.");
    return;
  }

  newOwnerReleaseState.remaining = normalizeNewOwnerReleasesRemaining(
    data?.new_owner_slots_remaining
  );
  newOwnerReleaseState.availableNow =
    newOwnerReleaseState.firstSeason &&
    newOwnerReleaseState.windowOpen &&
    newOwnerReleaseState.remaining > 0;
  syncNewOwnerListAvailability();
  renderNewOwnerReleaseBadge();
  applyNewOwnerReleaseOptionState();

  alert(
    `${data?.player_name || player.Name} listed (New Owner).\n\n` +
      `Reserve: ${formatMoney(data?.reserve_price ?? mv)}.\n` +
      `${newOwnerReleaseState.remaining} first-season slot(s) remaining.`
  );
  await refreshNavClubListingState(currentUserShort);
  refreshNavListingIndicators();
  await loadSquad();
}

async function terminateSeasonLoanPlayer(playerId) {
  const { data: player } = await supabase
    .from("Players")
    .select("Konami_ID, Name")
    .eq("Konami_ID", playerId)
    .maybeSingle();

  if (
    !confirm(
      `Terminate season loan for ${player?.Name || "this player"}?\n\n` +
        "50% of the loan fee is refunded. August minimum fines are not refunded."
    )
  ) {
    return;
  }

  const { data, error } = await terminateSeasonLoan(supabase, playerId);
  if (error) {
    alert(error.message || "Could not terminate season loan.");
    return;
  }

  alert(
    `${data?.player_name || player?.Name || "Player"} loan ended.\n\n` +
      `Refund: ₿${Number(data?.refund || 0).toLocaleString("en-GB")}`
  );
  await loadSquad();
}

async function sellPlayerToForeignClub(playerId, foreignTeamName) {
  const { data: player, error: loadErr } = await supabase
    .from("Players")
    .select(
      "Konami_ID, Name, market_value, Contracted_Team, Season_Signed, contract_seasons_remaining"
    )
    .eq("Konami_ID", playerId)
    .single();

  if (loadErr || !player) {
    alert("Could not load player.");
    return;
  }

  const contracted = playerContractClubKey(player.Contracted_Team);
  if (contracted !== currentUserShort) {
    alert("This player is not at your club.");
    return;
  }

  if (!playerCanListOrSellLocal(player)) {
    alert(
      isContractFinalYear(player)
        ? FINAL_YEAR_TRANSFER_MESSAGE
        : SAME_SEASON_TRANSFER_MESSAGE
    );
    return;
  }

  const mv = Number(player.market_value) || 0;
  const buyerLabel = foreignTeamName
    ? String(foreignTeamName).trim()
    : "a foreign club";
  const confirmed = window.confirm(
    `Sell ${player.Name} to ${buyerLabel}?\n\n` +
      `They return to the player database as a free agent but stay unavailable to GPSL clubs until next season (contracted abroad).\n` +
      `Your club will receive ${formatMoney(mv)} (market value).`
  );

  if (!confirmed) return;

  const rpcArgs = { p_player_id: String(playerId) };
  if (foreignTeamName) {
    rpcArgs.p_foreign_team_name = String(foreignTeamName).trim();
  }

  const { data, error } = await supabase.rpc(
    "sell_player_to_foreign_club",
    rpcArgs
  );

  if (error) {
    console.error("sell_player_to_foreign_club:", error);
    alert(error.message || "Sale to foreign club failed.");
    return;
  }

  const fee = data?.fee ?? mv;
  if (data?.foreign_interest_remaining != null) {
    foreignInterestRemaining = normalizeForeignInterest(
      data.foreign_interest_remaining
    );
  } else {
    foreignInterestRemaining = Math.max(0, foreignInterestRemaining - 1);
  }
  if (Array.isArray(data?.tracking_teams)) {
    foreignTrackingTeams = data.tracking_teams.map((t) => String(t));
  } else if (foreignTeamName) {
    foreignTrackingTeams = foreignTrackingTeams.filter(
      (t) => t !== foreignTeamName
    );
  }
  renderForeignInterestBadge();
  applyForeignSaleOptionState();

  const soldTo =
    data?.foreign_buyer_name || foreignTeamName || "a foreign club";
  const untilSeason = data?.unavailable_until_season
    ? `\nUnavailable in GPSL until ${data.unavailable_until_season}.`
    : "\nUnavailable in GPSL until next season.";
  alert(
    `${data?.player_name || player.Name} sold to ${soldTo}.\n` +
      `${formatMoney(fee)} credited to your club balance.${untilSeason}`
  );

  await loadSquad();
}

// LIST PLAYER MODAL
async function openListPlayerModalByID(playerRef) {
  const { data, error } = await supabase
    .from("Players")
    .select("*")
    .eq("Konami_ID", playerRef.Konami_ID)
    .single();

  if (error || !data) {
    console.error("Player lookup failed", error);
    return;
  }

  openListPlayerModal(data);
}

function openListPlayerModal(player) {
  selectedPlayerForListing = player;

  document.getElementById("modalPlayerName").textContent = player.Name;
  document.getElementById("modalPlayerInfo").textContent =
    `${player.Position} • Rating ${player.Rating}`;

  document.getElementById("modalMarketValue").textContent =
    `₿ ${Number(player.market_value).toLocaleString("en-GB")}`;
  document.getElementById("modalMaxReserve").textContent =
    `₿ ${Number(player.Maximum_Reserve_Price).toLocaleString("en-GB")}`;

  const reserveInput = document.getElementById("reserveInput");
  const reserveError = document.getElementById("reserveError");

  reserveInput.value = "";
  reserveInput.style.border = "1px solid #444";
  reserveError.textContent = "";

  document.getElementById("list-player-modal-backdrop").style.display = "flex";
}

// RESERVE INPUT + VALIDATION
function parseNumericInput(value) {
  return Number(String(value).replace(/,/g, "")) || 0;
}

function formatNumeric(value) {
  return Number(value).toLocaleString("en-GB");
}

function validateReserveInput() {
  const input = document.getElementById("reserveInput");
  const errorBox = document.getElementById("reserveError");

  if (!selectedPlayerForListing) {
    errorBox.textContent = "No player selected.";
    input.style.border = "2px solid red";
    return false;
  }

  let raw = String(input.value).replace(/,/g, "").trim();
  if (raw === "") {
    errorBox.textContent = "";
    input.style.border = "1px solid #444";
    return false;
  }

  let value = Number(raw);
  if (Number.isNaN(value) || value <= 0) {
    errorBox.textContent = "Enter a valid positive number.";
    input.style.border = "2px solid red";
    return false;
  }

  input.value = formatNumeric(value);

  const mv = selectedPlayerForListing.market_value;
  const max = selectedPlayerForListing.Maximum_Reserve_Price;

  if (value < mv) {
    errorBox.textContent =
      `Reserve must be at least market value (₿ ${formatNumeric(mv)}).`;
    input.style.border = "2px solid red";
    return false;
  }

  if (value > max) {
    errorBox.textContent =
      `Reserve cannot exceed max allowed (₿ ${formatNumeric(max)}).`;
    input.style.border = "2px solid red";
    return false;
  }

  errorBox.textContent = "";
  input.style.border = "2px solid #4CAF50";
  return true;
}

function addReserveIncrement(amount) {
  const input = document.getElementById("reserveInput");
  let current = parseNumericInput(input.value);

  current += amount;

  if (current < 0) current = 0;

  const mv = selectedPlayerForListing.market_value;
  if (current < mv) current = mv;

  const max = selectedPlayerForListing.Maximum_Reserve_Price;
  if (current > max) current = max;

  input.value = formatNumeric(current);
  validateReserveInput();
}

// CREATE LISTING (now refreshes live listing state)
async function validateAndCreateListing() {
  const input = document.getElementById("reserveInput");
  const reserve = parseNumericInput(input.value);
  const mv = selectedPlayerForListing.market_value;
  const max = selectedPlayerForListing.Maximum_Reserve_Price;

  if (!validateReserveInput()) return;

  if (!playerCanListOrSellLocal(selectedPlayerForListing)) {
    document.getElementById("reserveError").textContent =
      isContractFinalYear(selectedPlayerForListing)
        ? FINAL_YEAR_TRANSFER_MESSAGE
        : SAME_SEASON_TRANSFER_MESSAGE;
    return;
  }

  const playerId = String(selectedPlayerForListing.Konami_ID);
  const now = new Date().toISOString();
  const endTime = computeStandardListingEndTime().toISOString();

  // Close any stale listings for this player (expired engine not run yet, re-list, etc.)
  await supabase
    .from("Player_Transfer_Listings")
    .update({
      status: "Closed",
      transfer_completed: false,
    })
    .eq("player_id", playerId)
    .eq("seller_club_id", currentUserShort)
    .in("status", ["Active", "expired"]);

  const { error } = await supabase
    .from("Player_Transfer_Listings")
    .insert({
      player_id: playerId,
      seller_club_id: currentUserShort,
      reserve_price: reserve,
      market_value: mv,
      start_time: now,
      end_time: endTime,
      status: "Active",
      listing_type: "standard",
      hidden_bids: false,
      random_end_time: null,
      special_rules: {},
      current_highest_bid: null,
      current_highest_bidder: null,
      seller_review_deadline: endTime,
      review_deadline: endTime,
      winning_bid: null,
      winning_club: null,
      transfer_completed: false,
      archived: false,
      hour_extended: false,
      was_extended: false,
      extension_type: "none",
      extension_count: 0,
      initial_end_time: endTime,
      extension_state: "none",
      last_extension_time: null
    });

  if (error) {
    console.error("LISTING INSERT ERROR:", error);
    const msg = String(error.message || "");
    document.getElementById("reserveError").textContent = msg.includes(
      "final year"
    )
      ? FINAL_YEAR_TRANSFER_MESSAGE
      : msg.includes("current season")
        ? SAME_SEASON_TRANSFER_MESSAGE
        : "Failed to create listing. Please try again.";
    return;
  }

  document.getElementById("list-player-modal-backdrop").style.display = "none";

  await refreshNavClubListingState(currentUserShort);
  refreshNavListingIndicators();

  // ⭐ Reload fresh listing state from DB
  await loadSquad();
}

function wireButtons() {
  const dec500 = document.getElementById("dec-500k-list");
  const dec1m = document.getElementById("dec-1m-list");
  const dec5m = document.getElementById("dec-5m-list");

  const inc500 = document.getElementById("inc-500k-list");
  const inc1m = document.getElementById("inc-1m-list");
  const inc5m = document.getElementById("inc-5m-list");

  const useMV = document.getElementById("useMarketValueBtn");
  const useMax = document.getElementById("useMaxReserveBtn");

  const reserveInput = document.getElementById("reserveInput");
  const cancelBtn = document.getElementById("cancelListBtn");
  const confirmBtn = document.getElementById("confirmListBtn");

  if (dec500) dec500.onclick = () => addReserveIncrement(-500000);
  if (dec1m) dec1m.onclick = () => addReserveIncrement(-1000000);
  if (dec5m) dec5m.onclick = () => addReserveIncrement(-5000000);

  if (inc500) inc500.onclick = () => addReserveIncrement(500000);
  if (inc1m) inc1m.onclick = () => addReserveIncrement(1000000);
  if (inc5m) inc5m.onclick = () => addReserveIncrement(5000000);

  if (useMV) useMV.onclick = () => {
    if (!selectedPlayerForListing) return;
    reserveInput.value = formatNumeric(selectedPlayerForListing.market_value);
    validateReserveInput();
  };

  if (useMax) useMax.onclick = () => {
    if (!selectedPlayerForListing) return;
    reserveInput.value = formatNumeric(selectedPlayerForListing.Maximum_Reserve_Price);
    validateReserveInput();
  };

  if (reserveInput) reserveInput.oninput = () => validateReserveInput();

  if (cancelBtn) cancelBtn.onclick = () => {
    document.getElementById("list-player-modal-backdrop").style.display = "none";
  };

  if (confirmBtn) confirmBtn.onclick = validateAndCreateListing;

  wireManagerSackButton();
}

function wireManagerSackButton() {
  const sackBtn = document.getElementById("sackManagerBtn");
  if (!sackBtn || sackBtn.dataset.wired) return;
  sackBtn.dataset.wired = "1";

  sackBtn.addEventListener("click", async () => {
    if (!squadManagerState.managerId) return;

    const payout = formatMoney(
      Math.round(Math.max(squadManagerState.marketValue, 0) / 2)
    );

    if (
      !window.confirm(
        `Sack ${squadManagerState.managerName}?\n\n` +
          `You receive half market value (${payout}) as compensation.\n` +
          `You cannot sack another manager this season.\n` +
          `You cannot re-sign this manager until next season.\n` +
          `Your club will have no manager until you sign a replacement.`
      )
    ) {
      return;
    }

    sackBtn.disabled = true;
    const { error } = await supabase.rpc("manager_sack");
    sackBtn.disabled = false;

    if (error) {
      alert(error.message || "Could not sack manager.");
      return;
    }

    alert(
      `${squadManagerState.managerName} sacked.\n\n` +
        `Compensation: ${payout}.\n` +
        `You cannot re-sign them until next season.`
    );

    await Promise.all([loadSquadManagerState(), loadSquad()]);
  });
}

console.log("Squad JS loaded successfully (with transfer window logic).");
