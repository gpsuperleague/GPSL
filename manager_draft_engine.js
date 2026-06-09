/**
 * Manager draft auction — parallel to draft_engine.js (players).
 */

import { supabase } from "./global.js";
import {
  getDraftTimelineFromStart,
  getDraftPhaseFromStart,
  getEffectiveDraftPhase,
  isGpdbFreeAgentOfferAllowed,
  draftPhaseLabel,
} from "./draft_timeline.js";
import {
  getUKNow,
  getUKWallClockParts,
  ukLocalToInstant,
  getManagerDraftEnabled,
  isDraftAuctionEnded,
  getDraftBiddingOpen,
} from "./global.js";

export { supabase };

export {
  getDraftTimelineFromStart,
  getDraftPhaseFromStart,
  getEffectiveDraftPhase,
  isGpdbFreeAgentOfferAllowed,
  draftPhaseLabel,
  isDraftAuctionEnded,
};

export const MANAGER_DRAFT_BID_INCREMENT = 500_000;

export function getManagerDraftBidWindowBounds(draftAuctionStartTime) {
  const timeline = getDraftTimelineFromStart(
    draftAuctionStartTime ? new Date(draftAuctionStartTime) : null
  );
  if (!timeline) return null;
  return {
    startIso: timeline.start.toISOString(),
    endIso: timeline.publicEnd.toISOString(),
  };
}

export async function fetchManagerDraftBidsGrouped(managerIds, draftAuctionStartTime) {
  const bounds = getManagerDraftBidWindowBounds(draftAuctionStartTime);
  const ids = [...new Set((managerIds || []).map((id) => Number(id)).filter(Number.isFinite))];
  const map = new Map();
  for (const id of ids) map.set(id, []);
  if (!bounds || !ids.length) return map;

  const { data, error } = await supabase
    .from("Manager_Transfer_Bids")
    .select(
      "bidder_club_id, is_first_draft_bid, is_draft_join, draft_join_consumed, bid_time, bid_amount, id, manager_id, listing_id"
    )
    .gte("bid_time", bounds.startIso)
    .lt("bid_time", bounds.endIso)
    .in("manager_id", ids)
    .order("bid_time", { ascending: true });

  if (error) {
    console.error("fetchManagerDraftBidsGrouped:", error);
    return map;
  }

  for (const row of data || []) {
    const mid = Number(row.manager_id);
    if (!map.has(mid)) continue;
    map.get(mid).push(row);
  }
  return map;
}

export async function fetchCurrentManagerDraftBids(managerId, draftAuctionStartTime) {
  const id = Number(managerId);
  if (!Number.isFinite(id)) return [];
  const map = await fetchManagerDraftBidsGrouped([id], draftAuctionStartTime);
  return map.get(id) || [];
}

export function highestManagerDraftBid(bids) {
  if (!bids?.length) return null;
  return bids.reduce((max, b) =>
    Number(b.bid_amount) > Number(max.bid_amount) ? b : max
  );
}

export function managerDraftMinimumBid(marketValue, windowBids) {
  const mv = Number(marketValue) || 0;
  const bids = windowBids || [];
  if (!bids.length) return mv;
  const high = bids.reduce(
    (max, b) => Math.max(max, Number(b.bid_amount) || 0),
    0
  );
  return Math.max(mv, high + MANAGER_DRAFT_BID_INCREMENT);
}

function getManagerDraftWindowTimes() {
  const uk = getUKWallClockParts();
  const noon = ukLocalToInstant(uk.year, uk.month, uk.day, 12, 0, 0);
  const yest = getUKWallClockParts(new Date(noon.getTime() - 24 * 60 * 60 * 1000));
  return {
    sevenPmYesterday: ukLocalToInstant(yest.year, yest.month, yest.day, 19, 0, 0),
    sixPmToday: ukLocalToInstant(uk.year, uk.month, uk.day, 18, 0, 0),
  };
}

export async function getManagerDraftCredits(clubShortName, draftAuctionStartTime) {
  const timeline = getDraftTimelineFromStart(
    draftAuctionStartTime ? new Date(draftAuctionStartTime) : null
  );
  const { sevenPmYesterday, sixPmToday } = getManagerDraftWindowTimes();
  const earnStart = timeline?.start ?? sevenPmYesterday;
  const earnEnd = timeline?.cutoff ?? sixPmToday;
  const joinWindowEnd = timeline?.publicEnd ?? sixPmToday;

  const { data: firsts, error: firstsErr } = await supabase
    .from("Manager_Transfer_Bids")
    .select("manager_id")
    .eq("bidder_club_id", clubShortName)
    .eq("is_first_draft_bid", true)
    .gte("bid_time", earnStart.toISOString())
    .lt("bid_time", earnEnd.toISOString());

  if (firstsErr) {
    console.error(
      "getManagerDraftCredits: is_first_draft_bid query failed — run managers_draft_auction.sql",
      firstsErr
    );
    return { earned: 0, used: 0, credits: 0 };
  }

  const { data: joins, error: joinsErr } = await supabase
    .from("Manager_Transfer_Bids")
    .select("manager_id")
    .eq("bidder_club_id", clubShortName)
    .eq("is_draft_join", true)
    .eq("draft_join_consumed", true)
    .gte("bid_time", earnStart.toISOString())
    .lt("bid_time", joinWindowEnd.toISOString());

  if (joinsErr) {
    console.error(
      "getManagerDraftCredits: is_draft_join query failed — run managers_draft_auction.sql",
      joinsErr
    );
    return { earned: 0, used: 0, credits: 0 };
  }

  const earned = firsts ? firsts.length * 2 : 0;
  const used = joins ? new Set(joins.map((j) => j.manager_id)).size : 0;
  return { earned, used, credits: earned - used };
}

