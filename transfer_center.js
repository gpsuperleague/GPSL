// ============================================================
// TRANSFER CENTRE — Updated JS
// - Normal listings: 24h + next 19:00 UK, Extend/Remove after cutoff if no bids
// - Direct bids: Accept -> listing + opening bid, Reject -> mark rejected
// - Seller Review: below-reserve auctions + direct bids
// - Active Bids: live auctions only; Awaiting seller: review + direct offers
// ============================================================

import { supabase } from "./supabase_client.js";
import { formatMoney } from "./competition.js";
import { initGlobal, computeStandardListingEndTime, loadGlobalSettings } from "./global.js";
import { getUKNow, isDraftAuctionEnded } from "./draft_engine.js";
import {
  loadClubsMap,
  fullClubName,
  displayClubName,
  clubWithOwnerHtml,
  formatSeasonSaleDestination,
  formatSeasonSaleType,
} from "./clubs_lookup.js";
import {
  getBidPlayerId,
  isPendingContractedDirectOffer,
  isBuyerBidOnLiveAuction,
  isBuyerBidAwaitingSellerReview,
} from "./direct_offers.js";
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
import {
  loadScoutingTargets,
  SCOUTING_TIER_LABELS,
  isScoutingAvailable,
  scoutingSetupHint,
} from "./scouting_targets.js";
import { playerNameLinkHtml } from "./player_links.js";
import { loadCurrentSeasonStart } from "./finance_transfers.js";
import { formatTimeRemainingHtml, getCountdownParts } from "./countdown_display.js";

/** Current competition season start — scopes Season Signings / Sales / Closed Listings. */
let currentSeasonStartedAt = null;
let sellerDeadlineTicker = null;

function playerLinkCell(playerId, player, fallbackName) {
  const pid = String(playerId ?? player?.Konami_ID ?? "").trim();
  const name =
    player?.Name || fallbackName || (pid ? `Player ${pid}` : "Unknown");
  if (!pid) return name;
  return playerNameLinkHtml(pid, name);
}

/** Live countdown + cutoff wall times for seller review windows. */
function sellerDeadlineInnerHtml(iso, emptyLabel = "No timed cutoff") {
  if (!iso) {
    return `<span class="tc-deadline-empty">${emptyLabel}</span>`;
  }
  const end = new Date(iso);
  if (Number.isNaN(end.getTime())) {
    return `<span class="tc-deadline-empty">${emptyLabel}</span>`;
  }
  const parts = getCountdownParts(end);
  const msLeft = end.getTime() - Date.now();
  const urgent = !parts.expired && msLeft > 0 && msLeft < 60 * 60 * 1000;
  const cls = [
    "tc-deadline-live",
    parts.expired ? "tc-deadline-expired" : "",
    urgent ? "tc-deadline-urgent" : "",
  ]
    .filter(Boolean)
    .join(" ");
  return `<span class="${cls}" data-deadline="${end.toISOString()}">${formatTimeRemainingHtml(
    end.toISOString()
  )}</span>`;
}

function tickSellerDeadlineCells() {
  document.querySelectorAll(".tc-deadline-live[data-deadline]").forEach((el) => {
    const iso = el.getAttribute("data-deadline");
    if (!iso) return;
    const end = new Date(iso);
    if (Number.isNaN(end.getTime())) return;
    const parts = getCountdownParts(end);
    const msLeft = end.getTime() - Date.now();
    el.classList.toggle("tc-deadline-expired", parts.expired);
    el.classList.toggle(
      "tc-deadline-urgent",
      !parts.expired && msLeft > 0 && msLeft < 60 * 60 * 1000
    );
    el.innerHTML = formatTimeRemainingHtml(iso);
  });
}

function startSellerDeadlineTicker() {
  if (sellerDeadlineTicker) return;
  tickSellerDeadlineCells();
  sellerDeadlineTicker = setInterval(tickSellerDeadlineCells, 1000);
}

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

  currentSeasonStartedAt = await loadCurrentSeasonStart(supabase);

  loadGpdbScoutingSummary(shortName);
  loadDraftFavouritesSection(shortName);
  loadActiveListings(shortName);
  loadActiveBids(shortName);
  loadAwaitingSellerBids(shortName);
  loadSellerReview(shortName);
  loadClosedListings(shortName);
  loadSeasonSignings(shortName);
  loadSeasonSales(shortName);

  setupListPlayerModal(shortName);
  startSellerDeadlineTicker();

  window.__gpslCurrentSeasonLabel = await loadCurrentGpslSeasonLabel(supabase);

  if (window.location.hash === "#scouting-targets") {
    document.getElementById("scouting-targets")?.scrollIntoView({ behavior: "smooth" });
  }
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
// GPDB SCOUTING SUMMARY
// ============================================================

