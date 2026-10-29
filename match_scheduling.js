/**
 * Match scheduling — Phase 1 client helpers.
 */

import { supabase } from "./global.js";
import {
  fixtureOwnerOccupancy,
  ownerAssignedAtForClub,
} from "./clubs_lookup.js";
import { ownerHolidayStatusForClub } from "./owner_badge.js";
import { formatUkDateRange } from "./owner_holidays.js";
import { GPSL_MONTH_LABELS, GPSL_MONTH_ORDER } from "./competition.js";

export const UK_TZ = "Europe/London";
export const SLOT_MINUTES = 30;

/** @type {Map<string, { unlock_at?: string|null, lock_at?: string|null, sort_order?: number|null }>} */
let seasonCalendarByMonth = new Map();

/** Cache GPSL month unlock/lock rows for new-owner arrange grace checks. */
export function setSeasonCalendarMonths(rows) {
  seasonCalendarByMonth = new Map();
  for (const row of rows || []) {
    const key = String(row.gpsl_month || "").trim().toLowerCase();
    if (!key) continue;
    seasonCalendarByMonth.set(key, {
      unlock_at: row.unlock_at || null,
      lock_at: row.lock_at || null,
      sort_order: row.sort_order ?? null,
    });
  }
}

function monthLabel(monthKey) {
  const key = String(monthKey || "").toLowerCase();
  return GPSL_MONTH_LABELS[key] || monthKey || "—";
}

function nextGpslMonthKey(monthKey) {
  const key = String(monthKey || "").toLowerCase();
  const i = GPSL_MONTH_ORDER.indexOf(key);
  if (i < 0 || i >= GPSL_MONTH_ORDER.length - 1) return null;
  return GPSL_MONTH_ORDER[i + 1];
}

/**
 * Mid–play-month new owner on either side → arrangement deferred to next GPSL month.
 * @returns {null | {
 *   clubShort: string,
 *   playMonth: string,
 *   playMonthLabel: string,
 *   arrangeFromMonth: string|null,
 *   arrangeFromLabel: string,
 *   graceUntilIso: string|null,
 * }}
 */
export function fixtureNewOwnerArrangeGrace(fixture, nowMs = Date.now()) {
  if (!fixture || fixture.status === "played") return null;
  const playMonth = String(fixture.gpsl_month || "").trim().toLowerCase();
  if (!playMonth) return null;

  const cal = seasonCalendarByMonth.get(playMonth) || null;
  const unlockMs = cal?.unlock_at ? new Date(cal.unlock_at).getTime() : NaN;
  const lockMs = cal?.lock_at ? new Date(cal.lock_at).getTime() : NaN;

  // Grace only while the fixture's play month is still open (or calendar unknown).
  if (Number.isFinite(lockMs) && nowMs > lockMs) return null;

  const sides = [
    fixture.home_club_short_name,
    fixture.away_club_short_name,
  ];
  for (const short of sides) {
    const assignedIso = ownerAssignedAtForClub(short);
    if (!assignedIso) continue;
    const assignedMs = new Date(assignedIso).getTime();
    if (!Number.isFinite(assignedMs)) continue;

    let inPlayMonth = false;
    if (Number.isFinite(unlockMs)) {
      inPlayMonth =
        assignedMs >= unlockMs &&
        (!Number.isFinite(lockMs) || assignedMs <= lockMs);
    } else {
      // No calendar row — treat recent appointment during this fixture month label
      // as grace only when the fixture month matches (caller should load calendar).
      inPlayMonth = false;
    }
    if (!inPlayMonth) continue;

    const arrangeFrom = nextGpslMonthKey(playMonth);
    return {
      clubShort: String(short || "").toUpperCase(),
      playMonth,
      playMonthLabel: monthLabel(playMonth),
      arrangeFromMonth: arrangeFrom,
      arrangeFromLabel: arrangeFrom
        ? monthLabel(arrangeFrom)
        : "the following GPSL month",
      graceUntilIso: cal?.lock_at || null,
    };
  }
  return null;
}

