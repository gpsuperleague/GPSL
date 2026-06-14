// ============================================================
// GLOBAL.JS — SINGLE SOURCE OF TRUTH FOR THE ENTIRE DRAFT SYSTEM
// ============================================================

import { supabase } from "./supabase_client.js";
import {
  getDraftTimelineFromStart,
  getDraftPhaseFromStart,
  getDraftCountdownTick,
  getManagerDraftCountdownTick,
  getClubAuctionCountdownTick,
  isDraftAuctionEnded as isDraftAuctionEndedWithOptions,
} from "./draft_timeline.js";
import {
  formatDurationMs,
  formatLiveCountdownLines,
  formatDraftConclusionLines,
  prefixDraftCountdownDuration,
  formatTargetTimesSubline,
  isValidInstant,
} from "./countdown_display.js";
import { countUnreadInbox } from "./competition_inbox.js";
import { initDashboardPinUi } from "./dashboard_pin.js";
import { nationFlagSrc } from "./international_flags.js";
import { formatNavLabel } from "./nav_label.js";
export { supabase };

/** Bump when nav/admin chrome changes (cache bust for dynamic imports). */
export const GLOBAL_JS_VERSION = "20260608-admin-flyout";

/** League admin logins (nav Admin link + must match Supabase is_gpsl_admin()). */
export const GPSL_ADMIN_EMAILS = ["rotavator66@outlook.com"];

export function isGpslAdminUser(user) {
  const email = (user?.email || "").trim().toLowerCase();
  return GPSL_ADMIN_EMAILS.some((a) => a.toLowerCase() === email);
}

export function isAdminPagePath(pathNorm) {
  const p = (pathNorm || "").toLowerCase();
  return p === "admin.html" || /^admin[_-]/.test(p);
}

// ------------------------------------------------------------
// GLOBAL STATE
// ------------------------------------------------------------
let draftEnabled = false;
let managerDraftEnabled = false;
let clubAuctionEnabled = false;
let draftStart = null;        // Day 1 @ 19:00 UK
let draftCutoff = null;       // Day 2 @ 18:00 UK
let draftRandomStart = null;  // Day 2 @ 18:50 UK
let draftPublicEnd = null;    // Latest possible end (18:59:59 day 2) — not secret finish
let draftBiddingOpen = null;  // combined bid gate for engine helpers
let playerDraftBiddingOpen = null;
let managerDraftBiddingOpen = null;
let clubAuctionBiddingOpen = null;
let draftRandomLockedMs = null; // frozen count-up offset when secret finish fires
let draftRandomFinishRevealed = null; // exposed only after now() >= secret finish

// Countdown interval
let __draftCountdownInterval = null;

export function getDraftBiddingOpen() {
  return draftBiddingOpen;
}

/** Engine/bid-lock phase options (real server bidding state). */
export function getDraftPhaseOptions() {
  return draftEnginePhaseOptions();
}

/** Countdown UI tick options (may defer random lock until finish is revealed). */
export function getDraftCountdownOptions() {
  return draftCountdownUiOptions();
}

export function getManagerDraftEnabled() {
  return managerDraftEnabled;
}

export function getDraftAuctionStartTime() {
  return draftStart;
}

function isDraftCountdownActive() {
  return (
    (draftEnabled || managerDraftEnabled || clubAuctionEnabled) && isValidDate(draftStart)
  );
}

/** True when draft_auction_start_time is missing or the Day-2 window has fully passed. */
export function isDraftScheduleExpired(draftAuctionStartTime = draftStart) {
  if (!isValidDate(draftAuctionStartTime)) return true;
  return getDraftPhaseFromStart(getUKNow(), draftAuctionStartTime) === "ended";
}

function syncDraftRandomLockFromRevealedFinish() {
  if (!draftRandomFinishRevealed || !isValidDate(draftStart)) {
    return;
  }
  const finish = new Date(draftRandomFinishRevealed);
  if (!isValidDate(finish)) return;
  const timeline = getDraftTimelineFromStart(draftStart);
  if (!timeline) return;
  draftRandomLockedMs = Math.max(0, finish.getTime() - timeline.randomStart.getTime());
}

/** Freeze count-up only once draft_random_finish_revealed is available from the server. */
function ensureDraftRandomWindowFrozen() {
  if (!draftRandomFinishRevealed || !isValidDate(draftStart)) {
    draftRandomLockedMs = null;
    return;
  }
  syncDraftRandomLockFromRevealedFinish();
}

function applyDraftRandomFinishRevealed(data) {
  if (!data) return;
  const raw = data.draft_random_finish_revealed;
  if (raw) {
    draftRandomFinishRevealed = raw;
    syncDraftRandomLockFromRevealedFinish();
    return;
  }
  if (!("draft_random_finish_revealed" in data)) return;
  const biddingOpenNow =
    ("draft_bidding_open" in data && data.draft_bidding_open === true) ||
    ("manager_draft_bidding_open" in data && data.manager_draft_bidding_open === true);
  if (biddingOpenNow) {
    draftRandomFinishRevealed = null;
  }
}

function resolveRevealedFinishInstant(tickFinish) {
  const fromTick =
    tickFinish instanceof Date ? tickFinish : tickFinish ? new Date(tickFinish) : null;
  if (isValidInstant(fromTick)) return fromTick;
  if (!draftRandomFinishRevealed) return null;
  const fromGlobal = new Date(draftRandomFinishRevealed);
  return isValidDate(fromGlobal) ? fromGlobal : null;
}

function recomputeCombinedDraftBiddingOpen() {
  if (draftEnabled && managerDraftEnabled) {
    draftBiddingOpen =
      playerDraftBiddingOpen === true || managerDraftBiddingOpen === true;
  } else if (draftEnabled) {
    draftBiddingOpen = playerDraftBiddingOpen;
  } else if (managerDraftEnabled) {
    draftBiddingOpen =
      managerDraftBiddingOpen !== null ? managerDraftBiddingOpen : playerDraftBiddingOpen;
  } else {
    draftBiddingOpen = false;
  }
}

