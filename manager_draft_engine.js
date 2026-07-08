/**
 * Manager draft auction — parallel to draft_engine.js (players).
 */

import { supabase } from "./global.js";
import {
  getDraftTimelineFromStart,
  getManagerDraftEffectivePhase,
  getManagerDraftCountdownTick,
  isManagerDraftAuctionEnded,
  isManagerGpdbFreeAgentOfferAllowed,
  managerDraftPhaseLabel,
} from "./draft_timeline.js";
import {
  getUKNow,
  getUKWallClockParts,
  ukLocalToInstant,
  getManagerDraftEnabled,
  getDraftBiddingOpen,
} from "./global.js";

export { supabase };

export {
  getDraftTimelineFromStart,
  getManagerDraftEffectivePhase,
  getManagerDraftCountdownTick,
  isManagerDraftAuctionEnded,
  isManagerGpdbFreeAgentOfferAllowed,
  managerDraftPhaseLabel,
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

export function dedupeManagerDraftBidRows(rows) {
  const keep = new Map();
  for (const b of rows || []) {
    const key = `${b.manager_id}|${b.bidder_club_id}|${b.bid_amount}`;
    const prev = keep.get(key);
    if (!prev || Number(b.id) < Number(prev.id)) {
      keep.set(key, b);
    }
  }
  return [...keep.values()].sort(
    (a, b) => new Date(a.bid_time).getTime() - new Date(b.bid_time).getTime()
  );
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
  for (const [mid, rows] of map) {
    map.set(mid, dedupeManagerDraftBidRows(rows));
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

/** Manager id where club holds the highest bid on an active draft listing, or null. */
export async function getClubLeadingManagerDraftId(
  clubShortName,
  draftAuctionStartTime,
  excludeManagerId = null
) {
  if (!clubShortName) return null;

  const { data: listings, error } = await supabase
    .from("Manager_Transfer_Listings")
    .select("manager_id, current_highest_bidder")
    .eq("listing_type", "draft")
    .eq("status", "Active");

  if (error) {
    console.error("getClubLeadingManagerDraftId:", error);
    return null;
  }

  const managerIds = (listings || [])
    .map((l) => Number(l.manager_id))
    .filter(
      (id) =>
        Number.isFinite(id) &&
        (excludeManagerId == null || id !== Number(excludeManagerId))
    );

  const bidsByManager = managerIds.length
    ? await fetchManagerDraftBidsGrouped(managerIds, draftAuctionStartTime)
    : new Map();

  for (const listing of listings || []) {
    const mid = Number(listing.manager_id);
    if (excludeManagerId != null && mid === Number(excludeManagerId)) continue;

    const bids = bidsByManager.get(mid) || [];
    const top = highestManagerDraftBid(bids);
    const leader = top?.bidder_club_id ?? listing.current_highest_bidder;
    if (leader === clubShortName) return mid;
  }

  return null;
}

export async function getClubManagerVacancy(clubShortName) {
  if (!clubShortName) {
    return { vacant: false, reason: "No club linked to your account." };
  }

  const { data: clubRow } = await supabase
    .from("Clubs")
    .select("manager_id")
    .eq("ShortName", clubShortName)
    .maybeSingle();
  if (clubRow?.manager_id != null) {
    return {
      vacant: false,
      reason:
        "Your club already has a manager — sack them before opening a manager draft auction.",
    };
  }

  const { data: clubMgr } = await supabase
    .from("Managers")
    .select("id")
    .eq("contracted_club", clubShortName)
    .maybeSingle();
  if (clubMgr?.id != null) {
    return {
      vacant: false,
      reason:
        "Your club already has a manager signed — sack them before opening a manager draft auction.",
    };
  }

  return { vacant: true, reason: "" };
}

let blockedSackedManagerIds = null;
let blockedSackedManagerIdsAt = 0;
const SACK_BLOCK_CACHE_MS = 60_000;

export async function fetchClubSackedManagerIds({ force = false } = {}) {
  const now = Date.now();
  if (
    !force &&
    blockedSackedManagerIds != null &&
    now - blockedSackedManagerIdsAt < SACK_BLOCK_CACHE_MS
  ) {
    return blockedSackedManagerIds;
  }

  const { data, error } = await supabase.rpc("club_sacked_manager_ids");
  if (error) {
    console.warn("club_sacked_manager_ids:", error.message);
    return [];
  }

  blockedSackedManagerIds = (Array.isArray(data) ? data : [])
    .map((id) => Number(id))
    .filter(Number.isFinite);
  blockedSackedManagerIdsAt = now;
  return blockedSackedManagerIds;
}

export async function getManagerDraftBidEligibility({
  managerId,
  buyerShortName,
  managerDraftEnabled,
  draftAuctionStartTime,
}) {
  const nowUK = getUKNow();
  const start = draftAuctionStartTime ? new Date(draftAuctionStartTime) : null;
  const timeline = getDraftTimelineFromStart(start);

  if (!managerDraftEnabled) {
    return { allowed: false, reason: "Manager draft auction is not enabled." };
  }
  if (!buyerShortName) {
    return { allowed: false, reason: "No club linked to your account." };
  }
  if (!timeline) {
    return { allowed: false, reason: "Draft schedule is not set." };
  }

  const open = getDraftBiddingOpen();
  const phase = getManagerDraftEffectivePhase(
    nowUK,
    start,
    open === null ? {} : { biddingOpen: open }
  );
  if (phase === "before_start" || phase === "ended" || phase === "random_locked") {
    return { allowed: false, reason: "Bidding is not open right now." };
  }

  const vacancy = await getClubManagerVacancy(buyerShortName);
  if (!vacancy.vacant) {
    return { allowed: false, reason: vacancy.reason };
  }

  const sackedIds = await fetchClubSackedManagerIds();
  if (sackedIds.includes(Number(managerId))) {
    return {
      allowed: false,
      reason:
        "You cannot re-sign a manager you sacked this season. They may return next season.",
    };
  }

  const leadingElsewhere = await getClubLeadingManagerDraftId(
    buyerShortName,
    start,
    managerId
  );
  if (leadingElsewhere != null) {
    return {
      allowed: false,
      reason:
        "You already hold the highest bid on another manager draft auction. You may only lead one auction at a time.",
    };
  }

  return { allowed: true, reason: "" };
}

export async function canClubBidOnManagerDraft(opts) {
  const { allowed } = await getManagerDraftBidEligibility(opts);
  return allowed;
}

export function getManagerDraftListingEndTime() {
  const uk = getUKWallClockParts();
  const baseEnd = ukLocalToInstant(uk.year, uk.month, uk.day + 1, 18, 50, 0);
  const extraSeconds = Math.floor(Math.random() * 600);
  return new Date(baseEnd.getTime() + extraSeconds * 1000);
}

export async function ensureManagerDraftListing(manager) {
  const managerId = Number(manager.id);
  const { data: listingId, error } = await supabase.rpc("manager_draft_ensure_listing", {
    p_manager_id: managerId,
  });

  if (!error && listingId) {
    return { ok: true, listingId };
  }

  if (error?.message?.includes("manager_draft_ensure_listing")) {
    const { data: rows } = await supabase
      .from("Manager_Transfer_Listings")
      .select("id")
      .eq("manager_id", managerId)
      .eq("listing_type", "draft")
      .eq("status", "Active")
      .order("id", { ascending: true })
      .limit(1);

    if (rows?.[0]?.id) {
      return { ok: true, listingId: rows[0].id };
    }
  }

  const { data: rows } = await supabase
    .from("Manager_Transfer_Listings")
    .select("id")
    .eq("manager_id", managerId)
    .eq("listing_type", "draft")
    .eq("status", "Active")
    .order("id", { ascending: true })
    .limit(1);

  if (rows?.[0]?.id) {
    return { ok: true, listingId: rows[0].id };
  }

  const end = getManagerDraftListingEndTime();
  const { data: listing, error: insertError } = await supabase
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

  if (insertError || !listing) {
    return { ok: false, msg: insertError?.message || "Could not open manager draft listing." };
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
  const draftStart = draftAuctionStartTime ? new Date(draftAuctionStartTime) : null;

  if (!getManagerDraftEnabled()) {
    return { ok: false, msg: "Manager draft auction is not enabled." };
  }

  if (manager.contracted_club) {
    return { ok: false, msg: "Manager is not a free agent." };
  }

  const eligibility = await getManagerDraftBidEligibility({
    managerId: manager.id,
    buyerShortName,
    managerDraftEnabled: getManagerDraftEnabled(),
    draftAuctionStartTime: draftStart,
  });
  if (!eligibility.allowed) {
    return { ok: false, msg: eligibility.reason };
  }

  const existing = await fetchCurrentManagerDraftBids(manager.id, draftStart);
  const isFirstBid = existing.length === 0;
  const top = highestManagerDraftBid(existing);
  if (top?.bidder_club_id === buyerShortName) {
    return {
      ok: false,
      msg: "You already hold the highest bid on this manager. Wait until you are outbid before bidding again.",
    };
  }

  const listingResult = await ensureManagerDraftListing(manager);
  if (!listingResult.ok) return listingResult;

  const listingId = listingResult.listingId;
  const min = managerDraftMinimumBid(manager.market_value, existing);
  if (Number(offerAmount) < min) {
    return { ok: false, msg: `Minimum bid is ₿${min.toLocaleString("en-GB")}.` };
  }

  const { error } = await supabase.from("Manager_Transfer_Bids").insert({
    listing_id: listingId,
    manager_id: Number(manager.id),
    bidder_club_id: buyerShortName,
    bid_amount: offerAmount,
    is_direct: true,
    is_first_draft_bid: isFirstBid,
    is_draft_join: false,
    draft_join_consumed: false,
    bid_time: new Date().toISOString(),
  });

  if (error) {
    return { ok: false, msg: error.message || "Bid failed." };
  }

  await syncManagerDraftListingHighBid(listingId, manager.id, draftStart);
  return { ok: true };
}
