/**
 * Season transfer & auction schedule — discreet strip for owners.
 * Counts draft days used this season (from inbox schedule notifications)
 * and shows transfer window months (summer window pre-season until August, winter window in January).
 */

import { supabase } from "./supabase_client.js";
import { loadCalendarStatus, loadSeasonCalendarMonths } from "./competition_calendar.js";

export const SEASON_SCHEDULE_TOTALS = {
  player: 3,
  manager: 2,
  special: 3,
};

const DRAFT_DEDUPE_RE =
  /^draft_scheduled:(player|manager):(.+):(\d+):([A-Za-z0-9_]+)$/;

let __refreshTimer = null;

function parseDraftScheduleDedupe(dedupeKey) {
  const m = String(dedupeKey || "").match(DRAFT_DEDUPE_RE);
  if (!m) return null;
  return {
    kind: m[1],
    eventKey: `${m[1]}:${m[2]}:${m[3]}`,
    createdAtHint: m[2],
  };
}

function countDraftEvents(rows, kind, seasonStartIso) {
  const seasonStart = seasonStartIso ? new Date(seasonStartIso).getTime() : null;
  const keys = new Set();
  for (const row of rows || []) {
    const parsed = parseDraftScheduleDedupe(row.dedupe_key);
    if (!parsed || parsed.kind !== kind) continue;
    if (seasonStart != null && !Number.isNaN(seasonStart)) {
      const t = new Date(row.created_at).getTime();
      if (!Number.isNaN(t) && t < seasonStart) continue;
    }
    keys.add(parsed.eventKey);
  }
  return keys.size;
}

function windowStatusFromMonth(monthRow, transferOpen) {
  if (!monthRow) return "closed";
  if (monthRow.is_active) return transferOpen ? "open" : "closed";
  if (monthRow.is_future) return "upcoming";
  return "closed";
}

function resolveTransferWindows(calendar, months, transferOpen) {
  const byMonth = Object.fromEntries(
    (months || []).map((m) => [String(m.gpsl_month || "").toLowerCase(), m])
  );
  const aug = byMonth.august;
  const jan = byMonth.january;
  const phase = calendar?.calendar_phase;
  const augStarted = aug?.has_started === true || aug?.is_active === true;

  let preseason = "closed";
  if (augStarted) {
    preseason = "closed";
  } else if (phase === "pre_season") {
    preseason = transferOpen ? "open" : "closed";
  } else if (aug?.is_future && calendar?.season_id) {
    preseason = "upcoming";
  }

  const january = windowStatusFromMonth(jan, transferOpen);

  return {
    preseason: {
      label: "Summer window",
      range: "Pre-season until August",
      rangeSep: ": ",
      status: preseason,
      title:
        preseason === "open"
          ? "Summer transfer window open — pre-season until August (season starts in August)"
          : preseason === "upcoming"
            ? "Summer transfer window — pre-season until August"
            : "Summer transfer window has ended — season underway from August",
    },
    january: {
      label: "Winter window",
      range: "January",
      rangeSep: ": ",
      status: january,
      title:
        january === "open"
          ? "Winter transfer window is open (January)"
          : january === "upcoming"
            ? "Winter transfer window — opens in January"
            : "Winter transfer window (January) has ended",
    },
  };
}

