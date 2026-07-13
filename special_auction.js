// Shared special auction helpers (owners + admin)

import {
  formatDurationMs,
  formatTargetTimesSubline,
  formatInstantUK,
  formatInstantLocal,
  isValidInstant,
} from "./countdown_display.js";

export function formatBidTimeHtml(iso) {
  const d = new Date(iso);
  if (!isValidInstant(d)) return "—";
  const uk = formatInstantUK(d, { precise: true });
  const local = formatInstantLocal(d, { precise: true });
  return (
    `<span class="bid-time">${uk}</span>` +
    `<span class="bid-time-local">${local}</span>`
  );
}

export function formatBidTimePlain(iso) {
  const d = new Date(iso);
  if (!isValidInstant(d)) return "";
  return formatInstantUK(d, { precise: true });
}

export function formatMoney(n) {
  return `₿ ${Number(n || 0).toLocaleString("en-GB")}`;
}

export function roundToMillion(n) {
  const x = Number(n);
  if (!Number.isFinite(x)) return 0;
  return Math.round(x / 1000000) * 1000000;
}

/** True while a snap is still before its random finish — player identity must stay hidden. */
export function snapIdentityHidden(auction) {
  if (!auction || auction.auction_type !== "snap") return false;
  if (!["scheduled", "active"].includes(String(auction.status || ""))) return false;
  const end = new Date(specialAuctionEffectiveEnd(auction)).getTime();
  if (!Number.isFinite(end)) return true;
  return Date.now() < end;
}

/** Client fallback if owner-fetch RPC is not deployed yet. */
export function sanitizeAuctionForOwner(auction) {
  if (!auction) return auction;
  const out = { ...auction };
  if (auction.auction_type === "snap" && ["scheduled", "active"].includes(auction.status)) {
    const start = new Date(auction.start_time).getTime();
    const mins = Number.isFinite(start)
      ? Math.max(0, (Date.now() - start) / 60000)
      : 0;
    if (mins < 20) out.clue_2 = null;
    if (mins < 40) out.clue_3 = null;
    if (mins < 50) out.clue_4 = null;
  }
  if (snapIdentityHidden(auction)) {
    out.prize_player_id = null;
    out.known_player_id = null;
  }
  return out;
}

/** Owner-visible auction: live/upcoming first; stale revealed LUBs do not block. */
export async function fetchActiveSpecialAuction(supabase) {
  const { data: rpcData, error: rpcErr } = await supabase.rpc(
    "special_auction_fetch_owner_active"
  );
  if (!rpcErr) return rpcData || null;

  console.warn("special_auction_fetch_owner_active:", rpcErr);

  const { data: live, error: liveErr } = await supabase
    .from("special_auctions")
    .select("*")
    .in("status", ["scheduled", "active"])
    .order("start_time", { ascending: true })
    .limit(1)
    .maybeSingle();

  if (liveErr) {
    console.error("fetchActiveSpecialAuction:", liveErr);
  }
  if (live) return sanitizeAuctionForOwner(live);

  const cutoff = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
  const { data: revealed, error: revealedErr } = await supabase
    .from("special_auctions")
    .select("*")
    .eq("status", "revealed")
    .gt("end_time", cutoff)
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (revealedErr) {
    console.error("fetchActiveSpecialAuction (revealed):", revealedErr);
  }
  return sanitizeAuctionForOwner(revealed);
}

/** Bidding window open (start_time reached, before end_time / snap random end). */
export function specialAuctionEffectiveEnd(auction) {
  if (!auction) return null;
  if (auction.auction_type === "snap" && auction.snap_random_end_at) {
    return auction.snap_random_end_at;
  }
  return auction.end_time;
}

export function isSpecialAuctionLive(auction) {
  if (!auction) return false;
  if (!["scheduled", "active"].includes(String(auction.status || ""))) return false;
  const now = Date.now();
  const start = new Date(auction.start_time).getTime();
  const end = new Date(specialAuctionEffectiveEnd(auction)).getTime();
  return now >= start && now < end;
}

