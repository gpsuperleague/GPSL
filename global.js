// ============================================================
// GLOBAL.JS — SINGLE SOURCE OF TRUTH FOR THE ENTIRE DRAFT SYSTEM
// ============================================================

import { supabase } from "./supabase_client.js";
import {
  getDraftTimelineFromStart,
  getDraftPhaseFromStart,
  getDraftCountdownTick,
  isDraftAuctionEnded as isDraftAuctionEndedWithOptions,
} from "./draft_timeline.js";
import {
  formatDurationMs,
  formatLiveCountdownLines,
  formatTargetTimesSubline,
} from "./countdown_display.js";
import { countUnreadInbox } from "./competition_inbox.js";
export { supabase };

// ------------------------------------------------------------
// GLOBAL STATE
// ------------------------------------------------------------
let draftEnabled = false;
let draftStart = null;        // Day 1 @ 19:00 UK
let draftCutoff = null;       // Day 2 @ 18:00 UK
let draftRandomStart = null;  // Day 2 @ 18:50 UK
let draftPublicEnd = null;    // Latest possible end (18:59:59 day 2) — not secret finish
let draftBiddingOpen = null;  // from global_settings_public.draft_bidding_open (secret finish)

// Countdown interval
let __draftCountdownInterval = null;

export function getDraftBiddingOpen() {
  return draftBiddingOpen;
}

function draftCountdownOptions() {
  return draftBiddingOpen === null ? {} : { biddingOpen: draftBiddingOpen };
}