export async function loadSeasonTransferSchedule() {
  const nowIso = new Date().toISOString();
  const [{ data: season }, calendar, months, settingsRes, inboxRes, specialRes, liveSpecialRes] =
    await Promise.all([
      supabase
        .from("competition_seasons")
        .select("id, label, started_at")
        .eq("is_current", true)
        .eq("status", "active")
        .maybeSingle(),
      loadCalendarStatus(supabase),
      loadSeasonCalendarMonths(supabase),
      supabase
        .from("global_settings_public")
        .select(
          "transfer_window_open, draft_auction_enabled, draft_bidding_open, manager_draft_auction_enabled, manager_draft_bidding_open"
        )
        .maybeSingle(),
      supabase
        .from("competition_inbox")
        .select("dedupe_key, created_at")
        .eq("message_type", "draft_scheduled")
        .like("dedupe_key", "draft_scheduled:%"),
      supabase
        .from("special_auctions")
        .select("id, status, created_at")
        .in("status", ["scheduled", "active", "revealed", "settled"]),
      supabase
        .from("special_auctions")
        .select("id")
        .in("status", ["scheduled", "active"])
        .gt("end_time", nowIso)
        .limit(1)
        .maybeSingle(),
    ]);

  const seasonStart = season?.started_at || null;
  const transferOpen = settingsRes.data?.transfer_window_open === true;
  const inboxRows = inboxRes.data || [];

  const playerUsed = countDraftEvents(inboxRows, "player", seasonStart);
  const managerUsed = countDraftEvents(inboxRows, "manager", seasonStart);

  const seasonStartMs = seasonStart ? new Date(seasonStart).getTime() : null;
  const specialUsed = (specialRes.data || []).filter((row) => {
    if (!seasonStartMs || Number.isNaN(seasonStartMs)) return true;
    const t = new Date(row.created_at).getTime();
    return !Number.isNaN(t) && t >= seasonStartMs;
  }).length;

  const windows = resolveTransferWindows(calendar, months, transferOpen);

  return {
    seasonLabel: season?.label || null,
    player: {
      total: SEASON_SCHEDULE_TOTALS.player,
      used: playerUsed,
      remaining: Math.max(0, SEASON_SCHEDULE_TOTALS.player - playerUsed),
      live:
        settingsRes.data?.draft_auction_enabled === true &&
        settingsRes.data?.draft_bidding_open === true,
      href: "draftauction.html",
    },
    manager: {
      total: SEASON_SCHEDULE_TOTALS.manager,
      used: managerUsed,
      remaining: Math.max(0, SEASON_SCHEDULE_TOTALS.manager - managerUsed),
      live:
        settingsRes.data?.manager_draft_auction_enabled === true &&
        settingsRes.data?.manager_draft_bidding_open === true,
      href: "manager_draftauction.html",
    },
    special: {
      total: SEASON_SCHEDULE_TOTALS.special,
      used: specialUsed,
      remaining: Math.max(0, SEASON_SCHEDULE_TOTALS.special - specialUsed),
      live: !!liveSpecialRes.data?.id,
      href: "special_auction.html",
    },
    windows,
    transferOpen,
  };
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function draftChipHtml(kind, label, data) {
  const live = data.live;
  const remaining = data.remaining;
  const used = data.used;
  const total = data.total;
  const countText = live
    ? "Live"
    : remaining === 0
      ? "Done"
      : `${remaining} left`;
  const title = live
    ? `${label} auction is live now (${used} of ${total} scheduled this season)`
    : remaining === 0
      ? `All ${total} ${label.toLowerCase()} draft days used this season`
      : `${remaining} of ${total} ${label.toLowerCase()} draft days remaining this season (${used} scheduled)`;

  return (
    `<a href="${escapeHtml(data.href)}" class="ssc-chip ssc-draft${
      live ? " ssc-chip--live" : ""
    }" title="${escapeHtml(title)}">` +
    `<span class="ssc-chip-label">${escapeHtml(label)}</span>` +
    `<span class="ssc-chip-value">${escapeHtml(countText)}</span>` +
    `</a>`
  );
}

function windowChipHtml(win) {
  const status = win.status || "closed";
  const statusWord =
    status === "open" ? "OPEN" : status === "upcoming" ? "SOON" : "";
  const title = win.title || win.label;
  const rangeSep = win.rangeSep ?? " ";
  const rangeHtml =
    win.range && win.range !== win.label
      ? `<span class="ssc-chip-range">${escapeHtml(rangeSep)}${escapeHtml(win.range)}</span>`
      : "";
  return (
    `<span class="ssc-chip ssc-window ssc-window--${escapeHtml(status)}" title="${escapeHtml(title)}">` +
    `<span class="ssc-chip-label">${escapeHtml(win.label)}</span>` +
    rangeHtml +
    (statusWord
      ? `<span class="ssc-chip-status">${escapeHtml(statusWord)}</span>`
      : "") +
    `</span>`
  );
}

export function renderSeasonScheduleStripHtml(schedule) {
  if (!schedule) return "";

  const parts = [
    draftChipHtml("player", "Player draft", schedule.player),
    draftChipHtml("manager", "Manager draft", schedule.manager),
    draftChipHtml("special", "Special auction", schedule.special),
    `<span class="ssc-sep" aria-hidden="true"></span>`,
    windowChipHtml(schedule.windows.preseason),
    windowChipHtml(schedule.windows.january),
  ];

  const seasonHint = schedule.seasonLabel
    ? `Season schedule — ${schedule.seasonLabel}`
    : "Season schedule";

  return (
    `<div class="season-schedule-inner" role="region" aria-label="${escapeHtml(seasonHint)}">` +
    `<span class="ssc-kicker">Season</span>` +
    `<div class="ssc-chips">${parts.join("")}</div>` +
    `</div>`
  );
}

export async function refreshSeasonScheduleStrip() {
  const el = document.getElementById("seasonScheduleStrip");
  if (!el) return;

  try {
    const schedule = await loadSeasonTransferSchedule();
    const html = renderSeasonScheduleStripHtml(schedule);
    if (!html) {
      el.hidden = true;
      el.innerHTML = "";
      return;
    }
    el.innerHTML = html;
    el.hidden = false;
  } catch (err) {
    console.warn("season schedule strip:", err);
    el.hidden = true;
  }
}

export function ensureSeasonScheduleStripMount() {
  const nav = document.getElementById("nav");
  if (!nav) return null;

  let el = document.getElementById("seasonScheduleStrip");
  if (!el) {
    el = document.createElement("div");
    el.id = "seasonScheduleStrip";
    el.className = "season-schedule-strip";
    el.setAttribute("aria-live", "polite");
    el.hidden = true;
    nav.appendChild(el);
  }
  return el;
}

export function initSeasonScheduleStrip() {
  ensureSeasonScheduleStripMount();
  refreshSeasonScheduleStrip();

  if (__refreshTimer) return;
  __refreshTimer = setInterval(() => {
    refreshSeasonScheduleStrip();
  }, 60_000);
}
