// ============================================================
// TRANSFER CENTRE — Updated JS
// - Normal listings: 24h + next 19:00 UK, Extend/Remove after cutoff if no bids
// - Direct bids: Accept -> listing + opening bid, Reject -> mark rejected
// - Seller Review: direct bids only
// - Active Bids: read-only (no cancel)
// ============================================================

import { supabase } from "./supabase_client.js";
import { initGlobal, computeStandardListingEndTime, loadGlobalSettings } from "./global.js";
import { getUKNow, isDraftAuctionEnded } from "./draft_engine.js";
import { loadClubsMap, fullClubName, displayClubName } from "./clubs_lookup.js";
import { getBidPlayerId, isPendingContractedDirectOffer } from "./direct_offers.js";
import {
  loadCurrentGpslSeasonLabel,
  playerBlockedSameSeasonTransfer,
  SAME_SEASON_TRANSFER_MESSAGE,
} from "./player_season_transfer.js";
import {
  loadDraftFavouriteIds,
  toggleDraftFavourite,
  favouriteStarChar,
  favouriteButtonLabel,
  isDraftFavouritesAvailable,
  draftFavouritesSetupHint,
} from "./draft_favourites.js";

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

  loadDraftFavouritesSection(shortName);
  loadActiveListings(shortName);
  loadActiveBids(shortName);
  loadSellerReview(shortName);
  loadClosedListings(shortName);
  loadSeasonSignings(shortName);
  loadSeasonSales(shortName);

  setupListPlayerModal(shortName);

  window.__gpslCurrentSeasonLabel = await loadCurrentGpslSeasonLabel(supabase);
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
// SAVED DRAFT AUCTIONS (favourites)
// ============================================================

