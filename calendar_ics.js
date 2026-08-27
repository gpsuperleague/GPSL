/**
 * Client-side iCalendar (.ics) builders + download.
 * Events use UTC (Z) timestamps; stable UIDs help calendars update on re-import.
 */

const PRODID = "-//GPSL//Calendar//EN";
const DEFAULT_DURATION_MS = 90 * 60 * 1000; // match / auction open reminder window
const ALARM_MINUTES = 30;

function pad2(n) {
  return String(n).padStart(2, "0");
}

/** @param {Date|string|number} value */
export function toIcsUtc(value) {
  const d = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(d.getTime())) return null;
  return (
    d.getUTCFullYear() +
    pad2(d.getUTCMonth() + 1) +
    pad2(d.getUTCDate()) +
    "T" +
    pad2(d.getUTCHours()) +
    pad2(d.getUTCMinutes()) +
    pad2(d.getUTCSeconds()) +
    "Z"
  );
}

/** Escape text per RFC 5545. */
export function escapeIcsText(text) {
  return String(text ?? "")
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\r\n/g, "\\n")
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\n");
}

function foldLine(line) {
  const s = String(line);
  if (s.length <= 75) return s;
  const parts = [];
  let i = 0;
  parts.push(s.slice(0, 75));
  i = 75;
  while (i < s.length) {
    parts.push(" " + s.slice(i, i + 74));
    i += 74;
  }
  return parts.join("\r\n");
}

function alarmBlock() {
  return [
    "BEGIN:VALARM",
    "TRIGGER:-PT" + ALARM_MINUTES + "M",
    "ACTION:DISPLAY",
    "DESCRIPTION:GPSL reminder",
    "END:VALARM",
  ];
}

/**
 * @param {{
 *   uid: string,
 *   title: string,
 *   description?: string,
 *   startAt: Date|string|number,
 *   endAt?: Date|string|number|null,
 *   durationMs?: number,
 *   url?: string|null,
 *   location?: string|null,
 * }} opts
 */
export function buildVEvent(opts) {
  const start = toIcsUtc(opts.startAt);
  if (!start) return null;

  let endAt = opts.endAt;
  if (endAt == null) {
    const startDate = opts.startAt instanceof Date ? opts.startAt : new Date(opts.startAt);
    endAt = new Date(startDate.getTime() + (opts.durationMs ?? DEFAULT_DURATION_MS));
  }
  const end = toIcsUtc(endAt);
  if (!end) return null;

  const stamp = toIcsUtc(new Date());
  const lines = [
    "BEGIN:VEVENT",
    `UID:${opts.uid}`,
    `DTSTAMP:${stamp}`,
    `DTSTART:${start}`,
    `DTEND:${end}`,
    `SUMMARY:${escapeIcsText(opts.title)}`,
  ];
  if (opts.description) {
    lines.push(`DESCRIPTION:${escapeIcsText(opts.description)}`);
  }
  if (opts.location) {
    lines.push(`LOCATION:${escapeIcsText(opts.location)}`);
  }
  if (opts.url) {
    lines.push(`URL:${escapeIcsText(opts.url)}`);
  }
  lines.push(...alarmBlock());
  lines.push("END:VEVENT");
  return lines.map(foldLine).join("\r\n");
}

/** @param {string[]} vevents */
export function buildIcsCalendar(vevents) {
  const body = vevents.filter(Boolean).join("\r\n");
  return [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    `PRODID:${PRODID}`,
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    body,
    "END:VCALENDAR",
    "",
  ].join("\r\n");
}

/**
 * Trigger a .ics file download in the browser.
 * @param {string} filename
 * @param {string[]} vevents
 */
