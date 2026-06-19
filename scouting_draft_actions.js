/**
 * Draft auction actions for scouting targets (open thread + place bids).
 */

import {
  getUKWallClockParts,
  ukLocalToInstant,
  loadGlobalSettings,
} from "./global.js";
import {
  fetchDraftBidsGroupedForPlayers,
  fetchCurrentDraftAuctionBids,
  draftMinimumBidAmount,
  highestDraftBid,
  getDraftCreditsCount,
  syncDraftListingHighBid,
  getUKNow,
  isDraftAuctionEnded,
  getDraftPhaseFromStart,
  isGpdbFreeAgentOfferAllowed,
  draftPhaseLabel,
  canClubBidOnPlayerDraft,
  normalizeKonamiId,
} from "./draft_engine.js";
import { formatMoney } from "./competition.js";
import { displayClubName } from "./clubs_lookup.js";

function getDraftAuctionTimesForNewListing() {
  const uk = getUKWallClockParts();
  const sevenPmToday = ukLocalToInstant(uk.year, uk.month, uk.day, 19, 0, 0);
  const baseEnd = ukLocalToInstant(uk.year, uk.month, uk.day + 1, 18, 50, 0);
  const extraSeconds = Math.floor(Math.random() * 600);
  const end = new Date(baseEnd.getTime() + extraSeconds * 1000);
  return { start: sevenPmToday, end };
}

export async function ensureDraftListingForPlayer(supabase, player) {
  const konamiId = String(player.Konami_ID).trim();

  const { data: existing } = await supabase
    .from("Player_Transfer_Listings")
    .select("id")
    .eq("player_id", konamiId)
    .eq("listing_type", "draft")
    .eq("status", "Active")
    .maybeSingle();

  if (existing?.id) {
    return { ok: true, listingId: existing.id };
  }

  const { start, end } = getDraftAuctionTimesForNewListing();
  const { data: listing, error } = await supabase
    .from("Player_Transfer_Listings")
    .insert({
      player_id: konamiId,
      seller_club_id: null,
      reserve_price: player.market_value || 0,
      listing_type: "draft",
      market_value: player.market_value || 0,
      status: "Active",
      start_time: start.toISOString(),
      end_time: end.toISOString(),
      initial_end_time: end.toISOString(),
      created_at: new Date().toISOString(),
    })
    .select("id")
    .single();

  if (error || !listing) {
    return { ok: false, msg: error?.message || "Could not open draft auction." };
  }

  return { ok: true, listingId: listing.id };
}

async function insertDraftBid(supabase, player, amount, club, flags, listingId) {
  const konamiKey = normalizeKonamiId(player.Konami_ID);
  const { data, error } = await supabase
    .from("Player_Transfer_Bids")
    .insert({
      listing_id: listingId,
      player_id: konamiKey,
      direct_bid_id: konamiKey,
      bidder_club_id: club,
      bid_amount: amount,
      is_direct: true,
      is_first_draft_bid: flags.isFirst,
      is_draft_join: flags.isJoin,
      draft_join_consumed: flags.consumeJoin,
      bid_time: new Date().toISOString(),
    })
    .select("bid_id")
    .single();

  if (error || !data) {
    return { ok: false, msg: error?.message || "Bid failed." };
  }
  return { ok: true };
}

export async function submitScoutingDraftBid(
  supabase,
  { player, offerAmount, buyerShortName, draftAuctionStartTime }
) {
  const draftStart = draftAuctionStartTime
    ? new Date(draftAuctionStartTime)
    : null;

  const canBid = await canClubBidOnPlayerDraft({
    konamiId: player.Konami_ID,
    buyerShortName,
    draftAuctionEnabled: true,
    draftAuctionStartTime: draftStart,
  });

  if (!canBid) {
    const phase = getDraftPhaseFromStart(getUKNow(), draftStart);
    return {
      ok: false,
      msg:
        phase === "before_start"
          ? "Draft auction has not started yet."
          : "You cannot bid on this player right now.",
    };
  }

  const existing = await fetchCurrentDraftAuctionBids(
    player.Konami_ID,
    draftStart
  );
  const isFirstBid = existing.length === 0;
  const isJoining = !isFirstBid;

  const listingResult = await ensureDraftListingForPlayer(supabase, player);
  if (!listingResult.ok) return listingResult;

  const listingId = listingResult.listingId;
  let bidResult;

  if (isJoining) {
    const priorJoin = existing.filter(
      (b) => b.bidder_club_id === buyerShortName && b.is_draft_join === true
    );

    if (priorJoin.length > 0) {
      bidResult = await insertDraftBid(
        supabase,
        player,
        offerAmount,
        buyerShortName,
        { isFirst: false, isJoin: true, consumeJoin: false },
        listingId
      );
    } else {
      const credits = await getDraftCreditsCount(buyerShortName, draftStart);
      if (credits <= 0) {
        return {
          ok: false,
          msg: "Not enough draft credits to join this auction.",
        };
      }
      bidResult = await insertDraftBid(
        supabase,
        player,
        offerAmount,
        buyerShortName,
        { isFirst: false, isJoin: true, consumeJoin: true },
        listingId
      );
    }
  } else {
    bidResult = await insertDraftBid(
      supabase,
      player,
      offerAmount,
      buyerShortName,
      { isFirst: true, isJoin: false, consumeJoin: false },
      listingId
    );
  }

  if (!bidResult.ok) return bidResult;

  await syncDraftListingHighBid(
    supabase,
    listingId,
    player.Konami_ID,
    draftStart
  );

  return { ok: true };
}

