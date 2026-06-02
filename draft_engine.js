// draft_engine.js

/* ============================================================
   MODULE A: Supabase Client
   ============================================================ */

import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import {
  getDraftTimelineFromStart,
  getDraftPhaseFromStart,
  isDraftAuctionEnded,
} from "./draft_timeline.js";

export {
  getDraftTimelineFromStart,
  getDraftPhaseFromStart,
  isDraftAuctionEnded,
  draftPhaseLabel,
} from "./draft_timeline.js";

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

export function getDraftCutoff(draftAuctionStartTime) {
  const t = getDraftTimelineFromStart(
    draftAuctionStartTime ? new Date(draftAuctionStartTime) : null
  );
  if (t) return t.cutoff;

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
  const { sevenPmYesterday, sixPmToday } = getDraftWindowTimes();
  const timeline = getDraftTimelineFromStart(
    draftAuctionStartTime ? new Date(draftAuctionStartTime) : null
  );
  const joinWindowEnd = timeline?.publicEnd ?? sixPmToday;
  const joinWindowEndIso = joinWindowEnd.toISOString();

  const { data: firsts } = await supabase
    .from("Player_Transfer_Bids")
    .select("direct_bid_id")
    .eq("bidder_club_id", clubShortName)
    .eq("is_first_draft_bid", true)
    .gte("bid_time", sevenPmYesterday.toISOString())
    .lt("bid_time", sixPmToday.toISOString());

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

  const phase = getDraftPhaseFromStart(nowUK, start);
  if (phase === "before_start" || phase === "ended") return false;

  const cutoff = timeline.cutoff;

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