/**
 * Kick-off column: to be scheduled while new-owner mid-month grace applies.
 */
export function newOwnerGraceKickoffNoteHtml(grace, { catchUp = false } = {}) {
  if (!grace) return "";
  const prefix = catchUp ? catchUpKickoffPrefix() : "";
  const untilBit = grace.graceUntilIso
    ? ` through ${formatKickoff(grace.graceUntilIso, UK_TZ)} UK (end of ${grace.playMonthLabel})`
    : ` through end of ${grace.playMonthLabel}`;
  const title = escapeKoAttr(
    `A new owner took charge during ${grace.playMonthLabel}. Match arrangement does not apply until ${grace.arrangeFromLabel}. Grace${untilBit}.`
  );
  return (
    `<span class="ko-status ko-status--grace" title="${title}">` +
    `${prefix}To be scheduled · grace period in play` +
    `</span>` +
    `<span class="ko-status-detail">Grace${untilBit} — arrange from ${grace.arrangeFromLabel}</span>`
  );
}

function holidayOverlapsPlayMonth(hol, playMonth) {
  if (!hol?.starts_at || !hol?.ends_at || !playMonth) return false;
  const cal = seasonCalendarByMonth.get(String(playMonth).toLowerCase());
  if (!cal?.unlock_at || !cal?.lock_at) return false;
  const startMs = new Date(hol.starts_at).getTime();
  const endMs = new Date(hol.ends_at).getTime();
  const unlockMs = new Date(cal.unlock_at).getTime();
  const lockMs = new Date(cal.lock_at).getTime();
  if (
    ![startMs, endMs, unlockMs, lockMs].every((n) => Number.isFinite(n))
  ) {
    return false;
  }
  // Same rule as match_schedule_club_on_holiday_for_month
  return startMs < lockMs && endMs > unlockMs;
}

/**
 * UH/OH on either side that overlaps this fixture's GPSL month.
 * @returns {null | {
 *   clubShort: string,
 *   code: 'OH'|'UH',
 *   status: string,
 *   starts_at: string,
 *   ends_at: string,
 *   rangeLabel: string,
 *   playMonthLabel: string,
 * }}
 */
export function fixtureHolidayArrangeNote(fixture) {
  if (!fixture || fixture.status === "played") return null;
  const playMonth = String(fixture.gpsl_month || "").trim().toLowerCase();
  if (!playMonth) return null;

  const sides = [
    fixture.home_club_short_name,
    fixture.away_club_short_name,
  ];
  /** Prefer active (OH) over upcoming when both overlap. */
  let best = null;
  for (const short of sides) {
    const hol = ownerHolidayStatusForClub(short);
    if (!hol || (hol.code !== "OH" && hol.code !== "UH")) continue;
    if (!holidayOverlapsPlayMonth(hol, playMonth)) continue;
    const entry = {
      clubShort: String(short || "").toUpperCase(),
      code: hol.code,
      status: hol.status || (hol.code === "OH" ? "active" : "upcoming"),
      starts_at: hol.starts_at,
      ends_at: hol.ends_at,
      rangeLabel: formatUkDateRange(hol.starts_at, hol.ends_at),
      playMonthLabel: monthLabel(playMonth),
    };
    if (!best || (best.code === "UH" && entry.code === "OH")) {
      best = entry;
    }
  }
  return best;
}

