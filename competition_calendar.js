/**
 * Real-world calendar: Fri 19:00 UK → Fri 19:00 UK = one GPSL month (Aug–May).
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

export function calendarStatusBanner(status) {
  if (!status?.calendar_configured) {
    return "Season calendar not set — all fixtures are open until admin sets the first Friday 7pm UK anchor.";
  }

  const phase = status.calendar_phase;
  const activeLabel =
    GPSL_MONTH_LABELS[status.active_gpsl_month] ||
    status.active_gpsl_month_label ||
    "—";

  if (phase === "in_month") {
    return `GPSL ${activeLabel} is live — league & cup fixtures for ${activeLabel} can be played until ${formatUkDateTime(status.active_lock_at)} UK.`;
  }
  if (phase === "before_season") {
    return `Season starts ${formatUkDateTime(status.anchor_unlock_at)} UK (GPSL August unlocks).`;
  }
  if (phase === "after_season") {
    return "GPSL season calendar has ended (May locked).";
  }
  if (phase === "between_months") {
    const next =
      GPSL_MONTH_LABELS[status.next_gpsl_month] || status.next_gpsl_month;
    return `Between GPSL months — next (${next}) unlocks ${formatUkDateTime(status.next_unlock_at)} UK.`;
  }
  return "Calendar status unknown.";
}
