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

/** Default / configured snap per-bid fee. */
export function snapBidUnitFee(auction) {
  const n = Number(auction?.snap_bid_fee);
  return Number.isFinite(n) && n > 0 ? n : 300000;
}

/**
 * Fee to show for one snap bid row.
 * Live / pending: full unit fee (pending settlement).
 * Settled: fee_charged if set, else derive winner=100% / loser=25%.
 */
export function snapBidFeeDisplay(auction, bid, { settled = false } = {}) {
  const unit = snapBidUnitFee(auction);
  if (!settled) {
    return { amount: unit, pending: true, label: `${formatMoney(unit)} (pending)` };
  }
  if (bid?.fee_charged != null && bid.fee_charged !== "") {
    return {
      amount: Number(bid.fee_charged),
      pending: false,
      label: formatMoney(bid.fee_charged),
    };
  }
  const isWinnerClub =
    auction?.winning_club_id && bid?.club_id === auction.winning_club_id;
  const amount = isWinnerClub ? unit : Math.round(unit * 0.25);
  return { amount, pending: false, label: formatMoney(amount) };
}

/** Total bid fees charged to a club after settlement (sum of per-bid fees). */
export function snapClubBidFeesTotal(auction, bids, clubId) {
  const clubBids = (bids || []).filter((b) => b.club_id === clubId);
  if (!clubBids.length) return 0;
  return clubBids.reduce((sum, b) => {
    const { amount } = snapBidFeeDisplay(auction, b, { settled: true });
    return sum + amount;
  }, 0);
}

/**
 * Multi-line winner summary for settled snap (plain text for winner banner).
 */
export function snapWinnerSummaryText(auction, bids, clubNameFn) {
  if (!auction?.winning_club_id) {
    return "No bids — no winner this auction.";
  }
  const name =
    (typeof clubNameFn === "function"
      ? clubNameFn(auction.winning_club_id)
      : null) || auction.winning_club_id;
  const winAmount = Number(auction.winning_amount) || 0;
  const discountPct = Number(auction.winner_discount_pct) || 0;
  const purchase =
    auction.winner_purchase_amount != null && auction.winner_purchase_amount !== ""
      ? Number(auction.winner_purchase_amount)
      : Math.round(winAmount * (1 - discountPct / 100));
  const bidFees = snapClubBidFeesTotal(auction, bids, auction.winning_club_id);
  const lines = [
    `Winner: ${name}`,
    `Winning bid (before discount): ${formatMoney(winAmount)}`,
    discountPct > 0
      ? `First-bid discount: ${discountPct}% → amount charged: ${formatMoney(purchase)}`
      : `No first-bid discount → amount charged: ${formatMoney(purchase)}`,
    `Bid fees (100% × ${clubBidsCount(bids, auction.winning_club_id)} bid(s)): ${formatMoney(bidFees)}`,
    `Total charged to winner: ${formatMoney(bidFees + purchase)}`,
  ];
  return lines.join("\n");
}

function clubBidsCount(bids, clubId) {
  return (bids || []).filter((b) => b.club_id === clubId).length;
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
  if (typeof auction.snap_bidding_open === "boolean") {
    return auction.snap_bidding_open;
  }
  const end = new Date(specialAuctionEffectiveEnd(auction)).getTime();
  if (!Number.isFinite(end)) return true;
  return Date.now() < end;
}

/** Start of the final 10-minute mystery finish window (start + 50 min). */
export function snapMysteryWindowAt(auction) {
  if (!auction) return null;
  if (auction.snap_mystery_window_at) return auction.snap_mystery_window_at;
  const start = new Date(auction.start_time).getTime();
  if (!Number.isFinite(start)) return null;
  return new Date(start + 50 * 60 * 1000).toISOString();
}

/**
 * Snap timer mode for owners:
 *   before_start | countdown (to mystery window) | countup (mystery window) | ended
 */
