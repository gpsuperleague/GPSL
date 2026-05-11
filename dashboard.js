// ============================================================
// GPSL DASHBOARD — SUPABASE‑ONLY VERSION (PART 1/3)
// Accepts: initDashboard({ user, shortName })
// ============================================================

import { loadClubsMap, fullClubName } from "./clubs_lookup.js";

const supabase = window.supabase;

// GLOBAL STATE
let userObj = null;
let userId = null;
let userEmail = null;
let currentUserShort = null;
let clubId = null;
let activeListingsCache = [];
let selectedPlayerForListing = null;

// ============================================================
// INIT ENTRY POINT
// ============================================================
export async function initDashboard({ user, shortName }) {
  // Store user + club
  userObj = user;
  userId = user.id;
  userEmail = user.email;
  currentUserShort = shortName;

  // Update header UI
  document.getElementById("userEmail").textContent = userEmail;
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${shortName}.png`;

  // Load club name map
  await loadClubsMap();

  // Load club info (gets clubId)
  await loadClubFromSupabase();

  // Load everything else
  await loadDashboard();
}

// ============================================================
// LOAD CLUB INFO
// ============================================================
async function loadClubFromSupabase() {
  const { data, error } = await supabase
    .from("Clubs")
    .select("*")
    .eq("ShortName", currentUserShort)
    .single();

  if (error || !data) {
    console.error("Club lookup failed", error);
    return;
  }

  clubId = data.Club_ID;

  // Update UI
  document.getElementById("dashboardTitle").textContent =
    `${fullClubName(currentUserShort)} Dashboard`;

  document.getElementById("clubNameField").textContent =
    fullClubName(currentUserShort);

  document.getElementById("stadiumField").textContent =
    data.Stadium || "Unknown";

  document.getElementById("capacityField").textContent =
    data.Capacity || "Unknown";
}

// ============================================================
// MAIN DASHBOARD LOAD
// ============================================================
async function loadDashboard() {
  await loadActiveListingsCache();
  await loadFinance();
  await loadSquad();
  await loadListings();
  await loadMyActiveBids();
  await loadSeasonSignings();
  await loadSeasonSales();

  if (clubId) {
    await loadStadiumInfo(clubId);
  }
}

// ============================================================
// FINANCES
// ============================================================
async function loadFinance() {
  const { data, error } = await supabase
    .from("Club_Finances")
    .select("*")
    .eq("club_name", currentUserShort)
    .single();

  if (error || !data) {
    console.error("Finance lookup failed:", error);
    return;
  }

  document.getElementById("finance-balance").innerHTML =
    `<span class="money">₿ ${Number(data.balance).toLocaleString("en-GB")}</span>`;
}

// ============================================================
// STADIUM INFO
// ============================================================
async function loadStadiumInfo(clubId) {
  const { data: club, error: clubError } = await supabase
    .from("Clubs")
    .select("Capacity, last_stadium_upgrade_season")
    .eq("Club_ID", clubId)
    .single();

  if (clubError || !club) return;

  const { data: season } = await supabase
    .from("seasons")
    .select("season_id")
    .eq("is_active", true)
    .single();

  const currentCapacity = club.Capacity;

  const { data: nextCapData } = await supabase.rpc(
    "upgrade_stadium_capacity",
    { current_capacity: currentCapacity }
  );

  const nextCapacity = nextCapData;

  const { data: costData } = await supabase.rpc(
    "calculate_stadium_upgrade_cost",
    {
      current_capacity: currentCapacity,
      new_capacity: nextCapacity
    }
  );

  const upgradeCost = costData;

  // Update UI
  document.getElementById("current-capacity").textContent =
    currentCapacity.toLocaleString();
  document.getElementById("next-capacity").textContent =
    nextCapacity.toLocaleString();
  document.getElementById("upgrade-cost").textContent =
    "£" + upgradeCost.toLocaleString();

  const upgradeBtn = document.getElementById("upgrade-stadium-btn");

  if (nextCapacity === currentCapacity) {
    upgradeBtn.disabled = true;
    upgradeBtn.textContent = "Max Capacity Reached";
    return;
  }

  if (club.last_stadium_upgrade_season === season.season_id) {
    upgradeBtn.disabled = true;
    upgradeBtn.textContent = "Already Upgraded This Season";
    return;
  }

  upgradeBtn.disabled = false;
  upgradeBtn.textContent = "Upgrade Stadium";
  upgradeBtn.onclick = () => upgradeStadium(clubId);
}

async function upgradeStadium(clubId) {
  const message = document.getElementById("upgrade-message");
  message.textContent = "Processing upgrade...";

  const { data, error } = await supabase.rpc("upgrade_stadium_for_club", {
    p_Club: clubId
  });

  if (error) {
    message.textContent = "Error: " + error.message;
    return;
  }

  switch (data) {
    case "SUCCESS":
      message.textContent = "✅ Stadium upgraded successfully!";
      loadStadiumInfo(clubId);
      loadFinance();
      break;

    case "INSUFFICIENT_FUNDS":
      message.textContent = "❌ Not enough funds.";
      break;

    case "ALREADY_UPGRADED_THIS_SEASON":
      message.textContent = "❌ Already upgraded this season.";
      break;

    case "NO_UPGRADE_AVAILABLE":
      message.textContent = "❌ Max capacity reached.";
      break;
  }
}

// ============================================================
// ACTIVE LISTINGS CACHE
// ============================================================
async function loadActiveListingsCache() {
  const { data } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", currentUserShort)
    .eq("status", "Active");

  activeListingsCache = data || [];
}
// ============================================================
// GPSL DASHBOARD — SUPABASE‑ONLY VERSION (PART 2/3)
// ============================================================

// ============================================================
// SQUAD
// ============================================================
async function loadSquad() {
  const { data, error } = await supabase
    .from("Players")
    .select("*")
    .eq("Contracted_Team", currentUserShort);

  if (error) {
    console.error("Squad load error", error);
    return;
  }

  renderSquad(data);
}

function renderSquad(players) {
  const tbody = document.getElementById("squad-body");
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
      `<td colspan="8" class="squad-section-title">${groupName}</td>`;
    tbody.appendChild(headerRow);

    const groupPlayers = players
      .filter(p => positions.includes(p.Position))
      .sort((a, b) => b.market_value - a.market_value);

    groupPlayers.forEach(p => {
      const isListed = activeListingsCache.some(
        l => l.player_id === p.Konami_ID
      );

      const status = isListed
        ? `<span class="status-pill status-listed">Listed</span>`
        : `<span class="status-pill status-not-listed">Not Listed</span>`;

      const tr = document.createElement("tr");
      tr.dataset.konamiId = p.Konami_ID;

      tr.innerHTML = `
        <td>${p.Name}</td>
        <td>${p.Nation || "-"}</td>
        <td>${p.Position}</td>
        <td>${p.Rating || p.OVR}</td>
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
}