function buildRevealedFinishOptions(opts) {
  if (!draftRandomFinishRevealed) return opts;
  opts.finishRevealed = true;
  opts.biddingOpen = false;
  const finish = new Date(draftRandomFinishRevealed);
  if (isValidDate(finish)) {
    opts.finishInstant = finish;
  }
  if (draftRandomLockedMs != null) {
    opts.frozenMs = draftRandomLockedMs;
  }
  return opts;
}

function draftEnginePhaseOptions() {
  ensureDraftRandomWindowFrozen();
  const opts = {};
  if (draftBiddingOpen !== null) {
    opts.biddingOpen = draftBiddingOpen;
  }
  return buildRevealedFinishOptions(opts);
}

function draftCountdownUiBiddingOpen() {
  if (draftRandomFinishRevealed) return false;

  const timeline = getDraftTimelineFromStart(draftStart);
  const now = getUKNow();
  const inRandomWindow =
    timeline && now >= timeline.randomStart && now < timeline.publicEnd;

  const kind = pageDraftKindHint() || getDraftCountdownKind();

  if (kind === "club") {
    if (clubAuctionBiddingOpen === false && inRandomWindow) return true;
    return clubAuctionBiddingOpen;
  }

  // Server closed bids but finish not revealed yet — keep count-up running in UI.
  if (draftBiddingOpen === false && inRandomWindow) return true;

  return draftBiddingOpen;
}

function draftCountdownUiOptions() {
  ensureDraftRandomWindowFrozen();

  const opts = {};
  const uiBiddingOpen = draftCountdownUiBiddingOpen();

  if (uiBiddingOpen !== null && uiBiddingOpen !== undefined) {
    opts.biddingOpen = uiBiddingOpen;
  }

  return buildRevealedFinishOptions(opts);
}

function pageDraftKindHint() {
  if (typeof window === "undefined") return null;
  const page = String(window.CURRENT_PAGE || "").toLowerCase();
  const path = String(window.location?.pathname || "").toLowerCase();

  if (
    page === "manager_draftauction" ||
    page === "manager_draftauction_manager" ||
    page === "mgdb" ||
    /manager_draftauction|mgdb\.html/.test(path)
  ) {
    return "manager";
  }
  if (
    page === "draftauction" ||
    page === "draftauction_player" ||
    page === "gpdb" ||
    /draftauction|gpdb\.html/.test(path)
  ) {
    return "player";
  }
  if (page === "awaiting_club" || /awaiting_club|club_auction/.test(path)) {
    return "club";
  }
  return null;
}

/** Which draft timer labels to show — page-specific so MGDB/GPDB never share the wrong auction. */
export function getDraftCountdownKind() {
  const hint = pageDraftKindHint();
  if (hint) return hint;

  if (managerDraftEnabled && !draftEnabled) return "manager";
  if (draftEnabled && !managerDraftEnabled) return "player";

  if (managerDraftEnabled && draftEnabled) {
    if (managerDraftBiddingOpen === true && playerDraftBiddingOpen !== true) {
      return "manager";
    }
    if (playerDraftBiddingOpen === true && managerDraftBiddingOpen !== true) {
      return "player";
    }
    return "manager";
  }

  if (clubAuctionEnabled && !draftEnabled && !managerDraftEnabled) return "club";

  return managerDraftEnabled ? "manager" : "player";
}

function getPageDraftCountdownKind() {
  return getDraftCountdownKind();
}

function draftCountdownEndedSubline(kind) {
  if (kind === "club") {
    return "Club auction finished. Winners are assigned when admin or the transfer engine settles.";
  }
  if (kind === "manager") {
    return "Manager draft finished. Player draft may still be on — check Player Draft Auction / GPDB.";
  }
  if (managerDraftEnabled && draftEnabled) {
    return "Player draft finished. Manager draft may still be on — see Manager Draft Auction / MGDB.";
  }
  return "Previous player draft window finished. Admin → Transfer window → Save settings to schedule the next 7pm UK start.";
}

function getPageDraftCountdownTick(nowUK, start, options) {
  const kind = getPageDraftCountdownKind();
  if (kind === "club") {
    return getClubAuctionCountdownTick(nowUK, start, options);
  }
  if (kind === "manager") {
    return getManagerDraftCountdownTick(nowUK, start, options);
  }
  return getDraftCountdownTick(nowUK, start, options);
}

export function isDraftAuctionEnded(nowUK, draftAuctionStartTime) {
  return isDraftAuctionEndedWithOptions(
    nowUK,
    draftAuctionStartTime,
    draftEnginePhaseOptions()
  );
}

// ------------------------------------------------------------
// UK TIME HELPERS (THE ONLY VERSION USED ANYWHERE)
// ------------------------------------------------------------
/** True current instant — use for countdowns and comparisons with ISO timestamps from Supabase. */
export function getUKNow() {
  return new Date();
}

/** UK wall-clock parts for calendar rules (credits window, etc.). */
export function getUKWallClockParts(at = new Date()) {
  const fmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "numeric",
    second: "numeric",
    hour12: false,
  });

  const parts = fmt.formatToParts(at);
  const map = {};
  parts.forEach((p) => {
    if (p.type && p.value) map[p.type] = p.value;
  });

  return {
    year: Number(map.year),
    month: Number(map.month) - 1,
    day: Number(map.day),
    hour: Number(map.hour),
    minute: Number(map.minute),
    second: Number(map.second),
  };
}

/** Build a real instant for a UK local date/time (DST-safe). */
export function ukLocalToInstant(year, monthIndex, day, hour = 0, minute = 0, second = 0) {
  const guess = new Date(Date.UTC(year, monthIndex, day, hour, minute, second));
  const p = getUKWallClockParts(guess);
  const delta =
    Date.UTC(year, monthIndex, day, hour, minute, second) -
    Date.UTC(p.year, p.month, p.day, p.hour, p.minute, p.second);
  return new Date(guess.getTime() + delta);
}

export function makeUKDate(y, m, d, hh = 0, mm = 0, ss = 0) {
  return new Date(Date.UTC(y, m, d, hh, mm, ss));
}

export function isValidDate(d) {
  return d instanceof Date && !isNaN(d.getTime());
}