export function isDraftAuctionEnded(nowUK, draftAuctionStartTime) {
  return isDraftAuctionEndedWithOptions(
    nowUK,
    draftAuctionStartTime,
    draftCountdownOptions()
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

  // Load all bids for this player in this window
  const { data: bids } = await supabase
    .from("Player_Transfer_Bids")
    .select("bidder_club_id, is_first_draft_bid, is_draft_join, draft_join_consumed, bid_time")
    .eq("direct_bid_id", playerId)
    .eq("is_direct", true)
    .order("bid_time", { ascending: true });

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
  if (!draftEnabled) {
    draftBiddingOpen = false;
    return;
  }
  const { data } = await supabase
    .from("global_settings_public")
    .select("draft_bidding_open")
    .eq("id", 1)
    .single();
  draftBiddingOpen =
    data && "draft_bidding_open" in data
      ? data.draft_bidding_open === true
      : null;
}

export function startDraftCountdown(onTick) {
  stopDraftCountdown();

  const tick = async () => {
    if (draftEnabled && draftStart) {
      await refreshDraftBiddingOpen();
    }
    const tickData = getDraftCountdownTick(
      getUKNow(),
      draftStart,
      draftCountdownOptions()
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

  if (!draftEnabled || !isValidDate(draftStart)) {
    if (container) container.style.display = "none";
    stopDraftCountdown();
    return;
  }

  if (container) container.style.display = "";

  startDraftCountdown(({ phase, ms, label, target, countUp }) => {
    if (phase === "ended") {
      el.textContent = label;
      if (localEl) localEl.textContent = "";
      return;
    }

    const { duration, subline } = formatLiveCountdownLines(label, ms, target, {
      countUp,
    });
    el.textContent = duration;
    if (localEl) {
      localEl.textContent = subline || (target ? formatTargetTimesSubline(target) : "");
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
export async function loadGlobalSettings() {
  const { data } = await supabase
    .from("global_settings_public")
    .select(
      "transfer_window_open, draft_auction_enabled, draft_auction_start_time, draft_bidding_open"
    )
    .eq("id", 1)
    .single();

  draftEnabled = data?.draft_auction_enabled === true;
  draftBiddingOpen =
    data && "draft_bidding_open" in data
      ? data.draft_bidding_open === true
      : null;

  const rawStart = new Date(data?.draft_auction_start_time);
  draftStart = isValidDate(rawStart) ? new Date(rawStart) : null;

  const timeline = getDraftTimelineFromStart(draftStart);
  draftCutoff = timeline?.cutoff ?? null;
  draftRandomStart = timeline?.randomStart ?? null;
  draftPublicEnd = timeline?.publicEnd ?? null;

  return {
    draftEnabled,
    draftStart,
    draftCutoff,
    draftRandomStart,
    draftPublicEnd,
    draftBiddingOpen,
    transferWindowOpen: data?.transfer_window_open === true,
  };
}

// ------------------------------------------------------------
// NAV — Special Auction link (shared by buildNav + legacy inline navs)
// ------------------------------------------------------------
export async function specialAuctionNavLinkHtml() {
  const path = window.location.pathname.toLowerCase();
  if (path.includes("special_auction")) return "";

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

    if (!sa) return "";

    const starts = new Date(sa.start_time);
    const beforeStart = Date.now() < starts.getTime();
    const label = beforeStart
      ? `Special Auction (${starts.toLocaleString("en-GB", { hour: "2-digit", minute: "2-digit", day: "numeric", month: "short" })})`
      : "Special Auction";

    return `<a id="nav-special-auction" href="special_auction.html" class="button">${label}</a>`;
  } catch (_) {
    return "";
  }
}

// ------------------------------------------------------------
// NAV — owner club (inbox badge)
// ------------------------------------------------------------
async function getOwnerClubShort() {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;
  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();
  return club?.ShortName?.trim() || null;
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

/** @deprecated Use grouped nav; kept for any legacy inline callers */
export async function specialAuctionNavLinkHtml() {
  const item = await fetchActiveSpecialAuctionNavItem();
  if (!item) return "";
  return `<a href="${item.href}" class="nav-link">${item.label}</a>`;
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

/** Minimal nav if grouped menu fails (keeps site usable). */
export function renderFallbackNav() {
  const nav = document.getElementById("nav");
  if (!nav) return;

  nav.innerHTML = `
    <div class="gpsl-nav-bar gpsl-nav-fallback">
      <a href="dashboard.html" class="nav-shortcut nav-dashboard">Dashboard</a>
      <a href="inbox.html" class="nav-shortcut nav-inbox">📥 Inbox</a>
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
  let isNavItemActive;
  let sectionHasActiveItem;
  let normalizeNavPath;
  try {
    const navMod = await import("./nav_config.js");
    NAV_SECTIONS = navMod.NAV_SECTIONS;
    isNavItemActive = navMod.isNavItemActive;
    sectionHasActiveItem = navMod.sectionHasActiveItem;
    normalizeNavPath = navMod.normalizeNavPath;
  } catch (importErr) {
    console.error("nav_config.js failed to load:", importErr);
    renderFallbackNav();
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
    unread = clubShort
      ? await Promise.race([
          countUnreadInbox(supabase, clubShort),
          new Promise((resolve) => setTimeout(() => resolve(0), 4000)),
        ])
      : 0;
  } catch (err) {
    console.warn("Inbox count skipped:", err);
  }

  const specialAuction = await fetchActiveSpecialAuctionNavItem();

  const dashActive = pathNorm === "dashboard.html";
  const inboxActive = pathNorm === "inbox.html";
  const adminActive = pathNorm === "admin.html";

  let html = `<div class="gpsl-nav-bar">`;
  html += `<div class="gpsl-nav-shortcuts">`;
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

  html += `<div class="gpsl-nav-groups">`;

  for (const section of NAV_SECTIONS) {
    const items = section.items
      .filter((item) => {
        if (item.requiresDraft && !draftEnabled) return false;
        return true;
      })
      .map((item) => ({ ...item }));

    if (section.id === "transfers" && specialAuction) {
      items.push({ ...specialAuction });
    }

    if (!items.length) continue;

    const hasActive = sectionHasActiveItem({ items }, pathname, search);
    const open = hasActive;

    html += `<details class="nav-group${hasActive ? " nav-group-active" : ""}"${
      open ? " open" : ""
    }>`;
    html += `<summary class="nav-group-summary">${section.label}</summary>`;
    html += `<div class="nav-dropdown">`;

    for (const item of items) {
      const active = isNavItemActive(item, pathname, search);
      const indent = item.indent ? " nav-link-sub" : "";
      html += `<a href="${item.href}" class="nav-link${indent}${
        active ? " active" : ""
      }">${item.label}</a>`;
    }

    html += `</div></details>`;
  }

  html += `</div>`;

  html += `<div class="gpsl-nav-actions">`;
  if (user.email === "rotavator66@outlook.com") {
    html += `<a href="admin.html" class="nav-link nav-admin${
      adminActive ? " active" : ""
    }">Admin</a>`;
  }
  html += `<button type="button" id="logoutBtn" class="nav-logout">Logout</button>`;
  html += `</div></div>`;

  nav.innerHTML = html;
  wireNavLogout();

  nav.querySelectorAll(".nav-group").forEach((group) => {
    group.addEventListener("toggle", () => {
      if (!group.open) return;
      nav.querySelectorAll(".nav-group").forEach((other) => {
        if (other !== group) other.open = false;
      });
    });
  });
  } catch (err) {
    console.error("buildNav failed:", err);
    renderFallbackNav();
  }
}

// ------------------------------------------------------------
// INITIALISATION
// ------------------------------------------------------------
export async function initGlobal() {
  window.supabase = supabase;
  await loadGlobalSettings();
  wireDraftCountdownUI();
  try {
    await buildNav();
  } catch (err) {
    console.error("initGlobal buildNav:", err);
    renderFallbackNav();
  }
}
