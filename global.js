// ===============================
// GLOBAL.JS — Shared App Logic (6-stage draft logic)
// ===============================

import { supabase } from "./supabase_client.js";
import { formatCountdown } from "./global_ui.js";

// GLOBAL STATE
let draftEnabled = false;
let draftStart = null;   // Day 1, 19:00 UK (from DB)
let draftFinish = null;  // Secret random finish time (between 18:50–18:59 UK Day 2)

// Interval handle for countdown (single instance)
let __draftCountdownInterval = null;

/* ===============================
   Time helpers (robust UK now)
   =============================== */

// Build a stable Date for the intended UK wall-clock time
function makeUKDate(year, month, day, hour = 0, minute = 0, second = 0) {
  return new Date(Date.UTC(year, month, day, hour, minute, second));
}

// Convert any Date to a UK wall-clock Date
function toUKWallClock(d) {
  if (!isValidDate(d)) return null;

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

  const parts = fmt.formatToParts(d);
  const map = {};
  parts.forEach(p => {
    if (p.type && p.value) map[p.type] = p.value;
  });

  const y = Number(map.year);
  const m = Number(map.month) - 1;
  const day = Number(map.day);
  const hh = Number(map.hour);
  const mm = Number(map.minute);
  const ss = Number(map.second);

  return makeUKDate(y, m, day, hh, mm, ss);
}

// Robust current time in UK (Europe/London)
function getUKNow() {
  const now = new Date();
  return toUKWallClock(now);
}

function isValidDate(d) {
  return d instanceof Date && !isNaN(d.getTime());
}

/* ===============================
   Countdown control helpers
   =============================== */

function stopDraftCountdown() {
  if (__draftCountdownInterval) {
    clearInterval(__draftCountdownInterval);
    __draftCountdownInterval = null;
  }
}

/**
 * 6-stage draft countdown:
 *
 * Stage 1: Before draftStart
 *   - Message: "Draft Auction Starts in: X"
 *   - Countdown target: draftStart (19:00 UK Day 1)
 *
 * Stage 2: draftStart → cutoff (18:00 UK Day 2)
 *   - Message: "Draft is live — Time until 6pm cutoff"
 *   - Countdown target: cutoff
 *
 * Stage 3: cutoff → randomStart (18:50 UK Day 2)
 *   - Message: "6pm cutoff reached — Time until random timer kicks in"
 *   - Countdown target: randomStart
 *
 * Stage 4: randomStart → draftFinish (secret random time)
 *   - Message: "Random finish window active — draft may end at any moment"
 *   - NO countdown (secret time)
 *
 * Stage 5+: now >= draftFinish
 *   - Message: "Draft auction has ended"
 *   - NO countdown
 */
function startDraftCountdown(onTickDisplay, onEndCallback) {
  stopDraftCountdown();

  const container = document.getElementById("draftCountdownContainer");
  const el = document.getElementById("draftCountdown");
  const localEl = document.getElementById("draftLocalStart");

  if (!container || !el || !localEl) return;

  function hideAll() {
    container.style.display = "none";
  }

  function showAll() {
    container.style.display = "flex";
  }

  function tick() {
    if (!draftEnabled || !isValidDate(draftStart) || !isValidDate(draftFinish)) {
      hideAll();
      stopDraftCountdown();
      return;
    }

    const nowUK = getUKNow();

    // Derive stage boundaries from draftStart
    const cutoff = new Date(draftStart.getTime() + 23 * 60 * 60 * 1000); // 6pm cutoff (Day 2)
    const randomStart = new Date(cutoff.getTime() + 50 * 60 * 1000);     // 6:50pm random window start
    const randomFinish = draftFinish;                                    // secret random end

    let ms = null;
    let phase = "";
    let line1 = "";
    let line2 = "";

    // STAGE 1 — Waiting for draft to start
    if (nowUK < draftStart) {
      ms = draftStart.getTime() - nowUK.getTime();
      phase = "before_start";

      line1 = "Draft Auction Starts in: " + formatCountdown(ms);

      const localStart = new Date(draftStart);
      line2 = `Start time: 19:00 UK | Local: ${localStart.toLocaleTimeString([], {
        hour: "2-digit",
        minute: "2-digit"
      })}`;

      showAll();
    }

    // STAGE 2 — Draft live, countdown to 6pm cutoff
    else if (nowUK >= draftStart && nowUK < cutoff) {
      ms = cutoff.getTime() - nowUK.getTime();
      phase = "live_until_cutoff";

      line1 = "Draft is live — Time until 6pm cutoff: " + formatCountdown(ms);
      line2 = "";

      showAll();
    }

    // STAGE 3 — 6pm cutoff reached, countdown to random timer start
    else if (nowUK >= cutoff && nowUK < randomStart) {
      ms = randomStart.getTime() - nowUK.getTime();
      phase = "cutoff_to_random";

      line1 = "6pm cutoff reached — Time until random timer kicks in: " + formatCountdown(ms);
      line2 = "";

      showAll();
    }

    // STAGE 4 — Random window active, NO countdown
    else if (nowUK >= randomStart && nowUK < randomFinish) {
      phase = "random_window";

      line1 = "Random finish window active — draft may end at any moment";
      line2 = "";

      showAll();
    }

    // STAGE 5+ — Draft ended
    else {
      line1 = "Draft auction has ended";
      line2 = "";

      el.textContent = line1;
      localEl.textContent = "";
      showAll();

      stopDraftCountdown();
      if (typeof onEndCallback === "function") {
        try { onEndCallback(); } catch (e) { console.error("onEndCallback error", e); }
      }
      return;
    }

    const payload = { phase, ms, text: line1 };
    const out = onTickDisplay ? onTickDisplay(payload) : { show: true, text: line1 };

    if (out.show) {
      showAll();
      el.textContent = out.text;
      localEl.textContent = line2;
    } else {
      hideAll();
    }
  }

  tick();
  __draftCountdownInterval = setInterval(tick, 1000);
  window.addEventListener("beforeunload", stopDraftCountdown);
}

