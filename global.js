// ============================================================
// GLOBAL.JS — SINGLE SOURCE OF TRUTH FOR THE ENTIRE DRAFT SYSTEM
// ============================================================

import { supabase, getAuthUser } from "./supabase_client.js";
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
import { formatNavLabel, renderNavGroupSummaryLabel } from "./nav_label.js";
export { supabase, getAuthUser, waitForAuthSession } from "./supabase_client.js";

/** Bump when nav/admin chrome changes (cache bust for dynamic imports). */
import { APP_VERSION } from "./app_version.js";

export const GLOBAL_JS_VERSION = APP_VERSION;

let gpslSportModulePromise = null;

function getGpslSportModule() {
  if (!gpslSportModulePromise) {
    gpslSportModulePromise = import(`./gpsl_sport.js?v=${GLOBAL_JS_VERSION}`);
  }
  return gpslSportModulePromise;
}

function renderNavNatterLink(natterActive = false, unread = 0) {
  const n = Number(unread) || 0;
  return (
    `<a href="natter.html" class="nav-shortcut nav-natter${
      natterActive ? " active" : ""
    }${n > 0 ? " has-unread" : ""}" title="Natter" aria-label="Natter${
      n > 0 ? `, ${n} new` : ""
    }">` +
    `<span class="nav-natter-mark" aria-hidden="true">N</span>` +
    `<span class="nav-natter-label">Natter</span>` +
    (n > 0
      ? `<span class="nav-natter-badge">${n > 99 ? "99+" : n}</span>`
      : "") +
    `</a>`
  );
}

async function countNatterUnread() {
  try {
    const { data, error } = await supabase.rpc("natter_unread_count");
    if (error || !data?.ok) return 0;
    return Number(data.count) || 0;
  } catch {
    return 0;
  }
}

/** Update nav Natter badge after visiting Natter (no full nav rebuild). */
export async function refreshNatterNavBadge() {
  const link = document.querySelector("a.nav-natter");
  if (!link) return;

  try {
    const unread = await countNatterUnread();
    link.classList.toggle("has-unread", unread > 0);
    link.setAttribute(
      "aria-label",
      unread > 0 ? `Natter, ${unread} new` : "Natter"
    );

    let badge = link.querySelector(".nav-natter-badge");
    if (unread > 0) {
      const label = unread > 99 ? "99+" : String(unread);
      if (badge) {
        badge.textContent = label;
      } else {
        badge = document.createElement("span");
        badge.className = "nav-natter-badge";
        badge.textContent = label;
        link.appendChild(badge);
      }
    } else if (badge) {
      badge.remove();
    }
  } catch (err) {
    console.warn("refreshNatterNavBadge:", err);
  }
}

function renderNavGpslSportButton() {
  const v = GLOBAL_JS_VERSION;
  return (
    `<button type="button" id="gpslSportNavBtn" class="nav-shortcut nav-gpsl-sport" hidden ` +
    `onclick="(async(e)=>{e.preventDefault();e.stopPropagation();try{if(window.__openGpslSport){await window.__openGpslSport(e);return}const m=await import('./gpsl_sport.js?v=${v}');await m.openGpslSport(window.supabase)}catch(err){console.error(err);alert('GPSL Sport failed to open. Hard-refresh (Ctrl+F5).')}})(event)" ` +
    `title="GPSL Sport" aria-label="GPSL Sport newspaper">` +
    `<span class="nav-gpsl-sport-icon" aria-hidden="true">📰</span>` +
    `<span class="nav-gpsl-sport-label">GPSL Sport</span>` +
    `</button>`
  );
}

async function handleGpslSportNavClick(e) {
  e?.preventDefault?.();
  e?.stopPropagation?.();
  try {
    const mod = await getGpslSportModule();
    await mod.openGpslSport(supabase);
  } catch (err) {
    console.error("GPSL Sport open:", err);
    alert("GPSL Sport could not open. Hard-refresh the page (Ctrl+F5).");
  }
}

async function refreshGpslSportNavUi() {
  try {
    const mod = await getGpslSportModule();
    await mod.initGpslSportUi(supabase);
  } catch (err) {
    console.warn("GPSL Sport nav refresh skipped:", err);
  }
}

window.__openGpslSport = handleGpslSportNavClick;

/** Fail fast when Supabase REST/auth is unreachable (522 / network). */
function withRequestTimeout(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`${label} timed out`)), ms)
    ),
  ]);
}

async function getAuthUserFast(timeoutMs = 10000) {
  const { data: sessionData } = await supabase.auth.getSession();
  const cachedUser = sessionData?.session?.user ?? null;

  try {
    const user = await withRequestTimeout(getAuthUser(), timeoutMs, "auth session");
    return user ?? cachedUser;
  } catch (err) {
    console.warn("getAuthUserFast:", err);
    return cachedUser;
  }
}

