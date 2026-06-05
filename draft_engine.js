// draft_engine.js

/* ============================================================
   MODULE A: Supabase Client
   ============================================================ */

import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import {
  getDraftTimelineFromStart,
  getDraftPhaseFromStart,
  getEffectiveDraftPhase,
} from "./draft_timeline.js";
import {
  getUKWallClockParts,
  ukLocalToInstant,
  getDraftBiddingOpen,
  isDraftAuctionEnded,
} from "./global.js";

export {
  getDraftTimelineFromStart,
  getDraftPhaseFromStart,
  getEffectiveDraftPhase,
  isGpdbFreeAgentOfferAllowed,
  gpdbFreeAgentLockMessage,
  draftPhaseLabel,
} from "./draft_timeline.js";

export { isDraftAuctionEnded, getDraftBiddingOpen } from "./global.js";

const supabase = createClient(
  "https://omyyogfumrjoaweuawjn.supabase.co",
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9teXlvZ2Z1bXJqb2F3ZXVhd2puIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ5NTUxMzUsImV4cCI6MjA5MDUzMTEzNX0.7UVkpi4DOtC9VNjFLnE_ZnK6vhDtlfesZ_8rfnrkno4"
);

export { supabase };

/* ============================================================
   MODULE B: Time + Date Helpers
   ============================================================ */

export function makeUKDate(year, month, day, hour = 0, minute = 0, second = 0) {
  return new Date(Date.UTC(year, month, day, hour, minute, second));
}

export function isValidDate(d) {
  return d instanceof Date && !isNaN(d.getTime());
}

export function getUKNow() {
  return new Date();
}

export function getDraftWindowTimes() {
  const uk = getUKWallClockParts();
  const noon = ukLocalToInstant(uk.year, uk.month, uk.day, 12, 0, 0);
  const yest = getUKWallClockParts(new Date(noon.getTime() - 24 * 60 * 60 * 1000));

  const sevenPmYesterday = ukLocalToInstant(yest.year, yest.month, yest.day, 19, 0, 0);
  const sixPmToday = ukLocalToInstant(uk.year, uk.month, uk.day, 18, 0, 0);
  const sevenPmToday = ukLocalToInstant(uk.year, uk.month, uk.day, 19, 0, 0);

  return { sevenPmYesterday, sixPmToday, sevenPmToday };
}

export function getDraftCutoff(draftAuctionStartTime) {
  const t = getDraftTimelineFromStart(
    draftAuctionStartTime ? new Date(draftAuctionStartTime) : null
  );
  if (t) return t.cutoff;

  const uk = getUKWallClockParts();
  return ukLocalToInstant(uk.year, uk.month, uk.day + 1, 18, 0, 0);
}

export function formatMs(ms) {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return `${h}h ${m}m ${s}s`;
}

/** Minimum raise on an existing draft auction thread. */
export const DRAFT_BID_INCREMENT = 500_000;

/**
 * Lowest valid next bid: market value if opening; else highest bid in window + increment.
 */
export function draftMinimumBidAmount(marketValue, windowBids) {
  const mv = Number(marketValue) || 0;
  const bids = windowBids || [];
  if (!bids.length) return mv;
  const high = bids.reduce(
    (max, b) => Math.max(max, Number(b.bid_amount) || 0),
    0
  );
  return high + DRAFT_BID_INCREMENT;
}

/** Consistent Konami id for bid rows (DB may store number or text). */
export function normalizeKonamiId(id) {
  if (id == null || String(id).trim() === "") return "";
  return String(id).trim();
}

/** Current draft auction bid window (admin start → public end). */
export function getDraftBidWindowBounds(draftAuctionStartTime) {
  const timeline = getDraftTimelineFromStart(
    draftAuctionStartTime ? new Date(draftAuctionStartTime) : null
  );
  if (!timeline) return null;
  return {
    startIso: timeline.start.toISOString(),
    endIso: timeline.publicEnd.toISOString(),
  };
}

/** Konami id from a bid row (player_id preferred; matches string or numeric legacy ids). */
export function bidRowKonamiId(row) {
  return normalizeKonamiId(row?.player_id ?? row?.direct_bid_id);
}

/**
 * All draft bids in the current window, grouped by Konami id.
 * One query keeps the main list and player page in sync.
 */
export async function fetchDraftBidsGroupedForPlayers(
  playerIds,
  draftAuctionStartTime
) {
  const bounds = getDraftBidWindowBounds(draftAuctionStartTime);
  const normalized = [
    ...new Set((playerIds || []).map(normalizeKonamiId).filter(Boolean)),
  ];
  const map = new Map();
  for (const id of normalized) map.set(id, []);
  if (!bounds || !normalized.length) return map;

  const { data, error } = await supabase
    .from("Player_Transfer_Bids")
    .select(
      "bidder_club_id, is_first_draft_bid, is_draft_join, draft_join_consumed, bid_time, bid_amount, bid_id, direct_bid_id, player_id"
    )
    .eq("is_direct", true)
    .is("seller_club_id", null)
    .gte("bid_time", bounds.startIso)
    .lt("bid_time", bounds.endIso)
    .order("bid_time", { ascending: true });

  if (error) {
    console.error("fetchDraftBidsGroupedForPlayers:", error);
    return map;
  }

  for (const row of data || []) {
    const pid = bidRowKonamiId(row);
    if (!map.has(pid)) continue;
    map.get(pid).push(row);
  }
  return map;
}

/**
 * Draft auction bids for one player (current window, free-agent rows only).
 */
export async function fetchCurrentDraftAuctionBids(konamiId, draftAuctionStartTime) {
  const key = normalizeKonamiId(konamiId);
  if (!key) return [];
  const map = await fetchDraftBidsGroupedForPlayers([key], draftAuctionStartTime);
  return map.get(key) || [];
}

