// ============================================================
// GLOBAL.JS — SINGLE SOURCE OF TRUTH FOR THE ENTIRE DRAFT SYSTEM
// ============================================================

import { supabase } from "./supabase_client.js";
import {
  getDraftTimelineFromStart,
  getDraftPhaseFromStart,
} from "./draft_timeline.js";
export { supabase };

// ------------------------------------------------------------
// GLOBAL STATE
// ------------------------------------------------------------
let draftEnabled = false;
let draftStart = null;        // Day 1 @ 19:00 UK
let draftCutoff = null;       // Day 2 @ 18:00 UK
let draftRandomStart = null;  // Day 2 @ 18:50 UK
let draftPublicEnd = null;    // Latest possible end (18:59:59 day 2) — not secret finish

// Countdown interval
let __draftCountdownInterval = null;

// ------------------------------------------------------------
// UK TIME HELPERS (THE ONLY VERSION USED ANYWHERE)
// ------------------------------------------------------------
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
  parts.forEach(p => { if (p.type && p.value) map[p.type] = p.value; });

  const y = Number(map.year);
  const m = Number(map.month) - 1;
  const d = Number(map.day);
  const hh = Number(map.hour);
  const mm = Number(map.minute);
  const ss = Number(map.second);

  return new Date(Date.UTC(y, m, d, hh, mm, ss));
}

export function makeUKDate(y, m, d, hh = 0, mm = 0, ss = 0) {
  return new Date(Date.UTC(y, m, d, hh, mm, ss));
}

export function isValidDate(d) {
  return d instanceof Date && !isNaN(d.getTime());
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

  const next19Uk = makeUKDate(map.year, map.month - 1, endDay, 19, 0, 0);

  return minEndInstant.getTime() > next19Uk.getTime() ? minEndInstant : next19Uk;
}

// ------------------------------------------------------------
// PHASE ENGINE — THE HEART OF THE SYSTEM
// ------------------------------------------------------------
export function getDraftPhase() {
  if (!draftEnabled || !isValidDate(draftStart)) {
    return "disabled";
  }

  return getDraftPhaseFromStart(getUKNow(), draftStart);
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
  const now = getUKNow();

  // Window: 19:00 yesterday → 18:00 today
  const y = now.getFullYear();
  const m = now.getMonth();
  const d = now.getDate();

  const todayMid = makeUKDate(y, m, d, 0, 0, 0);
  const yesterdayMid = new Date(todayMid.getTime() - 24 * 3600 * 1000);

  const winStart = makeUKDate(
    yesterdayMid.getUTCFullYear(),
    yesterdayMid.getUTCMonth(),
    yesterdayMid.getUTCDate(),
    19, 0, 0
  );

  const winEnd = draftCutoff; // 18:00 today

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
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return `${h}h ${m}m ${s}s`;
}

function msUntil(target) {
  if (!isValidDate(target)) return 0;
  return target.getTime() - getUKNow().getTime();
}

export function startDraftCountdown(onTick) {
  stopDraftCountdown();

  const tick = () => {
    const phase = getDraftPhase();
    const timeline = getDraftTimelineFromStart(draftStart);

    let ms = 0;
    let label = "";

    switch (phase) {
      case "before_start":
        ms = timeline ? msUntil(timeline.start) : 0;
        label = "Draft starts in";
        break;
      case "live_until_cutoff":
        ms = timeline ? msUntil(timeline.cutoff) : 0;
        label = "Auction cutoff in";
        break;
      case "random_active":
        ms = timeline ? msUntil(timeline.publicEnd) : 0;
        label = "Random window (end time hidden)";
        break;
      case "pre_random":
        ms = timeline ? msUntil(timeline.randomStart) : 0;
        label = "Random window begins in";
        break;
      case "ended":
        label = "Draft has ended";
        break;
      default:
        label = "Draft disabled";
    }

    if (onTick) onTick({ phase, ms, label });
  };

  tick();
  __draftCountdownInterval = setInterval(tick, 1000);
}

