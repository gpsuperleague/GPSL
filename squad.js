// squad.js — CLEAN, FIXED, MODERN VERSION WITH TRANSFER WINDOW LOGIC

import { fullClubName } from "./clubs_lookup.js";
import { computeStandardListingEndTime, initGlobal, supabase } from "./global.js";
import {
  loadPlayerSeasonStatsForSquad,
  statsMapByPlayerId,
} from "./competition.js";
import {
  analyseSquadComposition,
  playerSquadQualificationBadges,
  squadComplianceRuleRows,
} from "./squad_rules.js";
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

window.supabase = supabase;

/** Columns needed for squad table + list modal (avoid select *). */
const SQUAD_PLAYER_COLUMNS =
  "Konami_ID, Name, Nation, Position, Rating, Potential, Calc_Potential, Age, market_value, Playstyle, Maximum_Reserve_Price, Contracted_Team, Season_Signed, contract_seasons_remaining, contract_wage";

const SQUAD_PLAYER_COLUMNS_LEGACY =
  "Konami_ID, Name, Nation, Position, Rating, Age, market_value, Playstyle, Maximum_Reserve_Price, Contracted_Team, Season_Signed, contract_seasons_remaining, contract_wage";

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
    .select("ShortName, Club, Nation, foreign_interest_remaining")
    .eq("owner_id", user.id)
    .single();

  club = clubRes.data;
  clubErr = clubRes.error;

  if (clubErr?.code === "42703") {
    const fallback = await supabase
      .from("Clubs")
      .select("ShortName, Club, Nation")
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
  renderForeignInterestBadge();
  applyForeignSaleOptionState();

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

function renderForeignInterestBadge() {
  const el = document.getElementById("foreignInterestBadge");
  if (!el) return;

  const n = foreignInterestRemaining;
  el.classList.toggle("foreign-interest-badge--empty", n <= 0);

  if (n <= 0) {
    el.textContent = "No foreign clubs interested in your players";
    return;
  }

  const clubWord = n === 1 ? "club" : "clubs";
  el.textContent = `${n} foreign ${clubWord} interested in your players`;
}

function squadActionOptionsHtml(player) {
  const contractOpts = squadContractActionOptionsHtml(player, clubNation);
  if (contractOpts) return contractOpts;

  if (!playerCanListOrSellLocal(player)) {
    if (isContractFinalYear(player)) {
      return `<option value="" disabled>Final contract year</option>`;
    }
    return `<option value="" disabled>Signed this season</option>`;
  }
  return `
            <option value="list">Transfer List</option>
            <option value="foreign">Sell to foreign club</option>`;
}

function playerCanListOrSellLocal(player) {
  return playerBlockedFromTransferMarket(player, currentGpslSeasonLabel) === false;
}

function applyForeignSaleOptionState() {
  const allowForeign = foreignInterestRemaining > 0;
  document.querySelectorAll("select.squad-action-select").forEach((sel) => {
    const pid = sel.dataset.playerId;
    const row = sel.closest("tr[data-konami-id]");
    const blocked = pid && !playerCanListOrSellLocal({
      Season_Signed: row?.dataset.seasonSigned,
      contract_seasons_remaining: row?.dataset.contractSeasons,
    });

    const listOpt = sel.querySelector('option[value="list"]');
    const foreignOpt = sel.querySelector('option[value="foreign"]');

    if (blocked) {
      if (listOpt) listOpt.disabled = true;
      if (foreignOpt) {
        foreignOpt.disabled = true;
        foreignOpt.textContent = "Signed this season";
      }
      return;
    }

    if (listOpt) {
      listOpt.disabled = !transferWindowOpen;
      listOpt.textContent = transferWindowOpen
        ? "Transfer List"
        : "Transfer Window Shut";
    }
    if (foreignOpt) {
      const finalYear =
        row?.dataset.contractSeasons === "1";
      foreignOpt.disabled = !allowForeign || finalYear;
      foreignOpt.textContent = finalYear
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
      '<tr data-squad-loading><td colspan="14" style="color:#888;padding:16px;">Loading squad…</td></tr>';
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
        '<tr><td colspan="14" style="color:#f88;">Failed to load squad.</td></tr>';
    }
    return;
  }

  const list = players || [];
  const playerIds = list.map((p) => String(p.Konami_ID));
  const idsKey = playerIds.slice().sort().join(",");

  renderSquadCompliance(list);

  if (!hadSquad || tbody?.dataset.squadIds !== idsKey) {
    renderSquad(list, null, new Map());
    if (tbody) tbody.dataset.squadIds = idsKey;
  }

  const [state, seasonStats] = await Promise.all([
    loadFreshTransferStatusState(),
    loadPlayerSeasonStatsForSquad(supabase, playerIds, currentUserShort),
  ]);
  transferStatusState = state;

  patchSquadEnrichment(transferStatusState, statsMapByPlayerId(seasonStats));
}

function renderSquadCompliance(players) {
  const el = document.getElementById("squadCompliancePanel");
  if (!el) return;

  const c = analyseSquadComposition(players, clubNation);
  const rows = squadComplianceRuleRows(c, clubNation);
  const panelClass = c.compliant
    ? "squad-rules-panel squad-rules-panel--ok"
    : "squad-rules-panel squad-rules-panel--warn";

  const tableRows = rows
    .map(
      (r) => `
    <tr class="${r.ok ? "squad-rules-row--ok" : "squad-rules-row--fail"}">
      <th scope="row">${r.rule}</th>
      <td class="squad-rules-who">${r.whoCounts}</td>
      <td class="squad-rules-req">${r.requirement}<span class="squad-rules-note">${r.note}</span></td>
      <td class="squad-rules-count"><strong>${r.count}</strong></td>
      <td class="squad-rules-status">${r.ok ? "✓" : "✗"} ${r.status}</td>
    </tr>`
    )
    .join("");

  const overall = c.compliant
    ? '<p class="squad-rules-overall squad-rules-overall--ok">Your squad meets all registration requirements.</p>'
    : `<p class="squad-rules-overall squad-rules-overall--warn">Your squad does not yet meet all requirements:</p>
       <ul class="squad-rules-issues">${c.issues.map((i) => `<li>${i}</li>`).join("")}</ul>`;

  el.innerHTML = `
    <section class="${panelClass}" aria-label="Squad registration requirements">
      <header class="squad-rules-header">
        <h2 class="squad-rules-title">Squad registration requirements</h2>
        <p class="squad-rules-intro">
          Counts are based on your contracted players in the table below.
          <strong>Home-grown</strong> and <strong>under-21</strong> are <em>minimums</em> — you may have more than required.
          Only <strong>squad size</strong> has a maximum.
        </p>
      </header>
      <table class="squad-rules-table">
        <thead>
          <tr>
            <th scope="col">Rule</th>
            <th scope="col">Who counts</th>
            <th scope="col">League requirement</th>
            <th scope="col">Your squad</th>
            <th scope="col">Status</th>
          </tr>
        </thead>
        <tbody>${tableRows}</tbody>
      </table>
      ${overall}
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

function renderSquad(players, transferState, statsByPlayer = new Map()) {
  const tbody = document.getElementById("squad-body");
  if (!tbody) return;

  tbody.innerHTML = "";

  const groups = {
    "Goalkeepers": ["GK"],
    "Defenders": ["LB", "CB", "RB"],
    "Midfielders": ["DMF", "LMF", "CMF", "RMF", "AMF"],
    "Attackers": ["SS", "LW", "CF", "RW"]
  };

  for (const [groupName, positions] of Object.entries(groups)) {
    const headerRow = document.createElement("tr");
    headerRow.classList.add("squad-section-row");
    headerRow.innerHTML =
      `<td colspan="14" class="squad-section-title">${groupName}</td>`;
    tbody.appendChild(headerRow);

    const groupPlayers = players
      .filter(p => positions.includes(p.Position))
      .sort((a, b) => b.market_value - a.market_value);

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
            label: "Not listed",
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

      const imgURL = `https://pesdb.net/assets/img/card/b${p.Konami_ID}.png`;

      const qualBadges = playerSquadQualificationBadges(p, clubNation);

      tr.innerHTML = `
        <td><img src="${imgURL}" class="player-thumb" onerror="this.src='https://i.imgur.com/3s8XQ7Y.png'"></td>
        <td>${p.Name}${qualBadges}</td>
        <td>${p.Nation || "-"}</td>
        <td>${p.Position}</td>
        <td>${formatRatingWithPotential(p)}</td>
        <td class="num squad-col-apps">${formatSeasonStat(st, "appearances", "0")}</td>
        <td class="num squad-col-goals">${formatSeasonStat(st, "goals", "0")}</td>
        <td class="num squad-col-assists">${formatSeasonStat(st, "assists", "0")}</td>
        <td class="num squad-col-avg">${avg}</td>
        <td>${p.Playstyle || "-"}</td>
        <td><span class="money">₿ ${Number(p.market_value).toLocaleString("en-GB")}</span></td>
        <td class="squad-col-contract">${formatSquadContractCell(p)}</td>
        <td class="squad-col-status">${status}</td>
        <td class="squad-col-action">
          <select class="squad-action-select" data-player-id="${String(p.Konami_ID)}">
            <option value="">Action</option>
            ${squadActionOptionsHtml(p)}
          </select>
        </td>
      `;

      tbody.appendChild(tr);
    });
  }

  applyTransferWindowRules();
  applyForeignSaleOptionState();
}