export function snapTimerMode(auction) {
  if (!auction || auction.auction_type !== "snap") return null;
  if (!["scheduled", "active"].includes(String(auction.status || ""))) {
    return "ended";
  }
  const now = Date.now();
  const start = new Date(auction.start_time).getTime();
  const mystery = new Date(snapMysteryWindowAt(auction)).getTime();
  if (!Number.isFinite(start)) return "ended";
  if (now < start) return "before_start";
  if (typeof auction.snap_bidding_open === "boolean" && !auction.snap_bidding_open) {
    return "ended";
  }
  // Without open flag, fall back to end_time (hour) only — never trust exposed random end
  const hardEnd = new Date(auction.end_time).getTime();
  if (Number.isFinite(hardEnd) && now >= hardEnd) return "ended";
  if (Number.isFinite(mystery) && now >= mystery) return "countup";
  return "countdown";
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

    // Never leak the secret finish to the client UI
    const mysteryMs = start + 50 * 60 * 1000;
    out.snap_mystery_window_at =
      auction.snap_mystery_window_at || new Date(mysteryMs).toISOString();
    if (typeof auction.snap_bidding_open === "boolean") {
      out.snap_bidding_open = auction.snap_bidding_open;
    } else if (auction.snap_random_end_at) {
      const rnd = new Date(auction.snap_random_end_at).getTime();
      out.snap_bidding_open =
        Date.now() >= start && Number.isFinite(rnd) && Date.now() < rnd;
    } else {
      const hard = new Date(auction.end_time).getTime();
      out.snap_bidding_open =
        Date.now() >= start && Number.isFinite(hard) && Date.now() < hard;
    }
    out.snap_random_end_at = null;
  }
  if (snapIdentityHidden(out)) {
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
  if (!rpcErr) return sanitizeAuctionForOwner(rpcData || null);

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

/**
 * Display / phase end for owners.
 * Snap: never use snap_random_end_at (secret). Use hour end_time for hard stop;
 * live/open is driven by snap_bidding_open from the server.
 */
export function specialAuctionEffectiveEnd(auction) {
  if (!auction) return null;
  return auction.end_time;
}

export function isSpecialAuctionLive(auction) {
  if (!auction) return false;
  if (!["scheduled", "active"].includes(String(auction.status || ""))) return false;
  if (auction.auction_type === "snap" && typeof auction.snap_bidding_open === "boolean") {
    return auction.snap_bidding_open;
  }
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
  if (!rpcErr) return sanitizeAuctionForOwner(rpcData || null);

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
  if (!rpcErr && rpcData) return sanitizeAuctionForOwner(rpcData);

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
  if (!["scheduled", "active"].includes(auction.status)) return auction.status;

  if (auction.auction_type === "snap") {
    const mode = snapTimerMode(auction);
    if (mode === "before_start") return "before_start";
    if (mode === "ended") return "ended_pending";
    return "live";
  }

  const now = Date.now();
  const start = new Date(auction.start_time).getTime();
  const end = new Date(specialAuctionEffectiveEnd(auction)).getTime();
  if (now < start) return "before_start";
  if (now >= end) return "ended_pending";
  return "live";
}

/** Owner-facing snap timer lines (countdown to window, then count-up). */
export function formatSnapAuctionTimer(auction) {
  const mode = snapTimerMode(auction);
  if (!mode) return null;
  if (mode === "before_start") {
    return formatAuctionTimerText("Bidding opens in", auction.start_time);
  }
  if (mode === "ended") {
    return {
      duration: "Snap finished",
      subline: "Bidding closed — waiting for settlement / results",
    };
  }
  const mysteryIso = snapMysteryWindowAt(auction);
  const mystery = new Date(mysteryIso).getTime();
  if (mode === "countdown") {
    const ms = Math.max(0, mystery - Date.now());
    return {
      duration: `Random finish window in: ${formatDurationMs(ms)}`,
      subline: "Final 10 minutes will count up — auction can end at any moment then",
    };
  }
  // countup
  const elapsed = Math.max(0, Date.now() - mystery);
  return {
    duration: `Random finish window: ${formatDurationMs(elapsed)}`,
    subline: "Counting up — auction can end at any moment",
  };
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