export { getAuthUserFast };

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
let specialAuctionNavLive = false;
let specialAuctionNavVisible = false;
let navClubPlayerListed = false;
let navClubManagerListed = false;
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

/** True when live bidding is open for a nav auction link (player / manager / club). */
export function isNavAuctionActive(kind) {
  if (kind === "player") {
    return draftEnabled && playerDraftBiddingOpen === true;
  }
  if (kind === "manager") {
    return managerDraftEnabled && managerDraftBiddingOpen === true;
  }
  if (kind === "club") {
    return clubAuctionEnabled && clubAuctionBiddingOpen === true;
  }
  if (kind === "special") {
    return specialAuctionNavLive;
  }
  return false;
}

/** True when any transfer auction has live bidding open. */
export function hasAnyNavAuctionActive() {
  return (
    isNavAuctionActive("player") ||
    isNavAuctionActive("manager") ||
    isNavAuctionActive("club") ||
    isNavAuctionActive("special")
  );
}

export function getDraftAuctionStartTime() {
  return draftStart;
}

/** ISO timestamp of secret random finish — only exposed after that instant has passed. */
export function getDraftRandomFinishRevealed() {
  return draftRandomFinishRevealed;
}

function isDraftKindEnabled(kind) {
  if (kind === "club") return clubAuctionEnabled;
  if (kind === "manager") return managerDraftEnabled;
  if (kind === "player") return draftEnabled;
  return false;
}

function isDraftCountdownActive() {
  if (!isValidDate(draftStart)) return false;
  const kind = getPageDraftCountdownKind();
  if (kind === "club") {
    if (clubAuctionEnabled) return true;
    if (draftRandomFinishRevealed) return true;
    return getDraftPhaseFromStart(getUKNow(), draftStart) !== "ended";
  }
  return isDraftKindEnabled(kind);
}