/** Update stats + listing pills only — keeps action dropdowns mounted and clickable. */
function patchSquadEnrichment(transferState, statsByPlayer) {
  const tbody = document.getElementById("squad-body");
  if (!tbody) return;

  tbody.querySelectorAll("tr[data-konami-id]").forEach((row) => {
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
      const statusRow = resolvePlayerTransferStatus({
        konamiId: id,
        contractedTeam:
          row.dataset.contractedTeam || currentUserShort,
        viewerClubShort: currentUserShort,
        state: transferState,
        seasonSigned: row.dataset.seasonSigned || null,
        contractSeasonsRemaining: row.dataset.contractSeasons || null,
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
    const sel = e.target.closest("select.squad-action-select");
    if (sel) {
      e.stopPropagation();
      return;
    }

    if (
      e.target.closest("button") ||
      e.target.closest(".decision-buttons")
    ) {
      return;
    }

    const row = e.target.closest("tr[data-konami-id]");
    if (!row?.dataset.konamiId) return;

    window.open(
      `https://pesdb.net/efootball/?id=${row.dataset.konamiId}`,
      "_blank",
      "noopener"
    );
  });

  tbody.addEventListener("change", (e) => {
    const sel = e.target.closest("select.squad-action-select");
    if (!sel) return;
    e.stopPropagation();
    void handlePlayerAction(sel.dataset.playerId, sel.value, sel);
  });
}

// Blocks listing when transfer window is closed
async function handlePlayerAction(playerId, action, selectEl) {
  if (!action) {
    resetActionSelect(selectEl);
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

    if (action === "foreign") {
      resetActionSelect(selectEl);
      if (foreignInterestRemaining <= 0) {
        alert("No foreign clubs are interested in your players (limit reached).");
        return;
      }
      await sellPlayerToForeignClub(playerId);
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

async function sellPlayerToForeignClub(playerId) {
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
  const confirmed = window.confirm(
    `Sell ${player.Name} to a foreign club?\n\n` +
      `The player will be released as a free agent.\n` +
      `Your club will receive ${formatMoney(mv)} (market value).`
  );

  if (!confirmed) return;

  const { data, error } = await supabase.rpc("sell_player_to_foreign_club", {
    p_player_id: String(playerId),
  });

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
  renderForeignInterestBadge();
  applyForeignSaleOptionState();

  alert(
    `${data?.player_name || player.Name} sold to a foreign club.\n` +
      `${formatMoney(fee)} credited to your club balance.`
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