/** Updates #draftCountdown / #draftLocalStart when present (dashboard, GPDB, draft auction). */
export function wireDraftCountdownUI() {
  const el = document.getElementById("draftCountdown");
  const container = document.getElementById("draftCountdownContainer");
  const localEl = document.getElementById("draftLocalStart");
  if (!el) return;

  if (!draftEnabled || !isValidDate(draftStart)) {
    if (container) container.style.display = "none";
    stopDraftCountdown();
    return;
  }

  if (container) container.style.display = "";

  startDraftCountdown(({ phase, ms, label }) => {
    if (phase === "ended") {
      el.textContent = label;
      if (localEl) localEl.textContent = "";
      return;
    }

    if (ms > 0) {
      el.textContent = `${label}: ${formatMs(ms)}`;
    } else {
      el.textContent = label;
    }

    if (localEl) {
      if (phase === "before_start") {
        localEl.textContent = `Opens ${draftStart.toLocaleString(undefined, {
          weekday: "short",
          day: "numeric",
          month: "short",
          hour: "2-digit",
          minute: "2-digit",
        })} (your time)`;
      } else {
        localEl.textContent = "";
      }
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
    .select("transfer_window_open, draft_auction_enabled, draft_auction_start_time")
    .eq("id", 1)
    .single();

  draftEnabled = data?.draft_auction_enabled === true;

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
    transferWindowOpen: data?.transfer_window_open === true,
  };
}

// ------------------------------------------------------------
// NAV BUILDER (SKIP CURRENT PAGE BUTTON)
// ------------------------------------------------------------
export async function buildNav() {
  const nav = document.getElementById("nav");
  const { data: { user } } = await supabase.auth.getUser();

  if (!user) {
    window.location = "login.html";
    return;
  }

  // Get current page filename
  const path = window.location.pathname.toLowerCase();
  
  // Check which page we're on
  const isHome = path.includes("index");
  const isGPDB = path.includes("gpdb");
  const isClubs = path.includes("clubs") && !path.includes("all_listings");
  const isMarket = path.includes("all_listings");
  const isDashboard = path.includes("dashboard");
  const isAdmin = path.includes("admin");
  const isDraft = path.includes("draftauction") && !path.includes("draftauction_player");

  // Build nav HTML - only include buttons for pages NOT currently viewing
  let html = "";
  
  if (!isHome) {
    html += `<a id="nav-home" href="index.html" class="button">Home</a>`;
  }
  
  if (!isGPDB) {
    html += `<a id="nav-gpdb" href="GPDB.html" class="button">Player Database</a>`;
  }
  
  if (!isClubs) {
    html += `<a id="nav-clubs" href="clubs.html" class="button">Clubs</a>`;
  }
  
  if (!isMarket) {
    html += `<a id="nav-market" href="all_listings.html" class="button">Transfer Market</a>`;
  }
  
  if (!isDashboard) {
    html += `<a id="nav-dashboard" href="dashboard.html" class="button">Dashboard</a>`;
  }

  if (user.email === "rotavator66@outlook.com" && !isAdmin) {
    html += `<a id="nav-admin" href="admin.html" class="button">GPSL Admin</a>`;
  }

  if (draftEnabled && !isDraft) {
    html += `<a id="nav-draft" href="draftauction.html" class="button">Draft Auction</a>`;
  }

  html += `<button id="logoutBtn" class="button">Logout</button>`;
  nav.innerHTML = html;

  // Logout
  document.getElementById("logoutBtn").onclick = async () => {
    await supabase.auth.signOut();
    window.location = "login.html";
  };
}

// ------------------------------------------------------------
// INITIALISATION
// ------------------------------------------------------------
export async function initGlobal() {
  await loadGlobalSettings();
  wireDraftCountdownUI();
  await buildNav();
}
