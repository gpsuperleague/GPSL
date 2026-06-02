// Shared special auction helpers (owners + admin)

import {
  formatDurationMs,
  formatTargetTimesSubline,
} from "./countdown_display.js";

export function formatMoney(n) {
  return `₿ ${Number(n || 0).toLocaleString("en-GB")}`;
}

export function roundToMillion(n) {
  const x = Number(n);
  if (!Number.isFinite(x)) return 0;
  return Math.round(x / 1000000) * 1000000;
}

/** Owner-visible auction: scheduled (before start) or active, not yet ended. */
export async function fetchActiveSpecialAuction(supabase) {
  const nowIso = new Date().toISOString();
  const { data, error } = await supabase
    .from("special_auctions")
    .select("*")
    .in("status", ["scheduled", "active"])
    .gt("end_time", nowIso)
    .order("start_time", { ascending: true })
    .limit(1)
    .maybeSingle();

  if (error) {
    console.error("fetchActiveSpecialAuction:", error);
    return null;
  }
  return data;
}

export async function fetchAuctionById(supabase, id) {
  const { data, error } = await supabase
    .from("special_auctions")
    .select("*")
    .eq("id", id)
    .maybeSingle();
  if (error) return null;
  return data;
}

export async function loadOwnerClub(supabase) {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { user: null, clubShort: null };

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();

  return { user, clubShort: club?.ShortName ?? null };
}

export async function fetchAuctionBids(supabase, auctionId) {
  const { data, error } = await supabase
    .from("special_auction_bids")
    .select("*")
    .eq("auction_id", auctionId)
    .order("bid_amount", { ascending: true });

  if (error) {
    console.error("fetchAuctionBids:", error);
    return [];
  }
  return data || [];
}

export async function submitSpecialBid(supabase, auctionId, amount) {
  return supabase.rpc("special_auction_submit_bid", {
    p_auction_id: auctionId,
    p_amount: amount,
  });
}

export function auctionPhase(auction) {
  if (!auction) return "none";
  const now = Date.now();
  const start = new Date(auction.start_time).getTime();
  const end = new Date(auction.end_time).getTime();
  if (!["scheduled", "active"].includes(auction.status)) return auction.status;
  if (now < start) return "before_start";
  if (now >= end) return "ended_pending";
  return "live";
}

export function timeRemainingLabel(endIso) {
  const ms = new Date(endIso).getTime() - Date.now();
  if (ms <= 0) return "0s";
  return formatDurationMs(ms);
}

/** Duration line + UK/local target subline for auction timers. */
export function formatAuctionTimerText(label, endIso) {
  const target = new Date(endIso);
  const ms = target.getTime() - Date.now();
  const duration =
    ms > 0 ? `${label}: ${formatDurationMs(ms)}` : `${label}: ended`;
  const subline = formatTargetTimesSubline(target);
  return subline ? { duration, subline } : { duration, subline: "" };
}

export function prizeDescription(auction) {
  if (!auction) return "";
  if (auction.prize_type === "player" && auction.prize_player_id) {
    return `Player prize (ID ${auction.prize_player_id})`;
  }
  if (auction.prize_type === "cash" && auction.prize_cash_amount) {
    return `Cash prize ${formatMoney(auction.prize_cash_amount)}`;
  }
  if (auction.prize_type === "discount") {
    return auction.prize_discount_label || "Discount prize";
  }
  return "Prize TBC";
}
