// ============================================================
// TRANSFER CENTRE — Updated JS
// - Normal listings: 24h + next 19:00 UK, Extend/Remove after cutoff if no bids
// - Direct bids: Accept -> listing + opening bid, Reject -> mark rejected
// - Seller Review: direct bids only
// - Active Bids: read-only (no cancel)
// ============================================================

import { supabase } from "./supabase_client.js";
import { initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

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
    .select("*")
    .eq("owner_id", user.id)
    .single();

  await loadClubsMap();

  const shortName = club.ShortName;
  const fullName = fullClubName(shortName) || club.Club || shortName;

  document.getElementById("pageTitle").textContent = `${fullName} — Transfer Centre`;
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${shortName}.png`;

  loadActiveListings(shortName);
  loadActiveBids(shortName);
  loadSellerReview(shortName);
  loadClosedListings(shortName);
  loadSeasonSignings(shortName);
  loadSeasonSales(shortName);

  setupListPlayerModal(shortName);
});

// ============================================================
// HELPERS
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

// Compute end time = max(now+24h, next 19:00 UK)
function computeListingEndTime() {
  const now = new Date();
  const minEnd = new Date(now.getTime() + 24 * 60 * 60 * 1000); // now + 24h

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

  const parts = ukString.replace(",", "").split(/[/ :]/);
  const [day, month, year, hour, minute, second] = parts.map((p) =>
    parseInt(p, 10)
  );

  const ukLocal = new Date(year, month - 1, day, hour, minute, second, 0);

  let next19 = new Date(ukLocal);
  next19.setHours(19, 0, 0, 0);
  if (ukLocal.getTime() > next19.getTime()) {
    next19.setDate(next19.getDate() + 1);
  }

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

  const listingIds = listings.map((l) => l.id);
  let bidsCountMap = new Map();

  if (listingIds.length > 0) {
    const { data: bids } = await supabase
      .from("Player_Transfer_Bids")
      .select("listing_id")
      .in("listing_id", listingIds);

    bids?.forEach((b) => {
      if (!b.listing_id) return;
      const current = bidsCountMap.get(b.listing_id) || 0;
      bidsCountMap.set(b.listing_id, current + 1);
    });
  }

  const now = new Date();

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>Reserve</th>
        <th>Ends</th>
        <th>Actions</th>
      </tr>
      ${listings
        .map((row) => {
          const player = players.get(row.player_id);
          const name = player?.Name || "Unknown";
          const reserve = Number(row.reserve_price).toLocaleString("en-GB");
          const endTime = row.end_time ? new Date(row.end_time) : null;
          const bidsCount = bidsCountMap.get(row.id) || 0;

          let actionsHtml = "";

          // Only after cutoff AND no bids: show Extend / Remove
          if (endTime && now > endTime && bidsCount === 0) {
            actionsHtml = `
              <button class="extend-listing-btn" data-id="${row.id}">Extend</button>
              <button class="expire-listing-btn" data-id="${row.id}" data-player-id="${row.player_id}">Remove</button>
            `;
          }

          return `
            <tr>
              <td>${name}</td>
              <td>₿ ${reserve}</td>
              <td>${endTime ? endTime.toLocaleString() : "-"}</td>
              <td>${actionsHtml}</td>
            </tr>
          `;
        })
        .join("")}
    </table>
  `;

  container.querySelectorAll(".extend-listing-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      extendListing(btn.dataset.id, shortName);
    });
  });

  container.querySelectorAll(".expire-listing-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      expireListing(btn.dataset.id, btn.dataset.playerId, shortName);
    });
  });
}

async function extendListing(listingId, shortName) {
  const newEnd = computeListingEndTime();

  await supabase
    .from("Player_Transfer_Listings")
    .update({
      start_time: new Date().toISOString(),
      end_time: newEnd.toISOString(),
    })
    .eq("id", listingId);

  loadActiveListings(shortName);
}

