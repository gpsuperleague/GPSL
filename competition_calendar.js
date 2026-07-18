/**
 * Real-world calendar: Fri 19:00 UK → Fri 19:00 UK = one GPSL month
 * (Aug–May league/cup programme, then Playoffs week).
 */

import { GPSL_MONTH_LABELS } from "./competition.js";

const UK_TZ = "Europe/London";

export function formatUkDateTime(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-GB", {
    timeZone: UK_TZ,
    weekday: "short",
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

export async function loadCalendarStatus(supabase) {
  const { data, error } = await supabase
    .from("competition_calendar_status_public")
    .select("*")
    .maybeSingle();

  if (error) {
    console.error("loadCalendarStatus:", error);
    return null;
  }
  return data;
}

export async function loadSeasonCalendarMonths(supabase) {
  const { data, error } = await supabase
    .from("competition_season_calendar_public")
    .select("*")
    .order("sort_order", { ascending: true });

  if (error) {
    console.error("loadSeasonCalendarMonths:", error);
    return [];
  }
  return data || [];
}

/** @param {string} fixtureMonth */
/** @param {{ calendar_configured?: boolean, active_gpsl_month?: string|null }} status */
export function isGpslMonthCurrentlyPlayable(fixtureMonth, status) {
  if (!status?.calendar_configured) return true;
  if (!status.active_gpsl_month) return false;
  return (
    String(fixtureMonth || "").toLowerCase() ===
    String(status.active_gpsl_month).toLowerCase()
  );
}

export function isFixtureCalendarPlayable(fixture, status) {
  if (!fixture) return false;
  return isGpslMonthCurrentlyPlayable(fixture.gpsl_month, status);
}

export function isPreSeasonPhase(status) {
  if (!status) return false;
  const active = String(status.active_gpsl_month || "").toLowerCase();
  if (active === "june" || active === "july") return true;
  const phase = status.calendar_phase;
  return (
    phase === "pre_season" ||
    phase === "before_season" ||
    phase === "not_configured" ||
    (!status.calendar_configured && !!status.season_id)
  );
}

/** Label for top navigation (null = hide badge). */
export function navGpslMonthDisplay(status) {
  if (!status?.season_id) return null;

  if (status.calendar_phase === "in_month") {
    return (
      status.active_gpsl_month_label ||
      GPSL_MONTH_LABELS[status.active_gpsl_month] ||
      status.active_gpsl_month ||
      "—"
    );
  }

  if (isPreSeasonPhase(status)) {
    const active = String(status.active_gpsl_month || "").toLowerCase();
    if (active === "june" || active === "july") {
      return (
        status.active_gpsl_month_label ||
        GPSL_MONTH_LABELS[active] ||
        active
      );
    }
    return "Pre-Season";
  }

  if (status.calendar_phase === "between_months") {
    return (
      GPSL_MONTH_LABELS[status.next_gpsl_month] ||
      status.next_gpsl_month ||
      "—"
    );
  }

  if (status.calendar_phase === "after_season") {
    return "Post-season";
  }

  return "Pre-Season";
}

export function navGpslMonthTitle(status) {
  const label = navGpslMonthDisplay(status);
  if (!label) return "";

  if (status?.calendar_phase === "in_month") {
    return `GPSL ${label} — match month live until ${formatUkDateTime(status.active_lock_at)} UK`;
  }
  if (isPreSeasonPhase(status)) {
    if (!status.calendar_configured) {
      return "Competition season is active — set the real-world calendar in GPSL Admin (season start = June)";
    }
    const active = String(status.active_gpsl_month || "").toLowerCase();
    if (active === "june" || active === "july") {
      return `GPSL ${status.active_gpsl_month_label || active} (pre-season) — until ${formatUkDateTime(status.active_lock_at)} UK`;
    }
    return `Before season start — June begins ${formatUkDateTime(status.anchor_unlock_at)} UK`;
  }
  if (status?.calendar_phase === "between_months") {
    const next =
      GPSL_MONTH_LABELS[status.next_gpsl_month] || status.next_gpsl_month;
    return `Between GPSL months — ${next} unlocks ${formatUkDateTime(status.next_unlock_at)} UK`;
  }
  if (status?.calendar_phase === "after_season") {
    return "GPSL season calendar complete (Playoffs locked)";
  }
  return label;
}

export function calendarStatusBanner(status) {
  if (!status?.season_id) {
    return "No active competition season.";
  }

  if (isPreSeasonPhase(status)) {
    if (!status.calendar_configured) {
      return "Pre-Season — competition season is active. Admin: set the first Friday 7pm UK anchor to open GPSL August.";
    }
    return `Pre-Season — GPSL August unlocks ${formatUkDateTime(status.anchor_unlock_at)} UK.`;
  }

  const phase = status.calendar_phase;
  const activeLabel =
    GPSL_MONTH_LABELS[status.active_gpsl_month] ||
    status.active_gpsl_month_label ||
    "—";
  const isPlayoffs = String(status.active_gpsl_month || "").toLowerCase() === "playoffs";

  if (phase === "in_month") {
    if (isPlayoffs) {
      return `GPSL Playoffs is live — promotion & relegation playoffs until ${formatUkDateTime(status.active_lock_at)} UK. End-of-season processing follows when Playoffs locks.`;
    }
    return `GPSL ${activeLabel} is live — league & cup fixtures for ${activeLabel} can be played until ${formatUkDateTime(status.active_lock_at)} UK.`;
  }
  if (phase === "after_season") {
    return "GPSL season calendar has ended (Playoffs locked). Ready for end-of-season archive.";
  }
  if (phase === "between_months") {
    const next =
      GPSL_MONTH_LABELS[status.next_gpsl_month] || status.next_gpsl_month;
    return `Between GPSL months — next (${next}) unlocks ${formatUkDateTime(status.next_unlock_at)} UK.`;
  }
  return "Calendar status unknown.";
}
