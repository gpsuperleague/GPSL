// squad.js — CLEAN, FIXED, MODERN VERSION WITH TRANSFER WINDOW LOGIC

import { fullClubName } from "./clubs_lookup.js";
import { computeStandardListingEndTime, initGlobal, supabase } from "./global.js";
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
let currentGpslSeasonLabel = "";

const MAX_FOREIGN_INTEREST = 3;
let foreignInterestRemaining = MAX_FOREIGN_INTEREST;
/** Fictional clubs currently tracking (same length as interest slots). */
let foreignTrackingTeams = [];
let voluntaryReleasesRemaining = MAX_VOLUNTARY_CONTRACT_RELEASES;
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
  await Promise.all([loadForeignInterestState(), loadVoluntaryReleaseState()]);
  renderForeignInterestBadge();
  renderVoluntaryReleaseBadge();
  applyForeignSaleOptionState();
  applyVoluntaryReleaseOptionState();

  wireButtons();
  wireSquadTable();

  await Promise.all([loadTransferWindowStatus(), loadSquad()]);

  setInterval(async () => {
    await Promise.all([loadTransferWindowStatus(), loadSquad()]);
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

function squadActionOptionsHtml(player) {
  const pid = String(player?.Konami_ID ?? "");
  if (seasonLoanPlayerIds.has(pid)) {
    return seasonLoanTerminateOptionHtml(
      !!squadMinimumStatus?.can_terminate_loans
    );
  }

  const releaseOpt = voluntaryReleaseOptionHtml(player);
  const contractOpts = squadContractActionOptionsHtml(player, clubNation, {
    optionHtml: releaseOpt,
  });
  if (contractOpts) return contractOpts;

  if (!playerCanListOrSellLocal(player)) {
    if (isContractFinalYear(player)) {
      return `<option value="" disabled>Final contract year</option>`;
    }
    return `${releaseOpt}
            <option value="" disabled>Signed this season</option>`;
  }
  const foreignOpts =
    foreignTrackingTeams.length > 0
      ? foreignSaleOptionsHtml(foreignTrackingTeams)
      : `<option value="foreign">Sell to foreign club</option>`;

  return `
            <option value="list">Transfer List</option>
            ${foreignOpts}
            ${releaseOpt}`;
}

function playerCanListOrSellLocal(player) {
  return playerBlockedFromTransferMarket(player, currentGpslSeasonLabel) === false;
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

function applyTransferWindowRules() {
  const msg = document.getElementById("windowClosedMessage");
  if (msg) msg.style.display = transferWindowOpen ? "none" : "block";
  applyForeignSaleOptionState();
  applyVoluntaryReleaseOptionState();
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

  renderSquadCompliance(list, squadDesignationsState, squadGhostPlayers);

  const [state, seasonStats] = await Promise.all([
    loadFreshTransferStatusState(),
    loadPlayerSeasonStatsForSquad(supabase, playerIds, currentUserShort),
  ]);
  transferStatusState = state;
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
      const status = formatSquadStatusHtml(statusRow);

      const tr = document.createElement("tr");
      tr.dataset.konamiId = p.Konami_ID;
      tr.dataset.contractedTeam = p.Contracted_Team || currentUserShort;
      tr.dataset.seasonSigned = p.Season_Signed ?? "";
      tr.dataset.contractSeasons =
        p.contract_seasons_remaining != null
          ? String(p.contract_seasons_remaining)
          : "";
      tr.style.cursor = "pointer";
      const st = statsByPlayer.get(String(p.Konami_ID));
      const avg =
        st?.avg_rating != null ? Number(st.avg_rating).toFixed(2) : "—";

      const qualBadges = playerSquadQualificationBadges(p, clubNation);
      const roleBadge = roleBadgeForPlayer(p, designationsState);
      const loanBadge = seasonLoanPlayerIds.has(String(p.Konami_ID))
        ? seasonLoanBadgeHtml()
        : "";

      tr.innerHTML = `
        <td class="squad-col-thumb">${playerThumbLinkHtml(p.Konami_ID, { alt: p.Name })}</td>
        <td class="squad-col-player">${playerNameLinkHtml(p.Konami_ID, p.Name)}${loanBadge}${roleBadge}${qualBadges}</td>
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
          <select class="squad-action-select" data-player-id="${String(p.Konami_ID)}">
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

  const widths = Array.from(ths, () => 0);

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
      status.innerHTML = formatSquadStatusHtml(statusRow);
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
    const nameCell = row.querySelector("td:nth-child(2)");
    if (!nameCell || !player) return;
    const link = nameCell.querySelector(".squad-player-link");
    const qual = nameCell.querySelector(".squad-qual-badge");
    if (link) {
      nameCell.innerHTML = `${link.outerHTML}${roleBadgeForPlayer(player, squadDesignationsState)}${qual ? qual.outerHTML : ""}`;
    }
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
}

console.log("Squad JS loaded successfully (with transfer window logic).");
