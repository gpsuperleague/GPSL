/**
 * Season transfer & auction schedule — info strip below nav (season, month, drafts).
 */

import { supabase } from "./supabase_client.js";
import {
  loadCalendarStatus,
  navGpslMonthDisplay,
  navGpslMonthTitle,
  isPreSeasonPhase,
} from "./competition_calendar.js";

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

export async function loadSeasonTransferSchedule() {
  const nowIso = new Date().toISOString();
  const [{ data: season }, settingsRes, inboxRes, specialRes, liveSpecialRes] =
    await Promise.all([
      supabase
        .from("competition_seasons")
        .select("id, label, started_at")
        .eq("is_current", true)
        .maybeSingle(),
      supabase
        .from("global_settings_public")
        .select(
          "transfer_window_open, draft_auction_enabled, draft_bidding_open, manager_draft_auction_enabled, manager_draft_bidding_open, league_phase"
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

  const seasonLabel =
    season?.label ||
    (await supabase.rpc("current_gpsl_season_label")).data ||
    null;

  let gpslMonthLabel = null;
  let gpslMonthTitle = "";
  let gpslMonthPre = false;
  try {
    const calStatus = await loadCalendarStatus(supabase);
    gpslMonthLabel = navGpslMonthDisplay(calStatus);
    gpslMonthTitle = navGpslMonthTitle(calStatus);
    gpslMonthPre = isPreSeasonPhase(calStatus);
  } catch (calErr) {
    console.warn("season strip calendar:", calErr);
  }

  if (!gpslMonthLabel && settingsRes.data?.league_phase === "summer_break") {
    gpslMonthLabel = "Summer Break";
    gpslMonthTitle = "GPSL is in summer break — no active competition month";
  }

  return {
    seasonLabel: seasonLabel ? String(seasonLabel).trim() : null,
    gpslMonthLabel,
    gpslMonthTitle,
    gpslMonthPre,
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
    transferWindow: {
      open: transferOpen,
      href: "transfer_center.html",
    },
  };
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Readable strip label — e.g. DB "1" → "Season 1". */
export function formatSeasonStripLabel(raw) {
  const s = String(raw ?? "").trim();
  if (!s) return "Season";
  if (/^season\b/i.test(s)) {
    return s.replace(/^season/i, "Season");
  }
  if (/^\d+$/.test(s)) {
    return `Season ${s}`;
  }
  return s;
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

function transferWindowChipHtml(data) {
  const open = data.open === true;
  const statusText = open ? "Open" : "Closed";
  const title = open
    ? "Transfer window is open — list players and make offers"
    : "Transfer window is closed";

  return (
    `<a href="${escapeHtml(data.href)}" class="ssc-chip ssc-transfer ssc-chip--live" title="${escapeHtml(title)}">` +
    `<span class="ssc-chip-label">Transfer window</span>` +
    `<span class="ssc-chip-value">${escapeHtml(statusText)}</span>` +
    `</a>`
  );
}

function gpslHeadlineHtml(schedule) {
  const seasonLabel = formatSeasonStripLabel(schedule.seasonLabel);
  const month = schedule.gpslMonthLabel || "—";
  const title = schedule.gpslMonthTitle || "";
  const pre = schedule.gpslMonthPre === true;
  const summer = month === "Summer Break";
  const classes = [
    "ssc-gpsl-headline",
    pre ? "ssc-gpsl-headline--pre" : "",
    summer ? "ssc-gpsl-headline--summer" : "",
  ]
    .filter(Boolean)
    .join(" ");

  return (
    `<span class="${classes}" title="${escapeHtml(title)}">` +
    `<span class="ssc-gpsl-brand">GPSL</span> ` +
    `<span class="ssc-gpsl-season">${escapeHtml(seasonLabel)}</span>` +
    `<span class="ssc-gpsl-colon">:</span> ` +
    `<span class="ssc-gpsl-month">${escapeHtml(month)}</span>` +
    `</span>` +
    `<span class="ssc-sep" aria-hidden="true"></span>`
  );
}

export function renderSeasonScheduleStripHtml(schedule) {
  if (!schedule) return "";

  const parts = [
    draftChipHtml("player", "Player draft", schedule.player),
    draftChipHtml("manager", "Manager draft", schedule.manager),
    draftChipHtml("special", "Special auction", schedule.special),
    `<span class="ssc-sep" aria-hidden="true"></span>`,
    transferWindowChipHtml(schedule.transferWindow),
  ];

  const seasonLabel = formatSeasonStripLabel(schedule.seasonLabel);
  const month = schedule.gpslMonthLabel || "—";
  const seasonHint = schedule.seasonLabel
    ? `GPSL ${seasonLabel} — ${month}`
    : `GPSL season schedule — ${month}`;

  return (
    `<div class="season-schedule-inner" role="region" aria-label="${escapeHtml(seasonHint)}">` +
    gpslHeadlineHtml(schedule) +
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