/** Day-2 draft start (7pm UK) and secret random finish (6:50:00–6:59:58 UK). */
export function computeNextDraftTimesFromNow() {
  const uk = getUKWallClockParts(getUKNow());
  const startDay = uk.hour >= 19 ? uk.day + 1 : uk.day;
  const start = ukLocalToInstant(uk.year, uk.month, startDay, 19, 0, 0);
  const timeline = getDraftTimelineFromStart(start);
  if (!timeline) {
    return { draftStartISO: null, randomFinishISO: null };
  }

  const maxOffsetSec = 9 * 60 + 58;
  const offsetSec = Math.floor(Math.random() * (maxOffsetSec + 1));
  const finish = new Date(timeline.randomStart.getTime() + offsetSec * 1000);

  return {
    draftStartISO: start.toISOString(),
    randomFinishISO: finish.toISOString(),
  };
}

/**
 * Standard transfer list end: at least 24h from start, or next 19:00 UK — whichever is later.
 * Used for squad listings, Transfer Centre list/extend, and accepted direct offers.
 */
export function computeStandardListingEndTime(fromInstant = new Date()) {
  const minEndInstant = new Date(fromInstant.getTime() + 24 * 60 * 60 * 1000);

  const fmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "numeric",
    second: "numeric",
    hour12: false,
  });

  const parts = fmt.formatToParts(minEndInstant);
  const map = {};
  parts.forEach((p) => {
    if (p.type !== "literal") map[p.type] = Number(p.value);
  });

  let endDay = map.day;
  if (
    map.hour > 19 ||
    (map.hour === 19 && (map.minute > 0 || map.second > 0))
  ) {
    endDay += 1;
  }

  const next19Uk = ukLocalToInstant(map.year, map.month - 1, endDay, 19, 0, 0);

  return minEndInstant.getTime() > next19Uk.getTime() ? minEndInstant : next19Uk;
}

// ------------------------------------------------------------
// PHASE ENGINE — THE HEART OF THE SYSTEM
// ------------------------------------------------------------
export function getDraftPhase() {
  if (!draftEnabled || !isValidDate(draftStart)) {
    return "disabled";
  }

  return getDraftPhaseFromStart(new Date(), draftStart);
}

// ------------------------------------------------------------
// CENTRAL BIDDING ELIGIBILITY
// ------------------------------------------------------------
export async function canClubBid(clubShort, playerId) {
  const phase = getDraftPhase();
  if (phase === "disabled" || phase === "before_start" || phase === "ended") {
    return { ok: false, reason: "Draft not active" };
  }

  const now = getUKNow();

  const winStart = draftStart ? draftStart.toISOString() : null;
  const winEnd = (draftPublicEnd || draftCutoff)?.toISOString?.() ?? null;

  let query = supabase
    .from("Player_Transfer_Bids")
    .select("bidder_club_id, is_first_draft_bid, is_draft_join, draft_join_consumed, bid_time")
    .eq("is_direct", true)
    .is("seller_club_id", null)
    .order("bid_time", { ascending: true });

  if (winStart) query = query.gte("bid_time", winStart);
  if (winEnd) query = query.lt("bid_time", winEnd);

  const key = String(playerId ?? "").trim();
  const num = Number(key);
  if (Number.isFinite(num)) {
    query = query.or(`direct_bid_id.eq.${key},direct_bid_id.eq.${num}`);
  } else {
    query = query.eq("direct_bid_id", key);
  }

  const { data: bids } = await query;

  const hasBids = bids && bids.length > 0;
  const firstBidder = hasBids ? bids[0].bidder_club_id : null;

  // NEW AUCTIONS LOCK AT CUTOFF
  if (!hasBids && now >= draftCutoff) {
    return { ok: false, reason: "New auctions locked after cutoff" };
  }

  if (phase === "ended") {
    return { ok: false, reason: "Draft ended" };
  }

  // FIRST BIDDER ALWAYS ALLOWED during active phases
  if (clubShort === firstBidder) {
    return { ok: true, reason: "First bidder" };
  }

  // JOINERS
  if (hasBids) {
    const priorJoin = bids.some(
      b => b.bidder_club_id === clubShort && b.is_draft_join
    );
    if (priorJoin) {
      return { ok: true, reason: "Already joined" };
    }

    const credits = await getCredits(clubShort);
    if (credits <= 0) {
      return { ok: false, reason: "No credits" };
    }

    return { ok: true, reason: "Has credits" };
  }

  return { ok: false, reason: "Unknown state" };
}

// ------------------------------------------------------------
// CENTRAL CREDITS ENGINE
// ------------------------------------------------------------
export async function getCredits(clubShort) {
  const uk = getUKWallClockParts();
  const noon = ukLocalToInstant(uk.year, uk.month, uk.day, 12, 0, 0);
  const yest = getUKWallClockParts(new Date(noon.getTime() - 24 * 60 * 60 * 1000));
  const winStart = ukLocalToInstant(yest.year, yest.month, yest.day, 19, 0, 0);

  const winEnd = draftCutoff; // 18:00 UK day 2 from draft timeline

  // First bids
  const { data: firsts } = await supabase
    .from("Player_Transfer_Bids")
    .select("direct_bid_id")
    .eq("bidder_club_id", clubShort)
    .eq("is_first_draft_bid", true)
    .gte("bid_time", winStart.toISOString())
    .lt("bid_time", winEnd.toISOString());

  const firstCount = firsts ? firsts.length : 0;

  // Join fees consumed
  const { data: joins } = await supabase
    .from("Player_Transfer_Bids")
    .select("direct_bid_id")
    .eq("bidder_club_id", clubShort)
    .eq("is_draft_join", true)
    .eq("draft_join_consumed", true)
    .gte("bid_time", winStart.toISOString())
    .lt("bid_time", (draftPublicEnd || draftCutoff || winEnd).toISOString());

  const joinCount = joins ? new Set(joins.map(j => j.direct_bid_id)).size : 0;

  return (firstCount * 2) - joinCount;
}

// ------------------------------------------------------------
// COUNTDOWN ENGINE (USED BY ALL PAGES)
// ------------------------------------------------------------
function formatMs(ms) {
  return formatDurationMs(ms);
}