export function downloadIcs(filename, vevents) {
  const list = (vevents || []).filter(Boolean);
  if (!list.length) return false;
  const ics = buildIcsCalendar(list);
  const blob = new Blob([ics], { type: "text/calendar;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename.endsWith(".ics") ? filename : `${filename}.ics`;
  a.rel = "noopener";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
  return true;
}

/**
 * Download each event as its own .ics (Outlook/Windows often only imports the
 * first VEVENT when opening a multi-event file).
 * Staggers clicks so browsers allow multiple downloads from one button press.
 * @param {{ filename: string, vevent: string }[]} entries
 */
export function downloadIcsEach(entries) {
  const list = (entries || []).filter((e) => e?.filename && e?.vevent);
  if (!list.length) return false;
  list.forEach((entry, i) => {
    const run = () => downloadIcs(entry.filename, [entry.vevent]);
    if (i === 0) run();
    else setTimeout(run, i * 450);
  });
  return true;
}

function absolutePageUrl(pathWithQuery) {
  try {
    return new URL(pathWithQuery, window.location.href).href;
  } catch {
    return pathWithQuery || "";
  }
}

/**
 * Agreed fixture kick-off (90 min duration).
 * @param {{ id: string|number, home: string, away: string, kickoffAt: string|Date, url?: string }} p
 */
export function fixtureKickoffEvent(p) {
  const id = String(p.id ?? "").trim();
  if (!id || !p.kickoffAt) return null;
  const home = p.home || "Home";
  const away = p.away || "Away";
  const url = p.url || absolutePageUrl(`fixture_schedule.html?fixture=${encodeURIComponent(id)}`);
  return buildVEvent({
    uid: `gpsl-fixture-${id}@gpsl`,
    title: `GPSL: ${home} vs ${away}`,
    description: `Agreed kick-off (GPSL).\nOpen: ${url}`,
    startAt: p.kickoffAt,
    durationMs: DEFAULT_DURATION_MS,
    url,
    location: "GPSL Matchday",
  });
}

/**
 * GPSL month unlock + lock as two short events (15 min markers).
 * @param {{ month: string, seasonLabel?: string, unlockAt?: string|Date|null, lockAt?: string|Date|null }} p
 * @returns {string[]}
 */
export function gpslMonthEvents(p) {
  const month = String(p.month || "").trim().toLowerCase();
  if (!month) return [];
  const label = (p.seasonLabel ? `${p.seasonLabel} ` : "") + monthLabel(month);
  const seasonKey = String(p.seasonLabel || "season")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-");
  const out = [];
  const markerMs = 15 * 60 * 1000;

  if (p.unlockAt) {
    const ev = buildVEvent({
      uid: `gpsl-month-${seasonKey}-${month}-unlock@gpsl`,
      title: `GPSL ${label} starts`,
      description: `GPSL month unlocks (UK week). Season calendar: ${absolutePageUrl("season_calendar.html")}`,
      startAt: p.unlockAt,
      durationMs: markerMs,
      url: absolutePageUrl("season_calendar.html"),
    });
    if (ev) out.push(ev);
  }
  if (p.lockAt) {
    const ev = buildVEvent({
      uid: `gpsl-month-${seasonKey}-${month}-lock@gpsl`,
      title: `GPSL ${label} ends`,
      description: `GPSL month locks (UK week). Season calendar: ${absolutePageUrl("season_calendar.html")}`,
      startAt: p.lockAt,
      durationMs: markerMs,
      url: absolutePageUrl("season_calendar.html"),
    });
    if (ev) out.push(ev);
  }
  return out;
}

function monthLabel(month) {
  const map = {
    pre_season: "Pre-Season",
    june: "June",
    july: "July",
    august: "August",
    september: "September",
    october: "October",
    november: "November",
    december: "December",
    january: "January",
    february: "February",
    march: "March",
    april: "April",
    may: "May",
    playoffs: "Playoffs",
  };
  return map[month] || month.charAt(0).toUpperCase() + month.slice(1);
}

/**
 * Transfer Market listing end (reminder to bid before close).
 * Times are stored as UTC in the .ics; the owner's calendar app shows local region time.
 * @param {{ id: string|number, playerName: string, endAt: string|Date, url?: string }} p
 */
export function transferListingEndEvent(p) {
  const id = String(p.id ?? "").trim();
  const name = String(p.playerName || "Player").trim() || "Player";
  if (!id || !p.endAt) return null;
  const url = p.url || absolutePageUrl("all_listings.html");
  return buildVEvent({
    uid: `gpsl-transfer-listing-${id}@gpsl`,
    title: `Transfer : ${name}`,
    description: `Transfer market listing ends — bid before this time.\nOpen: ${url}`,
    startAt: p.endAt,
    durationMs: 15 * 60 * 1000,
    url,
    location: "GPSL Transfer Market",
  });
}

/**
 * Draft auction milestones: open, Day-2 cutoff, random-timer start.
 * Times are UTC in the .ics; calendar apps show the owner's local region.
 * Returns one file entry per milestone (separate downloads — more reliable than
 * a single multi-event .ics in Outlook / Windows).
 * @param {{
 *   id: string,
 *   label: string,
 *   startAt?: string|Date|null,
 *   cutoffAt?: string|Date|null,
 *   randomStartAt?: string|Date|null,
 *   url?: string|null,
 *   includeCutoff?: boolean,
 *   cutoffDescription?: string,
 *   filePrefix?: string,
 * }} p
 * @returns {{ filename: string, vevent: string }[]}
 */
export function draftAuctionTimelineEvents(p) {
  const id = String(p.id || "draft").trim() || "draft";
  const label = String(p.label || "GPSL draft auction").trim();
  const url = p.url || absolutePageUrl("dashboard.html");
  const includeCutoff = p.includeCutoff !== false;
  const markerMs = 15 * 60 * 1000;
  const prefix = String(p.filePrefix || `gpsl-${id}-draft`)
    .replace(/[\\/:*?"<>|]+/g, "")
    .trim();
  const out = [];

  if (p.startAt) {
    const vevent = buildVEvent({
      uid: `gpsl-draft-${id}-start@gpsl`,
      title: `${label} opens`,
      description: `Draft auction bidding opens.\nOpen: ${url}`,
      startAt: p.startAt,
      durationMs: 60 * 60 * 1000,
      url,
      location: "GPSL Draft Auction",
    });
    if (vevent) {
      out.push({ filename: `${prefix}-opens.ics`, vevent });
    }
  }

  if (includeCutoff && p.cutoffAt) {
    const cutoffBlurb =
      p.cutoffDescription ||
      `Day-2 cutoff (6pm UK). Player draft: no new bids or free-agent openings after this time. Random window begins at 6:50pm UK.`;
    const vevent = buildVEvent({
      uid: `gpsl-draft-${id}-cutoff@gpsl`,
      title: `${label} cutoff`,
      description: `${cutoffBlurb}\nOpen: ${url}`,
      startAt: p.cutoffAt,
      durationMs: markerMs,
      url,
      location: "GPSL Draft Auction",
    });
    if (vevent) {
      out.push({ filename: `${prefix}-cutoff.ics`, vevent });
    }
  }

  if (p.randomStartAt) {
    const vevent = buildVEvent({
      uid: `gpsl-draft-${id}-random@gpsl`,
      title: `${label} random timer starts`,
      description: `Random finish window begins (from 6:50pm UK). Exact finish stays secret until revealed.\nOpen: ${url}`,
      startAt: p.randomStartAt,
      durationMs: markerMs,
      url,
      location: "GPSL Draft Auction",
    });
    if (vevent) {
      out.push({
        filename: `${prefix}-random-timer.ics`,
        vevent,
      });
    }
  }

  return out;
}

/**
 * Auction open (and optional public end).
 * @param {{ id: string, title: string, startAt: string|Date, endAt?: string|Date|null, url?: string }} p
 * @returns {string[]}
 */
export function auctionWindowEvents(p) {
  const id = String(p.id || "auction").trim();
  const out = [];
  if (p.startAt) {
    const open = buildVEvent({
      uid: `gpsl-auction-${id}-open@gpsl`,
      title: p.title || "GPSL auction opens",
      description: `Auction bidding opens.\n${p.url || absolutePageUrl("dashboard.html")}`,
      startAt: p.startAt,
      durationMs: 60 * 60 * 1000,
      url: p.url || undefined,
    });
    if (open) out.push(open);
  }
  if (p.endAt) {
    const end = buildVEvent({
      uid: `gpsl-auction-${id}-end@gpsl`,
      title: (p.title || "GPSL auction") + " ends",
      description: `Auction hard end (public).\n${p.url || ""}`,
      startAt: p.endAt,
      durationMs: 15 * 60 * 1000,
      url: p.url || undefined,
    });
    if (end) out.push(end);
  }
  return out;
}
