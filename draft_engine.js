// draft_engine.js

/* ============================================================
   MODULE A: Supabase Client
   ============================================================ */

import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

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
  const now = new Date();
  const fmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "numeric",
    second: "numeric",
    hour12: false
  });

  const parts = fmt.formatToParts(now);
  const map = {};
  parts.forEach(p => {
    if (p.type && p.value) map[p.type] = p.value;
  });

  const y = Number(map.year);
  const m = Number(map.month) - 1;
  const d = Number(map.day);
  const hh = Number(map.hour);
  const mm = Number(map.minute);
  const ss = Number(map.second);

  if ([y, m, d, hh, mm, ss].some(v => !isFinite(v))) {
    console.warn("getUKNow: failed to parse parts, falling back to local Date()");
    return new Date();
  }

  return makeUKDate(y, m, d, hh, mm, ss);
}

export function getDraftWindowTimes() {
  const nowUK = getUKNow();

  const y = nowUK.getFullYear();
  const m = nowUK.getMonth();
  const d = nowUK.getDate();

  const todayMidnight = makeUKDate(y, m, d, 0, 0, 0);
  const yesterdayMidnight = new Date(todayMidnight.getTime() - 24 * 60 * 60 * 1000);

  const sevenPmYesterday = makeUKDate(
    yesterdayMidnight.getUTCFullYear(),
    yesterdayMidnight.getUTCMonth(),
    yesterdayMidnight.getUTCDate(),
    19, 0, 0
  );

  const sixPmToday = makeUKDate(y, m, d, 18, 0, 0);
  const sevenPmToday = makeUKDate(y, m, d, 19, 0, 0);

  return { sevenPmYesterday, sixPmToday, sevenPmToday };
}

export function getDraftCutoff() {
  const nowUK = getUKNow();
  const y = nowUK.getFullYear();
  const m = nowUK.getMonth();
  const d = nowUK.getDate();
  return makeUKDate(y, m, d + 1, 18, 0, 0);
}

export function formatMs(ms) {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return `${h}h ${m}m ${s}s`;
}

/* ============================================================
   MODULE C: Global Settings
   ============================================================ */

export async function loadGlobalSettings() {
  const { data, error } = await supabase
    .from("global_settings")
    .select("draft_auction_enabled, draft_auction_start_time, draft_random_finish_time")
    .eq("id", 1)
    .single();

  if (error || !data) {
    return {
      draftAuctionEnabled: false,
      draftAuctionStartTime: null,
      draftRandomFinishTime: null
    };
  }

  return {
    draftAuctionEnabled: data.draft_auction_enabled === true,
    draftAuctionStartTime: data.draft_auction_start_time
      ? new Date(data.draft_auction_start_time)
      : null,
    draftRandomFinishTime: data.draft_random_finish_time
      ? new Date(data.draft_random_finish_time)
      : null
  };
}

/* ============================================================
   MODULE D: Draft Phase Logic
   ============================================================ */

export function getDraftPhase(nowUK, draftAuctionStartTime, draftRandomFinishTime) {
  if (!draftAuctionStartTime || !draftRandomFinishTime) return "ended";

  const start = new Date(draftAuctionStartTime);
  const randomFinish = new Date(draftRandomFinishTime);

  const cutoff = new Date(start.getTime() + 23 * 60 * 60 * 1000);
  const randomStart = new Date(cutoff.getTime() + 50 * 60 * 1000);

  if (nowUK < start) return "before_start";
  if (nowUK >= start && nowUK < cutoff) return "live_until_cutoff";
  if (nowUK >= cutoff && nowUK < randomStart) return "pre_random";
  if (nowUK >= randomStart && nowUK < randomFinish) return "random_active";
  return "ended";
}

/* ============================================================
   MODULE E: Credits Logic
   ============================================================ */

export async function getDraftCredits(clubShortName, draftRandomFinishTime) {
  const { sevenPmYesterday, sixPmToday } = getDraftWindowTimes();

  const { data: firsts } = await supabase
    .from("Player_Transfer_Bids")
    .select("direct_bid_id")
    .eq("bidder_club_id", clubShortName)
    .eq("is_first_draft_bid", true)
    .gte("bid_time", sevenPmYesterday.toISOString())
    .lt("bid_time", sixPmToday.toISOString());

  const rawJoinEnd = draftRandomFinishTime;
  const joinWindowEnd = isValidDate(rawJoinEnd) ? rawJoinEnd : sixPmToday;
  const joinWindowEndIso = joinWindowEnd.toISOString();

  const { data: joins } = await supabase
    .from("Player_Transfer_Bids")
    .select("direct_bid_id")
    .eq("bidder_club_id", clubShortName)
    .eq("is_draft_join", true)
    .eq("draft_join_consumed", true)
    .gte("bid_time", sevenPmYesterday.toISOString())
    .lt("bid_time", joinWindowEndIso);

  const earned = firsts ? firsts.length * 2 : 0;
  const used = joins ? new Set(joins.map(j => j.direct_bid_id)).size : 0;

  return { earned, used, credits: earned - used };
}

export async function getDraftCreditsCount(clubShortName, draftRandomFinishTime) {
  const { credits } = await getDraftCredits(clubShortName, draftRandomFinishTime);
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
  draftRandomFinishTime
}) {
  const nowUK = getUKNow();

  if (!draftAuctionEnabled) return false;
  if (!buyerShortName) return false;
  if (!draftAuctionStartTime || !draftRandomFinishTime) return false;

  if (nowUK < draftAuctionStartTime) return false;
  if (nowUK >= draftRandomFinishTime) return false;

  const cutoff = getDraftCutoff();

  const { data: existing } = await supabase
    .from("Player_Transfer_Bids")
    .select("bidder_club_id")
    .eq("direct_bid_id", konamiId)
    .eq("bidder_club_id", buyerShortName)
    .eq("is_direct", true);

  if (existing && existing.length) return true;

  const { data: allBids } = await supabase
    .from("Player_Transfer_Bids")
    .select("bidder_club_id")
    .eq("direct_bid_id", konamiId)
    .eq("is_direct", true);

  const isFirstBid = !allBids || allBids.length === 0;

  if (isFirstBid) {
    if (nowUK >= cutoff) return false;
    return true;
  }

  const credits = await getDraftCreditsCount(buyerShortName, draftRandomFinishTime);
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

/** Mirror highest direct draft bid onto the listing row for transferengine_* SQL */
export async function syncDraftListingHighBid(supabase, listingId, konamiId) {
  if (!listingId) return;

  const { data: top, error } = await supabase
    .from("Player_Transfer_Bids")
    .select("bid_amount, bidder_club_id")
    .eq("direct_bid_id", konamiId)
    .eq("is_direct", true)
    .order("bid_amount", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error || !top) return;

  await supabase
    .from("Player_Transfer_Listings")
    .update({
      current_highest_bid: top.bid_amount,
      current_highest_bidder: top.bidder_club_id,
    })
    .eq("id", listingId);
}