function msUntil(target) {
  if (!isValidDate(target)) return 0;
  return target.getTime() - Date.now();
}

export async function refreshDraftBiddingOpen() {
  if (!draftEnabled && !managerDraftEnabled) {
    draftBiddingOpen = false;
    draftRandomLockedMs = null;
    draftRandomFinishRevealed = null;
    return;
  }
  const wasOpen = draftBiddingOpen === true;
  let data = null;
  const selectAttempts = [
    "draft_bidding_open, manager_draft_bidding_open, draft_random_finish_revealed",
    "draft_bidding_open, manager_draft_bidding_open",
    "draft_bidding_open, draft_random_finish_revealed",
    "draft_bidding_open",
  ];
  for (const select of selectAttempts) {
    const { data: row, error } = await queryGlobalSettingsPublic(select);
    if (!error) {
      data = row;
      break;
    }
    if (select === selectAttempts[selectAttempts.length - 1]) {
      console.warn(
        "refreshDraftBiddingOpen failed — run repair_global_settings_public.sql",
        error
      );
      return;
    }
  }

  applyDraftBiddingOpenFromSettings(data);
  applyDraftRandomFinishRevealed(data);
  const nowOpen = draftBiddingOpen;

  if (wasOpen && nowOpen === false) {
    ensureDraftRandomWindowFrozen();
  }
  if (nowOpen === true) {
    draftRandomLockedMs = null;
    draftRandomFinishRevealed = null;
  } else if (!draftRandomFinishRevealed) {
    draftRandomLockedMs = null;
  }
}

export function startDraftCountdown(onTick) {
  stopDraftCountdown();

  const tick = async () => {
    if (isDraftCountdownActive()) {
      await refreshDraftBiddingOpen();
    }
    const tickData = getPageDraftCountdownTick(
      getUKNow(),
      draftStart,
      draftCountdownUiOptions()
    );
    if (onTick) onTick(tickData);
  };

  tick();
  __draftCountdownInterval = setInterval(tick, 1000);
}

function ensureDraftLocalStartEl(countdownEl) {
  let localEl = document.getElementById("draftLocalStart");
  if (localEl || !countdownEl?.parentElement) return localEl;

  localEl = document.createElement("div");
  localEl.id = "draftLocalStart";
  localEl.style.fontSize = "12px";
  localEl.style.color = "#ccc";
  localEl.style.marginTop = "4px";
  localEl.style.whiteSpace = "pre-line";
  localEl.style.lineHeight = "1.4";
  countdownEl.parentElement.appendChild(localEl);
  return localEl;
}

/** Updates #draftCountdown / #draftLocalStart when present (dashboard, GPDB, draft auction). */
export function wireDraftCountdownUI() {
  const el = document.getElementById("draftCountdown");
  const container = document.getElementById("draftCountdownContainer");
  if (!el) return;

  const localEl = ensureDraftLocalStartEl(el);

  if (!isDraftCountdownActive()) {
    if (container) container.style.display = "none";
    stopDraftCountdown();
    return;
  }

  if (container) container.style.display = "";

  startDraftCountdown((tick) => {
    const { phase, ms, label, target, countUp, frozen, finishInstant } = tick;
    const kind = getPageDraftCountdownKind();
    const revealedFinish = resolveRevealedFinishInstant(finishInstant);
    if (phase === "ended") {
      if (isValidInstant(revealedFinish)) {
        const { duration, subline } = formatDraftConclusionLines(revealedFinish, kind);
        el.textContent = duration;
        if (localEl) localEl.textContent = subline;
      } else {
        el.textContent = prefixDraftCountdownDuration(label, kind);
        if (localEl) {
          localEl.textContent = draftCountdownEndedSubline(kind);
        }
      }
      return;
    }

    const { duration, subline } = formatLiveCountdownLines(label, ms, target, {
      countUp,
      frozen,
      finishInstant: revealedFinish,
    });
    el.textContent = prefixDraftCountdownDuration(duration, kind);
    if (localEl) {
      localEl.textContent =
        subline || (!frozen && target ? formatTargetTimesSubline(target) : "");
    }
  });
}

export function stopDraftCountdown() {
  if (__draftCountdownInterval) {
    clearInterval(__draftCountdownInterval);
    __draftCountdownInterval = null;
  }
}

// ------------------------------------------------------------
// LOAD GLOBAL SETTINGS (THE ONLY PLACE THAT DOES THIS)
// ------------------------------------------------------------
async function queryGlobalSettingsPublic(select) {
  const { data, error } = await supabase
    .from("global_settings_public")
    .select(select)
    .eq("id", 1)
    .single();
  if (error) return { data: null, error };
  return { data, error: null };
}

function applyDraftBiddingOpenFromSettings(data) {
  if (!data) return;

  if ("draft_auction_enabled" in data) {
    draftEnabled = data.draft_auction_enabled === true;
  }
  if ("manager_draft_auction_enabled" in data) {
    managerDraftEnabled = data.manager_draft_auction_enabled === true;
  }
  if ("club_auction_enabled" in data) {
    clubAuctionEnabled = data.club_auction_enabled === true;
  }
  if ("draft_bidding_open" in data) {
    playerDraftBiddingOpen = data.draft_bidding_open === true;
  }
  if ("manager_draft_bidding_open" in data) {
    managerDraftBiddingOpen = data.manager_draft_bidding_open === true;
  }
  if ("club_auction_bidding_open" in data) {
    clubAuctionBiddingOpen = data.club_auction_bidding_open === true;
  }

  recomputeCombinedDraftBiddingOpen();
}

