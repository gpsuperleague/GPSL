// squad.js — CLEAN, FIXED, MODERN VERSION WITH TRANSFER WINDOW LOGIC

import { fullClubName } from "./clubs_lookup.js";
import { computeStandardListingEndTime } from "./global.js";
import { loadPlayerSeasonStats, statsMapByPlayerId } from "./competition.js";

const supabase = window.supabase;

// STATE
let userObj = null;
let userId = null;
let currentUserShort = null;
let selectedPlayerForListing = null;

// ⭐ NEW: Transfer window state
let transferWindowOpen = true;

// ENTRY POINT
document.addEventListener("DOMContentLoaded", async () => {
  const { data: { user } } = await supabase.auth.getUser();

  if (!user) {
    window.location = "login.html";
    return;
  }

  userObj = user;
  userId = user.id;

  document.getElementById("userEmail").textContent = user.email;

  // Load club
  const { data: club, error } = await supabase
    .from("Clubs")
    .select("*")
    .eq("owner_id", user.id)
    .single();

  if (error || !club) {
    alert("No club assigned to this account.");
    return;
  }

  currentUserShort = club.ShortName;
  window.GPSL_CLUB_SHORTNAME = currentUserShort;

  document.getElementById("dashboardTitle").textContent = `${club.Club} Squad`;
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${currentUserShort}.png`;

  // ⭐ Load transfer window status BEFORE loading squad
  await loadTransferWindowStatus();

  await loadSquad(); // now loads fresh listing state internally

  wireButtons();

  // OPTIONAL: auto-refresh listing status every 30 seconds
  setInterval(async () => {
    await loadTransferWindowStatus();
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
}

// ⭐ NEW: Apply UI rules when window is closed
function applyTransferWindowRules() {
  const msg = document.getElementById("windowClosedMessage");
  const selects = document.querySelectorAll("select");

  if (!transferWindowOpen) {
    // Show warning message
    if (msg) msg.style.display = "block";

    // Update dropdowns
    selects.forEach(sel => {
      const opt = sel.querySelector('option[value="list"]');
      if (opt) {
        opt.textContent = "Transfer Window Shut";
        opt.disabled = true;
      }
    });
  } else {
    if (msg) msg.style.display = "none";

    selects.forEach(sel => {
      const opt = sel.querySelector('option[value="list"]');
      if (opt) {
        opt.textContent = "Transfer List";
        opt.disabled = false;
      }
    });
  }
}

// ⭐ Always fetch ACTIVE listings live from Supabase
async function getActiveListings() {
  const now = new Date().toISOString();
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("player_id")
    .eq("status", "Active")
    .gt("end_time", now);

  if (error) {
    console.error("Error loading active listings:", error);
    return [];
  }

  return data.map((x) => String(x.player_id));
}

// LOAD SQUAD (now includes fresh listing state)
async function loadSquad() {
  const { data: players, error } = await supabase
    .from("Players")
    .select("*")
    .eq("Contracted_Team", currentUserShort);

  if (error) {
    console.error("Squad load error", error);
    return;
  }

  const activeListings = await getActiveListings();
  const seasonStats = await loadPlayerSeasonStats(supabase);
  const statsByPlayer = statsMapByPlayerId(
    seasonStats.filter(
      (r) =>
        (r.club_short_name || "").toUpperCase() ===
        (currentUserShort || "").toUpperCase()
    )
  );
  renderSquad(players, activeListings, statsByPlayer);
}

// RENDER SQUAD
function formatSeasonStat(row, key, fallback = "—") {
  if (!row) return fallback;
  const v = row[key];
  if (v == null || v === "") return fallback;
  return v;
}

function renderSquad(players, activeListings, statsByPlayer = new Map()) {
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
      `<td colspan="13" class="squad-section-title">${groupName}</td>`;
    tbody.appendChild(headerRow);

    const groupPlayers = players
      .filter(p => positions.includes(p.Position))
      .sort((a, b) => b.market_value - a.market_value);

    groupPlayers.forEach(p => {
      const isListed = activeListings.includes(String(p.Konami_ID));

      const status = isListed
        ? `<span class="status-pill status-listed">Listed</span>`
        : `<span class="status-pill status-not-listed">Not Listed</span>`;

      const tr = document.createElement("tr");
      tr.dataset.konamiId = p.Konami_ID;
      const st = statsByPlayer.get(String(p.Konami_ID));
      const avg =
        st?.avg_rating != null ? Number(st.avg_rating).toFixed(2) : "—";

      const imgURL = `https://pesdb.net/assets/img/card/b${p.Konami_ID}.png`;

      tr.innerHTML = `
        <td><img src="${imgURL}" class="player-thumb" onerror="this.src='https://i.imgur.com/3s8XQ7Y.png'"></td>
        <td>${p.Name}</td>
        <td>${p.Nation || "-"}</td>
        <td>${p.Position}</td>
        <td>${p.Rating || p.OVR}</td>
        <td class="num">${formatSeasonStat(st, "appearances", "0")}</td>
        <td class="num">${formatSeasonStat(st, "goals", "0")}</td>
        <td class="num">${formatSeasonStat(st, "assists", "0")}</td>
        <td class="num">${avg}</td>
        <td>${p.Playstyle || "-"}</td>
        <td><span class="money">₿ ${Number(p.market_value).toLocaleString("en-GB")}</span></td>
        <td>${status}</td>
        <td>
          <select onchange="handlePlayerAction('${p.Konami_ID}', this.value)">
            <option value="">Action</option>
            <option value="list">Transfer List</option>
          </select>
        </td>
      `;

      tbody.appendChild(tr);
    });
  }

  applyPESDBRowClicks("squad-body");

  // ⭐ Apply transfer window rules AFTER rendering
  applyTransferWindowRules();
}

// ⭐ UPDATED ACTION HANDLER — blocks listing when window is closed
window.handlePlayerAction = function(playerId, action) {
  if (action === "list") {
    if (!transferWindowOpen) {
      return; // block listing when window is closed
    }
    openListPlayerModalByID({ Konami_ID: playerId });
  }
};

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
    document.getElementById("reserveError").textContent =
      "Failed to create listing. Please try again.";
    return;
  }

  document.getElementById("list-player-modal-backdrop").style.display = "none";

  // ⭐ Reload fresh listing state from DB
  await loadSquad();
}

// PESDB CLICK HANDLER
function applyPESDBRowClicks(tbodyId) {
  const tbody = document.getElementById(tbodyId);
  if (!tbody) return;

  tbody.querySelectorAll("tr").forEach(row => {
    row.style.cursor = "pointer";

    row.addEventListener("click", e => {
      const clickedButton =
        e.target.closest("button") ||
        e.currentTarget.querySelector("button:hover");

      if (
        e.target.closest("select") ||
        clickedButton ||
        e.target.closest(".decision-buttons")
      ) {
        return;
      }

      const id = row.dataset.konamiId;
      if (id) {
        window.open(
          `https://pesdb.net/efootball/?id=${id}`,
          "_blank",
          "noopener"
        );
      }
    });
  });
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