export async function canClubBidOnManagerDraft({
  managerId,
  buyerShortName,
  managerDraftEnabled,
  draftAuctionStartTime,
}) {
  const nowUK = getUKNow();
  const start = draftAuctionStartTime ? new Date(draftAuctionStartTime) : null;
  const timeline = getDraftTimelineFromStart(start);

  if (!managerDraftEnabled) return false;
  if (!buyerShortName) return false;
  if (!timeline) return false;

  const open = getDraftBiddingOpen();
  const phase = getEffectiveDraftPhase(
    nowUK,
    start,
    open === null ? {} : { biddingOpen: open }
  );
  if (phase === "before_start" || phase === "ended" || phase === "random_locked") {
    return false;
  }

  const windowBids = await fetchCurrentManagerDraftBids(managerId, start);
  if (windowBids.some((b) => b.bidder_club_id === buyerShortName)) return true;

  if (windowBids.length === 0) {
    return nowUK < timeline.cutoff;
  }

  const { credits } = await getManagerDraftCredits(buyerShortName, start);
  return credits > 0;
}

export function getManagerDraftListingEndTime() {
  const uk = getUKWallClockParts();
  const baseEnd = ukLocalToInstant(uk.year, uk.month, uk.day + 1, 18, 50, 0);
  const extraSeconds = Math.floor(Math.random() * 600);
  return new Date(baseEnd.getTime() + extraSeconds * 1000);
}

export async function ensureManagerDraftListing(manager) {
  const managerId = Number(manager.id);
  const { data: existing } = await supabase
    .from("Manager_Transfer_Listings")
    .select("id")
    .eq("manager_id", managerId)
    .eq("listing_type", "draft")
    .eq("status", "Active")
    .maybeSingle();

  if (existing?.id) return { ok: true, listingId: existing.id };

  const end = getManagerDraftListingEndTime();
  const { data: listing, error } = await supabase
    .from("Manager_Transfer_Listings")
    .insert({
      manager_id: managerId,
      seller_club_id: null,
      listing_type: "draft",
      status: "Active",
      end_time: end.toISOString(),
      market_value: manager.market_value || 0,
    })
    .select("id")
    .single();

  if (error || !listing) {
    return { ok: false, msg: error?.message || "Could not open manager draft listing." };
  }
  return { ok: true, listingId: listing.id };
}

export async function syncManagerDraftListingHighBid(listingId, managerId, draftAuctionStartTime) {
  const bids = await fetchCurrentManagerDraftBids(managerId, draftAuctionStartTime);
  const top = highestManagerDraftBid(bids);
  if (!top || !listingId) return;
  await supabase
    .from("Manager_Transfer_Listings")
    .update({
      current_highest_bid: top.bid_amount,
      current_highest_bidder: top.bidder_club_id,
    })
    .eq("id", listingId);
}

export async function submitManagerDraftBid(manager, offerAmount, buyerShortName, draftAuctionStartTime) {
  const nowLocal = getUKNow();
  const draftStart = draftAuctionStartTime ? new Date(draftAuctionStartTime) : null;

  if (!getManagerDraftEnabled()) {
    return { ok: false, msg: "Manager draft auction is not enabled." };
  }

  if (manager.contracted_club) {
    return { ok: false, msg: "Manager is not a free agent." };
  }

  const existing = await fetchCurrentManagerDraftBids(manager.id, draftStart);
  const isFirstBid = existing.length === 0;
  const timeline = getDraftTimelineFromStart(draftStart);

  if (isFirstBid) {
    if (!isGpdbFreeAgentOfferAllowed(nowLocal, draftStart)) {
      return {
        ok: false,
        msg: "Opening bids on free agents close at 6pm UK. Join open threads on Manager Draft Auction.",
      };
    }
  } else if (nowLocal >= timeline.cutoff) {
    return { ok: false, msg: "No new join bids after 6pm UK." };
  }

  const listingResult = await ensureManagerDraftListing(manager);
  if (!listingResult.ok) return listingResult;

  const listingId = listingResult.listingId;
  const min = managerDraftMinimumBid(manager.market_value, existing);
  if (Number(offerAmount) < min) {
    return { ok: false, msg: `Minimum bid is ₿${min.toLocaleString("en-GB")}.` };
  }

  let isFirst = false;
  let isJoin = false;
  let consumeJoin = false;

  if (isFirstBid) {
    isFirst = true;
  } else {
    isJoin = true;
    const priorJoin = existing.filter(
      (b) => b.bidder_club_id === buyerShortName && b.is_draft_join
    );
    if (!priorJoin.length) {
      const { credits } = await getManagerDraftCredits(buyerShortName, draftStart);
      if (credits <= 0) {
        return {
          ok: false,
          msg: "Not enough manager draft credits. Be first to bid on a free agent in MGDB to earn credits.",
        };
      }
      consumeJoin = true;
    }
  }

  const { error } = await supabase.from("Manager_Transfer_Bids").insert({
    listing_id: listingId,
    manager_id: Number(manager.id),
    bidder_club_id: buyerShortName,
    bid_amount: offerAmount,
    is_direct: true,
    is_first_draft_bid: isFirst,
    is_draft_join: isJoin,
    draft_join_consumed: consumeJoin,
    bid_time: new Date().toISOString(),
  });

  if (error) {
    return { ok: false, msg: error.message || "Bid failed." };
  }

  await syncManagerDraftListingHighBid(listingId, manager.id, draftStart);
  return { ok: true };
}
