/**
 * Owner holiday booking — early fixture play when away (14 days/season).
 */

import { supabase } from "./global.js";
import { loadSeasonCalendarMonths } from "./competition_calendar.js";
import { isFixtureHolidayPlayable as isFixtureHolidayPlayableCore } from "./competition.js";

export const HOLIDAY_DAYS_PER_SEASON = 14;

export async function loadOwnerHolidays() {
  const { data, error } = await supabase
    .from("club_owner_holidays_public")
    .select("*")
    .order("starts_at", { ascending: true });

  if (error) {
    console.error("loadOwnerHolidays:", error);
    return { holidays: [], daysUsed: 0, daysRemaining: HOLIDAY_DAYS_PER_SEASON };
  }

  const holidays = data || [];
  const sample = holidays[0];
  const daysUsed = sample?.season_days_used ?? 0;
  const daysRemaining =
    sample?.season_days_remaining ??
    Math.max(0, HOLIDAY_DAYS_PER_SEASON - daysUsed);

  return { holidays, daysUsed, daysRemaining };
}

export async function bookOwnerHoliday(startDate, endDate) {
  const { data, error } = await supabase.rpc("club_holiday_book", {
    p_start_date: startDate,
    p_end_date: endDate,
  });

  if (error) {
    return { ok: false, msg: error.message || "Could not book holiday." };
  }

  return { ok: true, id: data };
}

export async function cancelOwnerHoliday(holidayId) {
  const { error } = await supabase.rpc("club_holiday_cancel", {
    p_holiday_id: holidayId,
  });

  if (error) {
    return { ok: false, msg: error.message || "Could not cancel holiday." };
  }

  return { ok: true };
}

export function isFixtureHolidayPlayable(fixture, clubIdentity, ctx) {
  return isFixtureHolidayPlayableCore(fixture, clubIdentity, ctx);
}

export async function loadHolidayPlayContext() {
  const [holidayState, calendarMonths, earlyRes] = await Promise.all([
    loadOwnerHolidays(),
    loadSeasonCalendarMonths(supabase),
    supabase.rpc("match_schedule_my_holiday_early_fixture_ids"),
  ]);

  const earlyFixtureIds = new Set();
  if (!earlyRes.error && Array.isArray(earlyRes.data)) {
    for (const id of earlyRes.data) {
      const n = Number(id);
      if (Number.isFinite(n)) earlyFixtureIds.add(n);
    }
  } else if (earlyRes.error) {
    console.warn("holiday early fixture ids:", earlyRes.error.message);
  }

  return {
    holidays: holidayState.holidays,
    calendarMonths,
    daysUsed: holidayState.daysUsed,
    daysRemaining: holidayState.daysRemaining,
    earlyFixtureIds,
  };
}

export function formatUkDateRange(startsAt, endsAt) {
  const opts = {
    timeZone: "Europe/London",
    day: "numeric",
    month: "short",
    year: "numeric",
  };
  const start = new Date(startsAt);
  const end = new Date(endsAt);
  end.setMilliseconds(end.getMilliseconds() - 1);

  const a = start.toLocaleDateString("en-GB", opts);
  const b = end.toLocaleDateString("en-GB", opts);
  return a === b ? a : `${a} – ${b}`;
}

export function holidayStatusLabel(row) {
  if (row.is_active) return "Active";
  if (row.is_upcoming) return "Upcoming";
  if (row.is_ended) return "Ended";
  return "—";
}

export function inclusiveDayCountFromDates(startDate, endDate) {
  const start = new Date(`${startDate}T12:00:00`);
  const end = new Date(`${endDate}T12:00:00`);
  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) return 0;
  if (end < start) return 0;
  return Math.round((end - start) / 86400000) + 1;
}