async function loadDraftFavouritesSection(shortName) {
  const container = document.getElementById("draftFavouritesContainer");
  if (!container) return;

  container.innerHTML = "Loading…";

  const favouriteIds = await loadDraftFavouriteIds(supabase, shortName);

  if (!isDraftFavouritesAvailable()) {
    container.innerHTML = `<i style="color:#c96;">${draftFavouritesSetupHint()}</i>`;
    return;
  }

  if (favouriteIds.size === 0) {
    container.innerHTML =
      "<i>No saved draft auctions. Open <a href=\"draftauction.html\" class=\"gpsl-link\">Draft Auction</a> and click ☆ on a player.</i>";
    return;
  }

  const playerIdList = [...favouriteIds];
  const players = await fetchPlayersMap(playerIdList);
  const numericIds = playerIdList
    .map((id) => Number(id))
    .filter((n) => Number.isFinite(n));

  const settings = await loadGlobalSettings();
  const draftStart = settings.draftStart;
  const draftEnabled = settings.draftEnabled;
  const nowUK = getUKNow();
  const auctionEnded =
    !draftEnabled || !draftStart || isDraftAuctionEnded(nowUK, draftStart);

  const listingByPlayer = new Map();
  if (numericIds.length > 0) {
    const { data: listings } = await supabase
      .from("Player_Transfer_Listings")
      .select("id, player_id, status")
      .eq("listing_type", "draft")
      .eq("status", "Active")
      .in("player_id", numericIds);

    for (const row of listings || []) {
      listingByPlayer.set(String(row.player_id), row);
    }
  }

  const bidsByPlayer = new Map();
  if (numericIds.length > 0) {
    const { data: bids } = await supabase
      .from("Player_Transfer_Bids")
      .select("direct_bid_id, bidder_club_id, bid_amount")
      .in("direct_bid_id", numericIds)
      .eq("is_direct", true);

    for (const b of bids || []) {
      const key = String(b.direct_bid_id);
      if (!bidsByPlayer.has(key)) bidsByPlayer.set(key, []);
      bidsByPlayer.get(key).push(b);
    }
  }

  const leadingClubShorts = new Set();
  for (const bids of bidsByPlayer.values()) {
    for (const b of bids) leadingClubShorts.add(b.bidder_club_id);
  }

  let clubNameMap = new Map();
  if (leadingClubShorts.size > 0) {
    const { data: clubs } = await supabase
      .from("Clubs")
      .select("ShortName, Club")
      .in("ShortName", [...leadingClubShorts]);
    clubNameMap = new Map((clubs || []).map((c) => [c.ShortName, c.Club]));
  }

  const rowsHtml = playerIdList
    .map((pid) => {
      const player = playerFromMap(players, pid);
      const name = player?.Name || `Player ${pid}`;
      const listing = listingByPlayer.get(pid);
      const playerBids = bidsByPlayer.get(pid) || [];

      let highestText = "None";
      if (playerBids.length) {
        const highest = playerBids.reduce(
          (max, b) => (b.bid_amount > max.bid_amount ? b : max),
          playerBids[0]
        );
        const clubLabel =
          clubNameMap.get(highest.bidder_club_id) || highest.bidder_club_id;
        highestText = `₿ ${Number(highest.bid_amount).toLocaleString("en-GB")} (${clubLabel})`;
      }

      let statusText = "Not in active draft auction";
      let actionHtml = `<a href="draftauction_player.html?player=${encodeURIComponent(pid)}" class="gpsl-link">View</a>`;
      if (listing) {
        statusText = auctionEnded ? "Auction ended" : "Active";
        if (!auctionEnded) {
          actionHtml = `<a href="draftauction_player.html?player=${encodeURIComponent(pid)}" class="gpsl-link">Bid</a>`;
        }
      } else if (!draftEnabled) {
        statusText = "Draft window closed";
      }

      return `
        <tr data-player-id="${pid}">
          <td>
            <button type="button" class="draft-fav-remove fav-on" data-player-id="${pid}" title="${favouriteButtonLabel(true)}" aria-label="${favouriteButtonLabel(true)}">${favouriteStarChar(true)}</button>
          </td>
          <td>${name}</td>
          <td>${highestText}</td>
          <td>${statusText}</td>
          <td>${actionHtml}</td>
        </tr>
      `;
    })
    .join("");

  container.innerHTML = `
    <table class="gpsl-table">
      <tr>
        <th>★</th>
        <th>Player</th>
        <th>Highest bid</th>
        <th>Status</th>
        <th></th>
      </tr>
      ${rowsHtml}
    </table>
  `;

  container.querySelectorAll(".draft-fav-remove").forEach((btn) => {
    btn.addEventListener("click", async () => {
      try {
        await toggleDraftFavourite(supabase, shortName, btn.dataset.playerId);
        await loadDraftFavouritesSection(shortName);
      } catch (err) {
        console.error(err);
        alert(err.message || "Could not remove saved draft auction.");
      }
    });
  });
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

  const endTime = computeStandardListingEndTime();

  const { data: rpcData, error: rpcError } = await supabase.rpc(
    "accept_direct_offer",
    {
      p_bid_id: bid.bid_id,
      p_end_time: endTime.toISOString(),
    }
  );

  if (rpcError) {
    const msg = String(rpcError.message || "");
    console.error("accept_direct_offer RPC failed:", rpcError);

    if (
      msg.includes("accept_direct_offer") &&
      (msg.includes("Could not find") || msg.includes("schema cache"))
    ) {
      alert(
        "Server function missing. In Supabase SQL Editor, run in order:\n" +
          "1) supabase/sql/sync_listing_high_from_bid.sql\n" +
          "2) supabase/sql/accept_direct_offer.sql\n" +
          "Then try Accept again."
      );
      return;
    }

    alert(msg || "Could not accept direct offer.");
    return;
  }

  console.log("accept_direct_offer OK", rpcData);

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

  const { data: bidsRaw, error } = await supabase
    .from("Player_Transfer_Bids")
    .select("*")
    .eq("seller_club_id", shortName)
    .eq("is_direct", true)
    .is("listing_id", null)
    .order("bid_time", { ascending: false });

  if (error) {
    console.error("Seller review load error:", error);
    container.innerHTML = "<i>Could not load direct bids.</i>";
    return;
  }

  const bids = (bidsRaw || []).filter(isPendingContractedDirectOffer);

  if (!bids.length) {
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

          const locked = playerBlockedSameSeasonTransfer(
            player,
            window.__gpslCurrentSeasonLabel
          );
          const actions = locked
            ? `<span class="locked-msg" title="${SAME_SEASON_TRANSFER_MESSAGE}">Signed this season</span>
               <button class="reject-direct-btn" data-id="${row.bid_id}">Reject</button>`
            : `<button class="accept-direct-btn" data-id="${row.bid_id}">Accept</button>
               <button class="reject-direct-btn" data-id="${row.bid_id}">Reject</button>`;

          return `
          <tr>
            <td>${name}</td>
            <td>${displayClubName(row.bidder_club_id)}</td>
            <td>₿ ${Number(row.bid_amount).toLocaleString("en-GB")}</td>
            <td>${new Date(row.bid_time).toLocaleString()}</td>
            <td>${actions}</td>
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
          <td>${displayClubName(row.seller_club_id)}</td>
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
          <td>${displayClubName(row.buyer_club_id)}</td>
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
    const { data: playerRow } = await supabase
      .from("Players")
      .select("Season_Signed")
      .eq("Konami_ID", playerId)
      .maybeSingle();

    if (
      playerBlockedSameSeasonTransfer(
        playerRow,
        window.__gpslCurrentSeasonLabel
      )
    ) {
      document.getElementById("reserveError").textContent =
        SAME_SEASON_TRANSFER_MESSAGE;
      return;
    }

    const now = new Date();
    const endTime = computeStandardListingEndTime();

    const { error: listErr } = await supabase.from("Player_Transfer_Listings").insert({
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

    if (listErr) {
      const msg = String(listErr.message || "");
      document.getElementById("reserveError").textContent = msg.includes(
        "current season"
      )
        ? SAME_SEASON_TRANSFER_MESSAGE
        : msg || "Could not create listing.";
      return;
    }

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