export async function loadScoutingDraftContext(supabase, clubShort, playerIds) {
  const settings = await loadGlobalSettings();
  const draftStart = settings.draftStart;
  const draftEnabled = settings.draftEnabled;
  const nowUK = getUKNow();
  const phase = draftStart
    ? getDraftPhaseFromStart(nowUK, new Date(draftStart))
    : "ended";
  const auctionEnded =
    !draftEnabled || !draftStart || isDraftAuctionEnded(nowUK, draftStart);

  const normalized = [
    ...new Set((playerIds || []).map(normalizeKonamiId).filter(Boolean)),
  ];

  const activeListingByPlayer = new Map();
  if (normalized.length) {
    const { data: listings } = await supabase
      .from("Player_Transfer_Listings")
      .select("id, player_id, status")
      .eq("listing_type", "draft")
      .eq("status", "Active")
      .in("player_id", normalized);

    for (const row of listings || []) {
      activeListingByPlayer.set(String(row.player_id), row);
    }
  }

  const bidsGrouped = await fetchDraftBidsGroupedForPlayers(
    normalized,
    draftStart ? new Date(draftStart) : null
  );

  return {
    settings,
    draftStart,
    draftEnabled,
    nowUK,
    phase,
    auctionEnded,
    activeListingByPlayer,
    bidsGrouped,
    clubShort,
  };
}

export async function buildPlayerDraftUiState(ctx, player) {
  const pid = normalizeKonamiId(player?.Konami_ID);
  const hasContract = Boolean(
    player?.Contracted_Team && String(player.Contracted_Team).trim()
  );

  if (hasContract) {
    return {
      status: "Under contract",
      leadingText: "—",
      yourBidText: "—",
      canOpen: false,
      canBid: false,
      canBidInline: false,
      minBid: null,
      playerPageUrl: null,
    };
  }

  if (!ctx.draftEnabled || !ctx.draftStart) {
    return {
      status: "Draft disabled",
      leadingText: "—",
      yourBidText: "—",
      canOpen: false,
      canBid: false,
      canBidInline: false,
      minBid: null,
      playerPageUrl: `draftauction_player.html?player=${encodeURIComponent(pid)}`,
    };
  }

  const listing = ctx.activeListingByPlayer.get(pid);
  const bids = ctx.bidsGrouped.get(pid) || [];
  const high = highestDraftBid(bids);
  const myBids = bids.filter((b) => b.bidder_club_id === ctx.clubShort);
  const myHigh = myBids.length
    ? myBids.reduce((max, b) =>
        Number(b.bid_amount) > Number(max.bid_amount) ? b : max
      )
    : null;

  const leadingText = high
    ? `${formatMoney(Number(high.bid_amount))} (${displayClubName(high.bidder_club_id)})`
    : "None";

  const yourBidText = myHigh
    ? formatMoney(Number(myHigh.bid_amount))
    : "—";

  const draftStartDate = new Date(ctx.draftStart);
  const canOpen =
    !listing &&
    isGpdbFreeAgentOfferAllowed(ctx.nowUK, draftStartDate);

  const canBid =
    !ctx.auctionEnded &&
    (await canClubBidOnPlayerDraft({
      konamiId: pid,
      buyerShortName: ctx.clubShort,
      draftAuctionEnabled: ctx.draftEnabled,
      draftAuctionStartTime: draftStartDate,
    }));

  const minBid = draftMinimumBidAmount(player.market_value, bids);

  let status;
  if (ctx.auctionEnded) {
    status = listing ? "Auction ended" : "Draft ended";
  } else if (listing) {
    status = "Auction open";
  } else if (canOpen) {
    status = "Ready — open auction";
  } else if (ctx.phase === "before_start") {
    status = draftPhaseLabel("before_start");
  } else {
    status = draftPhaseLabel(ctx.phase) || "Not in auction";
  }

  const playerPageUrl = `draftauction_player.html?player=${encodeURIComponent(pid)}`;

  return {
    playerId: pid,
    status,
    leadingText,
    yourBidText,
    canOpen,
    canBid,
    canBidInline: canBid,
    minBid,
    playerPageUrl,
    isLeading: high?.bidder_club_id === ctx.clubShort,
  };
}

export function renderDraftManageCell(ui) {
  const parts = [];

  if (ui.canOpen) {
    parts.push(
      `<button type="button" class="scout-open-auction button secondary" data-player-id="${ui.playerId}" style="padding:4px 10px;font-size:11px;margin:2px;">Open auction</button>`
    );
  }

  if (ui.canBidInline && ui.minBid != null) {
    parts.push(`
      <div class="scout-bid-row">
        <input type="text" class="scout-bid-input" data-player-id="${ui.playerId}" value="${Number(ui.minBid).toLocaleString("en-GB")}" aria-label="Bid amount">
        <button type="button" class="scout-bid-submit button" data-player-id="${ui.playerId}" style="padding:4px 8px;font-size:11px;">Bid</button>
      </div>`);
  }

  if (ui.playerPageUrl) {
    const label = ui.canBidInline ? "Full bid page" : "View";
    parts.push(
      `<a href="${ui.playerPageUrl}" class="gpsl-link" style="font-size:12px;">${label}</a>`
    );
  }

  if (!parts.length) {
    return '<span style="color:#666;">—</span>';
  }

  return `<div class="scout-draft-manage">${parts.join("")}</div>`;
}