async function expireListing(listingId, playerId, shortName) {
  await supabase
    .from("Player_Transfer_Listings")
    .update({ status: "Closed", transfer_completed: false })
    .eq("id", listingId);

  // If you track a "listed" flag on Players, update it here, e.g.:
  // await supabase
  //   .from("Players")
  //   .update({ listed: false })
  //   .eq("Konami_ID", playerId);

  loadActiveListings(shortName);
}

// ============================================================
// ACTIVE BIDS (your bids as buyer) — READ ONLY
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

  const listingBids = bids.filter((b) => b.listing_id !== null);
  const directBids = bids.filter((b) => b.listing_id === null && b.is_direct);

  let listingMap = new Map();
  let playersFromListings = new Map();

  const listingIds = listingBids
    .map((b) => b.listing_id)
    .filter((id) => id !== null);

  if (listingIds.length > 0) {
    const { data: listings } = await supabase
      .from("Player_Transfer_Listings")
      .select("*")
      .in("id", listingIds);

    listings?.forEach((l) => listingMap.set(l.id, l));

    const playerIds = listings.map((l) => l.player_id);
    playersFromListings = await fetchPlayersMap(playerIds);
  }

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
          </tr>
        `;
        })
        .join("")}
    </table>
  `;
}

// ============================================================
// DIRECT BID ACCEPT / REJECT
// ============================================================

async function acceptDirectBid(bid, shortName) {
  const now = new Date();
  const endTime = computeListingEndTime();

  const { data: listingInsert, error: listingError } = await supabase
    .from("Player_Transfer_Listings")
    .insert({
      player_id: bid.direct_bid_id,
      seller_club_id: shortName,
      reserve_price: bid.bid_amount,
      status: "Active",
      listing_type: "direct",
      created_at: now.toISOString(),
      start_time: now.toISOString(),
      end_time: endTime.toISOString(),
    })
    .select()
    .single();

  if (listingError) {
    console.error("Error creating listing from direct bid:", listingError);
    return;
  }

  const newListingId = listingInsert.id;

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

  await supabase
    .from("Player_Transfer_Bids")
    .update({ status: "accepted" })
    .eq("bid_id", bid.bid_id);

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
// SELLER REVIEW (DIRECT BIDS ONLY)
// ============================================================

async function loadSellerReview(shortName) {
  const container = document.getElementById("sellerReviewContainer");
  container.innerHTML = "Loading…";

  const { data: bids } = await supabase
    .from("Player_Transfer_Bids")
    .select("*")
    .eq("seller_club_id", shortName)
    .eq("status", "active")
    .eq("is_direct", true)
    .order("bid_time", { ascending: false });

  if (!bids || bids.length === 0) {
    container.innerHTML = "<i>No direct bids to review.</i>";
    return;
  }

  const directIds = bids.map((b) => b.direct_bid_id);
  const directPlayers = await fetchPlayersMap(directIds);

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>Bidder</th>
        <th>Amount</th>
        <th>Time</th>
        <th>Actions</th>
      </tr>
      ${bids
        .map((row) => {
          const player = directPlayers.get(row.direct_bid_id);
          const name = player?.Name || "Unknown";

          return `
          <tr>
            <td>${name}</td>
            <td>${row.bidder_club_id}</td>
            <td>₿ ${Number(row.bid_amount).toLocaleString("en-GB")}</td>
            <td>${new Date(row.bid_time).toLocaleString()}</td>
            <td>
              <button class="accept-direct-btn" data-id="${row.bid_id}">Accept</button>
              <button class="reject-direct-btn" data-id="${row.bid_id}">Reject</button>
            </td>
          </tr>
        `;
        })
        .join("")}
    </table>
  `;

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
// SEASON SIGNINGS
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
// SEASON SALES
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
    const now = new Date();
    const endTime = computeListingEndTime();

    await supabase.from("Player_Transfer_Listings").insert({
      player_id: playerId,
      seller_club_id: shortName,
      reserve_price: reserve,
      status: "Active",
      created_at: now.toISOString(),
      start_time: now.toISOString(),
      end_time: endTime.toISOString(),
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
