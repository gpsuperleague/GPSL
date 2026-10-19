/**
 * Owner holiday booking — early fixture play when away
 * (14 days/season; 21 while supporter is active).
 */

import { supabase } from "./global.js";
import { loadSeasonCalendarMonths } from "./competition_calendar.js";
import { isFixtureHolidayPlayable as isFixtureHolidayPlayableCore } from "./competition.js";

/** Baseline for non-supporters (supporters get 21 via RPC/view). */
export const HOLIDAY_DAYS_PER_SEASON = 14;
export const HOLIDAY_DAYS_SUPPORTER = 21;

export async function loadOwnerHolidayQuota() {
  const { data, error } = await supabase.rpc("club_holiday_my_quota");
  if (error) {
    console.warn("club_holiday_my_quota:", error.message);
    return null;
  }
  if (!data?.ok) return null;
  return {
    maxDays: Number(data.max_days) || HOLIDAY_DAYS_PER_SEASON,
    daysUsed: Number(data.days_used) || 0,
    daysRemaining: Number(data.days_remaining) || 0,
    supporterActive: !!data.supporter_active,
  };
}

export async function loadOwnerHolidays() {
  const [listRes, quota] = await Promise.all([
    supabase
      .from("club_owner_holidays_public")
      .select("*")
      .order("starts_at", { ascending: true }),
    loadOwnerHolidayQuota(),
  ]);

  if (listRes.error) {
    console.error("loadOwnerHolidays:", listRes.error);
    return {
      holidays: [],
      daysUsed: quota?.daysUsed ?? 0,
      daysRemaining: quota?.daysRemaining ?? HOLIDAY_DAYS_PER_SEASON,
      maxDays: quota?.maxDays ?? HOLIDAY_DAYS_PER_SEASON,
      supporterActive: quota?.supporterActive ?? false,
    };
  }

  const holidays = listRes.data || [];
  const sample = holidays[0];
  const maxDays =
    quota?.maxDays ??
    sample?.season_days_allowance ??
    HOLIDAY_DAYS_PER_SEASON;
  const daysUsed = quota?.daysUsed ?? sample?.season_days_used ?? 0;
  const daysRemaining =
    quota?.daysRemaining ??
    sample?.season_days_remaining ??
    Math.max(0, maxDays - daysUsed);

  return {
    holidays,
    daysUsed,
    daysRemaining,
    maxDays,
    supporterActive: quota?.supporterActive ?? maxDays >= HOLIDAY_DAYS_SUPPORTER,
  };
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

export async function amendOwnerHoliday(holidayId, startDate, endDate) {
  const { error } = await supabase.rpc("club_holiday_amend", {
    p_holiday_id: holidayId,
    p_start_date: startDate,
    p_end_date: endDate,
  });

  if (error) {
    return { ok: false, msg: error.message || "Could not amend holiday." };
  }

  return { ok: true };
}

/** Convert holiday starts_at / ends_at (exclusive end) to UK date inputs YYYY-MM-DD */
export function holidayRowToDateInputs(row) {
  const opts = {
    timeZone: "Europe/London",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  };
  const start = new Date(row.starts_at);
  const endExclusive = new Date(row.ends_at);
  const endInclusive = new Date(endExclusive.getTime() - 1);

  const fmt = (d) => {
    const parts = new Intl.DateTimeFormat("en-CA", opts).formatToParts(d);
    const y = parts.find((p) => p.type === "year")?.value;
    const m = parts.find((p) => p.type === "month")?.value;
    const day = parts.find((p) => p.type === "day")?.value;
    return `${y}-${m}-${day}`;
  };

  return { startDate: fmt(start), endDate: fmt(endInclusive) };
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
