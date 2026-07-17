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

  // Client fallback: pending prize for any settled row, then recent settled/revealed
  const cutoff = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();

  const { data: pendingPrize } = await supabase
    .from("special_auctions")
    .select("*")
    .eq("status", "settled")
    .eq("winner_prize_pending", true)
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (pendingPrize) return sanitizeAuctionForOwner(pendingPrize);

  const { data: settled } = await supabase
    .from("special_auctions")
    .select("*")
    .eq("status", "settled")
    .gt("end_time", cutoff)
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (settled) return sanitizeAuctionForOwner(settled);

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

/** True if a revealed/settled auction is still within the results window. */
export function isRecentRevealedAuction(auction, maxAgeMs = 7 * 24 * 60 * 60 * 1000) {
  if (!auction) return false;
  const status = String(auction.status || "");
  if (status === "settled" && auction.winner_prize_pending) return true;
  if (status !== "revealed" && status !== "settled") return false;
  const end = new Date(
    specialAuctionEffectiveEnd(auction) || auction.end_time || auction.updated_at
  ).getTime();
  if (!Number.isFinite(end)) return false;
  return Date.now() - end <= maxAgeMs;
}

/** Published in nav / owner pages (live, upcoming, or recent results). */
export function isSpecialAuctionPublished(auction) {
  if (!auction) return false;
  const status = String(auction.status || "");
  if (status === "scheduled" || status === "active") return true;
  if (status === "settled" && auction.winner_prize_pending) return true;
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

export const SPECIAL_AUCTION_SQUAD_MAX = 28;

export async function fetchClubSquadSize(supabase, clubShort) {
  if (!clubShort) return 0;
  const { count, error } = await supabase
    .from("Players")
    .select("Konami_ID", { count: "exact", head: true })
    .eq("Contracted_Team", clubShort);
  if (error) {
    console.error("fetchClubSquadSize:", error);
    return 0;
  }
  return Number(count) || 0;
}

export async function fetchPrizePlayerBrief(supabase, playerId) {
  if (!playerId) return null;
  const { data, error } = await supabase
    .from("Players")
    .select("Konami_ID, Name, Position, Rating, market_value, Contracted_Team")
    .eq("Konami_ID", playerId)
    .maybeSingle();
  if (error) {
    console.error("fetchPrizePlayerBrief:", error);
    return null;
  }
  return data;
}

/** Full GPSL career bundle (totals, honours, awards) for prize panels. */
export async function fetchPlayerCareerBundle(supabase, playerId) {
  if (!playerId) return null;
  const { data, error } = await supabase.rpc("competition_player_career_bundle", {
    p_player_id: String(playerId),
  });
  if (error) {
    if (!/competition_player_career_bundle|schema cache|Could not find/i.test(error.message || "")) {
      console.warn("competition_player_career_bundle:", error);
    }
    return null;
  }
  return data;
}

function escPrizeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function formatCareerAwardChip(a) {
  const type = String(a?.award_type || "");
  const season = a?.season_label || "";
  if (type === "ballon_dor") return `Ballon d'Or${season ? ` (${season})` : ""}`;
  if (type === "golden_boot") return `Golden Boot${season ? ` (${season})` : ""}`;
  if (type === "championship_player_of_season") {
    return `Champ Player of Season${season ? ` (${season})` : ""}`;
  }
  if (type === "team_of_season") return `Team of the Season${season ? ` (${season})` : ""}`;
  if (type === "team_of_month" || type === "championship_team_of_month") {
    const month = a?.gpsl_month || a?.metadata?.gpsl_month || "";
    return `Team of the Month${month || season ? ` (${month || season})` : ""}`;
  }
  return a?.award_label || type || "Award";
}

/**
 * Compact GPSL all-time stats + trophy haul for auction prize panels.
 * @param {object|null} bundle from competition_player_career_bundle
 * @param {{ playerId?: string, medalsHtml?: string }} opts
 */
export function renderPrizeCareerStatsHtml(bundle, opts = {}) {
  const totals = bundle?.totals || {};
  const honours = Array.isArray(bundle?.honours) ? bundle.honours : [];
  const awards = Array.isArray(bundle?.awards) ? bundle.awards : [];
  const playerId = opts.playerId || bundle?.player?.player_id || "";
  const careerHref = playerId
    ? `player_career.html?id=${encodeURIComponent(playerId)}`
    : "";

  const apps = Number(totals.appearances) || 0;
  const goals = Number(totals.goals) || 0;
  const assists = Number(totals.assists) || 0;
  const potm = Number(totals.potm_awards) || 0;
  const cs = Number(totals.clean_sheets) || 0;
  const avg =
    totals.avg_rating != null && totals.avg_rating !== ""
      ? Number(totals.avg_rating).toFixed(2)
      : "—";
  const yc = Number(totals.yellow_cards) || 0;
  const rc = Number(totals.red_cards) || 0;

  const hasAnyCareer =
    apps > 0 || goals > 0 || assists > 0 || potm > 0 || honours.length > 0 || awards.length > 0;

  const statsRow = `
    <div class="sa-career-stats">
      <div class="sa-career-heading">All-time GPSL stats</div>
      <div class="sa-career-totals">
        <span><b>Apps</b> ${apps}</span>
        <span><b>Goals</b> ${goals}</span>
        <span><b>Assists</b> ${assists}</span>
        <span><b>POTM</b> ${potm}</span>
        <span><b>CS</b> ${cs}</span>
        <span><b>Avg</b> ${avg}</span>
        <span><b>YC</b> ${yc}</span>
        <span><b>RC</b> ${rc}</span>
      </div>
    </div>`;

  let trophiesBlock = "";
  if (honours.length) {
    const medals =
      opts.medalsHtml ||
      `<p class="sa-career-empty">${honours.length} winner medal${
        honours.length === 1 ? "" : "s"
      }</p>`;
    trophiesBlock = `
      <div class="sa-career-trophies">
        <div class="sa-career-heading">Trophy haul</div>
        ${medals}
      </div>`;
  } else {
    trophiesBlock = `
      <div class="sa-career-trophies">
        <div class="sa-career-heading">Trophy haul</div>
        <p class="sa-career-empty">No league/cup winner medals yet.</p>
      </div>`;
  }

  let awardsBlock = "";
  if (awards.length) {
    const chips = awards
      .slice(0, 8)
      .map((a) => `<span class="sa-award-chip">${escPrizeHtml(formatCareerAwardChip(a))}</span>`)
      .join("");
    const more =
      awards.length > 8
        ? `<span class="sa-career-empty">+${awards.length - 8} more</span>`
        : "";
    awardsBlock = `
      <div class="sa-career-awards">
        <div class="sa-career-heading">Individual awards</div>
        <div class="sa-award-chips">${chips}${more}</div>
      </div>`;
  }

  const foot = careerHref
    ? `<a class="sa-career-link" href="${careerHref}">Full player career →</a>`
    : "";

  if (!hasAnyCareer && !bundle) {
    return `
      <div class="sa-career-block">
        <p class="sa-career-empty">GPSL career stats unavailable.</p>
        ${foot}
      </div>`;
  }

  return `
    <div class="sa-career-block">
      ${statsRow}
      ${trophiesBlock}
      ${awardsBlock}
      ${foot}
    </div>`;
}

export async function fetchPrizeActiveListing(supabase, playerId, clubShort) {
  if (!playerId || !clubShort) return null;
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("id, status, reserve_price, end_time")
    .eq("player_id", String(playerId))
    .eq("seller_club_id", clubShort)
    .eq("status", "Active")
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) {
    console.error("fetchPrizeActiveListing:", error);
    return null;
  }
  return data;
}