function escapeKoText(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

/**
 * Kick-off column when a booked holiday covers this fixture's play month.
 */
export function holidayKickoffNoteHtml(note, { catchUp = false } = {}) {
  if (!note) return "";
  const prefix = catchUp ? catchUpKickoffPrefix() : "";
  const onHoliday = note.code === "OH";
  const main = onHoliday
    ? "To be scheduled · holiday in play"
    : "To be scheduled · holiday booked";
  const detail = onHoliday
    ? `${note.clubShort} on holiday ${note.rangeLabel} — scheduling fines paused`
    : `${note.clubShort} holiday ${note.rangeLabel} covers ${note.playMonthLabel} — arrange/play early where possible`;
  const title = escapeKoAttr(
    onHoliday
      ? `${note.clubShort} is on holiday (${note.rangeLabel}). Scheduling fines are paused while away; arrange when both sides can.`
      : `${note.clubShort} has a booked holiday (${note.rangeLabel}) covering ${note.playMonthLabel}. Arrange/play early where possible (4+ day month overlap unlocks early play).`
  );
  return (
    `<span class="ko-status ko-status--holiday" title="${title}">` +
    `${prefix}${main}` +
    `</span>` +
    `<span class="ko-status-detail">${escapeKoText(detail)}</span>`
  );
}

/** ISO weekday 1=Mon … 7=Sun */
export const ISO_DOW_LABELS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/** Wall-clock pieces in a timezone for tidy kick-off labels. */
function kickoffParts(iso, timezone = UK_TZ) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: timezone || UK_TZ,
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(d);
  const pick = (type) => parts.find((p) => p.type === type)?.value || "";
  const weekday = pick("weekday");
  const day = pick("day");
  const month = pick("month");
  const hour = pick("hour");
  const minute = pick("minute");
  return {
    weekday,
    dayMonth: `${day} ${month}`,
    time: `${hour}:${minute}`,
    dateKey: `${weekday}|${day}|${month}`,
  };
}

/** e.g. Sat 17 Oct · 19:00 */
export function formatKickoff(iso, timezone = UK_TZ) {
  const p = kickoffParts(iso, timezone);
  if (!p) return "—";
  return `${p.weekday} ${p.dayMonth} · ${p.time}`;
}

/** Time only, or weekday+time when the calendar day differs from UK. */
function formatLocalVsUk(iso, timezone) {
  const local = kickoffParts(iso, timezone);
  const uk = kickoffParts(iso, UK_TZ);
  if (!local) return "—";
  if (uk && local.dateKey === uk.dateKey) return local.time;
  return `${local.weekday} ${local.time}`;
}

/**
 * Compact kick-off for propose / accept / agreed lines.
 * Always leads with UK; adds Home/Away times only when those zones differ.
 */
export function formatKickoffPair(iso, homeTz, awayTz) {
  const uk = formatKickoff(iso, UK_TZ);
  if (!uk || uk === "—") return "—";

  const h = homeTz && homeTz !== UK_TZ ? homeTz : null;
  const a = awayTz && awayTz !== UK_TZ ? awayTz : null;

  if (!h && !a) return `${uk} UK`;

  if (h && a && h === a) {
    return `${uk} UK · Local ${formatLocalVsUk(iso, h)}`;
  }

  const bits = [`${uk} UK`];
  if (h) bits.push(`Home ${formatLocalVsUk(iso, h)}`);
  if (a && a !== h) bits.push(`Away ${formatLocalVsUk(iso, a)}`);
  return bits.join(" · ");
}

/**
 * Slot button HTML: owner-local on top; UK / Home / Away extras muted underneath.
 */
export function formatKickoffSlotHtml(iso, { ownerTz, homeTz, awayTz } = {}) {
  const primaryTz = ownerTz || UK_TZ;
  const main = formatKickoff(iso, primaryTz);
  const extras = [];

  if (primaryTz !== UK_TZ) {
    const uk = kickoffParts(iso, UK_TZ);
    if (uk) extras.push(`${uk.time} UK`);
  }

  const h = homeTz && homeTz !== primaryTz && homeTz !== UK_TZ ? homeTz : null;
  const a = awayTz && awayTz !== primaryTz && awayTz !== UK_TZ ? awayTz : null;

  if (h && a && h === a) {
    extras.push(`Opp ${formatLocalVsUk(iso, h)}`);
  } else {
    if (h) extras.push(`H ${formatLocalVsUk(iso, h)}`);
    if (a && a !== h) extras.push(`A ${formatLocalVsUk(iso, a)}`);
  }

  if (!extras.length) {
    return `<span class="slot-main">${main}</span>`;
  }
  return (
    `<span class="slot-main">${main}</span>` +
    `<span class="slot-sub">${extras.join(" · ")}</span>`
  );
}