window.handlePlayerAction = function(playerId, action) {
  if (action === "list") {
    openListPlayerModalByID({ Konami_ID: playerId });
  }
};

// ============================================================
// LIST PLAYER MODAL
// ============================================================
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

  document.getElementById("reserveInput").value = "";
  document.getElementById("reserveError").textContent = "";

  document.getElementById("list-player-modal-backdrop").style.display = "flex";
}

document.getElementById("useMarketValueBtn").onclick = () => {
  document.getElementById("reserveInput").value =
    selectedPlayerForListing.market_value;
};

document.getElementById("useMaxReserveBtn").onclick = () => {
  document.getElementById("reserveInput").value =
    selectedPlayerForListing.Maximum_Reserve_Price;
};

document.getElementById("cancelListBtn").onclick = () => {
  document.getElementById("list-player-modal-backdrop").style.display = "none";
};

document.getElementById("confirmListBtn").onclick = validateAndCreateListing;

// ============================================================
// CREATE LISTING
// ============================================================
async function validateAndCreateListing() {
  const reserve = Number(document.getElementById("reserveInput").value);
  const mv = selectedPlayerForListing.market_value;
  const max = selectedPlayerForListing.Maximum_Reserve_Price;

  if (reserve < mv) {
    document.getElementById("reserveError").textContent =
      `Reserve must be at least market value (₿ ${mv.toLocaleString("en-GB")}).`;
    return;
  }

  if (reserve > max) {
    document.getElementById("reserveError").textContent =
      `Reserve cannot exceed max allowed (₿ ${max.toLocaleString("en-GB")}).`;
    return;
  }

  const now = new Date().toISOString();
  const endTime = new Date(Date.now() + 86400000).toISOString(); // 24h

  const { error } = await supabase
    .from("Player_Transfer_Listings")
    .insert({
      player_id: selectedPlayerForListing.Konami_ID,
      seller_club_id: currentUserShort,

      // Required core fields
      reserve_price: reserve,
      market_value: mv,
      start_time: now,
      end_time: endTime,
      status: "Active",

      // Listing behaviour defaults
      listing_type: "standard",
      hidden_bids: false,
      random_end_time: null,
      special_rules: {},

      // Bidding state
      current_highest_bid: null,
      current_highest_bidder: null,

      // Review deadlines
      seller_review_deadline: endTime,
      review_deadline: endTime,

      // Completion state
      winning_bid: null,
      winning_club: null,
      transfer_completed: false,
      archived: false,

      // Extension system
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

  await loadActiveListingsCache();
  await loadSquad();
  await loadListings();
}

// ============================================================
// PLAYER FETCH HELPER
// ============================================================
async function fetchPlayerByID(kid) {
  const { data } = await supabase
    .from("Players")
    .select("*")
    .eq("Konami_ID", kid)
    .single();

  return data;
}

// ============================================================
// DISMISS LISTING
// ============================================================
async function dismissListingForUser(listingId) {
  await supabase
    .from("User_Dismissed_Listings")
    .insert({
      user_id: userId,
      listing_id: listingId,
      dismissed_at: new Date().toISOString()
    });
}

// ============================================================
// LOAD LISTINGS
// ============================================================
async function loadListings() {
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", currentUserShort)
    .eq("archived", false);

  if (error) {
    console.error("Listings error:", error);
    return;
  }

  const updatedListings = data || [];

  const { data: dismissedRows } = await supabase
    .from("User_Dismissed_Listings")
    .select("listing_id")
    .eq("user_id", userId);

  const dismissedIds = new Set((dismissedRows || []).map(r => r.listing_id));

  const active = updatedListings.filter(l => l.status === "Active");
  const review = updatedListings.filter(l => l.status === "Review");
  const closed = updatedListings.filter(l => l.status === "Closed");

  renderActiveListings(active.filter(l => !dismissedIds.has(l.id)));
  renderSellerReview(review);
  renderClosedListings(closed);

  await loadActiveListingsCache();
  await loadSquad();
}

// ============================================================
// ACTIVE LISTINGS RENDER
// ============================================================
async function renderActiveListings(listings) {
  const tbody = document.getElementById("active-listings-body");
  tbody.innerHTML = "";

  for (const l of listings) {
    const player = await fetchPlayerByID(l.player_id);

    const tr = document.createElement("tr");
    tr.dataset.konamiId = l.player_id;
    tr.dataset.listingId = l.id;

    tr.innerHTML = `
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>${player?.Rating || "-"}</td>
      <td><span class="money">₿ ${Number(l.market_value).toLocaleString("en-GB")}</span></td>
      <td><span class="money">₿ ${Number(l.reserve_price).toLocaleString("en-GB")}</span></td>
      <td>${formatTimeRemaining(l.end_time)}</td>
      <td><span class="money">${l.current_highest_bid ? "₿ " + Number(l.current_highest_bid).toLocaleString("en-GB") : "-"}</span></td>
      <td>${l.current_highest_bidder || "-"}</td>
      <td><button class="button dismiss-btn" data-listing-id="${l.id}">❌</button></td>
    `;

    tbody.appendChild(tr);
  }

 tbody.querySelectorAll(".dismiss-btn").forEach(btn => {
  btn.addEventListener("click", async e => {
    e.stopPropagation();

    // FIX: reliably find the table row
    const row =
      e.target.closest("tr") ||
      e.currentTarget.closest("tr") ||
      e.currentTarget.parentElement.closest("tr");

    if (!row) {
      console.error("Dismiss failed: could not find table row");
      return;
    }

    const listingId = row.dataset.listingId;

    await dismissListingForUser(listingId);

    // Remove row from UI
    row.remove();

    // Refresh UI so everything stays in sync
    await loadActiveListings();
    await loadActiveListingsCache();
    await loadMyActiveBids();
    await loadListings();
  });
});

  applyPESDBRowClicks("active-listings-body");
}

// ============================================================
// SELLER REVIEW RENDER
// ============================================================
async function renderSellerReview(listings) {
  const tbody = document.getElementById("seller-review-body");
  tbody.innerHTML = "";

  for (const l of listings) {
    const player = await fetchPlayerByID(l.player_id);

    const tr = document.createElement("tr");
    tr.dataset.konamiId = l.player_id;

    tr.innerHTML = `
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>${player?.Rating || "-"}</td>
      <td><span class="money">${l.current_highest_bid ? "₿ " + Number(l.current_highest_bid).toLocaleString("en-GB") : "-"}</span></td>
      <td>${l.current_highest_bidder || "-"}</td>
      <td>${new Date(l.end_time).toLocaleString()}</td>
      <td>
        <div class="decision-buttons">
          <button class="button" onclick="transferEngine.acceptSale(${l.id})">Accept</button>
          <button class="button" onclick="transferEngine.rejectSale(${l.id})">Reject</button>
        </div>
      </td>
    `;

    tbody.appendChild(tr);
  }

  applyPESDBRowClicks("seller-review-body");
}

// ============================================================
// CLOSED LISTINGS RENDER
// ============================================================
async function renderClosedListings(listings) {
  const tbody = document.getElementById("closed-listings-body");
  tbody.innerHTML = "";

  for (const l of listings) {
    const player = await fetchPlayerByID(l.player_id);

    const tr = document.createElement("tr");
    tr.dataset.konamiId = l.player_id;

    tr.innerHTML = `
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>${player?.Rating || "-"}</td>
      <td><span class="money">${l.final_bid ? "₿ " + Number(l.final_bid).toLocaleString("en-GB") : "-"}</span></td>
      <td>${l.winner || "-"}</td>
      <td>${l.status}</td>
      <td><button class="button" style="background:#aa2222; color:#fff;" onclick="dismissClosedListing(${l.id})">❌</button></td>
    `;

    tbody.appendChild(tr);
  }

  applyPESDBRowClicks("closed-listings-body");
}

window.dismissClosedListing = async function(id) {
  await supabase
    .from("Player_Transfer_Listings")
    .update({ archived: true })
    .eq("id", id);

  loadListings();
};
// ============================================================
// GPSL DASHBOARD — SUPABASE‑ONLY VERSION (PART 3/3)
// ============================================================

/* ============================================================
   MODULE K: MY ACTIVE BIDS
   ============================================================ */
async function loadMyActiveBids() {
  const { data, error } = await supabase
    .from("Player_Transfer_Bids")
    .select(`
      listing_id,
      bid_amount,
      bid_time,
      Player_Transfer_Listings (
        id,
        player_id,
        reserve_price,
        current_highest_bid,
        current_highest_bidder,
        end_time,
        status
      )
    `)
    .eq("bidder_club_id", currentUserShort)
    .order("bid_time", { ascending: false });

  if (error) {
    console.error("Active bids error:", error);
    return;
  }

  const { data: dismissedRows } = await supabase
    .from("User_Dismissed_Listings")
    .select("listing_id")
    .eq("user_id", userId);

  const dismissedIds = new Set((dismissedRows || []).map(r => r.listing_id));

  const latestByListing = new Map();

  for (const b of data || []) {
    if (!latestByListing.has(b.listing_id)) {
      latestByListing.set(b.listing_id, b);
    }
  }

  const uniqueBids = Array.from(latestByListing.values());
  const filtered = uniqueBids.filter(b => !dismissedIds.has(b.listing_id));

  renderMyActiveBids(filtered);
}

async function renderMyActiveBids(bids) {
  const tbody = document.getElementById("my-active-bids-body");
  tbody.innerHTML = "";

  for (const b of bids) {
    const l = b.Player_Transfer_Listings;
    if (!l) continue;

    const player = await fetchPlayerByID(l.player_id);

    const tr = document.createElement("tr");
    tr.dataset.konamiId = l.player_id;
    tr.dataset.listingId = l.id;

    const showDismiss = l.status && l.status !== "Active";

    tr.innerHTML = `
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td><span class="money">₿ ${Number(b.bid_amount).toLocaleString("en-GB")}</span></td>
      <td><span class="money">${l.current_highest_bid ? "₿ " + Number(l.current_highest_bid).toLocaleString("en-GB") : "-"}</span></td>
      <td>${l.current_highest_bidder || "-"}</td>
      <td>${new Date(l.end_time).toLocaleString()}</td>
      <td>
        ${
          showDismiss
            ? `<button class="button dismiss-bid-btn" data-listing-id="${l.id}">❌</button>`
            : ""
        }
      </td>
    `;

    tbody.appendChild(tr);
  }

tbody.querySelectorAll(".dismiss-bid-btn").forEach(btn => {
  btn.addEventListener("click", async e => {
    e.stopPropagation();

    // FIX: reliably find the table row
    const row =
      e.target.closest("tr") ||
      e.currentTarget.closest("tr") ||
      e.currentTarget.parentElement.closest("tr");

    if (!row) {
      console.error("Dismiss failed: could not find table row");
      return;
    }

    const listingId = row.dataset.listingId;

    await dismissListingForUser(listingId);

    // Remove row from UI
    row.remove();

    // Refresh UI so everything stays in sync
    await loadMyActiveBids();
    await loadActiveListingsCache();
    await loadListings();
  });
});

  applyPESDBRowClicks("my-active-bids-body");
}

/* ============================================================
   MODULE N: SEASON SIGNINGS
   ============================================================ */
async function loadSeasonSignings() {
  const { data, error } = await supabase
    .from("Transfer_History")
    .select(`
      player_id,
      fee,
      seller_club_id,
      transfer_time,
      Players ( Name )
    `)
    .eq("buyer_club_id", currentUserShort)
    .order("transfer_time", { ascending: false });

  if (error) {
    console.error("Season signings load error:", error);
    return;
  }

  renderSeasonSignings(data || []);
}

function renderSeasonSignings(rows) {
  const tbody = document.getElementById("season-signings-body");
  tbody.innerHTML = "";

  if (!rows.length) {
    tbody.innerHTML = `
      <tr>
        <td colspan="3" style="text-align:center; opacity:0.7;">
          No signings this season.
        </td>
      </tr>
    `;
    return;
  }

  rows.forEach(r => {
    const tr = document.createElement("tr");
    tr.dataset.konamiId = r.player_id;

    const sellerFull = fullClubName(r.seller_club_id) || r.seller_club_id;

    tr.innerHTML = `
      <td>${r.Players?.Name || "Unknown"}</td>
      <td>${sellerFull}</td>
      <td><span class="money">₿ ${Number(r.fee).toLocaleString("en-GB")}</span></td>
    `;

    tbody.appendChild(tr);
  });

  applyPESDBRowClicks("season-signings-body");
}

/* ============================================================
   MODULE O: SEASON SALES
   ============================================================ */
async function loadSeasonSales() {
  const { data, error } = await supabase
    .from("Transfer_History")
    .select(`
      player_id,
      fee,
      buyer_club_id,
      transfer_time,
      Players ( Name )
    `)
    .eq("seller_club_id", currentUserShort)
    .order("transfer_time", { ascending: false });

  if (error) {
    console.error("Season sales load error:", error);
    return;
  }

  renderSeasonSales(data || []);
}

function renderSeasonSales(rows) {
  const tbody = document.getElementById("season-sales-body");
  tbody.innerHTML = "";

  if (!rows.length) {
    tbody.innerHTML = `
      <tr>
        <td colspan="3" style="text-align:center; opacity:0.7;">
          No sales this season.
        </td>
      </tr>
    `;
    return;
  }

  rows.forEach(r => {
    const tr = document.createElement("tr");
    tr.dataset.konamiId = r.player_id;

    const buyerFull = fullClubName(r.buyer_club_id) || r.buyer_club_id;

    tr.innerHTML = `
      <td>${r.Players?.Name || "Unknown"}</td>
      <td>${buyerFull}</td>
      <td>₿ ${Number(r.fee).toLocaleString("en-GB")}</td>
    `;

    tbody.appendChild(tr);
  });

  applyPESDBRowClicks("season-sales-body");
}

/* ============================================================
   MODULE L: UNIVERSAL PESDB ROW CLICK HANDLER
   ============================================================ */
function applyPESDBRowClicks(tbodyId) {
  const tbody = document.getElementById(tbodyId);
  if (!tbody) return;

  tbody.querySelectorAll("tr").forEach(row => {
    row.style.cursor = "pointer";

    row.addEventListener("click", e => {

      // FIX: detect button clicks reliably
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

/* ============================================================
   MODULE M: TIME REMAINING FORMATTER
   ============================================================ */
function formatTimeRemaining(endTime) {
  const end = new Date(endTime);
  const now = new Date();
  const diff = end - now;

  if (diff <= 0) return "Expired";

  const hours = Math.floor(diff / 3600000);
  const mins = Math.floor((diff % 3600000) / 60000);

  return `${hours}h ${mins}m`;
}

console.log("Dashboard JS loaded successfully.");
