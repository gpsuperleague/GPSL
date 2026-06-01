// draft_engine.js

// Build a stable Date for the intended UK wall-clock time
export function makeUKDate(year, month, day, hour = 0, minute = 0, second = 0) {
  return new Date(Date.UTC(year, month, day, hour, minute, second));
}

// Small helper to validate Date objects
export function isValidDate(d) {
  return d instanceof Date && !isNaN(d.getTime());
}

// Current time in UK (Europe/London), built from numeric parts (robust)
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
    console.warn("getUKNow: failed to parse parts, falling back to local Date()");
    return new Date();
  }

  return makeUKDate(y, m, d, hh, mm, ss);
}

/* Safe draft window times that avoid invalid Date at month boundaries */
export function getDraftWindowTimes() {
  const nowUK = getUKNow();

  const y = nowUK.getFullYear();
  const m = nowUK.getMonth();
  const d = nowUK.getDate();

  const todayMidnight = makeUKDate(y, m, d, 0, 0, 0);
  const yesterdayMidnight = new Date(todayMidnight.getTime() - 24 * 60 * 60 * 1000);

  const sevenPmYesterday = makeUKDate(
    yesterdayMidnight.getUTCFullYear(),
    yesterdayMidnight.getUTCMonth(),
    yesterdayMidnight.getUTCDate(),
    19, 0, 0
  );

  const sixPmToday = makeUKDate(y, m, d, 18, 0, 0);
  const sevenPmToday = makeUKDate(y, m, d, 19, 0, 0);

  return { sevenPmYesterday, sixPmToday, sevenPmToday };
}

/* Day‑2 cutoff: tomorrow 18:00 UK (for locking NEW auctions on Day 2) */
export function getDraftCutoff() {
  const nowUK = getUKNow();
  const y = nowUK.getFullYear();
  const m = nowUK.getMonth();
  const d = nowUK.getDate();
  return makeUKDate(y, m, d + 1, 18, 0, 0);
}

// Simple formatter you already use in countdowns
export function formatMs(ms) {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return `${h}h ${m}m ${s}s`;
}

/**
 * Optional helper: classify current draft phase.
 * Returns one of:
 * "before_start", "live_until_cutoff", "pre_random",
 * "random_active", "ended"
 */
export function getDraftPhase(nowUK, draftAuctionStartTime, draftRandomFinishTime) {
  if (!draftAuctionStartTime || !draftRandomFinishTime) return "ended";

  const start = new Date(draftAuctionStartTime);
  const randomFinish = new Date(draftRandomFinishTime);

  const cutoff = new Date(start.getTime() + 23 * 60 * 60 * 1000);   // Day 2, 18:00
  const randomStart = new Date(cutoff.getTime() + 50 * 60 * 1000);  // Day 2, 18:50

  if (nowUK < start) return "before_start";
  if (nowUK >= start && nowUK < cutoff) return "live_until_cutoff";
  if (nowUK >= cutoff && nowUK < randomStart) return "pre_random";
  if (nowUK >= randomStart && nowUK < randomFinish) return "random_active";
  return "ended";
}
