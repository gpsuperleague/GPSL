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

function makeUKDate(year, month, day, hour = 0, minute = 0, second = 0) {
  return new Date(Date.UTC(year, month, day, hour, minute, second));
}

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

/* ===============================
   Unified 6‑stage countdown
   =============================== */

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

    const cutoff = new Date(draftStart.getTime() + 23 * 60 * 60 * 1000); // 18:00 UK Day 2
    const randomStart = new Date(cutoff.getTime() + 50 * 60 * 1000);     // 18:50 UK Day 2
    const randomFinish = draftFinish;

    let ms = null;
    let phase = "";
    let line1 = "";
    let line2 = "";

    /* ===============================
       STAGE 1 — BEFORE START
       =============================== */
    if (nowUK < draftStart) {
      ms = draftStart.getTime() - nowUK.getTime();
      phase = "before_start";

      line1 = "Draft Auction Starts in: " + formatCountdown(ms);

      const userTZ = Intl.DateTimeFormat().resolvedOptions().timeZone;
      let localTimeStr;

      if (userTZ === "Europe/London") {
        localTimeStr = "19:00";
      } else {
        const localStart = new Date(draftStart);
        localTimeStr = localStart.toLocaleTimeString([], {
          hour: "2-digit",
          minute: "2-digit",
          hour12: false
        });
      }

      line2 = `Start time: 19:00 UK | Local: ${localTimeStr}`;

      showAll();
    }

    /* ===============================
       STAGE 2 — LIVE UNTIL 18:00
       =============================== */
    else if (nowUK >= draftStart && nowUK < cutoff) {
      ms = cutoff.getTime() - nowUK.getTime();
      phase = "live_until_cutoff";

      line1 = "Auction cutoff in: " + formatCountdown(ms);

      const userTZ = Intl.DateTimeFormat().resolvedOptions().timeZone;
      let localTimeStr;

      if (userTZ === "Europe/London") {
        localTimeStr = "18:00";
      } else {
        const localCut = new Date(cutoff);
        localTimeStr = localCut.toLocaleTimeString([], {
          hour: "2-digit",
          minute: "2-digit",
          hour12: false
        });
      }

      line2 = `Cutoff time: 18:00 UK | Local: ${localTimeStr}`;

      showAll();
    }

    /* ===============================
       STAGE 3 — 18:00 → 18:50
       =============================== */
    else if (nowUK >= cutoff && nowUK < randomStart) {
      ms = randomStart.getTime() - nowUK.getTime();
      phase = "cutoff_to_random";

      line1 = "Random timer begins in: " + formatCountdown(ms);

      const userTZ = Intl.DateTimeFormat().resolvedOptions().timeZone;
      let localTimeStr;

      if (userTZ === "Europe/London") {
        localTimeStr = "18:50";
      } else {
        const localRS = new Date(randomStart);
        localTimeStr = localRS.toLocaleTimeString([], {
          hour: "2-digit",
          minute: "2-digit"
        });
      }

      line2 = `Start time: 18:50 UK | Local: ${localTimeStr}`;

      showAll();
    }

    /* ===============================
       STAGE 4 — RANDOM WINDOW ACTIVE
       =============================== */
    else if (nowUK >= randomStart && nowUK < randomFinish) {
      phase = "random_window";

      const elapsed = nowUK.getTime() - randomStart.getTime();
      line1 = "Random finish window active — draft may end at any moment";
      line2 = "Running for: " + formatCountdown(elapsed);

      showAll();
    }

    /* ===============================
       STAGE 5 — DRAFT ENDED
       =============================== */
    else {
      line1 = "Draft auction has ended";
      line2 = "";

      el.textContent = line1;
      localEl.textContent = "";
      showAll();

      stopDraftCountdown();
      if (typeof onEndCallback === "function") {
        try { onEndCallback(); } catch (e) { console.error(e); }
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

  const transferWindowOpen = data?.transfer_window_open === true;
  const draftAuctionEnabled = data?.draft_auction_enabled === true;

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

  draftEnabled = draftAuctionEnabled;
  draftStart = toUKWallClock(draftAuctionStartTime);
  draftFinish = toUKWallClock(draftRandomFinishTime);

  stopDraftCountdown();

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
   EXPORTED HELPERS
   =============================== */

export {
  startDraftCountdown,
  stopDraftCountdown,
  getUKNow,
  isValidDate
};