/** Page-aware: only true when this page's auction type is enabled and scheduled. */
export function isPageDraftCountdownActive() {
  return isDraftCountdownActive();
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
    ("manager_draft_bidding_open" in data &&
      data.manager_draft_bidding_open === true) ||
    ("club_auction_bidding_open" in data &&
      data.club_auction_bidding_open === true);
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
    const finish = getDraftRandomFinishRevealed();
    if (finish) {
      const { subline } = formatDraftConclusionLines(new Date(finish), "club");
      return `${subline}\nWinners assign when the transfer engine runs (scheduled in Supabase, about every 5 minutes).`;
    }
    return "Club auction finished. Exact random finish time appears once the secret window closes. Winners assign via transfer engine or Admin → Settle club auctions.";
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
  if (!draftEnabled && !managerDraftEnabled && !clubAuctionEnabled) {
    draftBiddingOpen = false;
    playerDraftBiddingOpen = false;
    managerDraftBiddingOpen = false;
    clubAuctionBiddingOpen = false;
    draftRandomLockedMs = null;
    draftRandomFinishRevealed = null;
    refreshNavAuctionIndicators();
    return;
  }
  const wasOpen = draftBiddingOpen === true;
  let data = null;
  const selectAttempts = [
    "draft_bidding_open, manager_draft_bidding_open, club_auction_bidding_open, draft_random_finish_revealed",
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
  refreshNavAuctionIndicators();
}

const DRAFT_BIDDING_OPEN_POLL_MS = 30000;
let __lastCountdownBiddingRefreshMs = 0;

export function startDraftCountdown(onTick) {
  stopDraftCountdown();
  __lastCountdownBiddingRefreshMs = 0;

  const tick = async () => {
    const nowMs = Date.now();
    if (
      isDraftCountdownActive() &&
      nowMs - __lastCountdownBiddingRefreshMs >= DRAFT_BIDDING_OPEN_POLL_MS
    ) {
      __lastCountdownBiddingRefreshMs = nowMs;
      await refreshDraftBiddingOpen();
    }
    const tickData = getPageDraftCountdownTick(
      getUKNow(),
      draftStart,
      draftCountdownUiOptions()
    );
    if (onTick) onTick(tickData);
  };

  void tick();
  __draftCountdownInterval = setInterval(() => {
    void tick();
  }, 1000);
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
function globalSettingsErrorMessage(error) {
  if (!error) return "";
  return String(error.message || error.details || error || "");
}

function isGlobalSettingsConnectivityError(error) {
  const msg = globalSettingsErrorMessage(error).toLowerCase();
  return (
    msg.includes("failed to fetch") ||
    msg.includes("networkerror") ||
    msg.includes("network request failed") ||
    msg.includes("load failed") ||
    msg.includes("timed out") ||
    msg.includes("522")
  );
}

function isGlobalSettingsSchemaColumnError(error) {
  const msg = globalSettingsErrorMessage(error).toLowerCase();
  return (
    msg.includes("column") &&
    (msg.includes("does not exist") || msg.includes("schema cache"))
  );
}

async function queryGlobalSettingsPublic(select, timeoutMs = 12000) {
  const run = () =>
    supabase.from("global_settings_public").select(select).eq("id", 1).single();

  let result;
  try {
    result = await Promise.race([
      run(),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error("global_settings_public request timed out")), timeoutMs)
      ),
    ]);
  } catch (err) {
    return { data: null, error: err };
  }

  const { data, error } = result;
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
    if (isGlobalSettingsConnectivityError(error)) {
      console.error("loadGlobalSettings: backend unreachable", error);
      break;
    }
    if (i === selects.length - 1) {
      console.error("loadGlobalSettings:", error);
    } else if (i === 0 && isGlobalSettingsSchemaColumnError(error)) {
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

function renderNavDashboardHomeLink(ownerClub, homeHref, dashActive) {
  const active = dashActive ? " active" : "";
  const title = escapeNavAttr(
    ownerClub?.name ? `${ownerClub.name} — Dashboard` : "Dashboard"
  );
  let badgeHtml = "";
  if (ownerClub?.short) {
    const src = clubBadgeSrc(ownerClub.short);
    if (src) {
      badgeHtml =
        `<img class="nav-dashboard-home-badge" src="${escapeNavAttr(src)}" alt="" loading="lazy" ` +
        `onerror="this.style.display='none'">`;
    }
  }
  return (
    `<a href="${homeHref}" class="nav-shortcut nav-dashboard-home${active}" title="${title}" aria-label="${title}">` +
    badgeHtml +
    `<span class="nav-dashboard-home-label">Dashboard</span>` +
    `</a>`
  );
}

function renderNavInboxLink(inboxActive, unread) {
  return (
    `<a href="inbox.html" class="nav-shortcut nav-inbox${
      inboxActive ? " active" : ""
    }${unread > 0 ? " has-unread" : ""}" title="Inbox" aria-label="Inbox${
      unread > 0 ? `, ${unread} unread` : ""
    }">` +
    `<span class="nav-inbox-icon" aria-hidden="true">📥</span>` +
    (unread > 0
      ? `<span class="nav-inbox-badge">${unread > 99 ? "99+" : unread}</span>`
      : "") +
    `</a>`
  );
}

function renderNavMonthBlock(navMonthLabel, navMonthTitle, calendarStatus, calMod) {
  if (!navMonthLabel) return "";
  const isPre = calMod?.isPreSeasonPhase?.(calendarStatus) ?? false;
  const isSummer = navMonthLabel === "Summer Break";
  return (
    `<div class="gpsl-nav-month${isPre ? " gpsl-nav-month-pre" : ""}${
      isSummer ? " gpsl-nav-month-summer" : ""
    }" title="${escapeNavAttr(navMonthTitle)}">` +
    `<span class="gpsl-nav-month-kicker">GPSL</span>` +
    `<span class="gpsl-nav-month-value">${escapeNavHtml(navMonthLabel)}</span>` +
    `</div>`
  );
}

async function getOwnerClub(userFromCaller = null) {
  const user = userFromCaller || (await getAuthUserFast());
  if (!user) return null;

  let club;
  try {
    const { data } = await withRequestTimeout(
      supabase
        .from("Clubs")
        .select("ShortName, Club")
        .eq("owner_id", user.id)
        .maybeSingle(),
      8000,
      "Clubs lookup"
    );
    club = data;
  } catch (err) {
    console.warn("getOwnerClub:", err);
    return null;
  }

  if (!club?.ShortName) return null;
  const short = club.ShortName.trim();
  return {
    short,
    name: (club.Club || short).trim(),
  };
}

async function getOwnerClubShort(userFromCaller = null) {
  const club = await getOwnerClub(userFromCaller);
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

async function refreshSpecialAuctionNavLive() {
  try {
    const { fetchSpecialAuctionNavState, isSpecialAuctionLive } = await import(
      `./special_auction.js?v=${GLOBAL_JS_VERSION}`
    );
    const state = await fetchSpecialAuctionNavState(supabase);
    specialAuctionNavVisible = state.visible;
    specialAuctionNavLive = state.live || isSpecialAuctionLive(state.auction);
  } catch (err) {
    console.warn("refreshSpecialAuctionNavLive:", err);
    specialAuctionNavVisible = false;
    specialAuctionNavLive = false;
  }
}

/** Legacy inline navs (draftauction.html, etc.) */
export async function specialAuctionNavLinkHtml() {
  const path = window.location.pathname.toLowerCase();
  if (path.includes("special_auction")) return "";

  await refreshSpecialAuctionNavLive();
  if (!specialAuctionNavVisible) return "";
  return `<a id="nav-special-auction" href="special_auction.html" class="button">Special Auction</a>`;
}

/** Load nav layout CSS on every page (many HTML files never linked dashboard.css). */
function ensureNavStyles() {
  if (!document.getElementById("gpsl-nav-styles")) {
    const link = document.createElement("link");
    link.id = "gpsl-nav-styles";
    link.rel = "stylesheet";
    try {
      link.href = new URL(`dashboard.css?v=${GLOBAL_JS_VERSION}`, import.meta.url).href;
    } catch {
      link.href = `dashboard.css?v=${GLOBAL_JS_VERSION}`;
    }
    document.head.appendChild(link);
  }
  if (!document.getElementById("gpsl-sport-styles")) {
    const sport = document.createElement("link");
    sport.id = "gpsl-sport-styles";
    sport.rel = "stylesheet";
    try {
      sport.href = new URL(`gpsl_sport.css?v=${GLOBAL_JS_VERSION}`, import.meta.url).href;
    } catch {
      sport.href = `gpsl_sport.css?v=${GLOBAL_JS_VERSION}`;
    }
    document.head.appendChild(sport);
  }
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
function navAuctionActiveBadgeHtml(kind, visible = isNavAuctionActive(kind)) {
  if (!kind) return "";
  const hidden = visible ? "" : " is-hidden";
  return `<span class="nav-auction-active${hidden}" title="Bidding is open" aria-hidden="${visible ? "false" : "true"}">Active</span>`;
}

function navListingActiveBadgeHtml(kind, visible = isNavListingActive(kind)) {
  if (!kind) return "";
  const hidden = visible ? "" : " is-hidden";
  const title =
    kind === "manager"
      ? "Your manager is listed on the market"
      : "You have a player listed on the market";
  return `<span class="nav-listing-active${hidden}" title="${escapeNavAttr(
    title
  )}" aria-hidden="${visible ? "false" : "true"}">Listed</span>`;
}

function navLinkLeadingHtml(item) {
  const nationSrc = item.nationCode ? nationFlagSrc(item.nationCode) : null;
  if (nationSrc) {
    return (
      `<img class="nav-nat-flag" src="${escapeNavAttr(nationSrc)}" alt="" loading="lazy" />`
    );
  }
  const clubSrc = item.clubShort ? clubBadgeSrc(item.clubShort) : null;
  if (clubSrc) {
    return (
      `<img class="nav-club-badge" src="${escapeNavAttr(clubSrc)}" alt="" loading="lazy" ` +
      `onerror="this.outerHTML='<span class=&quot;nav-link-marker&quot; aria-hidden=&quot;true&quot;></span>'">`
    );
  }
  return `<span class="nav-link-marker" aria-hidden="true"></span>`;
}

function navLinkInnerHtml(item) {
  const auction = item.auctionNav
    ? navAuctionActiveBadgeHtml(item.auctionNav)
    : "";
  const listing = item.listingNav
    ? navListingActiveBadgeHtml(item.listingNav)
    : "";
  return (
    `<span class="nav-link-leading">${navLinkLeadingHtml(item)}</span>` +
    `<span class="nav-link-body">` +
    auction +
    listing +
    `<span class="nav-link-label">${escapeNavHtml(formatNavLabel(item.label))}</span>` +
    `</span>`
  );
}

/** @deprecated use navLinkInnerHtml */
function navLinkIconHtml(item) {
  return navLinkLeadingHtml(item);
}

function navLinkLabelHtml(item) {
  const badge = item.auctionNav
    ? navAuctionActiveBadgeHtml(item.auctionNav)
    : "";
  return `${badge}<span class="nav-link-label">${escapeNavHtml(
    formatNavLabel(item.label)
  )}</span>`;
}

function navGroupAuctionBadgeHtml(visible = hasAnyNavAuctionActive()) {
  const hidden = visible ? "" : " is-hidden";
  return `<span class="nav-group-auction-active${hidden}" title="Auction bidding is open" aria-hidden="${visible ? "false" : "true"}">Active</span>`;
}

function navGroupListingBadgeHtml(visible = hasAnyNavListingActive()) {
  const hidden = visible ? "" : " is-hidden";
  return `<span class="nav-group-listing-active${hidden}" title="You have a player or manager on the market" aria-hidden="${visible ? "false" : "true"}">Listed</span>`;
}

/** Live auction pages + related databases (path highlight stops on these). */
const NAV_AUCTION_RELATED_PAGES = {
  player: ["draftauction.html", "gpdb.html"],
  manager: ["manager_draftauction.html", "mgdb.html"],
  club: ["club_auction.html", "club_database.html"],
  special: ["special_auction.html"],
};

function isOnNavAuctionRelatedPage(kind, currentFile) {
  const file = String(currentFile || "").toLowerCase();
  const related = NAV_AUCTION_RELATED_PAGES[kind];
  return related?.some((p) => p.toLowerCase() === file) ?? false;
}

/** Target pages for live auction path indicators (Transfers → subgroup → page). */
const NAV_AUCTION_TARGETS = {
  player: "draftauction.html",
  manager: "manager_draftauction.html",
  club: "club_auction.html",
  special: "special_auction.html",
};

const NAV_LISTING_TARGETS = {
  player: "all_listings.html",
  manager: "manager_listings.html",
};

function isNavListingActive(kind) {
  if (kind === "player") return navClubPlayerListed;
  if (kind === "manager") return navClubManagerListed;
  return false;
}

function hasAnyNavListingActive() {
  return navClubPlayerListed || navClubManagerListed;
}

function isOnNavListingTargetPage(kind, currentFile) {
  const file = String(currentFile || "").toLowerCase();
  const target = NAV_LISTING_TARGETS[kind];
  return target?.toLowerCase() === file;
}

async function loadNavClubListingFlags(clubShort) {
  if (!clubShort) {
    return { player: false, manager: false };
  }

  const nowIso = new Date().toISOString();
  const [playerRes, managerRes] = await Promise.all([
    supabase
      .from("Player_Transfer_Listings")
      .select("id", { count: "exact", head: true })
      .eq("seller_club_id", clubShort)
      .neq("listing_type", "draft")
      .in("status", ["Active", "Review", "Seller Review"]),
    supabase
      .from("Manager_Transfer_Listings")
      .select("id", { count: "exact", head: true })
      .eq("seller_club_id", clubShort)
      .eq("status", "Active")
      .neq("listing_type", "draft")
      .gt("end_time", nowIso),
  ]);

  if (playerRes.error) {
    console.warn("nav player listing count:", playerRes.error.message);
  }
  if (managerRes.error) {
    console.warn("nav manager listing count:", managerRes.error.message);
  }

  return {
    player: !playerRes.error && (playerRes.count ?? 0) > 0,
    manager: !managerRes.error && (managerRes.count ?? 0) > 0,
  };
}

/** Reload whether this club has live player/manager market listings (nav badges). */
export async function refreshNavClubListingState(clubShort) {
  try {
    const short =
      clubShort ?? (await getOwnerClubShort(await getAuthUserFast()));
    const flags = await loadNavClubListingFlags(short);
    navClubPlayerListed = flags.player;
    navClubManagerListed = flags.manager;
    return flags;
  } catch (err) {
    console.warn("refreshNavClubListingState:", err);
    navClubPlayerListed = false;
    navClubManagerListed = false;
    return { player: false, manager: false };
  }
}

function currentNavPageFile() {
  return (window.location.pathname || "").toLowerCase().replace(/\\/g, "/").split("/").pop() || "";
}

/** Vertical path bars on Transfers + subgroup until the auction page is open. */
function refreshNavAuctionPathIndicators() {
  const nav = document.getElementById("nav");
  if (!nav) return;

  nav.querySelectorAll(".nav-auction-path").forEach((el) => {
    el.classList.remove("nav-auction-path");
  });

  const currentFile = currentNavPageFile();
  const transfersGroup = nav.querySelector('[data-nav-auction-section="transfers"]');
  let showTransfersPath = false;

  for (const [kind, targetFile] of Object.entries(NAV_AUCTION_TARGETS)) {
    if (!isNavAuctionActive(kind)) continue;
    if (isOnNavAuctionRelatedPage(kind, currentFile)) continue;

    showTransfersPath = true;
    nav.querySelectorAll("[data-nav-subgroup]").forEach((subgroup) => {
      const kinds = (subgroup.dataset.auctionKinds || "")
        .split(",")
        .map((k) => k.trim())
        .filter(Boolean);
      if (kinds.includes(kind)) {
        subgroup.classList.add("nav-auction-path");
      }
    });
  }

  if (showTransfersPath && transfersGroup) {
    transfersGroup.classList.add("nav-auction-path");
  }
}

/** Amber path bars on Transfers + subgroup while you have a live listing (until market page). */
function refreshNavListingPathIndicators() {
  const nav = document.getElementById("nav");
  if (!nav) return;

  nav.querySelectorAll(".nav-listing-path").forEach((el) => {
    el.classList.remove("nav-listing-path");
  });

  const currentFile = currentNavPageFile();
  const transfersGroup = nav.querySelector('[data-nav-auction-section="transfers"]');
  let showTransfersPath = false;

  for (const kind of ["player", "manager"]) {
    if (!isNavListingActive(kind)) continue;
    if (isOnNavListingTargetPage(kind, currentFile)) continue;

    showTransfersPath = true;
    nav.querySelectorAll("[data-nav-subgroup]").forEach((subgroup) => {
      const kinds = (subgroup.dataset.listingKinds || "")
        .split(",")
        .map((k) => k.trim())
        .filter(Boolean);
      if (kinds.includes(kind)) {
        subgroup.classList.add("nav-listing-path");
      }
    });
  }

  if (showTransfersPath && transfersGroup) {
    transfersGroup.classList.add("nav-listing-path");
  }
}

/** Update Listed badges + path bars without rebuilding the whole nav. */
export function refreshNavListingIndicators() {
  const nav = document.getElementById("nav");
  if (!nav) return;

  nav.querySelectorAll("[data-listing-nav]").forEach((link) => {
    const kind = link.dataset.listingNav;
    const badge = link.querySelector(".nav-listing-active");
    if (!badge || !kind) return;
    const active = isNavListingActive(kind);
    badge.classList.toggle("is-hidden", !active);
    badge.setAttribute("aria-hidden", active ? "false" : "true");
    link.classList.toggle("nav-link-has-listing", active);
  });

  const transfersGroup = nav.querySelector('[data-nav-auction-section="transfers"]');
  if (transfersGroup) {
    const anyListed = hasAnyNavListingActive();
    transfersGroup.classList.toggle("nav-group-has-listing", anyListed);
    const groupBadge = transfersGroup.querySelector(".nav-group-listing-active");
    if (groupBadge) {
      groupBadge.classList.toggle("is-hidden", !anyListed);
      groupBadge.setAttribute("aria-hidden", anyListed ? "false" : "true");
    }
  }

  refreshNavListingPathIndicators();
}

/** Update Active badges without rebuilding the whole nav. */
export function refreshNavAuctionIndicators() {
  const nav = document.getElementById("nav");
  if (!nav) return;
  nav.querySelectorAll("[data-auction-nav]").forEach((link) => {
    const kind = link.dataset.auctionNav;
    const badge = link.querySelector(".nav-auction-active");
    if (!badge || !kind) return;
    const active = isNavAuctionActive(kind);
    badge.classList.toggle("is-hidden", !active);
    badge.setAttribute("aria-hidden", active ? "false" : "true");
  });

  const transfersGroup = nav.querySelector('[data-nav-auction-section="transfers"]');
  if (transfersGroup) {
    const anyActive = hasAnyNavAuctionActive();
    transfersGroup.classList.toggle("nav-group-has-auction", anyActive);
    const groupBadge = transfersGroup.querySelector(".nav-group-auction-active");
    if (groupBadge) {
      groupBadge.classList.toggle("is-hidden", !anyActive);
      groupBadge.setAttribute("aria-hidden", anyActive ? "false" : "true");
    }
  }

  refreshNavAuctionPathIndicators();
  import(`./season_transfer_schedule.js?v=${GLOBAL_JS_VERSION}`)
    .then((m) => m.refreshSeasonScheduleStrip())
    .catch(() => {});
}

let __navAuctionRefreshInterval = null;

function startNavAuctionBadgeRefresh() {
  if (__navAuctionRefreshInterval) return;
  __navAuctionRefreshInterval = setInterval(() => {
    Promise.all([
      draftEnabled || managerDraftEnabled || clubAuctionEnabled
        ? refreshDraftBiddingOpen().catch((err) => {
            console.warn("nav auction badge refresh:", err);
          })
        : Promise.resolve(),
      refreshSpecialAuctionNavLive().then(() => refreshNavAuctionIndicators()),
      refreshNavClubListingState().then(() => refreshNavListingIndicators()),
    ]).catch((err) => {
      console.warn("nav badge refresh:", err);
    });
  }, 30000);
}

function renderNavDropdownItems(items, pathname, search, isNavItemActive, renderMegaNavHtml) {
  const hasHeadings = items.some(
    (item) =>
      item.heading ||
      item.testingMega ||
      item.seasonMega ||
      item.seasonMgmtMega ||
      item.seasonBreakMega ||
      item.ownersMega
  );
  if (!hasHeadings) {
    let flat = "";
    for (const item of items) {
      if (!item.href) continue;
      const active = isNavItemActive(item, pathname, search);
      const indent = item.indent ? " nav-link-sub" : "";
      const auctionAttr = item.auctionNav
        ? ` data-auction-nav="${item.auctionNav}"`
        : "";
      const listingAttr = item.listingNav
        ? ` data-listing-nav="${item.listingNav}"`
        : "";
      flat += `<a href="${item.href}" class="nav-link${indent}${
        active ? " active" : ""
      }"${auctionAttr}${listingAttr}>${navLinkInnerHtml(item)}</a>`;
    }
    return flat;
  }

  let topHtml = "";
  let groupHtml = "";
  let panelHtml = "";
  let panelLabel = "";
  let panelHasActive = false;
  let panelAuctionKinds = [];
  let panelListingKinds = [];

  const renderLink = (item, active) => {
    const indent = item.indent ? " nav-link-sub" : "";
    const danger = item.navDanger ? " nav-link-danger" : "";
    const auctionAttr = item.auctionNav
      ? ` data-auction-nav="${item.auctionNav}"`
      : "";
    const listingAttr = item.listingNav
      ? ` data-listing-nav="${item.listingNav}"`
      : "";
    const listingClass =
      item.listingNav && isNavListingActive(item.listingNav)
        ? " nav-link-has-listing"
        : "";
    return `<a href="${item.href}" class="nav-link${indent}${danger}${listingClass}${
      active ? " active" : ""
    }"${auctionAttr}${listingAttr}>${navLinkInnerHtml(item)}</a>`;
  };

  const flushPanel = () => {
    if (!panelLabel) return;
    const kindsAttr = panelAuctionKinds.length
      ? ` data-auction-kinds="${panelAuctionKinds.join(",")}"`
      : "";
    const listingKindsAttr = panelListingKinds.length
      ? ` data-listing-kinds="${panelListingKinds.join(",")}"`
      : "";
    groupHtml += `<div class="nav-subgroup${panelHasActive ? " open" : ""}" data-nav-subgroup${kindsAttr}${listingKindsAttr}>`;
    groupHtml += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
      panelHasActive ? "true" : "false"
    }">${escapeNavHtml(formatNavLabel(panelLabel))}</button>`;
    groupHtml += `<div class="nav-subgroup-panel" role="group">${panelHtml}</div>`;
    groupHtml += `</div>`;
    panelHtml = "";
    panelLabel = "";
    panelHasActive = false;
    panelAuctionKinds = [];
    panelListingKinds = [];
  };

  for (const item of items) {
    if (item.testingMega || item.seasonMega || item.seasonMgmtMega || item.seasonBreakMega || item.ownersMega) {
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
    if (item.auctionNav) panelAuctionKinds.push(item.auctionNav);
    if (item.listingNav) panelListingKinds.push(item.listingNav);
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

function activeLabelForNavItems(items, pathname, search, isNavItemActive) {
  for (const item of items || []) {
    if (item.heading || !item.href) continue;
    if (isNavItemActive(item, pathname, search)) return item.label;
  }
  return null;
}

/** Minimal nav if grouped menu fails (keeps site usable). */
export async function renderFallbackNav() {
  const nav = document.getElementById("nav");
  if (!nav) return;

  const user = await getAuthUser();

  let ownerClub = null;
  try {
    ownerClub = await getOwnerClub();
  } catch (_) {
    /* optional */
  }

  nav.innerHTML = `
    <div class="gpsl-nav-bar gpsl-nav-fallback">
      <div class="gpsl-nav-row gpsl-nav-row-menus">
        <div class="gpsl-nav-groups">
          <a href="GPDB.html" class="nav-link">Player Database</a>
          <a href="all_listings.html" class="nav-link">Transfer Market</a>
          <a href="fixtures.html" class="nav-link">Fixtures</a>
          <a href="squad.html" class="nav-link">Squad</a>
        </div>
        <div class="gpsl-nav-actions gpsl-nav-actions-primary">
          ${renderNavNatterLink(false, 0)}
          ${renderNavGpslSportButton()}
          ${renderNavDashboardHomeLink(ownerClub, "dashboard.html", false)}
          ${renderNavInboxLink(false, 0)}
          <button type="button" id="logoutBtn" class="nav-logout">Logout</button>
        </div>
      </div>
    </div>
  `;
  wireNavLogout();
  refreshGpslSportNavUi();
  refreshNatterNavBadge().catch((err) => {
    console.warn("Natter nav badge skipped:", err);
  });
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
  let isNavItemActive;
  let sectionHasActiveItem;
  let firstActiveNavSectionId;
  let normalizeNavPath;
  let renderAdminMegaNavHtml;
  try {
    const navMod = await import(`./nav_config.js?v=${GLOBAL_JS_VERSION}`);
    NAV_SECTIONS = navMod.NAV_SECTIONS;
    ADMIN_NAV_SECTION = navMod.ADMIN_NAV_SECTION;
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

  const user = await getAuthUserFast();

  if (!user) {
    window.location = "login.html";
    return;
  }

  const pathname = window.location.pathname;
  const search = window.location.search || "";
  const pathNorm = normalizeNavPath(pathname);
  const clubShort = await getOwnerClubShort(user);

  let unread = 0;
  let natterUnread = 0;
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

  try {
    natterUnread = await Promise.race([
      countNatterUnread(),
      new Promise((resolve) => setTimeout(() => resolve(0), 4000)),
    ]);
  } catch (err) {
    console.warn("Natter unread count skipped:", err);
  }

  if (clubShort) {
    try {
      const listingFlags = await Promise.race([
        loadNavClubListingFlags(clubShort),
        new Promise((resolve) =>
          setTimeout(() => resolve({ player: false, manager: false }), 4000)
        ),
      ]);
      navClubPlayerListed = listingFlags.player;
      navClubManagerListed = listingFlags.manager;
    } catch (err) {
      console.warn("Nav listing flags skipped:", err);
    }
  }

  await refreshSpecialAuctionNavLive();

  let myNation = null;
  try {
    const intl = await import("./international.js");
    myNation = await intl.loadMyNation(supabase);
  } catch (intlErr) {
    console.warn("Nav my nation skipped:", intlErr);
  }

  let ownerClub = null;
  try {
    ownerClub = await getOwnerClub(user);
  } catch (clubErr) {
    console.warn("Nav owner club skipped:", clubErr);
  }

  let registrySelf = null;
  try {
    const { data: reg } = await supabase.rpc("owner_registry_get_self");
    registrySelf = reg;
  } catch (regErr) {
    console.warn("Nav registry self skipped:", regErr);
  }

  const isWaitingListMember =
    registrySelf?.is_member === true && registrySelf?.has_club !== true;
  const memberHomeHref = "member_home.html";
  const homeHref =
    isWaitingListMember && !registrySelf?.needs_club_auction
      ? memberHomeHref
      : "dashboard.html";

  const dashActive = pathNorm === normalizeNavPath(homeHref);
  const inboxActive = pathNorm === "inbox.html";
  const natterActive = pathNorm === "natter.html";

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
  html += `<div class="gpsl-nav-row gpsl-nav-row-menus">`;
  html += `<div class="gpsl-nav-groups">`;

  const navItemsForSection = (section) => {
    if (
      (section.id === "myclub" || section.id === "mynation") &&
      isWaitingListMember
    ) {
      return [];
    }

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
      items.push({
        href: "nation_player_pool.html",
        label: "Nation player pool",
        page: "nation_player_pool",
      });
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
        if (item.requiresSpecialAuction && !specialAuctionNavVisible) return false;
        if (isWaitingListMember && item.page === "club_auction") return false;
        return true;
      })
      .map((item) => ({ ...item }));
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
    const isTransfersSection = section.id === "transfers";
    const anyAuctionActive = isTransfersSection && hasAnyNavAuctionActive();
    const anyListingActive = isTransfersSection && hasAnyNavListingActive();
    const activePageLabel = hasActive
      ? activeLabelForNavItems(items, pathname, search, isNavItemActive)
      : null;

    html += `<div class="nav-group${hasActive ? " nav-group-active" : ""}${
      anyAuctionActive ? " nav-group-has-auction" : ""
    }${anyListingActive ? " nav-group-has-listing" : ""}"${
      isTransfersSection ? ' data-nav-auction-section="transfers"' : ""
    } data-nav-group>`;
    html += `<button type="button" class="nav-group-summary" aria-expanded="false">${renderNavGroupSummaryLabel(
      section.label,
      escapeNavHtml,
      activePageLabel,
      isTransfersSection
        ? `${navGroupAuctionBadgeHtml(anyAuctionActive)}${navGroupListingBadgeHtml(
            anyListingActive
          )}`
        : ""
    )}</button>`;
    const dropdownClass =
      section.id === "admin" || section.id === "transfers"
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

  html += `<div class="gpsl-nav-actions gpsl-nav-actions-primary">`;
  html += renderNavNatterLink(natterActive, natterUnread);
  html += renderNavGpslSportButton();
  html += renderNavDashboardHomeLink(ownerClub, homeHref, dashActive);
  html += renderNavInboxLink(inboxActive, unread);
  html += `<button type="button" id="logoutBtn" class="nav-logout">Logout</button>`;
  html += `</div></div></div>`;

  nav.innerHTML = html;
  wireNavLogout();
  wireNavGroups(nav);
  refreshNavAuctionIndicators();
  refreshNavListingIndicators();
  startNavAuctionBadgeRefresh();
  refreshGpslSportNavUi();
  try {
    const sched = await import(`./season_transfer_schedule.js?v=${GLOBAL_JS_VERSION}`);
    sched.ensureSeasonScheduleStripMount();
    sched.refreshSeasonScheduleStrip();
  } catch (schedErr) {
    console.warn("Season schedule strip skipped:", schedErr);
  }
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
    const { enforceOwnerClubGate } = await import("./owner_gate.js?v=20260617-ios-auth");
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
    refreshGpslSportNavUi();
    refreshNatterNavBadge().catch((err) => {
      console.warn("Natter nav badge skipped:", err);
    });
    import(`./season_transfer_schedule.js?v=${GLOBAL_JS_VERSION}`)
      .then((m) => m.initSeasonScheduleStrip())
      .catch((err) => console.warn("Season schedule strip skipped:", err));
  }
}