async function loadGpdbScoutingSummary(shortName) {
  const el = document.getElementById("gpdbScoutingSummary");
  if (!el) return;

  if (!isScoutingAvailable()) {
    el.innerHTML = `<i style="color:#c96;">${scoutingSetupHint()}</i>`;
    return;
  }

  try {
    const rows = await loadScoutingTargets(supabase, shortName);
    if (!rows.length) {
      el.innerHTML =
        '<i style="color:#888;">No GPDB scouting targets yet — use ☆ in GPDB.</i>';
      return;
    }

    const counts = [1, 2, 3, 4].map((tier) => ({
      tier,
      n: rows.filter((r) => Number(r.tier) === tier).length,
    }));

    el.innerHTML = `
      <ul style="margin:0;padding-left:18px;color:#ccc;font-size:14px;line-height:1.6;">
        ${counts
          .map(
            (c) =>
              `<li><b>${SCOUTING_TIER_LABELS[c.tier]}</b>: ${c.n} player${c.n === 1 ? "" : "s"}</li>`
          )
          .join("")}
      </ul>`;
  } catch (err) {
    el.innerHTML = `<i style="color:#c96;">${err?.message || "Could not load scouting targets."}</i>`;
  }
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
      let actionHtml = `<a href="draftauction_player.html?player=${encodeURIComponent(pid)}" class="gpsl-link tc-action-link">View</a>`;
      if (listing) {
        statusText = auctionEnded ? "Auction ended" : "Active";
        if (!auctionEnded) {
          actionHtml = `<a href="draftauction_player.html?player=${encodeURIComponent(pid)}" class="gpsl-link tc-action-link">Bid</a>`;
        }
      } else if (!draftEnabled) {
        statusText = "Draft window closed";
      }

      return `
        <tr data-player-id="${pid}">
          <td>
            <button type="button" class="draft-fav-remove fav-on" data-player-id="${pid}" title="${favouriteButtonLabel(true)}" aria-label="${favouriteButtonLabel(true)}">${favouriteStarChar(true)}</button>
          </td>
          <td>${playerLinkCell(pid, player, name)}</td>
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
          const forced = row.perpetual_renew === true;

          let actionsHtml = "";
          const forcedNote = forced
            ? `<div style="font-size:11px;color:#e8a87c;margin-top:2px;">Underperformance — auto-relists at MV</div>`
            : "";

          // Only after cutoff AND no bids: show Extend / Remove (not for forced listings)
          if (!forced && endTime && now > endTime && bidsCount === 0) {
            actionsHtml = `
              <button class="extend-listing-btn" data-id="${row.id}">Extend</button>
              <button class="expire-listing-btn" data-id="${row.id}" data-player-id="${row.player_id}">Remove</button>
            `;
          }

          return `
            <tr>
              <td>${playerLinkCell(row.player_id, player, name)}${forcedNote}</td>
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

  const newEndIso = newEnd.toISOString();
  await supabase
    .from("Player_Transfer_Listings")
    .update({
      start_time: new Date().toISOString(),
      end_time: newEndIso,
      initial_end_time: newEndIso,
    })
    .eq("id", listingId);

  loadActiveListings(shortName);
}