export async function loadGlobalSettings() {
  let data = null;
  const selects = [
    "transfer_window_open, draft_auction_enabled, manager_draft_auction_enabled, club_auction_enabled, draft_auction_start_time, draft_bidding_open, manager_draft_bidding_open, club_auction_bidding_open, draft_random_finish_revealed",
    "transfer_window_open, draft_auction_enabled, manager_draft_auction_enabled, draft_auction_start_time, draft_bidding_open, manager_draft_bidding_open, draft_random_finish_revealed",
    "transfer_window_open, draft_auction_enabled, manager_draft_auction_enabled, draft_auction_start_time, draft_bidding_open, manager_draft_bidding_open",
    "transfer_window_open, draft_auction_enabled, draft_auction_start_time, draft_bidding_open",
    "transfer_window_open, draft_auction_enabled, draft_auction_start_time",
  ];

  for (let i = 0; i < selects.length; i++) {
    const { data: row, error } = await queryGlobalSettingsPublic(selects[i]);
    if (!error) {
      data = row;
      break;
    }
    if (i === selects.length - 1) {
      console.error("loadGlobalSettings:", error);
    } else if (i === 0) {
      console.warn(
        "loadGlobalSettings: manager draft columns missing — run repair_global_settings_public.sql",
        error
      );
    }
  }

  applyDraftBiddingOpenFromSettings(data);

  const rawStart = new Date(data?.draft_auction_start_time);
  draftStart = isValidDate(rawStart) ? new Date(rawStart) : null;

  const timeline = getDraftTimelineFromStart(draftStart);
  draftCutoff = timeline?.cutoff ?? null;
  draftRandomStart = timeline?.randomStart ?? null;
  draftPublicEnd = timeline?.publicEnd ?? null;

  applyDraftRandomFinishRevealed(data);
  ensureDraftRandomWindowFrozen();

  return {
    draftEnabled,
    managerDraftEnabled,
    clubAuctionEnabled,
    draftStart,
    draftCutoff,
    draftRandomStart,
    draftPublicEnd,
    draftBiddingOpen,
    transferWindowOpen: data?.transfer_window_open === true,
  };
}

// ------------------------------------------------------------
// NAV — owner club (inbox badge)
// ------------------------------------------------------------
function clubBadgeSrc(shortName) {
  const code = String(shortName ?? "").trim();
  if (!code) return null;
  return `images/club_badges/${code}.png`;
}

function renderNavOwnerClubBadge(ownerClub) {
  if (!ownerClub?.short) return "";
  const src = clubBadgeSrc(ownerClub.short);
  if (!src) return "";
  const title = escapeNavAttr(ownerClub.name || ownerClub.short);
  return (
    `<a href="club_details.html" class="nav-owner-club" title="${title}" aria-label="${title}">` +
    `<img class="nav-owner-club-badge" src="${escapeNavAttr(src)}" alt="" loading="lazy" ` +
    `onerror="this.parentElement.style.display='none'">` +
    `</a>`
  );
}

async function getOwnerClub() {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;
  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();
  if (!club?.ShortName) return null;
  const short = club.ShortName.trim();
  return {
    short,
    name: (club.Club || short).trim(),
  };
}

async function getOwnerClubShort() {
  const club = await getOwnerClub();
  return club?.short || null;
}

/** Update nav inbox badge after mark-read (no full nav rebuild). */
export async function refreshInboxNavBadge() {
  const link = document.querySelector("a.nav-inbox");
  if (!link) return;

  try {
    const clubShort = await getOwnerClubShort();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const unread =
      clubShort || user?.id
        ? await countUnreadInbox(supabase, clubShort, user?.id ?? null)
        : 0;

    link.classList.toggle("has-unread", unread > 0);
    link.setAttribute(
      "aria-label",
      unread > 0 ? `Inbox, ${unread} unread` : "Inbox"
    );

    let badge = link.querySelector(".nav-inbox-badge");
    if (unread > 0) {
      const label = unread > 99 ? "99+" : String(unread);
      if (badge) {
        badge.textContent = label;
      } else {
        badge = document.createElement("span");
        badge.className = "nav-inbox-badge";
        badge.textContent = label;
        link.appendChild(badge);
      }
    } else if (badge) {
      badge.remove();
    }
  } catch (err) {
    console.warn("refreshInboxNavBadge:", err);
  }
}

async function fetchActiveSpecialAuctionNavItem() {
  try {
    const nowIso = new Date().toISOString();
    const { data: sa } = await supabase
      .from("special_auctions")
      .select("id, title, start_time")
      .in("status", ["scheduled", "active"])
      .gt("end_time", nowIso)
      .order("start_time", { ascending: true })
      .limit(1)
      .maybeSingle();

    if (!sa) return null;

    const starts = new Date(sa.start_time);
    const beforeStart = Date.now() < starts.getTime();
    const label = beforeStart
      ? `Special Auction (${starts.toLocaleString("en-GB", { hour: "2-digit", minute: "2-digit", day: "numeric", month: "short" })})`
      : "Special Auction";

    return {
      href: "special_auction.html",
      label,
      page: "special_auction",
    };
  } catch (_) {
    return null;
  }
}

/** Legacy inline navs (draftauction.html, etc.) */
export async function specialAuctionNavLinkHtml() {
  const path = window.location.pathname.toLowerCase();
  if (path.includes("special_auction")) return "";

  const item = await fetchActiveSpecialAuctionNavItem();
  if (!item) return "";
  return `<a id="nav-special-auction" href="${item.href}" class="button">${item.label}</a>`;
}

/** Load nav layout CSS on every page (many HTML files never linked dashboard.css). */
function ensureNavStyles() {
  if (document.getElementById("gpsl-nav-styles")) return;
  const link = document.createElement("link");
  link.id = "gpsl-nav-styles";
  link.rel = "stylesheet";
  try {
    link.href = new URL("dashboard.css", import.meta.url).href;
  } catch {
    link.href = "dashboard.css";
  }
  document.head.appendChild(link);
}

function escapeNavHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapeNavAttr(s) {
  return escapeNavHtml(s).replace(/"/g, "&quot;");
}

/** Flat links, or collapsible sub-groups when items use `{ heading: true }`. */
function navLinkIconHtml(item) {
  const nationSrc = item.nationCode ? nationFlagSrc(item.nationCode) : null;
  if (nationSrc) {
    return `<img class="nav-nat-flag" src="${escapeNavAttr(nationSrc)}" alt="" loading="lazy" /> `;
  }
  const clubSrc = item.clubShort ? clubBadgeSrc(item.clubShort) : null;
  if (clubSrc) {
    return (
      `<img class="nav-club-badge" src="${escapeNavAttr(clubSrc)}" alt="" loading="lazy" ` +
      `onerror="this.style.display='none'" /> `
    );
  }
  return "";
}

function renderNavDropdownItems(items, pathname, search, isNavItemActive, renderMegaNavHtml) {
  const hasHeadings = items.some(
    (item) => item.heading || item.seasonMega || item.seasonBreakMega || item.ownersMega
  );
  if (!hasHeadings) {
    let flat = "";
    for (const item of items) {
      if (!item.href) continue;
      const active = isNavItemActive(item, pathname, search);
      const indent = item.indent ? " nav-link-sub" : "";
      flat += `<a href="${item.href}" class="nav-link${indent}${
        active ? " active" : ""
      }">${navLinkIconHtml(item)}${escapeNavHtml(formatNavLabel(item.label))}</a>`;
    }
    return flat;
  }

  let topHtml = "";
  let groupHtml = "";
  let panelHtml = "";
  let panelLabel = "";
  let panelHasActive = false;

  const renderLink = (item, active) => {
    const indent = item.indent ? " nav-link-sub" : "";
    const danger = item.navDanger ? " nav-link-danger" : "";
    return `<a href="${item.href}" class="nav-link${indent}${danger}${
      active ? " active" : ""
    }">${navLinkIconHtml(item)}${escapeNavHtml(formatNavLabel(item.label))}</a>`;
  };

  const flushPanel = () => {
    if (!panelLabel) return;
    groupHtml += `<div class="nav-subgroup${panelHasActive ? " open" : ""}" data-nav-subgroup>`;
    groupHtml += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
      panelHasActive ? "true" : "false"
    }">${escapeNavHtml(formatNavLabel(panelLabel))}</button>`;
    groupHtml += `<div class="nav-subgroup-panel" role="group">${panelHtml}</div>`;
    groupHtml += `</div>`;
    panelHtml = "";
    panelLabel = "";
    panelHasActive = false;
  };

  for (const item of items) {
    if (item.seasonMega || item.seasonBreakMega || item.ownersMega) {
      if (renderMegaNavHtml) {
        flushPanel();
        groupHtml += renderMegaNavHtml(item, pathname, search);
      }
      continue;
    }
    if (item.heading) {
      flushPanel();
      panelLabel = item.label;
      continue;
    }
    if (!item.href) continue;

    const active = isNavItemActive(item, pathname, search);
    if (!panelLabel) {
      topHtml += renderLink(item, active);
      continue;
    }

    if (active) panelHasActive = true;
    panelHtml += renderLink(item, active);
  }
  flushPanel();
  return topHtml + groupHtml;
}

function wireNavLogout() {
  const btn = document.getElementById("logoutBtn");
  if (!btn || btn.dataset.wired === "1") return;
  btn.dataset.wired = "1";
  btn.onclick = async () => {
    await supabase.auth.signOut();
    window.location = "login.html";
  };
}

function renderAdminFlyoutHtml(links, pathname) {
  const file = (pathname || "").toLowerCase().replace(/\\/g, "/").split("/").pop() || "";
  let html = "";
  for (const block of links || []) {
    if (block.heading && block.links?.length) {
      html += `<div class="gpsl-admin-flyout-group">`;
      html += `<div class="gpsl-admin-flyout-title">${escapeNavHtml(block.heading)}</div>`;
      for (const link of block.links) {
        const href = link.href || "#";
        const itemFile = href.split("?")[0].split("#")[0].toLowerCase();
        const active = file === itemFile;
        const cls = [
          "gpsl-admin-flyout-link",
          link.home ? "gpsl-admin-flyout-home" : "",
          link.danger ? "gpsl-admin-flyout-link-danger" : "",
          active ? "gpsl-admin-flyout-link-active" : "",
        ]
          .filter(Boolean)
          .join(" ");
        html += `<a href="${escapeNavAttr(href)}" class="${cls}">${escapeNavHtml(
          formatNavLabel(link.label)
        )}</a>`;
      }
      html += `</div>`;
      continue;
    }
    if (!block.href) continue;
    const itemFile = block.href.split("?")[0].split("#")[0].toLowerCase();
    const active = file === itemFile;
    const cls = [
      "gpsl-admin-flyout-link",
      block.home ? "gpsl-admin-flyout-home" : "",
      active ? "gpsl-admin-flyout-link-active" : "",
    ]
      .filter(Boolean)
      .join(" ");
    html += `<a href="${escapeNavAttr(block.href)}" class="${cls}">${escapeNavHtml(
      formatNavLabel(block.label)
    )}</a>`;
  }
  return html;
}

function wireAdminZone(nav) {
  const zone = nav.querySelector("[data-nav-admin-zone]");
  if (!zone || zone.dataset.wired === "1") return;
  zone.dataset.wired = "1";
  const trigger = zone.querySelector(".nav-admin-trigger");
  if (!trigger) return;

  const close = () => {
    zone.classList.remove("open");
    trigger.setAttribute("aria-expanded", "false");
  };

  trigger.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    const willOpen = !zone.classList.contains("open");
    nav.querySelectorAll("[data-nav-group].open").forEach((group) => {
      group.classList.remove("open");
      group.querySelector(".nav-group-summary")?.setAttribute("aria-expanded", "false");
    });
    zone.classList.toggle("open", willOpen);
    trigger.setAttribute("aria-expanded", willOpen ? "true" : "false");
  });

  zone.querySelectorAll(".gpsl-admin-flyout-link").forEach((link) => {
    link.addEventListener("click", () => close());
  });

  if (!nav.dataset.adminZoneOutsideClose) {
    nav.dataset.adminZoneOutsideClose = "1";
    document.addEventListener("click", (e) => {
      if (e.target.closest("[data-nav-admin-zone]")) return;
      close();
    });
  }
}