/** True if a revealed auction is still within the short results window. */
export function isRecentRevealedAuction(auction, maxAgeMs = 7 * 24 * 60 * 60 * 1000) {
  if (!auction || String(auction.status || "") !== "revealed") return false;
  const end = new Date(specialAuctionEffectiveEnd(auction) || auction.end_time).getTime();
  if (!Number.isFinite(end)) return false;
  return Date.now() - end <= maxAgeMs;
}

/** Published in nav / owner pages (live, upcoming, or recent results). */
export function isSpecialAuctionPublished(auction) {
  if (!auction) return false;
  const status = String(auction.status || "");
  if (status === "scheduled" || status === "active") return true;
  return isRecentRevealedAuction(auction);
}

/** Nav strip + dropdown visibility / live badge. */
export async function fetchSpecialAuctionNavState(supabase) {
  const auction = await fetchActiveSpecialAuction(supabase);
  if (!auction) {
    return { visible: false, live: false, auction: null };
  }
  return {
    visible: isSpecialAuctionPublished(auction),
    live: isSpecialAuctionLive(auction),
    auction,
  };
}

export async function fetchAuctionById(supabase, id) {
  const { data: rpcData, error: rpcErr } = await supabase.rpc(
    "special_auction_fetch_owner_by_id",
    { p_auction_id: id }
  );
  if (!rpcErr) return rpcData || null;

  const { data, error } = await supabase
    .from("special_auctions")
    .select("*")
    .eq("id", id)
    .maybeSingle();
  if (error) return null;
  return sanitizeAuctionForOwner(data);
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
  const { data, error } = await supabase.rpc("special_auction_list_bids", {
    p_auction_id: auctionId,
  });

  if (!error) return data || [];

  console.error("fetchAuctionBids (rpc):", error);

  const { data: direct, error: directErr } = await supabase
    .from("special_auction_bids")
    .select("*")
    .eq("auction_id", auctionId)
    .order("bid_amount", { ascending: true });

  if (directErr) {
    console.error("fetchAuctionBids (table):", directErr);
    return [];
  }
  return direct || [];
}

/** Refresh auction row (status / winner fields) during live polling. */
export async function refreshAuctionRecord(supabase, auction) {
  if (!auction?.id) return auction;
  const { data: rpcData, error: rpcErr } = await supabase.rpc(
    "special_auction_fetch_owner_by_id",
    { p_auction_id: auction.id }
  );
  if (!rpcErr && rpcData) return rpcData;

  const { data, error } = await supabase
    .from("special_auctions")
    .select("*")
    .eq("id", auction.id)
    .maybeSingle();
  if (error) {
    console.error("refreshAuctionRecord:", error);
    return auction;
  }
  return sanitizeAuctionForOwner(data || auction);
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
  const end = new Date(specialAuctionEffectiveEnd(auction)).getTime();
  if (!["scheduled", "active"].includes(auction.status)) return auction.status;
  if (now < start) return "before_start";
  if (now >= end) return "ended_pending";
  return "live";
}

export async function fetchVisibleClues(supabase, auctionId) {
  const { data, error } = await supabase.rpc("special_auction_visible_clues", {
    p_auction_id: auctionId,
  });
  if (error) {
    console.error("fetchVisibleClues:", error);
    return [];
  }
  return Array.isArray(data) ? data : [];
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
  if (auction.prize_type === "player") {
    if (snapIdentityHidden(auction)) {
      return "Mystery player prize (identity revealed when the snap ends)";
    }
    if (auction.prize_player_id) {
      return `Player prize (ID ${auction.prize_player_id})`;
    }
    return "Player prize";
  }
  if (auction.prize_type === "cash" && auction.prize_cash_amount) {
    return `Cash prize ${formatMoney(auction.prize_cash_amount)}`;
  }
  if (auction.prize_type === "discount") {
    return auction.prize_discount_label || "Discount prize";
  }
  return "Prize TBC";
}