/** Wall-clock parts in a timezone (for comparing local date/time). */
function localDateTimeKey(date, timeZone) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).formatToParts(date);
  const pick = (type) => parts.find((p) => p.type === type)?.value || "00";
  return `${pick("year")}-${pick("month")}-${pick("day")} ${pick("hour")}:${pick("minute")}:${pick("second")}`;
}

/**
 * True if kick-off block start is still in the future in the owner's timezone.
 */
export function isSelectableKickoffSlot(iso, ownerTimezone = UK_TZ) {
  if (!iso) return false;
  const kickoff = new Date(iso);
  if (Number.isNaN(kickoff.getTime())) return false;
  const tz = ownerTimezone || UK_TZ;
  return localDateTimeKey(kickoff, tz) > localDateTimeKey(new Date(), tz);
}

export function filterSelectableKickoffSlots(slots, ownerTimezone = UK_TZ) {
  return (slots || []).filter((iso) => isSelectableKickoffSlot(iso, ownerTimezone));
}

/** Wall-clock Y/M/D/H/M in a timezone. */
function zonedYmdHm(date, timeZone) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: timeZone || UK_TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(date);
  const pick = (type) => parts.find((p) => p.type === type)?.value || "00";
  let hour = pick("hour");
  if (hour === "24") hour = "00";
  return {
    y: Number(pick("year")),
    mo: Number(pick("month")),
    d: Number(pick("day")),
    h: Number(hour),
    mi: Number(pick("minute")),
  };
}

/**
 * datetime-local value (wall clock in `timeZone`) → Date (UTC instant).
 * Used for Schedule “poke” free date/time entry.
 */
export function dateFromZonedDateTimeLocal(localValue, timeZone = UK_TZ) {
  const m = String(localValue || "").match(
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/
  );
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  const h = Number(m[4]);
  const mi = Number(m[5]);
  const tz = timeZone || UK_TZ;
  let utc = Date.UTC(y, mo - 1, d, h, mi, 0);
  for (let i = 0; i < 4; i++) {
    const got = zonedYmdHm(new Date(utc), tz);
    const wantMs = Date.UTC(y, mo - 1, d, h, mi, 0);
    const gotMs = Date.UTC(got.y, got.mo - 1, got.d, got.h, got.mi, 0);
    const diff = wantMs - gotMs;
    if (diff === 0) break;
    utc += diff;
  }
  const out = new Date(utc);
  return Number.isNaN(out.getTime()) ? null : out;
}

/** ISO instant → datetime-local string in `timeZone`. */
export function zonedDateTimeLocalValue(isoOrDate, timeZone = UK_TZ) {
  const d = isoOrDate instanceof Date ? isoOrDate : new Date(isoOrDate);
  if (Number.isNaN(d.getTime())) return "";
  const p = zonedYmdHm(d, timeZone || UK_TZ);
  const pad = (n) => String(n).padStart(2, "0");
  return `${p.y}-${pad(p.mo)}-${pad(p.d)}T${pad(p.h)}:${pad(p.mi)}`;
}

/**
 * Snap to a UK 30-minute GPSL kick-off boundary (floor).
 * @returns {Date|null}
 */
export function snapToUkHalfHourSlot(isoOrDate) {
  const d = isoOrDate instanceof Date ? isoOrDate : new Date(isoOrDate);
  if (Number.isNaN(d.getTime())) return null;
  const uk = zonedYmdHm(d, UK_TZ);
  const snappedMi = uk.mi < 30 ? 0 : 30;
  const local = `${uk.y}-${String(uk.mo).padStart(2, "0")}-${String(uk.d).padStart(2, "0")}T${String(uk.h).padStart(2, "0")}:${String(snappedMi).padStart(2, "0")}`;
  return dateFromZonedDateTimeLocal(local, UK_TZ);
}

