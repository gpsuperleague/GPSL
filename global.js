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
import {
  applyStoredSiteTheme,
  renderNavThemeToggle,
  wireNavThemeToggle,
} from "./gpsl_light_mode.js?v=20261002-light-mode2";
export { supabase, getAuthUser, waitForAuthSession } from "./supabase_client.js";

applyStoredSiteTheme();

/** Bump when nav/admin chrome changes (cache bust for dynamic imports). */
import { APP_VERSION } from "./app_version.js";

export const GLOBAL_JS_VERSION = APP_VERSION;

const HIDE_EMAIL_KEY = "gpsl_hide_email";

export function isEmailHidden() {
  try {
    return localStorage.getItem(HIDE_EMAIL_KEY) === "1";
  } catch {
    return false;
  }
}

export function setEmailHidden(hidden) {
  try {
    if (hidden) localStorage.setItem(HIDE_EMAIL_KEY, "1");
    else localStorage.removeItem(HIDE_EMAIL_KEY);
  } catch {
    /* ignore */
  }
  document.documentElement.classList.toggle("gpsl-hide-email", Boolean(hidden));
}

/** Recording / privacy mode: blanks the signed-in email on every page (?hide_email=1 / 0 also toggles). */
function applyEmailPrivacyMode() {
  try {
    const param = new URLSearchParams(window.location.search).get("hide_email");
    if (param === "1" || param === "0") setEmailHidden(param === "1");
  } catch {
    /* ignore */
  }
  if (!document.getElementById("gpslHideEmailStyle")) {
    const style = document.createElement("style");
    style.id = "gpslHideEmailStyle";
    style.textContent =
      "html.gpsl-hide-email #userEmail, html.gpsl-hide-email #accountEmail, html.gpsl-hide-email [data-gpsl-email] { visibility:hidden !important; }";
    document.head.appendChild(style);
  }
  document.documentElement.classList.toggle("gpsl-hide-email", isEmailHidden());
}

applyEmailPrivacyMode();

let gpslSportModulePromise = null;

function getGpslSportModule() {
  if (!gpslSportModulePromise) {
    gpslSportModulePromise = import(`./gpsl_sport.js?v=${GLOBAL_JS_VERSION}`);
  }
  return gpslSportModulePromise;
}

function renderNavSeasonCalendarLink(calendarActive = false) {
  return (
    `<a href="season_calendar.html" class="nav-shortcut nav-season-calendar${
      calendarActive ? " active" : ""
    }" title="Season calendar" aria-label="Season calendar">` +
    `<span class="nav-season-calendar-mark" aria-hidden="true">📅</span>` +
    `<span class="nav-season-calendar-label">Calendar</span>` +
    `</a>`
  );
}

