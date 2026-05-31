// ============================================================
// TRANSFER CENTRE — Merged JS (Direct bids + status + 24h+next‑7pm)
// ============================================================

import { supabase } from "./supabase_client.js";
import { initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  // Load user
  const {
    data: { user },
  } = await supabase.auth.getUser();
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
  if (!playerIds || playerIds.length === 0) return new Map();

  const { data } = await supabase
    .from("Players")
    .select("*")
    .in("Konami_ID", playerIds);

  const map = new Map();
  data?.forEach((p) => map.set(p.Konami_ID, p));
  return map;
}

// ============================================================
// HELPER: Compute end time = max(now+24h, next 19:00 UK)
// ============================================================

function computeListingEndTime() {
  const now = new Date();
  const minEnd = new Date(now.getTime() + 24 * 60 * 60 * 1000); // now + 24h

  // Convert minEnd to Europe/London local components
  const ukString = minEnd.toLocaleString("en-GB", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  });

  // ukString like "31/05/2026, 20:15:30"
  const parts = ukString.replace(",", "").split(/[/ :]/);
  const [day, month, year, hour, minute, second] = parts.map((p) =>
    parseInt(p, 10)
  );

  // Build a Date that represents that local UK time
  const ukLocal = new Date(year, month - 1, day, hour, minute, second, 0);

  // Next 19:00 UK on that date or next day if already past 19:00
  let next19 = new Date(ukLocal);
  next19.setHours(19, 0, 0, 0);
  if (ukLocal.getTime() > next19.getTime()) {
    // move to next day 19:00
    next19.setDate(next19.getDate() + 1);
  }

  // Convert that UK local 19:00 back to UTC
  const next19UTC = new Date(
    next19.getTime() - next19.getTimezoneOffset() * 60000
  );

  return minEnd > next19UTC ? minEnd : next19UTC;
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

  const playerIds = listings.map((l) => l.player_id);
  const players = await fetchPlayersMap(playerIds);

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>Reserve</th>
        <th>Status</th>
        <th></th>
      </tr>
      ${listings
        .map(
          (row) => `
        <tr>
          <td>${players.get(row.player_id)?.Name || "Unknown"}</td>
          <td>₿ ${Number(row.reserve_price).toLocaleString("en-GB")}</td>
          <td><span class="status-pill status-listed">Listed</span></td>
          <td><button class="dismiss-btn" data-id="${row.id}">Remove</button></td>
        </tr>
      `
        )
        .join("")}
    </table>
  `;

  container.querySelectorAll(".dismiss-btn").forEach((btn) => {
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
// ACTIVE BIDS (your bids as buyer)
// ============================================================

async function loadActiveBids(shortName) {
  const container = document.getElementById("activeBidsContainer");
  container.innerHTML = "Loading…";

  const { data: bids } = await supabase
    .from("Player_Transfer_Bids")
    .select("*")
    .eq("bidder_club_id", shortName)
    .eq("status", "active")
    .order("bid_time", { ascending: false });

  if (!bids || bids.length === 0) {
    container.innerHTML = "<i>No active bids.</i>";
    return;
  }

  // Separate listing bids vs direct bids
  const listingBids = bids.filter((b) => b.listing_id !== null);
  const directBids = bids.filter((b) => b.listing_id === null && b.is_direct);

  // Fetch listings for listing bids
  let listingMap = new Map();
  let playersFromListings = new Map();
  if (listingBids.length > 0) {
    const listingIds = listingBids.map((b) => b.listing_id);
    const { data: listings } = await supabase
      .from("Player_Transfer_Listings")
      .select("*")
      .in("id", listingIds);

    listings?.forEach((l) => listingMap.set(l.id, l));

    const playerIds = listings.map((l) => l.player_id);
    playersFromListings = await fetchPlayersMap(playerIds);
  }

  // Fetch players for direct bids (by direct_bid_id = Konami_ID)
  let directPlayers = new Map();
  if (directBids.length > 0) {
    const directIds = directBids.map((b) => b.direct_bid_id);
    directPlayers = await fetchPlayersMap(directIds);
  }

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>Bid</th>
        <th>Type</th>
        <th>Time</th>
        <th></th>
      </tr>
      ${bids
        .map((row) => {
          let playerName = "Unknown";
          let typeLabel = "Listing Bid";

          if (row.listing_id !== null) {
            const listing = listingMap.get(row.listing_id);
            const player = playersFromListings.get(listing?.player_id);
            playerName = player?.Name || "Unknown";
          } else if (row.is_direct && row.direct_bid_id) {
            const player = directPlayers.get(row.direct_bid_id);
            playerName = player?.Name || "Unknown";
            typeLabel = "Direct Bid";
          }

          return `
          <tr>
            <td>${playerName}</td>
            <td>₿ ${Number(row.bid_amount).toLocaleString("en-GB")}</td>
            <td>${typeLabel}</td>
            <td>${new Date(row.bid_time).toLocaleString()}</td>
            <td><button class="dismiss-bid-btn" data-id="${row.bid_id}">Cancel</button></td>
          </tr>
        `;
        })
        .join("")}
    </table>
  `;

  container.querySelectorAll(".dismiss-bid-btn").forEach((btn) => {
    btn.addEventListener("click", () => removeBid(btn.dataset.id, shortName));
  });
}