function wireNavGroups(nav) {
  const groups = nav.querySelectorAll("[data-nav-group]");

  const closeAll = () => {
    groups.forEach((group) => {
      group.classList.remove("open");
      const btn = group.querySelector(".nav-group-summary");
      btn?.setAttribute("aria-expanded", "false");
    });
  };

  groups.forEach((group) => {
    const btn = group.querySelector(".nav-group-summary");
    if (!btn) return;

    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const willOpen = !group.classList.contains("open");
      closeAll();
      if (willOpen) {
        group.classList.add("open");
        btn.setAttribute("aria-expanded", "true");
      }
    });
  });

  nav.querySelectorAll(".nav-dropdown .nav-link").forEach((link) => {
    link.addEventListener("click", () => closeAll());
  });

  nav.querySelectorAll("[data-nav-subgroup]").forEach((subgroup) => {
    const btn = subgroup.querySelector(".nav-subgroup-summary");
    if (!btn || btn.dataset.wired === "1") return;
    btn.dataset.wired = "1";
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const willOpen = !subgroup.classList.contains("open");
      subgroup.classList.toggle("open", willOpen);
      btn.setAttribute("aria-expanded", willOpen ? "true" : "false");
    });
  });

  if (!nav.dataset.outsideClose) {
    nav.dataset.outsideClose = "1";
    document.addEventListener("click", (e) => {
      if (e.target.closest("[data-nav-group]")) return;
      closeAll();
    });
  }
}

/** Minimal nav if grouped menu fails (keeps site usable). */
export async function renderFallbackNav() {
  const nav = document.getElementById("nav");
  if (!nav) return;

  const {
    data: { user },
  } = await supabase.auth.getUser();

  let ownerClub = null;
  try {
    ownerClub = await getOwnerClub();
  } catch (_) {
    /* optional */
  }

  nav.innerHTML = `
    <div class="gpsl-nav-bar gpsl-nav-fallback">
      <div class="gpsl-nav-shortcuts">
      ${renderNavOwnerClubBadge(ownerClub)}
      <a href="dashboard.html" class="nav-shortcut nav-dashboard">Dashboard</a>
      <a href="inbox.html" class="nav-shortcut nav-inbox">📥 Inbox</a>
      </div>
      <a href="GPDB.html" class="nav-link">Player Database</a>
      <a href="all_listings.html" class="nav-link">Transfer Market</a>
      <a href="fixtures.html" class="nav-link">Fixtures</a>
      <a href="squad.html" class="nav-link">Squad</a>
      <button type="button" id="logoutBtn" class="nav-logout">Logout</button>
    </div>
  `;
  wireNavLogout();
}

