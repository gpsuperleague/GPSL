// ============================================================
// TRANSFER CENTRE — Updated JS
// - Normal listings: 24h + next 19:00 UK, Extend/Remove after cutoff if no bids
// - Direct bids: Accept -> listing + opening bid, Reject -> mark rejected
// - Seller Review: direct bids only
// - Active Bids: read-only (no cancel)
// ============================================================

import { supabase } from "./supabase_client.js";
import { initGlobal, computeStandardListingEndTime } from "./global.js";
import { loadClubsMap, fullClubName, buyerClubLabel } from "./clubs_lookup.js";
import { getBidPlayerId } from "./direct_offers.js";

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

  const numericIds = [
    ...new Set(
      playerIds
        .filter((id) => id != null && String(id).trim() !== "")
        .map((id) => Number(id))
        .filter((n) => Number.isFinite(n))
    ),
  ];

  if (numericIds.length === 0) return new Map();

  const { data, error } = await supabase
    .from("Players")
    .select("*")
    .in("Konami_ID", numericIds);

  if (error) {
    console.error("fetchPlayersMap error:", error);
    return new Map();
  }

  const map = new Map();
  for (const p of data || []) {
    map.set(String(p.Konami_ID), p);
  }
  return map;
}

function playerFromMap(map, id) {
  if (id == null || String(id).trim() === "") return null;
  return map.get(String(id)) ?? null;
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
          const player = playerFromMap(players, row.player_id);
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
  const newEnd = computeStandardListingEndTime();

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
    const directIds = directBids.map((b) => getBidPlayerId(b)).filter(Boolean);
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
            const player = playerFromMap(
              playersFromListings,
              listing?.player_id
            );
            playerName = player?.Name || "Unknown";
          } else if (row.is_direct && getBidPlayerId(row)) {
            const player = playerFromMap(directPlayers, getBidPlayerId(row));
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
  const playerId = getBidPlayerId(bid);
  if (!playerId) {
    console.error("Cannot accept direct bid without player_id", bid);
    alert("This offer is missing a player id. Reject it and ask the buyer to submit again.");
    return;
  }

  const now = new Date();
  const endTime = computeStandardListingEndTime();

  const { data: listingInsert, error: listingError } = await supabase
    .from("Player_Transfer_Listings")
    .insert({
      player_id: playerId,
      seller_club_id: shortName,
      reserve_price: bid.bid_amount,
      status: "Active",
      listing_type: "direct",
      created_at: now.toISOString(),
      start_time: now.toISOString(),
      end_time: endTime.toISOString(),
      initial_end_time: endTime.toISOString(),
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
    player_id: playerId,
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
    .is("listing_id", null)
    .order("bid_time", { ascending: false });

  if (!bids || bids.length === 0) {
    container.innerHTML = "<i>No direct bids to review.</i>";
    return;
  }

  const directIds = bids.map((b) => getBidPlayerId(b)).filter(Boolean);
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
          const pid = getBidPlayerId(row);
          const player = playerFromMap(directPlayers, pid);
          const name = player?.Name
            || (pid ? "Unknown" : "Unknown (missing player id on bid)");

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
          <td>${playerFromMap(players, row.player_id)?.Name || "Unknown"}</td>
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
          <td>${playerFromMap(players, row.player_id)?.Name || "Unknown"}</td>
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
          <td>${playerFromMap(players, row.player_id)?.Name || "Unknown"}</td>
          <td>${buyerClubLabel(row.buyer_club_id)}</td>
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
    const endTime = computeStandardListingEndTime();

    await supabase.from("Player_Transfer_Listings").insert({
      player_id: playerId,
      seller_club_id: shortName,
      reserve_price: reserve,
      status: "Active",
      listing_type: "standard",
      created_at: now.toISOString(),
      start_time: now.toISOString(),
      end_time: endTime.toISOString(),
      initial_end_time: endTime.toISOString(),
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