async function removeBid(bidId, shortName) {
  await supabase
    .from("Player_Transfer_Bids")
    .update({ status: "cancelled" })
    .eq("bid_id", bidId);

  loadActiveBids(shortName);
}

// ============================================================
// DIRECT BID ACCEPT / REJECT HELPERS
// ============================================================

async function acceptDirectBid(bid, shortName) {
  const now = new Date();
  const endTime = computeListingEndTime();

  // 1) Create new listing
  const { data: listingInsert, error: listingError } = await supabase
    .from("Player_Transfer_Listings")
    .insert({
      player_id: bid.direct_bid_id, // Konami_ID
      seller_club_id: shortName,
      reserve_price: bid.bid_amount,
      status: "Active",
      listing_type: "direct",
      created_at: now.toISOString(),
      end_time: endTime.toISOString(),
    })
    .select()
    .single();

  if (listingError) {
    console.error("Error creating listing from direct bid:", listingError);
    return;
  }

  const newListingId = listingInsert.id;

  // 2) Insert opening bid
  await supabase.from("Player_Transfer_Bids").insert({
    listing_id: newListingId,
    direct_bid_id: null,
    bidder_club_id: bid.bidder_club_id,
    seller_club_id: shortName,
    bid_amount: bid.bid_amount,
    bid_time: now.toISOString(),
    is_direct: false,
    is_opening_bid: true,
    status: "opening",
  });

  // 3) Mark original direct bid as accepted
  await supabase
    .from("Player_Transfer_Bids")
    .update({ status: "accepted" })
    .eq("bid_id", bid.bid_id);

  // Refresh panels
  loadSellerReview(shortName);
  loadActiveListings(shortName);
  loadActiveBids(shortName);
}

