// ===============================
// GLOBAL.JS — Shared App Logic (patched)
// ===============================

import { supabase } from "./supabase_client.js";
import { formatCountdown } from "./global_ui.js";

// GLOBAL STATE
let draftEnabled = false;
let draftStart = null;
let draftFinish = null;

// Interval handle for countdown (single instance)
let __draftCountdownInterval = null;

/* ===============================
   Time helpers (robust UK now)
   =============================== */

// Build a stable Date for the intended UK wall-clock time
function makeUKDate(year, month, day, hour = 0, minute = 0, second = 0) {
  return new Date(Date.UTC(year, month, day, hour, minute, second));
}

// Robust current time in UK (Europe/London) using formatToParts
function getUKNow() {
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
  parts.forEach(p => {
    if (p.type && p.value) map[p.type] = p.value;
  });

  const y = Number(map.year);
  const m = Number(map.month) - 1;
  const d = Number(map.day);
  const hh = Number(map.hour);
  const mm = Number(map.minute);
  const ss = Number(map.second);

  if ([y, m, d, hh, mm, ss].some(v => !isFinite(v))) {
    // fallback to local Date if something unexpected happens
    return new Date();
  }

  return makeUKDate(y, m, d, hh, mm, ss);
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

function startDraftCountdown(onTickDisplay, onEndCallback) {
  stopDraftCountdown();

  const el = document.getElementById("draftCountdown");
  if (!el) return;

  // onTickDisplay must return an object { show: boolean, text: string }
  function tick() {
    if (!draftEnabled || !isValidDate(draftStart) || !isValidDate(draftFinish)) {
      el.textContent = "";
      el.style.display = "none";
      stopDraftCountdown();
      return;
    }

    const nowUK = getUKNow();

    if (nowUK < draftStart) {
      const ms = draftStart.getTime() - nowUK.getTime();
      const text = "Draft starts in: " + formatCountdown(ms);
      const out = onTickDisplay ? onTickDisplay({ phase: "before", ms, text }) : { show: true, text };
      if (out && out.show) {
        el.style.display = "block";
        el.textContent = out.text;
      } else {
        el.style.display = "none";
      }
    } else if (nowUK >= draftStart && nowUK < draftFinish) {
      const ms = draftFinish.getTime() - nowUK.getTime();
      const text = "Draft ends in: " + formatCountdown(ms);
      const out = onTickDisplay ? onTickDisplay({ phase: "during", ms, text }) : { show: true, text };
      if (out && out.show) {
        el.style.display = "block";
        el.textContent = out.text;
      } else {
        el.style.display = "none";
      }
    } else {
      // finished
      el.textContent = "Draft auction has ended";
      el.style.display = "block";
      stopDraftCountdown();
      if (typeof onEndCallback === "function") {
        try { onEndCallback(); } catch (e) { console.error("onEndCallback error", e); }
      }
    }
  }

  // initial tick and then every second
  tick();
  __draftCountdownInterval = setInterval(tick, 1000);

  // cleanup on unload
  window.addEventListener("beforeunload", stopDraftCountdown);
}

/* ===============================
   LOAD GLOBAL SETTINGS
   =============================== */

export async function loadGlobalSettings() {
  const { data } = await supabase
    .from("global_settings")
    .select("draft_auction_enabled, draft_auction_start_time, draft_random_finish_time")
    .eq("id", 1)
    .single();

  draftEnabled = data?.draft_auction_enabled === true;

  // Defensive parsing: accept nulls and invalid strings
  function parseSafeDate(v) {
    if (!v) return null;
    try {
      const d = new Date(v);
      return isValidDate(d) ? d : null;
    } catch (e) {
      return null;
    }
  }

  draftStart = parseSafeDate(data?.draft_auction_start_time);
  draftFinish = parseSafeDate(data?.draft_random_finish_time);

  // Stop any existing countdown before starting a new one
  stopDraftCountdown();

  if (draftEnabled && isValidDate(draftStart) && isValidDate(draftFinish)) {
    // start countdown; pass a simple onTickDisplay and onEnd callback
    startDraftCountdown(
      // onTickDisplay: you can customize display logic here
      ({ phase, ms, text }) => {
        // always show the timer in the header
        return { show: true, text };
      },
      // onEndCallback: refresh global settings and UI when countdown finishes
      () => {
        // reload settings and rebuild nav; callers can also refresh page-specific UI
        loadGlobalSettings().catch(e => console.error("reload after countdown end failed", e));
      }
    );
  } else {
    // hide countdown if not enabled or invalid times
    const el = document.getElementById("draftCountdown");
    if (el) {
      el.textContent = "";
      el.style.display = "none";
    }
  }

  return { draftEnabled, draftStart, draftFinish };
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