function renderNavHandbookLink(handbookActive = false) {
  return (
    `<a href="learning_gpsl.html" class="nav-shortcut nav-season-calendar nav-handbook${
      handbookActive ? " active" : ""
    }" title="GPSL Handbook — rules &amp; guides" aria-label="GPSL Handbook">` +
    `<span class="nav-season-calendar-mark" aria-hidden="true">📖</span>` +
    `<span class="nav-season-calendar-label">Handbook</span>` +
    `</a>`
  );
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

function renderNavFantasyLink(fantasyActive = false) {
  return (
    `<a href="fantasy.html" class="nav-shortcut nav-fantasy${
      fantasyActive ? " active" : ""
    }" title="GP Fantasy League (GPFL)" aria-label="GP Fantasy League">` +
    `<span class="nav-fantasy-mark" aria-hidden="true">` +
    `<img src="images/nav/gpfl_icon.svg?v=20260821" alt="" width="18" height="18" loading="lazy" />` +
    `</span>` +
    `<span class="nav-fantasy-label">GPFL</span>` +
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

/** Cached from gpsl_am_mod() for the current session (buildNav / initAdminPage). */
let isGpslModNav = false;

export function isGpslModUserCached() {
  return isGpslModNav === true;
}

/** Refresh mod flag from Supabase (admins are never shown the Mod menu). */
export async function fetchIsGpslModUser(force = false) {
  if (!force && isGpslModNav === true) return true;
  try {
    const { data, error } = await supabase.rpc("gpsl_am_mod");
    if (error) {
      console.warn("gpsl_am_mod:", error.message);
      isGpslModNav = false;
      return false;
    }
    isGpslModNav = data === true;
    return isGpslModNav;
  } catch (err) {
    console.warn("gpsl_am_mod failed:", err);
    isGpslModNav = false;
    return false;
  }
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
let playerDraftStart = null;
let managerDraftStart = null;
let clubDraftStart = null;
/** Active countdown clock (synced from page kind). */
let draftStart = null;
let draftCutoff = null;
let draftRandomStart = null;
let draftPublicEnd = null;
let draftBiddingOpen = null; // combined / legacy
let playerDraftBiddingOpen = null;
let managerDraftBiddingOpen = null;
let clubAuctionBiddingOpen = null;
let specialAuctionNavLive = false;
let specialAuctionNavVisible = false;
/** Contested final-year wage market has at least one player. */
let expiringContractMarketLive = false;
/** Active GPSL month key for conditional nav (e.g. playoffs). */
let activeGpslMonthNav = "";
let isGpslAdminNav = false;
let isGpslModOnlyNav = false;
let navClubPlayerListed = false;
let navClubManagerListed = false;
let draftRandomLockedMs = null;
let playerDraftRandomFinishRevealed = null;
let managerDraftRandomFinishRevealed = null;
let clubDraftRandomFinishRevealed = null;
/** Active countdown revealed finish (synced from page kind). */
let draftRandomFinishRevealed = null;

// Countdown interval
let __draftCountdownInterval = null;

/** @param {'player'|'manager'|'club'|null|undefined} kind */
export function getDraftBiddingOpen(kind = null) {
  if (kind === "player") return playerDraftBiddingOpen;
  if (kind === "manager") return managerDraftBiddingOpen;
  if (kind === "club") return clubAuctionBiddingOpen;
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
  if (kind === "expiring") {
    return expiringContractMarketLive;
  }
  return false;
}

/** True when any transfer auction has live bidding open. */
export function hasAnyNavAuctionActive() {
  return (
    isNavAuctionActive("player") ||
    isNavAuctionActive("manager") ||
    isNavAuctionActive("club") ||
    isNavAuctionActive("special") ||
    isNavAuctionActive("expiring")
  );
}

/** @param {'player'|'manager'|'club'|null|undefined} kind */
export function getDraftAuctionStartTime(kind = null) {
  const k = kind || pageDraftKindHint() || "player";
  if (k === "manager") return managerDraftStart;
  if (k === "club") return clubDraftStart;
  return playerDraftStart;
}

/** ISO timestamp of secret random finish — only exposed after that instant has passed. */
/** @param {'player'|'manager'|'club'|null|undefined} kind */
export function getDraftRandomFinishRevealed(kind = null) {
  const k = kind || pageDraftKindHint() || "player";
  if (k === "manager") return managerDraftRandomFinishRevealed;
  if (k === "club") return clubDraftRandomFinishRevealed;
  return playerDraftRandomFinishRevealed;
}

function isDraftKindEnabled(kind) {
  if (kind === "club") return clubAuctionEnabled;
  if (kind === "manager") return managerDraftEnabled;
  if (kind === "player") return draftEnabled;
  return false;
}

/** Point countdown helpers at this page's auction clock. */
function syncActiveDraftClockFromKind(kind = null) {
  const k = kind || getPageDraftCountdownKind() || "player";
  draftStart = getDraftAuctionStartTime(k);
  draftRandomFinishRevealed = getDraftRandomFinishRevealed(k);
  const timeline = getDraftTimelineFromStart(draftStart);
  draftCutoff = timeline?.cutoff ?? null;
  draftRandomStart = timeline?.randomStart ?? null;
  draftPublicEnd = timeline?.publicEnd ?? null;
  ensureDraftRandomWindowFrozen();
  return k;
}

function isDraftCountdownActive() {
  const kind = syncActiveDraftClockFromKind();
  if (!isValidDate(draftStart)) return false;
  // Club pages must not borrow the player-draft clock when club auction is off
  // (waiting_list.html was showing "Club auction" for the player random window).
  if (kind === "club") {
    return clubAuctionEnabled;
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

  if ("draft_random_finish_revealed" in data) {
    playerDraftRandomFinishRevealed = data.draft_random_finish_revealed || null;
    if (data.draft_bidding_open === true) playerDraftRandomFinishRevealed = null;
  }
  if ("manager_draft_random_finish_revealed" in data) {
    managerDraftRandomFinishRevealed =
      data.manager_draft_random_finish_revealed || null;
    if (data.manager_draft_bidding_open === true) {
      managerDraftRandomFinishRevealed = null;
    }
  }
  if ("club_auction_random_finish_revealed" in data) {
    clubDraftRandomFinishRevealed = data.club_auction_random_finish_revealed || null;
    if (data.club_auction_bidding_open === true) clubDraftRandomFinishRevealed = null;
  }

  // Legacy fallback: only player revealed column present
  if (
    !("manager_draft_random_finish_revealed" in data) &&
    !("club_auction_random_finish_revealed" in data) &&
    "draft_random_finish_revealed" in data
  ) {
    const raw = data.draft_random_finish_revealed;
    if (raw) {
      playerDraftRandomFinishRevealed = raw;
      if (managerDraftEnabled) managerDraftRandomFinishRevealed = raw;
      if (clubAuctionEnabled) clubDraftRandomFinishRevealed = raw;
    }
  }

  syncActiveDraftClockFromKind();
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
  // Legacy combined flag — prefer page kind when possible; engines should pass kind.
  const kind = pageDraftKindHint();
  if (kind === "player") {
    draftBiddingOpen = playerDraftBiddingOpen;
  } else if (kind === "manager") {
    draftBiddingOpen = managerDraftBiddingOpen;
  } else if (kind === "club") {
    draftBiddingOpen = clubAuctionBiddingOpen;
  } else if (draftEnabled && !managerDraftEnabled) {
    draftBiddingOpen = playerDraftBiddingOpen;
  } else if (managerDraftEnabled && !draftEnabled) {
    draftBiddingOpen = managerDraftBiddingOpen;
  } else if (clubAuctionEnabled && !draftEnabled && !managerDraftEnabled) {
    draftBiddingOpen = clubAuctionBiddingOpen;
  } else {
    draftBiddingOpen =
      playerDraftBiddingOpen === true ||
      managerDraftBiddingOpen === true ||
      clubAuctionBiddingOpen === true;
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
  const kind = syncActiveDraftClockFromKind();
  if (draftRandomFinishRevealed) return false;

  const timeline = getDraftTimelineFromStart(draftStart);
  const now = getUKNow();
  const inRandomWindow =
    timeline && now >= timeline.randomStart && now < timeline.publicEnd;

  if (kind === "club") {
    if (clubAuctionBiddingOpen === false && inRandomWindow) return true;
    return clubAuctionBiddingOpen;
  }
  if (kind === "manager") {
    if (managerDraftBiddingOpen === false && inRandomWindow) return true;
    return managerDraftBiddingOpen;
  }
  if (playerDraftBiddingOpen === false && inRandomWindow) return true;
  return playerDraftBiddingOpen;
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
  if (
    page === "awaiting_club" ||
    page === "waiting_list" ||
    page === "club_auction" ||
    page === "club_database" ||
    /awaiting_club|waiting_list|club_auction|club_database/.test(path)
  ) {
    return "club";
  }
  return null;
}

/** Which draft timer labels to show — page-specific so MGDB/GPDB never share the wrong auction. */
export function getDraftCountdownKind() {
  const hint = pageDraftKindHint();
  if (hint) return hint;

  if (clubAuctionEnabled && !draftEnabled && !managerDraftEnabled) return "club";
  if (managerDraftEnabled && !draftEnabled && !clubAuctionEnabled) return "manager";
  if (draftEnabled && !managerDraftEnabled && !clubAuctionEnabled) return "player";

  if (managerDraftBiddingOpen === true && playerDraftBiddingOpen !== true) {
    return "manager";
  }
  if (playerDraftBiddingOpen === true && managerDraftBiddingOpen !== true) {
    return "player";
  }
  if (clubAuctionBiddingOpen === true) return "club";

  if (managerDraftEnabled) return "manager";
  if (draftEnabled) return "player";
  if (clubAuctionEnabled) return "club";
  return "player";
}

function getPageDraftCountdownKind() {
  return getDraftCountdownKind();
}

function draftCountdownEndedSubline(kind) {
  if (kind === "club") {
    const finish = getDraftRandomFinishRevealed("club");
    if (finish) {
      const { subline } = formatDraftConclusionLines(new Date(finish), "club");
      return `${subline}\nWinners assign when the transfer engine runs (scheduled in Supabase, about every 5 minutes).`;
    }
    return "Club auction finished. Exact random finish time appears once the secret window closes. Winners assign via transfer engine or Admin → Settle club auctions.";
  }
  if (kind === "manager") {
    return "Manager draft finished. Other auction types use their own clocks.";
  }
  return "Previous player draft window finished. Admin → Transfer management to schedule the next player draft.";
}

function getPageDraftCountdownTick(nowUK, start, options) {
  const kind = syncActiveDraftClockFromKind();
  const clockStart = start || draftStart;
  if (kind === "club") {
    return getClubAuctionCountdownTick(nowUK, clockStart, options);
  }
  if (kind === "manager") {
    return getManagerDraftCountdownTick(nowUK, clockStart, options);
  }
  return getDraftCountdownTick(nowUK, clockStart, options);
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

function pickSecretFinishFromTimeline(timeline) {
  if (!timeline) return null;
  const maxOffsetSec = 9 * 60 + 58;
  const offsetSec = Math.floor(Math.random() * (maxOffsetSec + 1));
  return new Date(timeline.randomStart.getTime() + offsetSec * 1000);
}

/** True at/after 19:00:01 UK — next nominal Day-1 open is tomorrow 19:00. */
export function isPastNominalDraftStartUk(at = getUKNow()) {
  const uk = getUKWallClockParts(at);
  return uk.hour > 19 || (uk.hour === 19 && (uk.minute > 0 || uk.second > 0));
}

/**
 * Next nominal Day-1 19:00 UK + secret Day-2 finish (18:50–18:59:58 UK window).
 * After 19:00 UK this rolls to tomorrow — use computeLateDraftStartNow() instead
 * when you need bidding to open tonight.
 */
export function computeNextDraftTimesFromNow() {
  const uk = getUKWallClockParts(getUKNow());
  const startDay = isPastNominalDraftStartUk() ? uk.day + 1 : uk.day;
  const start = ukLocalToInstant(uk.year, uk.month, startDay, 19, 0, 0);
  const timeline = getDraftTimelineFromStart(start);
  const finish = pickSecretFinishFromTimeline(timeline);
  if (!timeline || !finish) {
    return { draftStartISO: null, randomFinishISO: null };
  }

  return {
    draftStartISO: start.toISOString(),
    randomFinishISO: finish.toISOString(),
  };
}

/**
 * Late / salvage start — same rules as a normal manager/club draft window:
 *   Day-1 anchor = today's 19:00 UK (if that time has already passed)
 *   Day-2 secret finish = Day-1 + 23h50m + random 0–9m58s  (18:50–18:59:58 UK window)
 * Bidding is already open because start is in the past (tonight's 19:00).
 *
 * If it is still before today's 19:00 UK: start = now (immediate), finish still
 * from tonight's 19:00 Day-1 so Day-2 lands at the usual tomorrow evening window.
 */
export function computeLateDraftStartNow() {
  const now = getUKNow();
  const uk = getUKWallClockParts(now);
  const day1Tonight = ukLocalToInstant(uk.year, uk.month, uk.day, 19, 0, 0);
  const timeline = getDraftTimelineFromStart(day1Tonight);
  const finish = pickSecretFinishFromTimeline(timeline);
  if (!timeline || !finish) {
    return { draftStartISO: null, randomFinishISO: null };
  }

  // After (or at) tonight's 19:00 → exact normal Day-1 = 19:00 UK (live now)
  if (now.getTime() >= day1Tonight.getTime()) {
    return {
      draftStartISO: day1Tonight.toISOString(),
      randomFinishISO: finish.toISOString(),
    };
  }

  // Before 19:00 → open immediately, keep the usual Day-2 finish from tonight's 19:00
  return {
    draftStartISO: new Date(now.getTime() - 5000).toISOString(),
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
    syncActiveDraftClockFromKind();
    if (
      isDraftCountdownActive() &&
      nowMs - __lastCountdownBiddingRefreshMs >= DRAFT_BIDDING_OPEN_POLL_MS
    ) {
      __lastCountdownBiddingRefreshMs = nowMs;
      await refreshDraftBiddingOpen();
      syncActiveDraftClockFromKind();
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
  const compactCountdown = () =>
    document.body.classList.contains("page-dashboard") &&
    window.matchMedia("(max-width: 900px)").matches;

  if (!isDraftCountdownActive()) {
    if (container) container.style.display = "none";
    stopDraftCountdown();
    return;
  }

  if (container) container.style.display = "";

  startDraftCountdown((tick) => {
    const { phase, ms, label, target, countUp, frozen, finishInstant } = tick;
    const kind = getPageDraftCountdownKind();
    const compact = compactCountdown();
    const revealedFinish = resolveRevealedFinishInstant(finishInstant);
    if (phase === "ended") {
      if (isValidInstant(revealedFinish)) {
        const { duration, subline } = formatDraftConclusionLines(
          revealedFinish,
          kind,
          { compact }
        );
        el.textContent = duration;
        if (localEl) {
          localEl.textContent = compact ? "" : subline;
          localEl.hidden = compact;
        }
      } else {
        el.textContent = prefixDraftCountdownDuration(label, kind, { compact });
        if (localEl) {
          localEl.textContent = compact ? "" : draftCountdownEndedSubline(kind);
          localEl.hidden = compact;
        }
      }
      return;
    }

    const { duration, subline } = formatLiveCountdownLines(label, ms, target, {
      countUp,
      frozen,
      finishInstant: revealedFinish,
    });
    el.textContent = prefixDraftCountdownDuration(duration, kind, { compact });
    if (localEl) {
      const line =
        subline || (!frozen && target ? formatTargetTimesSubline(target) : "");
      localEl.textContent = compact ? "" : line;
      localEl.hidden = compact;
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
    "transfer_window_open, draft_auction_enabled, manager_draft_auction_enabled, club_auction_enabled, draft_auction_start_time, manager_draft_auction_start_time, club_auction_start_time, draft_bidding_open, manager_draft_bidding_open, club_auction_bidding_open, draft_random_finish_revealed, manager_draft_random_finish_revealed, club_auction_random_finish_revealed",
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
        "loadGlobalSettings: per-type schedule columns missing — run patches/draft_schedules_per_type.sql",
        error
      );
    }
  }

  applyDraftBiddingOpenFromSettings(data);

  const parseStart = (raw) => {
    const d = new Date(raw);
    return isValidDate(d) ? new Date(d) : null;
  };

  playerDraftStart = parseStart(data?.draft_auction_start_time);
  managerDraftStart = parseStart(
    data?.manager_draft_auction_start_time ?? data?.draft_auction_start_time
  );
  // Only inherit the player draft start when club auction is actually enabled.
  clubDraftStart = parseStart(
    data?.club_auction_start_time ??
      (clubAuctionEnabled ? data?.draft_auction_start_time : null)
  );

  applyDraftRandomFinishRevealed(data);
  syncActiveDraftClockFromKind();

  return {
    draftEnabled,
    managerDraftEnabled,
    clubAuctionEnabled,
    draftStart,
    playerDraftStart,
    managerDraftStart,
    clubDraftStart,
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
  const isMemberHome =
    String(homeHref || "").toLowerCase().includes("waiting_list") ||
    String(homeHref || "").toLowerCase().includes("member_home");
  const label = isMemberHome ? "Home" : "Dashboard";
  const title = escapeNavAttr(
    isMemberHome
      ? "Waiting list home"
      : ownerClub?.name
        ? `${ownerClub.name} — Dashboard`
        : "Dashboard"
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
    `<span class="nav-dashboard-home-label">${label}</span>` +
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

function renderNavStaffAlertsLink(active, unread) {
  const n = Number(unread) || 0;
  return (
    `<a href="admin_staff_alerts.html" class="nav-shortcut nav-staff-alerts${
      active ? " active" : ""
    }${n > 0 ? " has-unread" : ""}" title="Staff alerts" aria-label="Staff alerts${
      n > 0 ? `, ${n} unread` : ""
    }">` +
    `<span class="nav-staff-alerts-mark" aria-hidden="true">⚠</span>` +
    (n > 0
      ? `<span class="nav-inbox-badge">${n > 99 ? "99+" : n}</span>`
      : "") +
    `</a>`
  );
}

async function countStaffAlertsUnread() {
  try {
    const { data, error } = await supabase.rpc("gpsl_staff_alerts_unread_count");
    if (error) {
      console.warn("gpsl_staff_alerts_unread_count:", error.message);
      return 0;
    }
    return Number(data) || 0;
  } catch (err) {
    console.warn("staff alerts unread:", err);
    return 0;
  }
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

/** Single shared Club Wire module instance (nav badge + dashboard card share one poll). */
export function loadClubWire() {
  return import(`./club_wire.js?v=${GLOBAL_JS_VERSION}`);
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

/** Matchday checklist "your move" count on the Match Day nav link + its group. */
export async function refreshMatchdayNavBadge() {
  const nav = document.getElementById("nav");
  if (!nav) return;
  let count = 0;
  try {
    const { data, error } = await supabase.rpc("matchday_checklist_count");
    if (!error) count = Number(data) || 0;
  } catch {
    count = 0;
  }
  const label = count > 99 ? "99+" : String(count);
  const title = `${count} matchday item${count === 1 ? "" : "s"} need you`;
  nav.querySelectorAll(".nav-mc-badge").forEach((el) => el.remove());
  if (count <= 0) return;
  nav.querySelectorAll('a[href^="matchday.html"]').forEach((link) => {
    const badge = document.createElement("span");
    badge.className = "nav-group-staff-badge nav-mc-badge";
    badge.title = title;
    badge.textContent = label;
    link.appendChild(badge);
    const summary = link.closest("[data-nav-group]")?.querySelector(".nav-group-summary");
    if (summary && !summary.querySelector(".nav-mc-badge")) {
      const groupBadge = badge.cloneNode(true);
      summary.appendChild(groupBadge);
    }
  });
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

const EXPIRING_NAV_CACHE_KEY = "gpsl_expiring_market_live_v1";
const EXPIRING_NAV_CACHE_MS = 5 * 60_000;

/** Contested final-year market — Active badge when any players are listed. */
async function refreshExpiringContractNavLive() {
  try {
    // The full market RPC is heavy; the badge only needs yes/no — share across pages for 5 min
    try {
      const cached = JSON.parse(sessionStorage.getItem(EXPIRING_NAV_CACHE_KEY) || "null");
      if (cached && Date.now() - cached.at < EXPIRING_NAV_CACHE_MS) {
        expiringContractMarketLive = cached.live === true;
        return;
      }
    } catch {
      /* ignore bad cache */
    }
    const { data, error } = await supabase.rpc("list_expiring_contract_market");
    if (error) {
      // Schema not applied yet — fail quiet
      expiringContractMarketLive = false;
      return;
    }
    expiringContractMarketLive = Array.isArray(data) && data.length > 0;
    try {
      sessionStorage.setItem(
        EXPIRING_NAV_CACHE_KEY,
        JSON.stringify({ at: Date.now(), live: expiringContractMarketLive })
      );
    } catch {
      /* storage full / private mode */
    }
  } catch (err) {
    console.warn("refreshExpiringContractNavLive:", err);
    expiringContractMarketLive = false;
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
  /* Inline wins over stale cached dashboard.css?v=… (phones were stuck on vertical menus). */
  if (!document.getElementById("gpsl-nav-horizontal-fix")) {
    const style = document.createElement("style");
    style.id = "gpsl-nav-horizontal-fix";
    style.textContent = `
#nav .gpsl-nav-row-menus{
  display:flex!important;flex-direction:row!important;flex-wrap:nowrap!important;
  align-items:stretch!important;overflow:visible!important;
}
#nav .gpsl-nav-groups{
  display:flex!important;flex-direction:row!important;flex-wrap:nowrap!important;
  align-items:stretch!important;width:auto!important;min-width:0!important;flex:1 1 auto!important;
  overflow:visible!important;
}
#nav .nav-group{position:relative;flex:0 0 auto!important;width:auto!important;max-width:none!important;}
#nav .nav-group-summary{width:auto!important;white-space:nowrap;}
#nav .gpsl-nav-actions-primary{
  display:flex!important;flex-direction:row!important;flex-wrap:nowrap!important;
  flex:0 0 auto!important;width:auto!important;margin-left:auto!important;
  position:relative;z-index:2;background:#1a1a1a;
}
#nav .nav-dropdown{position:absolute!important;top:100%!important;left:0!important;z-index:1200!important;}
#nav .nav-group.open .nav-dropdown{display:flex!important;flex-direction:column!important;}
@media (max-width:1400px){
  #nav .nav-natter-label,#nav .nav-season-calendar-label,
  #nav .nav-dashboard-home-label,#nav .nav-gpsl-sport-label,
  #nav .nav-fantasy-label{display:none!important;}
}
@media (max-width:1280px){
  #nav .gpsl-nav-row-menus{flex-wrap:wrap!important;overflow:visible!important;}
  #nav .gpsl-nav-groups{flex:1 1 100%!important;width:100%!important;max-width:100%!important;overflow-x:auto!important;overflow-y:visible!important;}
  #nav .gpsl-nav-groups:has(.nav-group.open){overflow:visible!important;}
  #nav .gpsl-nav-actions-primary{
    flex:1 1 100%!important;width:100%!important;max-width:100%!important;margin-left:0!important;
    justify-content:center!important;border-left:none!important;border-top:1px solid #333!important;
  }
}
`.replace(/\s+/g, " ").trim();
    document.head.appendChild(style);
  }
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
  if (!document.getElementById("gpsl-nav-force-horizontal")) {
    const force = document.createElement("link");
    force.id = "gpsl-nav-force-horizontal";
    force.rel = "stylesheet";
    try {
      force.href = new URL(
        `nav_force_horizontal.css?v=${GLOBAL_JS_VERSION}`,
        import.meta.url
      ).href;
    } catch {
      force.href = `nav_force_horizontal.css?v=${GLOBAL_JS_VERSION}`;
    }
    document.head.appendChild(force);
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
  const title =
    kind === "expiring"
      ? "Contested expiring-contract market has players"
      : "Bidding is open";
  return `<span class="nav-auction-active${hidden}" title="${title}" aria-hidden="${visible ? "false" : "true"}">Active</span>`;
}

const NAV_MENU_ICON_FILES = {
  boardroom: { src: "images/nav/boardroom.svg", title: "Boardroom" },
  club_details: { src: "images/nav/club_details.svg", title: "Club Details" },
  owner_details: { src: "images/nav/owner_details.svg", title: "Owner Details" },
  finances: { src: "images/nav/finances.svg", title: "Club Finances" },
  building_society: {
    src: "images/nav/building_society.svg",
    title: "GPSL Building Society",
  },
  club_history: { src: "images/nav/club_history.svg", title: "Club History" },
  stadium: { src: "images/nav/stadium.svg", title: "Stadium" },
  challenges: { src: "images/nav/challenges.svg", title: "Challenges" },
  matchday: { src: "images/nav/matchday.svg", title: "Match Day" },
  fixtures: { src: "images/nav/fixtures.svg", title: "Fixtures" },
  friendlies: { src: "images/nav/friendlies.svg", title: "Friendlies" },
  nation_select: {
    src: "images/nav/nation_select.svg",
    title: "Nation selection",
  },
  nation_player_pool: {
    src: "images/nav/nation_player_pool.svg",
    title: "Nation player pool",
  },
  transfer_center: {
    src: "images/nav/transfer_center.svg",
    title: "Transfer Centre",
  },
  scouting_targets: {
    src: "images/nav/scouting_targets.svg",
    title: "Scouting Targets",
  },
  scouting_board: {
    src: "images/nav/scouting_board.svg",
    title: "Scouting board",
  },
  clubs: { src: "images/nav/clubs.svg", title: "Clubs" },
  tables: { src: "images/nav/tables.svg", title: "Tables" },
  playoffs: { src: "images/nav/playoffs.svg", title: "Playoffs" },
  stats: { src: "images/nav/stats.svg", title: "Stats" },
  injuries: { src: "images/nav/injuries.svg", title: "Injuries" },
  // Real GPSL trophy art (same assets as cup pages)
  league_cup: {
    src: "images/trophies/league_cup.png",
    title: "League Cup",
    trophy: true,
  },
  world_cup: {
    src: "images/trophies/world_cup.png",
    title: "World Cup",
    trophy: true,
  },
  super8: {
    src: "images/trophies/super8.png",
    title: "Super8",
    trophy: true,
  },
  plate: { src: "images/trophies/plate.png", title: "Plate", trophy: true },
  shield: { src: "images/trophies/shield.png", title: "Shield", trophy: true },
  bowl: { src: "images/trophies/bowl.png", title: "Bowl", trophy: true },
};

function navInlineIconHtml(title, svgInner) {
  return (
    `<span class="nav-menu-icon" title="${escapeNavAttr(title)}" aria-hidden="true">` +
    `<svg viewBox="0 0 20 20" width="18" height="18" focusable="false">${svgInner}</svg>` +
    `</span>`
  );
}

function navLinkLeadingHtml(item) {
  if (item?.navIcon === "first_aid") {
    return (
      `<span class="nav-first-aid" title="Medical Room" aria-hidden="true">` +
      `<svg viewBox="0 0 20 20" width="16" height="16" focusable="false">` +
      `<rect x="1" y="1" width="18" height="18" rx="3" fill="#8b1a1a"/>` +
      `<rect x="8" y="4" width="4" height="12" fill="#f5f5f5"/>` +
      `<rect x="4" y="8" width="12" height="4" fill="#f5f5f5"/>` +
      `</svg></span>`
    );
  }
  // Inline so League icons still show if images/nav/*.svg is not deployed yet.
  if (item?.navIcon === "clubs") {
    return navInlineIconHtml(
      "Clubs",
      `<path d="M10 1.8 L16.2 4 V9.4 C16.2 13.8 13.4 17.2 10 18.6 C6.6 17.2 3.8 13.8 3.8 9.4 V4 Z" fill="#1e3a5f"/>` +
        `<path d="M10 3.2 L14.8 5 V9.3 C14.8 12.8 12.6 15.6 10 16.8 C7.4 15.6 5.2 12.8 5.2 9.3 V5 Z" fill="#2e5a8f"/>` +
        `<circle cx="10" cy="8.6" r="2.4" fill="#f0c14b"/>` +
        `<circle cx="10" cy="8.6" r="1.55" fill="#1e3a5f"/>` +
        `<path d="M10 7.2c.35.3.6.75.7 1.25h-1.4c.1-.5.35-.95.7-1.25zm-1.45 1.55c.1.55.4 1 .8 1.3-.45-.1-.85-.4-1.1-.8.1-.15.2-.3.3-.5zm2.1 0c.1.2.2.35.3.5-.25.4-.65.7-1.1.8.4-.3.7-.75.8-1.3zm-1.85-1.05c-.35.25-.6.65-.75 1.1h.8c0-.4.15-.75.4-1.05-.15 0-.3 0-.45-.05zm1.2 0c-.15.05-.3.05-.45.05.25.3.4.65.4 1.05h.8c-.15-.45-.4-.85-.75-1.1z" fill="#f5f5f5"/>` +
        `<rect x="6.8" y="12.2" width="6.4" height="1.15" rx="0.4" fill="#d0d7e2"/>` +
        `<rect x="7.6" y="14" width="4.8" height="1.05" rx="0.4" fill="#8aa4c4"/>`
    );
  }
  if (item?.navIcon === "injuries") {
    return navInlineIconHtml(
      "Injuries",
      `<rect x="1.5" y="1.5" width="17" height="17" rx="3.2" fill="#8b1a1a"/>` +
        `<rect x="2.7" y="2.7" width="14.6" height="14.6" rx="2.4" fill="#a82828"/>` +
        `<rect x="8.5" y="4.6" width="3" height="10.8" rx="0.7" fill="#f5f5f5"/>` +
        `<rect x="4.6" y="8.5" width="10.8" height="3" rx="0.7" fill="#f5f5f5"/>`
    );
  }
  if (item?.navIcon === "friendlies") {
    return navInlineIconHtml(
      "Friendlies",
      `<rect x="1.6" y="4" width="16.8" height="12" rx="2" fill="#2a6b45"/>` +
        `<rect x="2.5" y="4.9" width="15" height="10.2" rx="1.2" fill="none" stroke="#a8d4b5" stroke-width="0.75"/>` +
        `<line x1="10" y1="4.9" x2="10" y2="15.1" stroke="#a8d4b5" stroke-width="0.65" stroke-dasharray="1.4 1.1"/>` +
        `<circle cx="10" cy="10" r="2.2" fill="none" stroke="#a8d4b5" stroke-width="0.65" stroke-dasharray="1.2 1"/>` +
        `<circle cx="14.4" cy="13.6" r="3.5" fill="#1a1a1a"/>` +
        `<circle cx="14.4" cy="13.6" r="3.1" fill="#f5f5f5"/>` +
        `<path d="M14.4 10.7c.65.55 1.1 1.35 1.3 2.3h-2.6c.2-.95.65-1.75 1.3-2.3zm-2.7 2.9c.15 1 .7 1.85 1.5 2.4-.85-.2-1.55-.75-2-1.5.2-.3.35-.6.5-.9zm3.9 0c.15.3.3.6.5.9-.45.75-1.15 1.3-2 1.5.8-.55 1.35-1.4 1.5-2.4zm-3.3-2.25c-.55.4-1 1.05-1.2 1.8h1.45c0-.65.25-1.2.65-1.7-.3 0-.6-.05-.9-.1zm2.7 0c-.3.05-.6.1-.9.1.4.5.65 1.05.65 1.7h1.45c-.2-.75-.65-1.4-1.2-1.8z" fill="#2c3e50"/>` +
        `<path d="M4.2 8.2 C5.1 7.1 6.6 7.1 7.5 8.2" stroke="#f0c14b" stroke-width="1.15" stroke-linecap="round" fill="none"/>` +
        `<path d="M4.2 8.2 C4.5 9.6 5.2 10.4 5.85 10.4 C6.5 10.4 7.2 9.6 7.5 8.2" stroke="#f0c14b" stroke-width="1.15" stroke-linecap="round" fill="none"/>`
    );
  }
  if (item?.navIcon === "nation_select") {
    return navInlineIconHtml(
      "Nation selection",
      `<circle cx="9.2" cy="10" r="7.2" fill="#1e3a5f"/>` +
        `<circle cx="9.2" cy="10" r="7.2" fill="none" stroke="#4a7fb0" stroke-width="0.7"/>` +
        `<ellipse cx="9.2" cy="10" rx="3.2" ry="7.2" fill="none" stroke="#6a9ad0" stroke-width="0.65"/>` +
        `<path d="M2.2 10 H16.2" stroke="#6a9ad0" stroke-width="0.65"/>` +
        `<path d="M3.4 6.4 H15" stroke="#4a7fb0" stroke-width="0.55"/>` +
        `<path d="M3.4 13.6 H15" stroke="#4a7fb0" stroke-width="0.55"/>` +
        `<path d="M13.2 3.2 L13.2 11.2" stroke="#2c3e50" stroke-width="1.15" stroke-linecap="round"/>` +
        `<path d="M13.2 3.2 H18 L16.9 5.1 L18 7 H13.2 Z" fill="#c0392b"/>`
    );
  }
  if (item?.navIcon === "nation_player_pool") {
    return navInlineIconHtml(
      "Nation player pool",
      `<circle cx="5.2" cy="6.2" r="2.1" fill="#d0d7e2"/>` +
        `<path d="M1.8 12.2 C1.8 9.9 3.3 8.4 5.2 8.4 C7.1 8.4 8.6 9.9 8.6 12.2 Z" fill="#2e5a8f"/>` +
        `<circle cx="10.4" cy="5.6" r="2.35" fill="#e8eef4"/>` +
        `<path d="M6.6 12.6 C6.6 10 8.3 8.2 10.4 8.2 C12.5 8.2 14.2 10 14.2 12.6 Z" fill="#1e3a5f"/>` +
        `<circle cx="15.4" cy="6.2" r="2.1" fill="#d0d7e2"/>` +
        `<path d="M12 12.2 C12 9.9 13.5 8.4 15.4 8.4 C17.3 8.4 18.8 9.9 18.8 12.2 Z" fill="#2e5a8f"/>` +
        `<rect x="8.6" y="13.6" width="1.15" height="4.2" rx="0.35" fill="#2c3e50"/>` +
        `<path d="M9.75 13.7 H14.4 L13.5 15.15 L14.4 16.6 H9.75 Z" fill="#c0392b"/>`
    );
  }
  if (item?.navIcon === "rewards") {
    return (
      `<span class="nav-rewards-icon" title="Rewards Centre" aria-hidden="true">` +
      `<img src="images/nav/rewards_medal.png?v=20260717-alpha" alt="" width="18" height="18" loading="lazy" />` +
      `</span>`
    );
  }
  const menuIcon = item?.navIcon ? NAV_MENU_ICON_FILES[item.navIcon] : null;
  if (menuIcon) {
    const trophyCls = menuIcon.trophy ? " nav-menu-icon--trophy" : "";
    return (
      `<span class="nav-menu-icon${trophyCls}" title="${escapeNavAttr(menuIcon.title)}" aria-hidden="true">` +
      `<img src="${escapeNavAttr(menuIcon.src)}?v=20261022-cups-nav" alt="" width="18" height="18" loading="lazy" />` +
      `</span>`
    );
  }
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
  return (
    `<span class="nav-link-leading">${navLinkLeadingHtml(item)}</span>` +
    `<span class="nav-link-body">` +
    auction +
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

function navListingPathClass(item, currentFile = currentNavPageFile()) {
  if (!item?.listingNav) return "";
  if (!isNavListingActive(item.listingNav)) return "";
  if (isOnNavListingTargetPage(item.listingNav, currentFile)) return "";
  return " nav-listing-path";
}

/** Green left path on live auction links (same stripe as Transfer Market). */
function navAuctionPathClass(item, currentFile = currentNavPageFile()) {
  if (!item?.auctionNav) return "";
  if (!isNavAuctionActive(item.auctionNav)) return "";
  if (isOnNavAuctionRelatedPage(item.auctionNav, currentFile)) return "";
  return " nav-auction-path";
}

/** Live auction pages + related databases (path highlight stops on these). */
const NAV_AUCTION_RELATED_PAGES = {
  player: ["draftauction.html", "gpdb.html"],
  manager: ["manager_draftauction.html", "mgdb.html"],
  club: ["club_auction.html", "club_database.html"],
  special: ["special_auction.html", "special_auction_gauntlet.html"],
  expiring: ["expiring_contracts.html"],
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
  expiring: "expiring_contracts.html",
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

function isOnNavListingTargetPage(kind, currentFile) {
  const file = String(currentFile || "").toLowerCase();
  const target = NAV_LISTING_TARGETS[kind];
  return target?.toLowerCase() === file;
}

/** Any live Transfer / Manager Market listing (all owners see the same nav cue). */
async function loadNavClubListingFlags(_clubShort) {
  const nowIso = new Date().toISOString();
  const [playerRes, managerRes] = await Promise.all([
    supabase
      .from("Player_Transfer_Listings")
      .select("id", { count: "exact", head: true })
      .neq("listing_type", "draft")
      .in("status", ["Active", "Pending Window", "Review", "Seller Review"]),
    supabase
      .from("Manager_Transfer_Listings")
      .select("id", { count: "exact", head: true })
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

/** Reload whether Transfer / Manager Market has live listings (nav path for all owners). */
export async function refreshNavClubListingState(clubShort) {
  try {
    const flags = await loadNavClubListingFlags(clubShort);
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

/** Vertical path bars on Transfers + subgroup + live auction links until the page is open. */
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

  nav.querySelectorAll("[data-auction-nav]").forEach((link) => {
    const kind = link.dataset.auctionNav;
    if (!kind) return;
    const show =
      isNavAuctionActive(kind) && !isOnNavAuctionRelatedPage(kind, currentFile);
    link.classList.toggle("nav-auction-path", show);
  });

  if (showTransfersPath && transfersGroup) {
    transfersGroup.classList.add("nav-auction-path");
  }
}

/** Green bar on Transfer / Manager Market when any live listing is on that market. */
export function refreshNavListingIndicators() {
  const nav = document.getElementById("nav");
  if (!nav) return;

  const currentFile = currentNavPageFile();
  nav.querySelectorAll(".nav-listing-path").forEach((el) => {
    if (el.matches(".nav-group, .nav-subgroup")) {
      el.classList.remove("nav-listing-path");
    }
  });

  let showPlayer = false;
  let showManager = false;

  nav.querySelectorAll("[data-listing-nav]").forEach((link) => {
    const kind = link.dataset.listingNav;
    if (!kind) return;
    const show =
      isNavListingActive(kind) && !isOnNavListingTargetPage(kind, currentFile);
    link.classList.toggle("nav-listing-path", show);
    if (kind === "player" && show) showPlayer = true;
    if (kind === "manager" && show) showManager = true;
  });

  // Highlight parent Transfers group + Players/Managers subgroups (same green path as auctions)
  const transfersGroup = nav.querySelector('[data-nav-auction-section="transfers"]');
  if (transfersGroup && (showPlayer || showManager)) {
    transfersGroup.classList.add("nav-listing-path");
  }
  nav.querySelectorAll(".nav-subgroup").forEach((subgroup) => {
    const kinds = (subgroup.getAttribute("data-listing-section") || "")
      .split(",")
      .map((k) => k.trim())
      .filter(Boolean);
    if (
      (kinds.includes("player") && showPlayer) ||
      (kinds.includes("manager") && showManager)
    ) {
      subgroup.classList.add("nav-listing-path");
    }
  });
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
    // Background tabs left open were polling all day
    if (document.visibilityState === "hidden") return;
    Promise.all([
      draftEnabled || managerDraftEnabled || clubAuctionEnabled
        ? refreshDraftBiddingOpen().catch((err) => {
            console.warn("nav auction badge refresh:", err);
          })
        : Promise.resolve(),
      refreshSpecialAuctionNavLive().then(() => refreshNavAuctionIndicators()),
      refreshExpiringContractNavLive().then(() => refreshNavAuctionIndicators()),
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
      item.adminMainMega ||
      item.testingMega ||
      item.modPreviewMega
  );
  if (!hasHeadings) {
    let flat = "";
    const currentFile = currentNavPageFile();
    for (const item of items) {
      if (!item.href) continue;
      const active = isNavItemActive(item, pathname, search);
      const indent = item.indent
        ? ` nav-link-sub${item.indent === 2 ? " nav-link-sub2" : ""}`
        : "";
      const auctionAttr = item.auctionNav
        ? ` data-auction-nav="${item.auctionNav}"`
        : "";
      const listingAttr = item.listingNav
        ? ` data-listing-nav="${item.listingNav}"`
        : "";
      const externalAttr = item.external
        ? ` target="_blank" rel="noopener noreferrer"`
        : "";
      flat += `<a href="${item.href}" class="nav-link${indent}${
        active ? " active" : ""
      }${navListingPathClass(item, currentFile)}${navAuctionPathClass(
        item,
        currentFile
      )}"${auctionAttr}${listingAttr}${externalAttr}>${navLinkInnerHtml(item)}</a>`;
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
  const currentFile = currentNavPageFile();

  const renderLink = (item, active) => {
    const indent = item.indent
      ? ` nav-link-sub${item.indent === 2 ? " nav-link-sub2" : ""}`
      : "";
    const danger = item.navDanger ? " nav-link-danger" : "";
    const checklist = item.navChecklist ? " nav-link-checklist" : "";
    const auctionAttr = item.auctionNav
      ? ` data-auction-nav="${item.auctionNav}"`
      : "";
    const listingAttr = item.listingNav
      ? ` data-listing-nav="${item.listingNav}"`
      : "";
    const externalAttr = item.external
      ? ` target="_blank" rel="noopener noreferrer"`
      : "";
    return `<a href="${item.href}" class="nav-link${indent}${danger}${checklist}${
      active ? " active" : ""
    }${navListingPathClass(item, currentFile)}${navAuctionPathClass(
      item,
      currentFile
    )}"${auctionAttr}${listingAttr}${externalAttr}>${navLinkInnerHtml(item)}</a>`;
  };

  const flushPanel = () => {
    if (!panelLabel) return;
    const kindsAttr = panelAuctionKinds.length
      ? ` data-auction-kinds="${panelAuctionKinds.join(",")}"`
      : "";
    const listingKindsAttr = panelListingKinds.length
      ? ` data-listing-section="${[...new Set(panelListingKinds)].join(",")}"`
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
    if (
      item.adminMainMega ||
      item.testingMega ||
      item.modPreviewMega
    ) {
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
    try {
      localStorage.removeItem(SITE_LOGIN_LS_KEY);
    } catch {
      /* ignore */
    }
    await supabase.auth.signOut();
    window.location = "login.html";
  };
}

function adminNavText(el) {
  return (el?.textContent || "").replace(/\s+/g, " ").trim().toLowerCase();
}

function adminNavShowAllUnder(el) {
  if (!el) return;
  el.classList.remove("nav-search-hidden");
  el.querySelectorAll(".nav-search-hidden").forEach((node) => {
    node.classList.remove("nav-search-hidden");
  });
  if (el.matches?.("[data-nav-subgroup]")) adminNavForceOpen(el);
  el.querySelectorAll?.("[data-nav-subgroup]").forEach((subgroup) => {
    adminNavForceOpen(subgroup);
  });
}

function adminNavRememberOpen(subgroup) {
  if (subgroup.dataset.searchOpened === "1") return;
  subgroup.dataset.searchWasOpen = subgroup.classList.contains("open") ? "1" : "0";
  subgroup.dataset.searchOpened = "1";
}

function adminNavForceOpen(subgroup) {
  adminNavRememberOpen(subgroup);
  subgroup.classList.add("open");
  subgroup
    .querySelector(":scope > .nav-subgroup-summary")
    ?.setAttribute("aria-expanded", "true");
}

function adminNavRestoreOpen(dropdown) {
  dropdown.querySelectorAll("[data-search-opened]").forEach((subgroup) => {
    const wasOpen = subgroup.dataset.searchWasOpen === "1";
    subgroup.classList.toggle("open", wasOpen);
    subgroup
      .querySelector(":scope > .nav-subgroup-summary")
      ?.setAttribute("aria-expanded", wasOpen ? "true" : "false");
    delete subgroup.dataset.searchOpened;
    delete subgroup.dataset.searchWasOpen;
  });
}

function adminNavApplyFilterToNode(el, query, filtering) {
  if (!(el instanceof Element)) return false;
  if (
    el.classList.contains("nav-admin-search") ||
    el.classList.contains("nav-admin-search-empty")
  ) {
    return false;
  }

  if (el.matches("a.nav-link")) {
    const match = !filtering || adminNavText(el).includes(query);
    el.classList.toggle("nav-search-hidden", !match);
    return match;
  }

  if (el.matches("[data-nav-subgroup]")) {
    const summary = el.querySelector(":scope > .nav-subgroup-summary");
    const panel = el.querySelector(":scope > .nav-subgroup-panel");
    const labelMatch =
      !filtering || adminNavText(summary).includes(query);

    let childMatch = false;
    for (const child of panel?.children || []) {
      if (filtering && labelMatch) {
        adminNavShowAllUnder(child);
        childMatch = true;
        continue;
      }
      if (adminNavApplyFilterToNode(child, query, filtering)) childMatch = true;
    }

    const show = !filtering || labelMatch || childMatch;
    el.classList.toggle("nav-search-hidden", !show);
    if (filtering && show) adminNavForceOpen(el);
    return show;
  }

  return false;
}

function applyAdminNavSearch(dropdown, rawQuery) {
  if (!dropdown) return;
  const query = String(rawQuery || "")
    .trim()
    .toLowerCase();
  const filtering = query.length > 0;
  const emptyEl = dropdown.querySelector(".nav-admin-search-empty");

  if (!filtering) {
    dropdown.querySelectorAll(".nav-search-hidden").forEach((node) => {
      node.classList.remove("nav-search-hidden");
    });
    adminNavRestoreOpen(dropdown);
    if (emptyEl) emptyEl.hidden = true;
    dropdown.classList.remove("nav-admin-filtering");
    return;
  }

  dropdown.classList.add("nav-admin-filtering");
  let any = false;
  for (const child of dropdown.children) {
    if (adminNavApplyFilterToNode(child, query, true)) any = true;
  }
  if (emptyEl) emptyEl.hidden = any;
}

function clearAdminNavSearch(group) {
  const dropdown = group?.querySelector(".nav-dropdown-admin");
  if (!dropdown) return;
  const input = dropdown.querySelector(".nav-admin-search-input");
  if (input) input.value = "";
  applyAdminNavSearch(dropdown, "");
}

function wireAdminNavSearch(nav) {
  nav.querySelectorAll("[data-nav-admin-search]").forEach((wrap) => {
    const input = wrap.querySelector(".nav-admin-search-input");
    const dropdown = wrap.closest(".nav-dropdown");
    if (!input || !dropdown || input.dataset.wired === "1") return;
    input.dataset.wired = "1";

    input.addEventListener("click", (e) => e.stopPropagation());
    input.addEventListener("mousedown", (e) => e.stopPropagation());
    input.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "Escape") {
        input.value = "";
        applyAdminNavSearch(dropdown, "");
        e.preventDefault();
      }
    });
    input.addEventListener("input", () => {
      applyAdminNavSearch(dropdown, input.value);
    });
  });
}

function wireNavGroups(nav) {
  const groups = nav.querySelectorAll("[data-nav-group]");

  const closeAll = () => {
    groups.forEach((group) => {
      clearAdminNavSearch(group);
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
        const searchInput = group.querySelector(".nav-admin-search-input");
        if (searchInput) {
          requestAnimationFrame(() => searchInput.focus());
        }
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

  wireAdminNavSearch(nav);

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
          ${renderNavSeasonCalendarLink(false)}
          ${renderNavHandbookLink(false)}
          ${renderNavNatterLink(false, 0)}
          ${renderNavFantasyLink(false)}
          ${renderNavGpslSportButton()}
          ${renderNavDashboardHomeLink(ownerClub, "dashboard.html", false)}
          ${renderNavInboxLink(false, 0)}
          ${renderNavThemeToggle()}
          <button type="button" id="logoutBtn" class="nav-logout">Logout</button>
        </div>
      </div>
    </div>
  `;
  wireNavLogout();
  wireNavThemeToggle(nav);
  refreshGpslSportNavUi();
  refreshNatterNavBadge().catch((err) => {
    console.warn("Natter nav badge skipped:", err);
  });
  try {
    const tn = await import(`./transfer_news_ticker.js?v=${GLOBAL_JS_VERSION}`);
    tn.initTransferNewsStrip();
  } catch (tnErr) {
    console.warn("Transfer news strip skipped:", tnErr);
  }
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
  let MOD_NAV_SECTION;
  let isNavItemActive;
  let sectionHasActiveItem;
  let firstActiveNavSectionId;
  let normalizeNavPath;
  let renderAdminMegaNavHtml;
  try {
    const navMod = await import(`./nav_config.js?v=${GLOBAL_JS_VERSION}`);
    NAV_SECTIONS = navMod.NAV_SECTIONS;
    ADMIN_NAV_SECTION = navMod.ADMIN_NAV_SECTION;
    MOD_NAV_SECTION = navMod.MOD_NAV_SECTION;
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
  let staffAlertsUnread = 0;
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
  await refreshExpiringContractNavLive();

  activeGpslMonthNav = "";
  try {
    const calMod = await import("./competition_calendar.js");
    const calStatus = await calMod.loadCalendarStatus(supabase);
    activeGpslMonthNav = String(calStatus?.active_gpsl_month || "").toLowerCase();
  } catch (calErr) {
    console.warn("Nav calendar month skipped:", calErr);
  }
  isGpslAdminNav = isGpslAdminUser(user);
  isGpslModOnlyNav = false;
  if (!isGpslAdminNav) {
    isGpslModOnlyNav = await fetchIsGpslModUser(true);
  } else {
    isGpslModNav = false;
  }

  if (isGpslAdminNav || isGpslModOnlyNav) {
    try {
      staffAlertsUnread = await Promise.race([
        countStaffAlertsUnread(),
        new Promise((resolve) => setTimeout(() => resolve(0), 4000)),
      ]);
    } catch (err) {
      console.warn("Staff alerts unread skipped:", err);
    }
  }

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

  const isVisitorNav = !isGpslAdminNav && user?.app_metadata?.gpsl_visitor === true;

  // Admins always get full menus (even without a club). Pre-club lock is for owners only.
  const isPreClubOwner =
    !isGpslAdminNav &&
    !isVisitorNav &&
    registrySelf?.has_club !== true &&
    (registrySelf?.is_member === true ||
      registrySelf?.needs_club_auction === true ||
      registrySelf?.status === "awaiting_club_auction");
  const memberHomeHref = "waiting_list.html";
  const homeHref = isVisitorNav
    ? "progress.html"
    : isPreClubOwner
    ? registrySelf?.needs_club_auction
      ? "awaiting_club.html"
      : memberHomeHref
    : "dashboard.html";

  const dashActive = pathNorm === normalizeNavPath(homeHref);
  const inboxActive = pathNorm === "inbox.html";
  const natterActive = pathNorm === "natter.html";
  const calendarActive = pathNorm === "season_calendar.html";
  const fantasyActive = pathNorm === "fantasy.html";
  const handbookActive = pathNorm === "learning_gpsl.html";

  let navSections = Array.isArray(NAV_SECTIONS) ? [...NAV_SECTIONS] : [];
  if (!navSections.length) {
    console.error("buildNav: NAV_SECTIONS missing from nav_config.js");
    await renderFallbackNav();
    return;
  }

  if (isVisitorNav) {
    window.GPSL_VISITOR = true;
    let visitorItems = [];
    try {
      const accessMod = await import(`./member_access.js?v=${GLOBAL_JS_VERSION}`);
      visitorItems = [...(accessMod.VISITOR_NAV_ITEMS || [])];
    } catch (visErr) {
      console.warn("Visitor nav items skipped:", visErr);
      visitorItems = [
        { href: "progress.html", label: "Tables", page: "progress" },
        { href: "cups.html", label: "Cups", page: "cups" },
        { href: "all_listings.html", label: "Transfer market", page: "all_listings" },
      ];
    }
    navSections = [{ id: "visitor", label: "Visitor — read only", items: visitorItems }];
  } else if (isPreClubOwner) {
    window.GPSL_PRE_CLUB = true;
    window.GPSL_MEMBER_HOME = homeHref;
    try {
      const accessMod = await import(`./member_access.js?v=${GLOBAL_JS_VERSION}`);
      navSections = [
        {
          id: "preclub",
          label: "The Waiting Room",
          items: [...(accessMod.PRE_CLUB_NAV_ITEMS || [])],
        },
      ];
    } catch (preErr) {
      console.warn("Pre-club nav items skipped:", preErr);
      navSections = [
        {
          id: "preclub",
          label: "The Waiting Room",
          items: [
            { href: "waiting_list.html", label: "Waiting list", page: "waiting_list" },
            { href: "awaiting_club.html", label: "Owner details", page: "awaiting_club" },
            { href: "club_database.html", label: "Club Database", page: "club_database" },
            { href: "GPDB.html", label: "Player Database", page: "gpdb" },
            { href: "MGDB.html", label: "Manager Database", page: "mgdb" },
            { href: "scouting.html", label: "Scouting", page: "scouting" },
            {
              href: "club_auction.html",
              label: "Club draft auction",
              page: "club_auction",
            },
            {
              href: "learning_gpsl.html",
              label: "Learning GPSL",
              page: "learning_gpsl",
            },
            {
              href: "video_tutorials.html",
              label: "Video tutorials",
              page: "video_tutorials",
            },
          ],
        },
      ];
    }
  }

  try {
    const vtMod = await import(`./video_tutorials_data.js?v=${GLOBAL_JS_VERSION}`);
    const vtFolders = await Promise.race([
      vtMod.loadVideoTutorialMenuFolders(supabase),
      new Promise((resolve) => setTimeout(() => resolve([]), 3000)),
    ]);
    if (vtFolders.length) {
      navSections = navSections.map((section) => {
        const items = section.items || [];
        const at = items.findIndex((it) => it.page === "video_tutorials" && !it.hash);
        if (at < 0) return section;
        const parent = items[at];
        const subs = vtFolders.map((f) => ({
          href: `video_tutorials.html#${f.slug}`,
          label: f.title,
          page: "video_tutorials",
          hash: f.slug,
          indent: parent.indent ? 2 : true,
        }));
        return { ...section, items: [...items.slice(0, at + 1), ...subs, ...items.slice(at + 1)] };
      });
    }
  } catch (vtErr) {
    console.warn("Nav video tutorial folders skipped:", vtErr);
  }

  if (isGpslAdminNav && ADMIN_NAV_SECTION?.items?.length) {
    navSections.push(ADMIN_NAV_SECTION);
  } else if (isGpslModOnlyNav && MOD_NAV_SECTION?.items?.length) {
    navSections.push(MOD_NAV_SECTION);
  }

  let html = `<div class="gpsl-nav-bar">`;
  html += `<div class="gpsl-nav-row gpsl-nav-row-menus">`;
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
          navIcon: "nation_select",
        });
      } else {
        items.unshift({
          href: "nation_select.html",
          label: "Choose your nation",
          page: "nation_select",
          navIcon: "nation_select",
        });
      }
      items.push({
        href: "nation_player_pool.html",
        label: "Nation player pool",
        page: "nation_player_pool",
        navIcon: "nation_player_pool",
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
        if (item.adminOnly && !isGpslAdminNav) return false;
        if (item.requiresDraft && !draftEnabled) return false;
        if (item.requiresSpecialAuction && !specialAuctionNavVisible) return false;
        if (item.showWhenGpslMonth) {
          const want = String(item.showWhenGpslMonth).toLowerCase();
          const onPage = item.page && pathNorm === `${item.page}.html`;
          const monthOk = activeGpslMonthNav === want;
          const adminOk = item.showForAdmin && isGpslAdminNav;
          if (!monthOk && !adminOk && !onPage) return false;
        }
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
    const activePageLabel = hasActive
      ? activeLabelForNavItems(items, pathname, search, isNavItemActive)
      : null;

    html += `<div class="nav-group${hasActive ? " nav-group-active" : ""}${
      anyAuctionActive ? " nav-group-has-auction" : ""
    }"${isTransfersSection ? ' data-nav-auction-section="transfers"' : ""} data-nav-group>`;
    html += `<button type="button" class="nav-group-summary" aria-expanded="false">${renderNavGroupSummaryLabel(
      section.label,
      escapeNavHtml,
      activePageLabel,
      [
        isTransfersSection ? navGroupAuctionBadgeHtml(anyAuctionActive) : "",
        (section.id === "admin" || section.id === "mod") && staffAlertsUnread > 0
          ? `<span class="nav-group-staff-badge" title="Unread staff alerts">${
              staffAlertsUnread > 99 ? "99+" : staffAlertsUnread
            }</span>`
          : "",
      ]
        .filter(Boolean)
        .join("")
    )}</button>`;
    const dropdownClass =
      section.id === "admin" || section.id === "mod" || section.id === "transfers"
        ? "nav-dropdown nav-dropdown-scrollable"
        : "nav-dropdown";
    const adminSearchClass = section.id === "admin" ? " nav-dropdown-admin" : "";
    html += `<div class="${dropdownClass}${adminSearchClass}" role="menu">`;
    if (section.id === "admin") {
      html += `<div class="nav-admin-search" data-nav-admin-search>`;
      html += `<input type="search" class="nav-admin-search-input" placeholder="Search admin menu…" aria-label="Search admin menu" autocomplete="off" spellcheck="false" />`;
      html += `<p class="nav-admin-search-empty" hidden>No matching pages</p>`;
      html += `</div>`;
    }
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
  if (isVisitorNav) {
    html += renderNavHandbookLink(handbookActive);
    html +=
      `<span class="nav-shortcut" title="You are browsing as a Discord visitor — read only" ` +
      `style="color:#9cf;font-weight:bold;white-space:nowrap;">👁 Visitor</span>`;
  } else if (!isPreClubOwner) {
    html += renderNavSeasonCalendarLink(calendarActive);
    html += renderNavHandbookLink(handbookActive);
    html += renderNavNatterLink(natterActive, natterUnread);
    html += renderNavFantasyLink(fantasyActive);
    html += renderNavGpslSportButton();
  } else {
    html += renderNavHandbookLink(handbookActive);
    const bal = Number(registrySelf?.pending_starting_balance);
    if (Number.isFinite(bal) && bal > 0) {
      html +=
        `<a href="awaiting_club.html" class="nav-shortcut" title="Starting bank balance" ` +
        `style="color:#9f9;font-weight:bold;white-space:nowrap;">` +
        `₿${Math.round(bal).toLocaleString("en-GB")}</a>`;
    }
  }
  if (!isVisitorNav) {
    html += renderNavDashboardHomeLink(ownerClub, homeHref, dashActive);
  }
  if (!isPreClubOwner && !isVisitorNav) {
    html += renderNavInboxLink(inboxActive, unread);
  }
  if (isGpslAdminNav || isGpslModOnlyNav) {
    const staffActive = pathNorm === "admin_staff_alerts.html";
    html += renderNavStaffAlertsLink(staffActive, staffAlertsUnread);
  }
  html += renderNavThemeToggle();
  html += `<button type="button" id="logoutBtn" class="nav-logout">Logout</button>`;
  html += `</div></div></div>`;

  nav.innerHTML = html;
  wireNavLogout();
  wireNavThemeToggle(nav);
  wireNavGroups(nav);
  refreshNavAuctionIndicators();
  refreshNavListingIndicators();
  startNavAuctionBadgeRefresh();
  refreshGpslSportNavUi();
  if (!isPreClubOwner && ownerClub) {
    void refreshMatchdayNavBadge();
    import(`./owner_ready_lock_banner.js?v=${GLOBAL_JS_VERSION}`)
      .then((m) => m.refreshOwnerReadyLockBanner())
      .catch((lockErr) => console.warn("Ready lock banner skipped:", lockErr));
  }
  if (!isVisitorNav) {
    try {
      const cw = await loadClubWire();
      cw.mountClubWireNavBadge(nav, {
        href: isPreClubOwner ? "club_auction.html" : "dashboard.html#clubWire",
      });
    } catch (cwErr) {
      console.warn("Club Wire nav badge skipped:", cwErr);
    }
  }
  if (!isPreClubOwner) {
    try {
      const sched = await import(
        `./season_transfer_schedule.js?v=${GLOBAL_JS_VERSION}`
      );
      sched.ensureSeasonScheduleStripMount();
      sched.refreshSeasonScheduleStrip();
    } catch (schedErr) {
      console.warn("Season schedule strip skipped:", schedErr);
    }
    try {
      const tn = await import(`./transfer_news_ticker.js?v=${GLOBAL_JS_VERSION}`);
      tn.ensureTransferNewsStripMount();
      tn.refreshTransferNewsStrip();
    } catch (tnErr) {
      console.warn("Transfer news strip skipped:", tnErr);
    }
  }
  } catch (err) {
    console.error("buildNav failed:", err);
    await renderFallbackNav();
  }
}

// ------------------------------------------------------------
// SITE ACTIVITY → login events (remembered sessions count too)
// ------------------------------------------------------------
const SITE_LOGIN_LS_KEY = "gpsl_site_login_at";
/** Match server debounce in record_owner_site_login (1 hour). */
const SITE_LOGIN_COOLDOWN_MS = 60 * 60 * 1000;
let siteLoginInFlight = false;

/**
 * Treat an authenticated site open / return-to-tab as a login when the session
 * was restored from storage (Windows/browser "remember me"), not only password
 * submit on login.html. Cooldown avoids counting every in-site page click.
 */
export async function recordOwnerSiteActivity() {
  if (siteLoginInFlight) return;
  try {
    const last = Number(localStorage.getItem(SITE_LOGIN_LS_KEY) || 0);
    if (Number.isFinite(last) && Date.now() - last < SITE_LOGIN_COOLDOWN_MS) {
      return;
    }

    const user = await getAuthUser();
    if (!user || user.app_metadata?.gpsl_visitor === true) return;

    siteLoginInFlight = true;
    const { error } = await supabase.rpc("record_owner_site_login");
    if (error) {
      console.warn("record_owner_site_login:", error.message);
      return;
    }
    try {
      localStorage.setItem(SITE_LOGIN_LS_KEY, String(Date.now()));
    } catch {
      /* private mode */
    }
  } catch (err) {
    console.warn("record_owner_site_login:", err);
  } finally {
    siteLoginInFlight = false;
  }
}

function wireOwnerSiteActivityTracking() {
  if (typeof window === "undefined" || window.__gpslSiteLoginWired) return;
  window.__gpslSiteLoginWired = true;
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") {
      void recordOwnerSiteActivity();
    }
  });
}

// ------------------------------------------------------------
// INITIALISATION
// ------------------------------------------------------------
export async function initGlobal() {
  window.supabase = supabase;
  ensureNavStyles();
  wireOwnerSiteActivityTracking();
  void recordOwnerSiteActivity();
  await loadGlobalSettings();
  try {
    const { enforceOwnerClubGate } = await import(
      `./owner_gate.js?v=${GLOBAL_JS_VERSION}`
    );
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
  try {
    const { applyMemberViewOnlyChrome } = await import(
      `./member_view_only.js?v=${GLOBAL_JS_VERSION}`
    );
    applyMemberViewOnlyChrome({
      homeHref: window.GPSL_MEMBER_HOME || "waiting_list.html",
    });
  } catch (err) {
    console.warn("member view-only chrome:", err);
  }

  if (document.getElementById("nav") && window.GPSL_VISITOR) {
    import(`./transfer_news_ticker.js?v=${GLOBAL_JS_VERSION}`)
      .then((m) => m.initTransferNewsStrip())
      .catch((err) => console.warn("Transfer news strip skipped:", err));
  } else if (document.getElementById("nav")) {
    initDashboardPinUi(supabase).catch((err) => {
      console.warn("Dashboard pin UI skipped:", err);
    });
    if (!window.GPSL_PRE_CLUB) {
      refreshGpslSportNavUi();
      refreshNatterNavBadge().catch((err) => {
        console.warn("Natter nav badge skipped:", err);
      });
      import(`./season_transfer_schedule.js?v=${GLOBAL_JS_VERSION}`)
        .then((m) => m.initSeasonScheduleStrip())
        .catch((err) => console.warn("Season schedule strip skipped:", err));
      import(`./transfer_news_ticker.js?v=${GLOBAL_JS_VERSION}`)
        .then((m) => m.initTransferNewsStrip())
        .catch((err) => console.warn("Transfer news strip skipped:", err));
      // Supporter club colours on owner pages when theme_scope = club_pages
      import(`./club_theme_common.js?v=${GLOBAL_JS_VERSION}`)
        .then((m) => m.initOwnerClubThemeAuto(supabase))
        .catch((err) => console.warn("Club theme auto-apply skipped:", err));
    }
  }
}