/** Winner can keep only when squad ≤ 28 (prize already on the books). */
export function winnerCanKeepPrize(squadSize) {
  return Number(squadSize) <= SPECIAL_AUCTION_SQUAD_MAX;
}

export async function winnerKeepPrize(supabase, auctionId) {
  return supabase.rpc("special_auction_winner_keep_prize", {
    p_auction_id: auctionId,
  });
}

export async function winnerListPrize(supabase, auctionId) {
  return supabase.rpc("special_auction_winner_list_prize_player", {
    p_auction_id: auctionId,
  });
}

export async function winnerReleasePrize(supabase, auctionId, _playerId = null) {
  // Single-arg RPC only — prize player comes from the auction row server-side
  return supabase.rpc("special_auction_winner_release_player", {
    p_auction_id: auctionId,
  });
}

/** Release a current squad player (not the prize) at MV to unlock Keep-only path. */
export async function winnerReleaseSquadForKeep(supabase, auctionId, playerId) {
  return supabase.rpc("special_auction_winner_release_squad_for_keep", {
    p_auction_id: auctionId,
    p_player_id: String(playerId),
  });
}

/** Squad players eligible to release while deciding on a special-auction prize. */
export async function fetchSquadPlayersForPrizeKeepPrep(
  supabase,
  clubShort,
  prizePlayerId
) {
  if (!clubShort) return [];
  const { data, error } = await supabase
    .from("Players")
    .select("Konami_ID, Name, Position, Rating, market_value")
    .eq("Contracted_Team", clubShort)
    .order("Name", { ascending: true });
  if (error) {
    console.error("fetchSquadPlayersForPrizeKeepPrep:", error);
    return [];
  }
  const prize = prizePlayerId != null ? String(prizePlayerId) : "";
  return (data || []).filter((p) => String(p.Konami_ID) !== prize);
}