/* ===============================
   LOAD GLOBAL SETTINGS
   =============================== */

export async function loadGlobalSettings() {
  const { data } = await supabase
    .from("global_settings")
    .select("transfer_window_open, draft_auction_enabled, draft_auction_start_time, draft_random_finish_time")
    .eq("id", 1)
    .single();

  console.log("RAW GLOBAL SETTINGS FROM SUPABASE:", data);

  // Parse booleans
  const transferWindowOpen = data?.transfer_window_open === true;
  const draftAuctionEnabled = data?.draft_auction_enabled === true;

  // Safe date parser
  function parseSafeDate(v) {
    if (!v) return null;
    try {
      const d = new Date(v);
      return isValidDate(d) ? d : null;
    } catch {
      return null;
    }
  }

  const draftAuctionStartTime = parseSafeDate(data?.draft_auction_start_time);
  const draftRandomFinishTime = parseSafeDate(data?.draft_random_finish_time);

  // Update internal state (convert to UK wall-clock)
  draftEnabled = draftAuctionEnabled;
  draftStart = toUKWallClock(draftAuctionStartTime);
  draftFinish = toUKWallClock(draftRandomFinishTime);

  // Reset countdown
  stopDraftCountdown();

  // Start countdown if valid
  if (draftAuctionEnabled && isValidDate(draftStart) && isValidDate(draftFinish)) {
    startDraftCountdown(
      ({ text }) => ({ show: true, text }),
      () => {
        loadGlobalSettings().catch(e =>
          console.error("reload after countdown end failed", e)
        );
      }
    );
  } else {
    const container = document.getElementById("draftCountdownContainer");
    const el = document.getElementById("draftCountdown");
    const localEl = document.getElementById("draftLocalStart");

    if (container) container.style.display = "none";
    if (el) el.textContent = "";
    if (localEl) localEl.textContent = "";
  }

  // RETURN EXACTLY WHAT gpdb_v2.js EXPECTS
  return {
    transferWindowOpen,
    draftAuctionEnabled,
    draftAuctionStartTime,
    draftRandomFinishTime
  };
}

/* ===============================
   NAVIGATION BUILDER
   =============================== */

export async function buildNav() {
  const nav = document.getElementById("nav");

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const buttons = [
    { page: "index", label: "Home", href: "index.html" },
    { page: "gpdb", label: "Player Database", href: "GPDB.html" },
    { page: "clubs", label: "Clubs", href: "clubs.html" },
    { page: "listings", label: "Transfer Market", href: "all_listings.html" },
    { page: "dashboard", label: "Dashboard", href: "dashboard.html" }
  ];

  let html = "";

  for (const btn of buttons) {
    if (btn.page !== window.CURRENT_PAGE) {
      html += `<a href="${btn.href}" class="button">${btn.label}</a>`;
    }
  }

  if (user.email === "rotavator66@outlook.com" && window.CURRENT_PAGE !== "admin") {
    html += `<a href="admin.html" class="button">GPSL Admin</a>`;
  }

  if (draftEnabled && window.CURRENT_PAGE !== "draftauction") {
    html += `<a href="draftauction.html" class="button">Draft Auction</a>`;
  }

  html += `<button id="logoutBtn" class="button">Logout</button>`;
  nav.innerHTML = html;

  document.getElementById("logoutBtn").onclick = async () => {
    await supabase.auth.signOut();
    window.location = "login.html";
  };
}

/* ===============================
   PAGE INITIALISATION
   =============================== */

export async function initGlobal() {
  await loadGlobalSettings();
  await buildNav();
}

/* ===============================
   EXPORTED HELPERS (for gpdb_v2.js)
   =============================== */

export {
  startDraftCountdown,
  stopDraftCountdown,
  getUKNow,
  isValidDate
};
