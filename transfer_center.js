// ============================================================
// TRANSFER CENTRE — Corrected JS (Schema‑accurate, error‑free)
// ============================================================

import { supabase } from "./supabase_client.js";
import { initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  // Load user
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  document.getElementById("userEmail").textContent = user.email;

  // Load club
  const { data: club } = await supabase
    .from("Clubs")
    .select("*")
    .eq("owner_id", user.id)
    .single();

  await loadClubsMap();

  const shortName = club.ShortName;
  const fullName = fullClubName(shortName) || club.Club || shortName;

  document.getElementById("pageTitle").textContent = `${fullName} — Transfer Centre`;
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${shortName}.png`;

  // Load all sections
  loadActiveListings(shortName);
  loadActiveBids(shortName);
  loadSellerReview(shortName);
  loadClosedListings(shortName);
  loadSeasonSignings(shortName);
  loadSeasonSales(shortName);

  setupListPlayerModal(shortName);
});


// ============================================================
// HELPER: Fetch players by Konami_ID
// ============================================================

async function fetchPlayersMap(playerIds) {
  if (playerIds.length === 0) return new Map();

  const { data } = await supabase
    .from("Players")
    .select("*")
    .in("Konami_ID", playerIds);

  const map = new Map();
  data.forEach(p => map.set(p.Konami_ID, p));
  return map;
}


// ============================================================
// ACTIVE LISTINGS
// ============================================================

async function loadActiveListings(shortName) {
  const container = document.getElementById("activeListingsContainer");
  container.innerHTML = "Loading…";

  const { data: listings } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", shortName)
    .eq("status", "Active")
    .order("created_at", { ascending: false });

  if (!listings || listings.length === 0) {
    container.innerHTML = "<i>No active listings.</i>";
    return;
  }

  const playerIds = listings.map(l => l.player_id);
  const players = await fetchPlayersMap(playerIds);

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>Reserve</th>
        <th>Status</th>
        <th></th>
      </tr>
      ${listings.map(row => `
        <tr>
          <td>${players.get(row.player_id)?.Name || "Unknown"}</td>
          <td>₿ ${Number(row.reserve_price).toLocaleString("en-GB")}</td>
          <td><span class="status-pill status-listed">Listed</span></td>
          <td><button class="dismiss-btn" data-id="${row.id}">Remove</button></td>
        </tr>
      `).join("")}
    </table>
  `;

  container.querySelectorAll(".dismiss-btn").forEach(btn => {
    btn.addEventListener("click", () => removeListing(btn.dataset.id, shortName));
  });
}

async function removeListing(listingId, shortName) {
  await supabase
    .from("Player_Transfer_Listings")
    .update({ status: "removed" })
    .eq("id", listingId);

  loadActiveListings(shortName);
}


// ============================================================
// ACTIVE BIDS
// ============================================================

async function loadActiveBids(shortName) {
  const container = document.getElementById("activeBidsContainer");
  container.innerHTML = "Loading…";

  const { data: bids } = await supabase
    .from("Player_Transfer_Bids")
    .select("*")
    .eq("bidder_club_id", shortName)
    .eq("is_direct", true)
    .order("bid_time", { ascending: false });

  if (!bids || bids.length === 0) {
    container.innerHTML = "<i>No active bids.</i>";
    return;
  }

  // Fetch listings
  const listingIds = bids.map(b => b.listing_id);
  const { data: listings } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .in("id", listingIds);

  const listingMap = new Map();
  listings.forEach(l => listingMap.set(l.id, l));

  // Fetch players
  const playerIds = listings.map(l => l.player_id);
  const players = await fetchPlayersMap(playerIds);

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>Bid</th>
        <th>Time</th>
        <th></th>
      </tr>
      ${bids.map(row => {
        const listing = listingMap.get(row.listing_id);
        const player = players.get(listing?.player_id);
        return `
          <tr>
            <td>${player?.Name || "Unknown"}</td>
            <td>₿ ${Number(row.bid_amount).toLocaleString("en-GB")}</td>
            <td>${new Date(row.bid_time).toLocaleString()}</td>
            <td><button class="dismiss-bid-btn" data-id="${row.bid_id}">Cancel</button></td>
          </tr>
        `;
      }).join("")}
    </table>
  `;

  container.querySelectorAll(".dismiss-bid-btn").forEach(btn => {
    btn.addEventListener("click", () => removeBid(btn.dataset.id, shortName));
  });
}

async function removeBid(bidId, shortName) {
  await supabase
    .from("Player_Transfer_Bids")
    .update({ cancelled: true })
    .eq("bid_id", bidId);

  loadActiveBids(shortName);
}


// ============================================================
// SELLER REVIEW
// ============================================================

async function loadSellerReview(shortName) {
  const container = document.getElementById("sellerReviewContainer");
  container.innerHTML = "Loading…";

  const { data: bids } = await supabase
    .from("Player_Transfer_Bids")
    .select("*")
    .eq("seller_club_id", shortName)
    .eq("is_direct", true)
    .order("bid_time", { ascending: false });

  if (!bids || bids.length === 0) {
    container.innerHTML = "<i>No bids to review.</i>";
    return;
  }

  const listingIds = bids.map(b => b.listing_id);
  const { data: listings } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .in("id", listingIds);

  const listingMap = new Map();
  listings.forEach(l => listingMap.set(l.id, l));

  const playerIds = listings.map(l => l.player_id);
  const players = await fetchPlayersMap(playerIds);

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>Bidder</th>
        <th>Amount</th>
        <th>Time</th>
      </tr>
      ${bids.map(row => {
        const listing = listingMap.get(row.listing_id);
        const player = players.get(listing?.player_id);
        return `
          <tr>
            <td>${player?.Name || "Unknown"}</td>
            <td>${row.bidder_club_id}</td>
            <td>₿ ${Number(row.bid_amount).toLocaleString("en-GB")}</td>
            <td>${new Date(row.bid_time).toLocaleString()}</td>
          </tr>
        `;
      }).join("")}
    </table>
  `;
}