async function expireListing(listingId, playerId, shortName) {
  const { data: row } = await supabase
    .from("Player_Transfer_Listings")
    .select("perpetual_renew")
    .eq("id", listingId)
    .maybeSingle();

  if (row?.perpetual_renew) {
    alert(
      "This listing was created after club underperformance. It relists automatically at market value and cannot be removed manually."
    );
    return;
  }

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

async function loadBuyerBidSections(shortName) {
  const { data: bidsRaw } = await supabase
    .from("Player_Transfer_Bids")
    .select("*")
    .eq("bidder_club_id", shortName)
    .eq("status", "active")
    .order("bid_time", { ascending: false });

  const now = getUKNow();
  const settings = await loadGlobalSettings();
  const draftEnded = isDraftAuctionEnded(now, settings.draftStart);
  const filterOpts = { now, draftAuctionEnded: draftEnded };

  const listingIds = [
    ...new Set(
      (bidsRaw || [])
        .map((b) => b.listing_id)
        .filter((id) => id != null)
    ),
  ];

  const listingMap = new Map();
  if (listingIds.length > 0) {
    const { data: listings } = await supabase
      .from("Player_Transfer_Listings")
      .select("*")
      .in("id", listingIds);

    listings?.forEach((l) => listingMap.set(l.id, l));
  }

  const liveBids = [];
  const awaitingBids = [];

  for (const row of bidsRaw || []) {
    const listing = listingMap.get(row.listing_id);
    if (isBuyerBidOnLiveAuction(row, listing, shortName, filterOpts)) {
      liveBids.push(row);
    } else if (
      isBuyerBidAwaitingSellerReview(row, listing, shortName, filterOpts) ||
      isPendingContractedDirectOffer(row)
    ) {
      awaitingBids.push(row);
    }
  }

  return { liveBids, awaitingBids, listingMap };
}

async function renderBuyerBidTable(bids, listingMap, emptyText, options = {}) {
  const showSeller = options.showSeller === true;

  if (!bids.length) {
    return `<i>${emptyText}</i>`;
  }

  const listingBids = bids.filter((b) => b.listing_id != null);
  const directBids = bids.filter(
    (b) => b.listing_id == null && isPendingContractedDirectOffer(b)
  );

  const playerIds = listingBids
    .map((b) => listingMap.get(b.listing_id)?.player_id)
    .filter((id) => id != null);
  const directIds = directBids.map((b) => getBidPlayerId(b)).filter(Boolean);

  const playersFromListings = await fetchPlayersMap(playerIds);
  const directPlayers = await fetchPlayersMap(directIds);

  return `
    <table class="gpsl-table">
      <tr>
        <th>Player</th>
        <th>Bid</th>
        ${showSeller ? "<th>Seller</th>" : ""}
        <th>Type</th>
        ${showSeller ? '<th class="countdown-col">Seller cutoff</th>' : ""}
        <th>Bid time</th>
      </tr>
      ${bids
        .map((row) => {
          let playerId = "";
          let player = null;
          let typeLabel = "Listing bid";
          let sellerShort = "";
          let deadlineIso = null;

          if (row.listing_id != null) {
            const listing = listingMap.get(row.listing_id);
            playerId = listing?.player_id;
            player = playerFromMap(playersFromListings, playerId);
            sellerShort = String(listing?.seller_club_id || "").trim();
            deadlineIso = listing?.seller_review_deadline || null;
            const st = String(listing?.status || "");
            if (st === "Review" || st === "Seller Review") {
              typeLabel = "Leading — seller review";
            } else if (
              String(listing?.listing_type || "").toLowerCase() === "draft"
            ) {
              typeLabel = "Draft auction";
            } else {
              typeLabel = "Leading — auction live";
            }
          } else if (isPendingContractedDirectOffer(row)) {
            playerId = getBidPlayerId(row);
            player = playerFromMap(directPlayers, playerId);
            sellerShort = String(row.seller_club_id || "").trim();
            typeLabel = "Direct offer — awaiting seller";
            deadlineIso = null;
          }

          const sellerCell = showSeller
            ? `<td>${
                sellerShort
                  ? clubWithOwnerHtml(
                      displayClubName(sellerShort) || sellerShort,
                      sellerShort,
                      "inline"
                    )
                  : "—"
              }</td>`
            : "";

          const cutoffCell = showSeller
            ? `<td class="countdown-cell">${sellerDeadlineInnerHtml(
                deadlineIso,
                row.listing_id == null
                  ? "Open until seller decides"
                  : "24h from auction end"
              )}</td>`
            : "";

          return `
          <tr>
            <td>${playerLinkCell(playerId, player)}</td>
            <td>₿ ${Number(row.bid_amount).toLocaleString("en-GB")}</td>
            ${sellerCell}
            <td>${typeLabel}</td>
            ${cutoffCell}
            <td>${new Date(row.bid_time).toLocaleString()}</td>
          </tr>
        `;
        })
        .join("")}
    </table>
  `;
}

async function loadActiveBids(shortName) {
  const container = document.getElementById("activeBidsContainer");
  container.innerHTML = "Loading…";

  const { liveBids, listingMap } = await loadBuyerBidSections(shortName);
  container.innerHTML = await renderBuyerBidTable(
    liveBids,
    listingMap,
    "No live auction bids — only open listings where you are the high bidder appear here (same as the transfer market Active filter)."
  );
}

async function loadAwaitingSellerBids(shortName) {
  const container = document.getElementById("awaitingSellerBidsContainer");
  if (!container) return;

  container.innerHTML = "Loading…";

  const { awaitingBids, listingMap } = await loadBuyerBidSections(shortName);
  container.innerHTML = await renderBuyerBidTable(
    awaitingBids,
    listingMap,
    "Nothing awaiting the seller.",
    { showSeller: true }
  );
  tickSellerDeadlineCells();
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

async function hydrateListingHighBids(listings) {
  const rows = (listings || []).map((l) => ({ ...l }));
  const needs = rows.filter(
    (l) => l.current_highest_bid == null || !l.current_highest_bidder
  );
  if (!needs.length) return rows;

  const ids = needs.map((l) => l.id).filter((id) => id != null);
  const { data: bids } = await supabase
    .from("Player_Transfer_Bids")
    .select("listing_id, bid_amount, bidder_club_id, status")
    .in("listing_id", ids);

  const bestByListing = new Map();
  for (const b of bids || []) {
    if (String(b.status || "").toLowerCase() !== "active") continue;
    const lid = String(b.listing_id);
    const prev = bestByListing.get(lid);
    if (!prev || Number(b.bid_amount) > Number(prev.bid_amount)) {
      bestByListing.set(lid, b);
    }
  }

  return rows.map((l) => {
    if (l.current_highest_bid != null && l.current_highest_bidder) return l;
    const best = bestByListing.get(String(l.id));
    if (!best) return l;
    return {
      ...l,
      current_highest_bid: best.bid_amount,
      current_highest_bidder: best.bidder_club_id,
    };
  });
}

function sellerReviewDeadlineLabel(listing) {
  return sellerDeadlineInnerHtml(
    listing?.seller_review_deadline,
    "24h from auction end"
  );
}

function isSellerReviewExpired(listing) {
  if (!listing?.seller_review_deadline) return false;
  return new Date(listing.seller_review_deadline) <= new Date();
}

async function acceptBelowReserve(listingId, shortName) {
  const { data, error } = await supabase.rpc("club_accept_below_reserve_sale", {
    p_listing_id: Number(listingId),
  });

  if (error) {
    const msg = String(error.message || "");
    console.error("club_accept_below_reserve_sale:", error);
    if (
      msg.includes("club_accept_below_reserve_sale") &&
      (msg.includes("Could not find") || msg.includes("schema cache"))
    ) {
      alert(
        "Server function missing. Run supabase/sql/transfer_ledger_polish.sql in Supabase, then try again."
      );
      return;
    }
    alert(msg || "Could not accept sale.");
    return;
  }

  console.log("Below-reserve sale accepted", data);
  loadSellerReview(shortName);
  loadClosedListings(shortName);
  loadSeasonSales(shortName);
  loadActiveListings(shortName);
}

async function rejectBelowReserve(listingId, shortName) {
  const { error } = await supabase.rpc("club_reject_below_reserve_sale", {
    p_listing_id: Number(listingId),
  });

  if (error) {
    const msg = String(error.message || "");
    console.error("club_reject_below_reserve_sale:", error);
    if (
      msg.includes("club_reject_below_reserve_sale") &&
      (msg.includes("Could not find") || msg.includes("schema cache"))
    ) {
      alert(
        "Server function missing. Run supabase/sql/transfer_ledger_polish.sql in Supabase, then try again."
      );
      return;
    }
    alert(msg || "Could not reject sale.");
    return;
  }

  loadSellerReview(shortName);
  loadClosedListings(shortName);
  loadActiveListings(shortName);
}

// ============================================================
// SELLER REVIEW (BELOW-RESERVE + DIRECT BIDS)
// ============================================================

async function loadSellerReview(shortName) {
  const container = document.getElementById("sellerReviewContainer");
  container.innerHTML = "Loading…";

  const [listingsRes, bidsRes] = await Promise.all([
    supabase
      .from("Player_Transfer_Listings")
      .select("*")
      .eq("seller_club_id", shortName)
      .in("status", ["Review", "Seller Review"])
      .order("end_time", { ascending: false }),
    supabase
      .from("Player_Transfer_Bids")
      .select("*")
      .eq("seller_club_id", shortName)
      .eq("is_direct", true)
      .is("listing_id", null)
      .order("bid_time", { ascending: false }),
  ]);

  if (listingsRes.error) {
    console.error("Below-reserve listings error:", listingsRes.error);
  }
  if (bidsRes.error) {
    console.error("Seller review load error:", bidsRes.error);
    container.innerHTML = "<i>Could not load seller review items.</i>";
    return;
  }

  const reviewListings = await hydrateListingHighBids(listingsRes.data || []);
  const bids = (bidsRes.data || []).filter(isPendingContractedDirectOffer);

  if (!reviewListings.length && !bids.length) {
    container.innerHTML =
      "<i>Nothing to review — no below-reserve auctions or direct offers.</i>";
    return;
  }

  const playerIds = [
    ...reviewListings.map((l) => l.player_id),
    ...bids.map((b) => getBidPlayerId(b)),
  ].filter(Boolean);
  const players = await fetchPlayersMap(playerIds);

  let html = "";

  if (reviewListings.length) {
    html += `<h3 style="margin:0 0 8px 0;font-size:15px;">Below reserve (${reviewListings.length})</h3>
      <table class="gpsl-table">
        <tr>
          <th>Player</th>
          <th>Reserve</th>
          <th>Best bid</th>
          <th>Shortfall</th>
          <th>Bidder</th>
          <th class="countdown-col">Accept by</th>
          <th>Actions</th>
        </tr>
        ${reviewListings
          .map((row) => {
            const player = playerFromMap(players, row.player_id);
            const name = player?.Name || "Unknown";
            const reserve = Number(row.reserve_price) || 0;
            const bid = Number(row.current_highest_bid) || 0;
            const shortfall = Math.max(reserve - bid, 0);
            const expired = isSellerReviewExpired(row);
            const locked = playerBlockedSameSeasonTransfer(
              player,
              window.__gpslCurrentSeasonLabel
            );

            const forced = row.perpetual_renew === true;
            const forcedNote = forced
              ? `<div style="font-size:11px;color:#e8a87c;">Underperformance listing — relists if rejected</div>`
              : "";

            let actions;
            if (forced) {
              if (!row.current_highest_bidder || bid <= 0) {
                actions = `<span style="color:#aaa;">Awaiting bids</span>`;
              } else if (locked) {
                actions = `<button class="accept-below-btn" data-id="${row.id}">Accept ₿${bid.toLocaleString("en-GB")}</button>`;
              } else if (expired) {
                actions = `<button class="accept-below-btn" data-id="${row.id}">Accept ₿${bid.toLocaleString("en-GB")}</button>`;
              } else {
                actions = `<button class="accept-below-btn" data-id="${row.id}">Accept ₿${bid.toLocaleString("en-GB")}</button>`;
              }
            } else if (!row.current_highest_bidder || bid <= 0) {
              actions = `<button class="reject-below-btn" data-id="${row.id}">Close listing</button>`;
            } else if (locked) {
              actions = `<span class="locked-msg" title="${SAME_SEASON_TRANSFER_MESSAGE}">Signed this season</span>
                 <button class="reject-below-btn" data-id="${row.id}">Reject</button>`;
            } else if (expired) {
              actions = `<span style="color:#aaa;">Review window ended</span>
                 <button class="reject-below-btn" data-id="${row.id}">Reject</button>`;
            } else {
              actions = `<button class="accept-below-btn" data-id="${row.id}">Accept ₿${bid.toLocaleString("en-GB")}</button>
                 <button class="reject-below-btn" data-id="${row.id}">Reject</button>`;
            }

            return `
            <tr>
              <td>${playerLinkCell(row.player_id, player, name)}${forcedNote}</td>
              <td>${formatMoney(reserve)}</td>
              <td>${bid > 0 ? formatMoney(bid) : "—"}</td>
              <td>${shortfall > 0 ? formatMoney(shortfall) : "—"}</td>
              <td>${displayClubName(row.current_highest_bidder) || "—"}</td>
              <td class="countdown-cell">${sellerReviewDeadlineLabel(row)}</td>
              <td>${actions}</td>
            </tr>`;
          })
          .join("")}
      </table>`;
  }

  if (bids.length) {
    html += `<h3 style="margin:${reviewListings.length ? "18px" : "0"} 0 8px 0;font-size:15px;">Direct offers (${bids.length})</h3>
      <table class="gpsl-table">
        <tr>
          <th>Player</th>
          <th>Bidder</th>
          <th>Amount</th>
          <th class="countdown-col">Cutoff</th>
          <th>Time</th>
          <th>Actions</th>
        </tr>
        ${bids
          .map((row) => {
            const pid = getBidPlayerId(row);
            const player = playerFromMap(players, pid);
            const name =
              player?.Name ||
              (pid ? "Unknown" : "Unknown (missing player id on bid)");

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
              <td>${playerLinkCell(pid, player, name)}</td>
              <td>${displayClubName(row.bidder_club_id)}</td>
              <td>${formatMoney(row.bid_amount)}</td>
              <td class="countdown-cell">${sellerDeadlineInnerHtml(
                null,
                "Open until you decide"
              )}</td>
              <td>${new Date(row.bid_time).toLocaleString()}</td>
              <td>${actions}</td>
            </tr>`;
          })
          .join("")}
      </table>`;
  }

  container.innerHTML = html;

  container.querySelectorAll(".accept-below-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const listingId = btn.dataset.id;
      if (
        !confirm(
          "Accept this below-reserve bid? The player will transfer and funds will settle immediately."
        )
      ) {
        return;
      }
      acceptBelowReserve(listingId, shortName);
    });
  });

  container.querySelectorAll(".reject-below-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      rejectBelowReserve(btn.dataset.id, shortName);
    });
  });

  container.querySelectorAll(".accept-direct-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const bidId = btn.dataset.id;
      const bid = bids.find((b) => String(b.bid_id) === String(bidId));
      if (bid) acceptDirectBid(bid, shortName);
    });
  });

  container.querySelectorAll(".reject-direct-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      rejectDirectBid(btn.dataset.id, shortName);
    });
  });

  tickSellerDeadlineCells();
}

// ============================================================
// CLOSED LISTINGS
// ============================================================

async function loadClosedListings(shortName) {
  const container = document.getElementById("closedListingsContainer");
  container.innerHTML = "Loading…";

  let q = supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", shortName)
    .eq("status", "Closed")
    .order("end_time", { ascending: false });

  if (currentSeasonStartedAt) {
    q = q.gte("end_time", currentSeasonStartedAt);
  }

  const { data: listings } = await q;

  if (!listings || listings.length === 0) {
    container.innerHTML = "<i>No closed listings this season.</i>";
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
        .map((row) => {
          const player = playerFromMap(players, row.player_id);
          return `
        <tr>
          <td>${playerLinkCell(row.player_id, player)}</td>
          <td>₿ ${Number(row.final_price || 0).toLocaleString("en-GB")}</td>
          <td>${new Date(row.end_time).toLocaleString()}</td>
        </tr>
      `;
        })
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

  let q = supabase
    .from("Transfer_History")
    .select("*")
    .eq("buyer_club_id", shortName)
    .order("transfer_time", { ascending: false });

  if (currentSeasonStartedAt) {
    q = q.gte("transfer_time", currentSeasonStartedAt);
  }

  const { data: transfers } = await q;

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
        .map((row) => {
          const player = playerFromMap(players, row.player_id);
          return `
        <tr>
          <td>${playerLinkCell(row.player_id, player)}</td>
          <td>${displayClubName(row.seller_club_id)}</td>
          <td>₿ ${Number(row.fee).toLocaleString("en-GB")}</td>
          <td>${new Date(row.transfer_time).toLocaleString()}</td>
        </tr>
      `;
        })
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

  let q = supabase
    .from("Transfer_History")
    .select("*")
    .eq("seller_club_id", shortName)
    .order("transfer_time", { ascending: false });

  if (currentSeasonStartedAt) {
    q = q.gte("transfer_time", currentSeasonStartedAt);
  }

  const { data: transfers } = await q;

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
        <th>Type</th>
        <th>To / reason</th>
        <th>Price</th>
        <th>Date</th>
      </tr>
      ${transfers
        .map((row) => {
          const player = playerFromMap(players, row.player_id);
          return `
        <tr>
          <td>${playerLinkCell(row.player_id, player)}</td>
          <td>${formatSeasonSaleType(row)}</td>
          <td>${formatSeasonSaleDestination(row)}</td>
          <td>₿ ${Number(row.fee).toLocaleString("en-GB")}</td>
          <td>${new Date(row.transfer_time).toLocaleString()}</td>
        </tr>
      `;
        })
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