async function rejectDirectBid(bidId, shortName) {
  await supabase
    .from("Player_Transfer_Bids")
    .update({ status: "rejected" })
    .eq("bid_id", bidId);

  loadSellerReview(shortName);
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
    .eq("status", "active")
    .order("bid_time", { ascending: false });

  if (!bids || bids.length === 0) {
    container.innerHTML = "<i>No bids to review.</i>";
    return;
  }

  // Separate listing bids vs direct bids
  const listingBids = bids.filter((b) => b.listing_id !== null);
  const directBids = bids.filter((b) => b.listing_id === null && b.is_direct);

  // Fetch listings for listing bids
  let listingMap = new Map();
  let playersFromListings = new Map();
  if (listingBids.length > 0) {
    const listingIds = listingBids.map((b) => b.listing_id);
    const { data: listings } = await supabase
      .from("Player_Transfer_Listings")
      .select("*")
      .in("id", listingIds);

    listings?.forEach((l) => listingMap.set(l.id, l));

    const playerIds = listings.map((l) => l.player_id);
    playersFromListings = await fetchPlayersMap(playerIds);
  }

  // Fetch players for direct bids (by direct_bid_id = Konami_ID)
  let directPlayers = new Map();
  if (directBids.length > 0) {
    const directIds = directBids.map((b) => b.direct_bid_id);
    directPlayers = await fetchPlayersMap(directIds);
  }

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>Bidder</th>
        <th>Amount</th>
        <th>Type</th>
        <th>Time</th>
        <th></th>
      </tr>
      ${bids
        .map((row) => {
          let playerName = "Unknown";
          let typeLabel = "Listing Bid";

          if (row.listing_id !== null) {
            const listing = listingMap.get(row.listing_id);
            const player = playersFromListings.get(listing?.player_id);
            playerName = player?.Name || "Unknown";
          } else if (row.is_direct && row.direct_bid_id) {
            const player = directPlayers.get(row.direct_bid_id);
            playerName = player?.Name || "Unknown";
            typeLabel = "Direct Bid";
          }

          const isDirect = row.is_direct && row.listing_id === null;

          return `
          <tr>
            <td>${playerName}</td>
            <td>${row.bidder_club_id}</td>
            <td>₿ ${Number(row.bid_amount).toLocaleString("en-GB")}</td>
            <td>${typeLabel}</td>
            <td>${new Date(row.bid_time).toLocaleString()}</td>
            <td>
              ${
                isDirect
                  ? `
                <button class="accept-direct-btn" data-id="${row.bid_id}">Accept</button>
                <button class="reject-direct-btn" data-id="${row.bid_id}">Reject</button>
              `
                  : `
                <button class="view-listing-btn" data-listing-id="${row.listing_id}">View Listing</button>
              `
              }
            </td>
          </tr>
        `;
        })
        .join("")}
    </table>
  `;

  // Wire up buttons
  container.querySelectorAll(".accept-direct-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const bidId = btn.dataset.id;
      const bid = bids.find((b) => String(b.bid_id) === String(bidId));
      if (bid) acceptDirectBid(bid, shortName);
    });
  });

  container.querySelectorAll(".reject-direct-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const bidId = btn.dataset.id;
      rejectDirectBid(bidId, shortName);
    });
  });

  container.querySelectorAll(".view-listing-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const listingId = btn.dataset.listingId;
      if (listingId) {
        window.location.href = `listing.html?id=${listingId}`;
      }
    });
  });
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

  const playerIds = listings.map((l) => l.player_id);
  const players = await fetchPlayersMap(playerIds);

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>Final Price</th>
        <th>Ended</th>
      </tr>
      ${listings
        .map(
          (row) => `
        <tr>
          <td>${players.get(row.player_id)?.Name || "Unknown"}</td>
          <td>₿ ${Number(row.final_price || 0).toLocaleString("en-GB")}</td>
          <td>${new Date(row.end_time).toLocaleString()}</td>
        </tr>
      `
        )
        .join("")}
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

  const playerIds = transfers.map((t) => t.player_id);
  const players = await fetchPlayersMap(playerIds);

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>From</th>
        <th>Price</th>
        <th>Date</th>
      </tr>
      ${transfers
        .map(
          (row) => `
        <tr>
          <td>${players.get(row.player_id)?.Name || "Unknown"}</td>
          <td>${row.seller_club_id || "FREE AGENT"}</td>
          <td>₿ ${Number(row.fee).toLocaleString("en-GB")}</td>
          <td>${new Date(row.transfer_time).toLocaleString()}</td>
        </tr>
      `
        )
        .join("")}
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

  const playerIds = transfers.map((t) => t.player_id);
  const players = await fetchPlayersMap(playerIds);

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>To</th>
        <th>Price</th>
        <th>Date</th>
      </tr>
      ${transfers
        .map(
          (row) => `
        <tr>
          <td>${players.get(row.player_id)?.Name || "Unknown"}</td>
          <td>${row.buyer_club_id}</td>
          <td>₿ ${Number(row.fee).toLocaleString("en-GB")}</td>
          <td>${new Date(row.transfer_time).toLocaleString()}</td>
        </tr>
      `
        )
        .join("")}
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
      created_at: new Date().toISOString(),
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