// ============================================================
// CLOSED LISTINGS
// ============================================================

async function loadClosedListings(shortName) {
  const container = document.getElementById("closedListingsContainer");
  container.innerHTML = "Loading…";

  const { data: listings } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", shortName)
    .eq("status", "Closed")
    .order("end_time", { ascending: false });

  if (!listings || listings.length === 0) {
    container.innerHTML = "<i>No closed listings.</i>";
    return;
  }

  const playerIds = listings.map(l => l.player_id);
  const players = await fetchPlayersMap(playerIds);

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>Final Price</th>
        <th>Ended</th>
      </tr>
      ${listings.map(row => `
        <tr>
          <td>${players.get(row.player_id)?.Name || "Unknown"}</td>
          <td>₿ ${Number(row.final_price || 0).toLocaleString("en-GB")}</td>
          <td>${new Date(row.end_time).toLocaleString()}</td>
        </tr>
      `).join("")}
    </table>
  `;
}


// ============================================================
// SEASON SIGNINGS (Transfer_History)
// ============================================================

async function loadSeasonSignings(shortName) {
  const container = document.getElementById("seasonSigningsContainer");
  container.innerHTML = "Loading…";

  const { data: transfers } = await supabase
    .from("Transfer_History")
    .select("*")
    .eq("buyer_club_id", shortName)
    .order("transfer_time", { ascending: false });

  if (!transfers || transfers.length === 0) {
    container.innerHTML = "<i>No signings this season.</i>";
    return;
  }

  const playerIds = transfers.map(t => t.player_id);
  const players = await fetchPlayersMap(playerIds);

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>From</th>
        <th>Price</th>
        <th>Date</th>
      </tr>
      ${transfers.map(row => `
        <tr>
          <td>${players.get(row.player_id)?.Name || "Unknown"}</td>
          <td>${row.seller_club_id || "FREE AGENT"}</td>
          <td>₿ ${Number(row.fee).toLocaleString("en-GB")}</td>
          <td>${new Date(row.transfer_time).toLocaleString()}</td>
        </tr>
      `).join("")}
    </table>
  `;
}


// ============================================================
// SEASON SALES (Transfer_History)
// ============================================================

async function loadSeasonSales(shortName) {
  const container = document.getElementById("seasonSalesContainer");
  container.innerHTML = "Loading…";

  const { data: transfers } = await supabase
    .from("Transfer_History")
    .select("*")
    .eq("seller_club_id", shortName)
    .order("transfer_time", { ascending: false });

  if (!transfers || transfers.length === 0) {
    container.innerHTML = "<i>No sales this season.</i>";
    return;
  }

  const playerIds = transfers.map(t => t.player_id);
  const players = await fetchPlayersMap(playerIds);

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>To</th>
        <th>Price</th>
        <th>Date</th>
      </tr>
      ${transfers.map(row => `
        <tr>
          <td>${players.get(row.player_id)?.Name || "Unknown"}</td>
          <td>${row.buyer_club_id}</td>
          <td>₿ ${Number(row.fee).toLocaleString("en-GB")}</td>
          <td>${new Date(row.transfer_time).toLocaleString()}</td>
        </tr>
      `).join("")}
    </table>
  `;
}


// ============================================================
// LIST PLAYER MODAL
// ============================================================

function setupListPlayerModal(shortName) {
  const backdrop = document.getElementById("list-player-modal-backdrop");
  const confirmBtn = document.getElementById("confirmListBtn");
  const cancelBtn = document.getElementById("cancelListBtn");

  cancelBtn.onclick = () => {
    backdrop.style.display = "none";
  };

  confirmBtn.onclick = async () => {
    const reserveInput = document.getElementById("reserveInput");
    const reserve = Number(reserveInput.value.replace(/[^\d]/g, ""));

    if (!reserve || reserve <= 0) {
      document.getElementById("reserveError").textContent =
        "Enter a valid reserve price.";
      return;
    }

    const playerId = backdrop.dataset.playerId;

    await supabase.from("Player_Transfer_Listings").insert({
      player_id: playerId,
      seller_club_id: shortName,
      reserve_price: reserve,
      status: "Active",
      created_at: new Date().toISOString()
    });

    backdrop.style.display = "none";

    loadActiveListings(shortName);
  };
}


// ============================================================
// OPEN LIST PLAYER MODAL
// ============================================================

export function openListPlayerModal(playerId, name, info) {
  const backdrop = document.getElementById("list-player-modal-backdrop");

  backdrop.dataset.playerId = playerId;
  document.getElementById("modalPlayerName").textContent = name;
  document.getElementById("modalPlayerInfo").textContent = info;

  document.getElementById("reserveInput").value = "";
  document.getElementById("reserveError").textContent = "";

  backdrop.style.display = "flex";
}