export function highestDraftBid(bids) {
  if (!bids?.length) return null;
  return bids.reduce((max, b) =>
    Number(b.bid_amount) > Number(max.bid_amount) ? b : max
  );
}

/* ============================================================
   MODULE C: Global Settings
   ============================================================ */

export async function loadGlobalSettings() {
  const { data, error } = await supabase
    .from("global_settings_public")
    .select(
      "draft_auction_enabled, draft_auction_start_time, transfer_window_open"
    )
    .eq("id", 1)
    .single();

  if (error || !data) {
    return {
      draftAuctionEnabled: false,
      draftAuctionStartTime: null,
      transferWindowOpen: false,
    };
  }

  const draftAuctionStartTime = data.draft_auction_start_time
    ? new Date(data.draft_auction_start_time)
    : null;

  return {
    draftAuctionEnabled: data.draft_auction_enabled === true,
    draftAuctionStartTime,
    transferWindowOpen: data.transfer_window_open === true,
    draftTimeline: getDraftTimelineFromStart(draftAuctionStartTime),
  };
}

/** @deprecated Use getDraftPhaseFromStart — finish time is never exposed to clients */
export function getDraftPhase(nowUK, draftAuctionStartTime) {
  return getDraftPhaseFromStart(nowUK, draftAuctionStartTime);
}

/* ============================================================
   MODULE E: Credits Logic
   ============================================================ */

export async function getDraftCredits(clubShortName, draftAuctionStartTime) {
  const timeline = getDraftTimelineFromStart(
    draftAuctionStartTime ? new Date(draftAuctionStartTime) : null
  );
  const { sevenPmYesterday, sixPmToday } = getDraftWindowTimes();

  // Earn first-bid credits during the live draft window (start → 6pm cutoff), not calendar midnight bounds
  const earnStart = timeline?.start ?? sevenPmYesterday;
  const earnEnd = timeline?.cutoff ?? sixPmToday;
  const joinWindowEnd = timeline?.publicEnd ?? sixPmToday;
  const earnStartIso = earnStart.toISOString();
  const earnEndIso = earnEnd.toISOString();
  const joinWindowEndIso = joinWindowEnd.toISOString();

  const { data: firsts } = await supabase
    .from("Player_Transfer_Bids")
    .select("direct_bid_id")
    .eq("bidder_club_id", clubShortName)
    .eq("is_first_draft_bid", true)
    .gte("bid_time", earnStartIso)
    .lt("bid_time", earnEndIso);

  const { data: joins } = await supabase
    .from("Player_Transfer_Bids")
    .select("direct_bid_id")
    .eq("bidder_club_id", clubShortName)
    .eq("is_draft_join", true)
    .eq("draft_join_consumed", true)
    .gte("bid_time", earnStartIso)
    .lt("bid_time", joinWindowEndIso);

  const earned = firsts ? firsts.length * 2 : 0;
  const used = joins ? new Set(joins.map(j => j.direct_bid_id)).size : 0;

  return { earned, used, credits: earned - used };
}

export async function getDraftCreditsCount(clubShortName, draftAuctionStartTime) {
  const { credits } = await getDraftCredits(clubShortName, draftAuctionStartTime);
  return credits;
}

/* ============================================================
   MODULE F: Bidding Eligibility
   ============================================================ */

export async function canClubBidOnPlayerDraft({
  konamiId,
  buyerShortName,
  draftAuctionEnabled,
  draftAuctionStartTime,
}) {
  const nowUK = getUKNow();
  const start = draftAuctionStartTime ? new Date(draftAuctionStartTime) : null;
  const timeline = getDraftTimelineFromStart(start);

  if (!draftAuctionEnabled) return false;
  if (!buyerShortName) return false;
  if (!timeline) return false;

  const open = getDraftBiddingOpen();
  const phase = getEffectiveDraftPhase(
    nowUK,
    start,
    open === null ? {} : { biddingOpen: open }
  );
  if (
    phase === "before_start" ||
    phase === "ended" ||
    phase === "random_locked"
  ) {
    return false;
  }

  const cutoff = timeline.cutoff;

  const windowBids = await fetchCurrentDraftAuctionBids(konamiId, start);

  if (windowBids.some((b) => b.bidder_club_id === buyerShortName)) return true;

  const isFirstBid = windowBids.length === 0;

  if (isFirstBid) {
    if (nowUK >= cutoff) return false;
    return true;
  }

  const credits = await getDraftCreditsCount(buyerShortName, start);
  return credits > 0;
}

/* ============================================================
   MODULE G: Listing sync (for SQL transfer engine)
   ============================================================ */

/** Active draft listing id for a free agent, if any */
export async function getActiveDraftListingId(supabase, konamiId) {
  const id = String(konamiId);
  const { data } = await supabase
    .from("Player_Transfer_Listings")
    .select("id")
    .eq("listing_type", "draft")
    .eq("status", "Active")
    .eq("player_id", id)
    .maybeSingle();

  return data?.id ?? null;
}

/** Mirror highest in-window draft bid onto the listing (same rules as bid history UI). */
export async function syncDraftListingHighBid(
  supabaseClient,
  listingId,
  konamiId,
  draftAuctionStartTime = null
) {
  if (!listingId) return;

  const bids = await fetchCurrentDraftAuctionBids(
    konamiId,
    draftAuctionStartTime
  );
  const top = highestDraftBid(bids);
  if (!top) return;

  await supabaseClient
    .from("Player_Transfer_Listings")
    .update({
      current_highest_bid: top.bid_amount,
      current_highest_bidder: top.bidder_club_id,
    })
    .eq("id", listingId);
}