// ------------------------------------------------------------
// NAV BUILDER — grouped, collapsible categories
// ------------------------------------------------------------
export async function buildNav() {
  const nav = document.getElementById("nav");
  if (!nav) return;

  try {
  let NAV_SECTIONS;
  let ADMIN_NAV_SECTION;
  let ADMIN_FLYOUT_LINKS;
  let isNavItemActive;
  let sectionHasActiveItem;
  let firstActiveNavSectionId;
  let normalizeNavPath;
  let renderAdminMegaNavHtml;
  try {
    const navMod = await import(`./nav_config.js?v=${GLOBAL_JS_VERSION}`);
    NAV_SECTIONS = navMod.NAV_SECTIONS;
    ADMIN_NAV_SECTION = navMod.ADMIN_NAV_SECTION;
    ADMIN_FLYOUT_LINKS = navMod.ADMIN_FLYOUT_LINKS;
    isNavItemActive = navMod.isNavItemActive;
    sectionHasActiveItem = navMod.sectionHasActiveItem;
    firstActiveNavSectionId = navMod.firstActiveNavSectionId;
    normalizeNavPath = navMod.normalizeNavPath;
    renderAdminMegaNavHtml = navMod.renderAdminMegaNavHtml;
  } catch (importErr) {
    console.error("nav_config.js failed to load:", importErr);
    await renderFallbackNav();
    return;
  }

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    window.location = "login.html";
    return;
  }

  const pathname = window.location.pathname;
  const search = window.location.search || "";
  const pathNorm = normalizeNavPath(pathname);
  const clubShort = await getOwnerClubShort();

  let unread = 0;
  try {
    unread =
      clubShort || user?.id
        ? await Promise.race([
            countUnreadInbox(supabase, clubShort, user?.id ?? null),
            new Promise((resolve) => setTimeout(() => resolve(0), 4000)),
          ])
        : 0;
  } catch (err) {
    console.warn("Inbox count skipped:", err);
  }

  const specialAuction = await fetchActiveSpecialAuctionNavItem();

  let myNation = null;
  try {
    const intl = await import("./international.js");
    myNation = await intl.loadMyNation(supabase);
  } catch (intlErr) {
    console.warn("Nav my nation skipped:", intlErr);
  }

  let ownerClub = null;
  try {
    ownerClub = await getOwnerClub();
  } catch (clubErr) {
    console.warn("Nav owner club skipped:", clubErr);
  }

  let calendarStatus = null;
  let navMonthLabel = null;
  let navMonthTitle = "";
  let calMod = null;
  try {
    calMod = await import("./competition_calendar.js");
    calendarStatus = await calMod.loadCalendarStatus(supabase);
    navMonthLabel = calMod.navGpslMonthDisplay(calendarStatus);
    navMonthTitle = calMod.navGpslMonthTitle(calendarStatus);
  } catch (calErr) {
    console.warn("Nav calendar badge skipped:", calErr);
  }

  const dashActive = pathNorm === "dashboard.html";
  const inboxActive = pathNorm === "inbox.html";

  let navSections = Array.isArray(NAV_SECTIONS) ? [...NAV_SECTIONS] : [];
  if (!navSections.length) {
    console.error("buildNav: NAV_SECTIONS missing from nav_config.js");
    await renderFallbackNav();
    return;
  }

  if (isGpslAdminUser(user) && ADMIN_NAV_SECTION?.items?.length) {
    navSections.push(ADMIN_NAV_SECTION);
  }

  let html = `<div class="gpsl-nav-bar">`;
  html += `<div class="gpsl-nav-shortcuts">`;
  html += renderNavOwnerClubBadge(ownerClub);
  html += `<a href="dashboard.html" class="nav-shortcut nav-dashboard${
    dashActive ? " active" : ""
  }" title="Dashboard">Dashboard</a>`;
  html += `<a href="inbox.html" class="nav-shortcut nav-inbox${
    inboxActive ? " active" : ""
  }${unread > 0 ? " has-unread" : ""}" title="Inbox" aria-label="Inbox${
    unread > 0 ? `, ${unread} unread` : ""
  }">`;
  html += `<span class="nav-inbox-icon" aria-hidden="true">📥</span>`;
  if (unread > 0) {
    html += `<span class="nav-inbox-badge">${unread > 99 ? "99+" : unread}</span>`;
  }
  html += `</a>`;
  html += `</div>`;

  const showAdminZone = isGpslAdminUser(user);
  if (showAdminZone && ADMIN_FLYOUT_LINKS?.length) {
    const adminHubActive = pathNorm === "admin.html";
    html += `<div class="gpsl-nav-admin-zone" data-nav-admin-zone>`;
    html += `<span class="gpsl-nav-zone-label">Admin</span>`;
    html += `<button type="button" class="nav-admin-trigger nav-shortcut${
      adminHubActive ? " active" : ""
    }" aria-expanded="false" aria-haspopup="true">Admin tools</button>`;
    html += `<div class="gpsl-nav-admin-flyout" role="menu">`;
    html += renderAdminFlyoutHtml(ADMIN_FLYOUT_LINKS, pathname);
    html += `</div></div>`;
  }

  if (!navMonthLabel) {
    try {
      const { data: gs } = await supabase
        .from("global_settings_public")
        .select("league_phase")
        .eq("id", 1)
        .maybeSingle();
      if (gs?.league_phase === "summer_break") {
        navMonthLabel = "Summer Break";
        navMonthTitle = "GPSL is in summer break — no active competition month";
      }
    } catch (_) {
      /* optional column until admin_season_lifecycle.sql is run */
    }
  }

  if (navMonthLabel) {
    const isPre = calMod?.isPreSeasonPhase?.(calendarStatus) ?? false;
    const isSummer = navMonthLabel === "Summer Break";
    html += `<div class="gpsl-nav-month${isPre ? " gpsl-nav-month-pre" : ""}${
      isSummer ? " gpsl-nav-month-summer" : ""
    }" title="${escapeNavAttr(navMonthTitle)}">`;
    html += `<span class="gpsl-nav-month-kicker">GPSL</span>`;
    html += `<span class="gpsl-nav-month-value">${escapeNavHtml(navMonthLabel)}</span>`;
    html += `</div>`;
  }

  html += `<div class="gpsl-nav-groups">`;

  const navItemsForSection = (section) => {
    if (section.id === "mynation") {
      const items = [];
      if (myNation?.code) {
        items.unshift({
          href: `national_team.html?nation=${encodeURIComponent(myNation.code)}`,
          label: myNation.name,
          page: "national_team",
          nationCode: myNation.code,
        });
        items.push({
          href: "nation_select.html",
          label: "Nation selection",
          page: "nation_select",
        });
      } else {
        items.unshift({
          href: "nation_select.html",
          label: "Choose your nation",
          page: "nation_select",
        });
      }
      return items;
    }

    if (section.id === "myclub") {
      const items = (section.items || [])
        .filter((item) => {
          if (item.requiresDraft && !draftEnabled) return false;
          return true;
        })
        .map((item) => ({ ...item }))
        .filter((item) => item.page !== "squad");

      if (ownerClub?.short) {
        items.unshift({
          href: "squad.html",
          label: ownerClub.name,
          page: "squad",
          clubShort: ownerClub.short,
        });
      } else {
        items.unshift({
          href: "squad.html",
          label: "Squad",
          page: "squad",
        });
      }
      return items;
    }

    const items = (section.items || [])
      .filter((item) => {
        if (item.requiresDraft && !draftEnabled) return false;
        return true;
      })
      .map((item) => ({ ...item }));
    if (section.id === "transfers" && specialAuction) {
      items.push({ ...specialAuction });
    }
    return items;
  };

  const openSectionId = firstActiveNavSectionId(
    navSections,
    pathname,
    search,
    navItemsForSection
  );

  for (const section of navSections) {
    if (!section?.items?.length) continue;

    const items = navItemsForSection(section);

    if (!items.length) continue;

    const sectionMatchesPage = sectionHasActiveItem({ items }, pathname, search);
    const isPrimarySection = section.id === openSectionId;
    const hasActive = sectionMatchesPage && isPrimarySection;

    html += `<div class="nav-group${hasActive ? " nav-group-active" : ""}" data-nav-group>`;
    html += `<button type="button" class="nav-group-summary" aria-expanded="false">${escapeNavHtml(
      formatNavLabel(section.label)
    )}</button>`;
    const dropdownClass =
      section.id === "admin"
        ? "nav-dropdown nav-dropdown-scrollable"
        : "nav-dropdown";
    html += `<div class="${dropdownClass}" role="menu">`;
    html += renderNavDropdownItems(
      items,
      pathname,
      search,
      isNavItemActive,
      renderAdminMegaNavHtml
    );
    html += `</div></div>`;
  }

  html += `</div>`;

  html += `<div class="gpsl-nav-actions">`;
  html += `<button type="button" id="logoutBtn" class="nav-logout">Logout</button>`;
  html += `</div></div>`;

  nav.innerHTML = html;
  wireNavLogout();
  wireNavGroups(nav);
  wireAdminZone(nav);
  } catch (err) {
    console.error("buildNav failed:", err);
    await renderFallbackNav();
  }
}

// ------------------------------------------------------------
// INITIALISATION
// ------------------------------------------------------------
export async function initGlobal() {
  window.supabase = supabase;
  ensureNavStyles();
  await loadGlobalSettings();
  try {
    const { enforceOwnerClubGate } = await import("./owner_gate.js?v=20260606-settle");
    await enforceOwnerClubGate();
  } catch (err) {
    console.warn("owner club gate:", err);
  }
  wireDraftCountdownUI();
  try {
    await buildNav();
  } catch (err) {
    console.error("initGlobal buildNav:", err);
    await renderFallbackNav();
  }

  if (document.getElementById("nav")) {
    initDashboardPinUi(supabase).catch((err) => {
      console.warn("Dashboard pin UI skipped:", err);
    });
  }
}