export function formatOwnerNowLine(ownerTimezone = UK_TZ) {
  const tz = ownerTimezone || UK_TZ;
  const now = new Date();
  const label = now.toLocaleString("en-GB", {
    timeZone: tz,
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const tzLabel = tz.replace(/_/g, " ");
  return `Your local time: ${label} (${tzLabel})`;
}

export function scheduleUrl(fixtureId) {
  return `fixture_schedule.html?fixture=${encodeURIComponent(String(fixtureId))}`;
}

export function isCatchUpFixture(fixture) {
  // Calendar catch-up (play month locked) or admin wipe stamped for replay.
  return fixture?.is_catch_up === true || fixture?.is_admin_replay === true;
}

export function catchUpBadgeHtml() {
  return '<span class="catch-up-badge" title="Re-arrange and play as catch-up / replay (month locked or admin reset)">Catch-up / replay</span>';
}

/** Kick-off column prefix for catch-up (month locked) or admin replay reset. */
export function catchUpKickoffPrefix() {
  return "Catch-up / replay · ";
}

/** Human-readable response deadline line for schedule UI. */
export function formatResponseDeadlineLine(deadline, myClubShort) {
  if (!deadline?.due_at) return "";
  const mine = deadline.my_turn === true;
  const overdue = deadline.overdue === true;
  const uk = deadline.due_at_uk || formatKickoff(deadline.due_at, UK_TZ) + " UK";
  const misses = "";
  if (mine && overdue) {
    return `Response overdue since ${uk} — reply now. First overdue month lock is a warning only; later locks while still overdue charge ₿2.5m (once per lock).`;
  }
  if (mine) {
    return `Your response due by ${uk}${misses}.`;
  }
  if (deadline.required_club_short_name && myClubShort) {
    const waiting =
      (deadline.required_club_short_name || "").toUpperCase() ===
      (myClubShort || "").toUpperCase()
        ? "You"
        : "Opponent";
    if (waiting === "You") return `Your response due by ${uk}${misses}.`;
    return `Waiting for opponent — response due ${uk}${misses}.`;
  }
  return `Response due ${uk}${misses}.`;
}

export async function loadScheduleContext(fixtureId) {
  const { data, error } = await supabase.rpc("match_schedule_fixture_context", {
    p_fixture_id: fixtureId,
  });
  if (error) throw error;

  const ctx = data || {};
  // Fallback when DB context has not yet been patched with manager flags
  if (ctx.my_has_manager == null) {
    try {
      const short =
        ctx.my_role === "home"
          ? ctx.fixture?.home_club_short_name
          : ctx.my_role === "away"
            ? ctx.fixture?.away_club_short_name
            : null;
      if (short) {
        const { data: hasMgr } = await supabase.rpc("club_has_signed_manager", {
          p_club_short: short,
        });
        ctx.my_has_manager = hasMgr === true;
        if (!ctx.my_has_manager) {
          ctx.can_propose_first = false;
          ctx.can_respond = false;
        }
      }
    } catch (_) {
      /* RPC may be missing until patch is run */
    }
  } else if (ctx.my_has_manager === false) {
    ctx.can_propose_first = false;
    ctx.can_respond = false;
  }

  return ctx;
}

export async function loadAvailabilityContext() {
  const { data, error } = await supabase.rpc("club_availability_context");
  if (error) throw error;
  return data;
}

export async function saveWeeklyAvailability(slots) {
  const { error } = await supabase.rpc("club_availability_save_weekly", {
    p_slots: slots,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
}

export async function setOwnerTimezone(timezone) {
  const { error } = await supabase.rpc("club_owner_timezone_set", {
    p_timezone: timezone,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
}

export async function loadAvailabilityContextForClub(clubShortName) {
  const { data, error } = await supabase.rpc("admin_club_availability_context", {
    p_club_short_name: clubShortName,
  });
  if (error) throw error;
  return data;
}

export async function saveWeeklyAvailabilityForClub(clubShortName, slots) {
  const { error } = await supabase.rpc("admin_club_availability_save_weekly", {
    p_club_short_name: clubShortName,
    p_slots: slots,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
}

export async function setClubTimezoneForClub(clubShortName, timezone) {
  const { error } = await supabase.rpc("admin_club_owner_timezone_set", {
    p_club_short_name: clubShortName,
    p_timezone: timezone,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
}

export async function loadOnboardingAvailabilityContext() {
  const { data, error } = await supabase.rpc("owner_onboarding_availability_context");
  if (error) throw error;
  return data;
}

export async function saveOnboardingWeeklyAvailability(slots) {
  const { error } = await supabase.rpc("owner_onboarding_availability_save_weekly", {
    p_slots: slots,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
}

export async function setOnboardingTimezone(timezone) {
  const { error } = await supabase.rpc("owner_onboarding_timezone_set", {
    p_timezone: timezone,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
}

export async function proposeKickoff(fixtureId, kickoffAt) {
  const { data, error } = await supabase.rpc("fixture_schedule_propose", {
    p_fixture_id: fixtureId,
    p_kickoff_at: kickoffAt,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true, proposalId: data };
}

export async function acceptProposal(proposalId) {
  const { data, error } = await supabase.rpc("fixture_schedule_accept", {
    p_proposal_id: proposalId,
  });
  if (error) return { ok: false, msg: error.message };
  if (data && data.ok === false) {
    const softCodes = new Set([
      "already_accepted",
      "already_agreed",
      "superseded",
      "withdrawn",
      "not_pending",
    ]);
    return {
      ok: false,
      msg: data.message || "Could not accept proposal",
      soft: softCodes.has(data.code),
    };
  }
  return { ok: true };
}

export async function checkInToFixture(fixtureId) {
  const { data, error } = await supabase.rpc("fixture_check_in", {
    p_fixture_id: fixtureId,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true, data };
}

export async function loadMatchdayCheckinReadiness(fixtureId) {
  const { data, error } = await supabase.rpc("club_matchday_checkin_ready", {
    p_fixture_id: fixtureId,
  });
  if (error) return { ok: false, msg: error.message, data: null };
  return { ok: true, data };
}

export async function voluntaryRescheduleDrop(fixtureId) {
  const { error } = await supabase.rpc("fixture_voluntary_reschedule_drop", {
    p_fixture_id: fixtureId,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
}

export async function catchUpResetSchedule(fixtureId) {
  const { error } = await supabase.rpc("fixture_catch_up_reset_schedule", {
    p_fixture_id: fixtureId,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
}

export async function emergencyDrop(fixtureId) {
  const { error } = await supabase.rpc("fixture_emergency_drop", {
    p_fixture_id: fixtureId,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
}

export async function requestMutualOverridePlayNow(fixtureId, kickoffAt = null) {
  const args = {
    p_fixture_id: fixtureId,
    p_kind: "play_now",
  };
  if (kickoffAt) args.p_kickoff_at = kickoffAt;
  const { data, error } = await supabase.rpc("fixture_mutual_override_request", args);
  if (error) return { ok: false, msg: error.message };
  return { ok: true, data };
}

export async function requestMutualOverrideNewTime(fixtureId, kickoffAt) {
  const { data, error } = await supabase.rpc("fixture_mutual_override_request", {
    p_fixture_id: fixtureId,
    p_kind: "new_time",
    p_kickoff_at: kickoffAt,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true, data };
}

export async function confirmMutualOverride(fixtureId) {
  const { data, error } = await supabase.rpc("fixture_mutual_override_confirm", {
    p_fixture_id: fixtureId,
  });
  if (error) return { ok: false, msg: error.message };
  if (data && data.ok === false) {
    const softCodes = new Set(["no_pending", "already_confirmed"]);
    return {
      ok: false,
      msg: data.message || "Could not confirm override",
      soft: softCodes.has(data.code),
    };
  }
  return { ok: true, msg: data?.message, applied: data?.applied };
}

export async function cancelMutualOverride(fixtureId) {
  const { data, error } = await supabase.rpc("fixture_mutual_override_cancel", {
    p_fixture_id: fixtureId,
  });
  if (error) return { ok: false, msg: error.message };
  if (data && data.ok === false) {
    return { ok: false, msg: data.message, soft: true };
  }
  return { ok: true, msg: data?.message };
}

/** Client mirror of server play window (after Phase 2). */
export function canPlayAgreedFixture(fixture) {
  if (!fixture || fixture.status !== "scheduled") return false;
  if (fixture.schedule_status !== "agreed" || !fixture.agreed_kickoff_at) return false;

  const kickoff = new Date(fixture.agreed_kickoff_at).getTime();
  const now = Date.now();
  const blockMs = SLOT_MINUTES * 60 * 1000;

  if (now < kickoff || now >= kickoff + blockMs) return false;
  if (!fixture.home_checked_in || !fixture.away_checked_in) return false;
  return true;
}

export function checkinStatusLabel(fixture) {
  if (fixture?.schedule_status !== "agreed" || !fixture?.agreed_kickoff_at) return null;
  const h = fixture.home_checked_in ? "✓" : "—";
  const a = fixture.away_checked_in ? "✓" : "—";
  return `Check-in: home ${h} · away ${a}`;
}

export function slotKey(isoDow, hour, minute) {
  return `${isoDow}:${hour}:${minute}`;
}

export function parseSlotKey(key) {
  const [isoDow, hour, minute] = key.split(":").map(Number);
  return { iso_dow: isoDow, hour, minute };
}

export function slotsFromKeys(keys) {
  return keys.map((k) => parseSlotKey(k));
}

/** Hours shown on the weekly grid (UK wall clock). */
export const GRID_HOURS = Array.from({ length: 18 }, (_, i) => 6 + i);

/**
 * True when my club faces a vacant or season-absent opponent (walkover path).
 * @param {object} fixture
 * @param {string} myClubShort
 * @param {ReturnType<typeof fixtureOwnerOccupancy>} [occ]
 */
export function fixtureOpponentIsInactive(fixture, myClubShort, occ = null) {
  if (!fixture || !myClubShort) return false;
  const occupancy =
    occ ||
    fixtureOwnerOccupancy(
      fixture.home_club_short_name,
      fixture.away_club_short_name
    );
  const me = String(myClubShort).toUpperCase();
  const home = String(fixture.home_club_short_name || "").toUpperCase();
  const away = String(fixture.away_club_short_name || "").toUpperCase();
  if (home === me) {
    return !occupancy.awayOwned || occupancy.awayAbsent;
  }
  if (away === me) {
    return !occupancy.homeOwned || occupancy.homeAbsent;
  }
  return false;
}

function escapeKoAttr(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;");
}

/**
 * Kick-off column note when one side is vacant / season-absent.
 * Owned club is awarded 3–0 at month end — not necessarily the home side.
 */
export function vacantOpponentKickoffNoteHtml({
  forOwnedClub = false,
  catchUp = false,
  seasonAbsent = false,
} = {}) {
  const prefix = catchUp ? catchUpKickoffPrefix() : "";
  const why = seasonAbsent ? "season absence" : "no owner (vacant)";
  if (forOwnedClub) {
    const title = escapeKoAttr(
      `Opponent has ${why}. You are awarded 3–0 at GPSL month end — no need to arrange kick-off. If they pick up a new owner before the month ends, match arrangement still does not apply until the following month.`
    );
    return (
      `<span class="ko-status ko-status--vacant" title="${title}">` +
      `${prefix}Vacant / inactive opponent · 3–0 walkover at month end` +
      `</span>` +
      `<span class="ko-status-detail">No arrange needed. New owner mid-month → arrangement from next month only.</span>`
    );
  }
  const title = escapeKoAttr(
    `One club has ${why}. The owned club is awarded 3–0 at GPSL month end. No match arrangement is required.`
  );
  return (
    `<span class="ko-status ko-status--vacant" title="${title}">` +
    `${prefix}Vacant / inactive opponent · walkover at month end (3–0 to owned club)` +
    `</span>`
  );
}

export function scheduleActionLabel(fixture, myClubShort) {
  if (!fixture || !myClubShort) return null;
  if (fixture.status !== "scheduled") return null;

  // Vacant / season-absent opponent — no propose / reply loop
  if (fixtureOpponentIsInactive(fixture, myClubShort)) {
    const catchUpEarly = isCatchUpFixture(fixture);
    return {
      label: catchUpEarly
        ? "Catch-up / replay · walkover (no arrange)"
        : "Walkover — no arrange needed",
      href: scheduleUrl(fixture.id),
      muted: true,
      vacantWalkover: true,
    };
  }

  const catchUp = isCatchUpFixture(fixture);
  const newOwnerGrace = fixtureNewOwnerArrangeGrace(fixture);
  // Mid-month takeover: arrangement deferred until the following GPSL month
  if (
    newOwnerGrace &&
    fixture.schedule_status !== "agreed" &&
    !fixture.agreed_kickoff_at
  ) {
    return {
      label: catchUp
        ? `Catch-up / replay · grace — arrange from ${newOwnerGrace.arrangeFromLabel}`
        : `Grace period — arrange from ${newOwnerGrace.arrangeFromLabel}`,
      href: scheduleUrl(fixture.id),
      muted: true,
      newOwnerGrace: true,
    };
  }

  if (fixture.schedule_status === "agreed" && fixture.agreed_kickoff_at) {
    const kickoff = new Date(fixture.agreed_kickoff_at).getTime();
    const stale = Number.isFinite(kickoff) && kickoff < Date.now();
    if (catchUp && stale) {
      return {
        label: "Catch-up / replay · re-schedule",
        href: scheduleUrl(fixture.id),
      };
    }
    return {
      label: catchUp
        ? "Catch-up / replay · kick-off agreed"
        : "Kick-off agreed",
      href: scheduleUrl(fixture.id),
      muted: true,
    };
  }
  const me = (myClubShort || "").toUpperCase();
  const isHome = (fixture.home_club_short_name || "").toUpperCase() === me;
  const isAway = (fixture.away_club_short_name || "").toUpperCase() === me;

  if (fixture.schedule_status === "unscheduled" && isHome) {
    return {
      label: catchUp
        ? "Catch-up / replay · propose kick-off"
        : "Propose kick-off",
      href: scheduleUrl(fixture.id),
    };
  }
  if (fixture.schedule_status === "unscheduled" && isAway) {
    return {
      label: catchUp
        ? "Catch-up / replay · waiting for home"
        : "Waiting for home",
      href: scheduleUrl(fixture.id),
      muted: true,
    };
  }

  if (
    fixture.schedule_status === "negotiating" &&
    fixture.schedule_pending_proposal_id
  ) {
    const myTurn = isMyScheduleResponseTurn(fixture, myClubShort);
    if (myTurn) {
      return {
        label: catchUp
          ? "Catch-up / replay · reply to proposal"
          : "Reply to proposal",
        href: scheduleUrl(fixture.id),
      };
    }
    return {
      label: catchUp
        ? "Catch-up / replay · waiting on opponent"
        : "Waiting on opponent",
      href: scheduleUrl(fixture.id),
      muted: true,
    };
  }

  if (fixture.schedule_status === "negotiating" && isHome) {
    return {
      label: catchUp ? "Catch-up / replay · schedule" : "Schedule",
      href: scheduleUrl(fixture.id),
    };
  }

  return {
    label: catchUp ? "Catch-up / replay · schedule" : "Schedule",
    href: scheduleUrl(fixture.id),
  };
}

/**
 * Whose turn is it to accept / counter-propose?
 * Prefers schedule_response_required_club; falls back to proposal counts.
 */
export function isMyScheduleResponseTurn(fixture, myClubShort) {
  if (!fixture || !myClubShort) return false;
  const me = (myClubShort || "").toUpperCase();
  const required = (fixture.schedule_response_required_club || "").toUpperCase();
  if (required) return required === me;

  const isHome = (fixture.home_club_short_name || "").toUpperCase() === me;
  const isAway = (fixture.away_club_short_name || "").toUpperCase() === me;
  if (!isHome && !isAway) return false;

  const homeCount = Number(fixture.schedule_home_proposal_count) || 0;
  const awayCount = Number(fixture.schedule_away_proposal_count) || 0;
  // Home proposes first: if home has more proposals than away, away must respond.
  if (isHome) return homeCount <= awayCount;
  return homeCount > awayCount;
}
