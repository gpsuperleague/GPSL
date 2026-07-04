/**
 * Match scheduling — Phase 1 client helpers.
 */

import { supabase } from "./global.js";

export const UK_TZ = "Europe/London";
export const SLOT_MINUTES = 30;

/** ISO weekday 1=Mon … 7=Sun */
export const ISO_DOW_LABELS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

export function formatKickoff(iso, timezone = UK_TZ) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-GB", {
    timeZone: timezone,
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

export function formatKickoffPair(iso, homeTz, awayTz) {
  const uk = formatKickoff(iso, UK_TZ) + " UK";
  if (!homeTz || homeTz === awayTz) {
    return uk;
  }
  return `${uk} · Home: ${formatKickoff(iso, homeTz)} · Away: ${formatKickoff(iso, awayTz)}`;
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
  return fixture?.is_catch_up === true;
}

export function catchUpBadgeHtml() {
  return '<span class="catch-up-badge">Catch-up</span>';
}

export async function loadScheduleContext(fixtureId) {
  const { data, error } = await supabase.rpc("match_schedule_fixture_context", {
    p_fixture_id: fixtureId,
  });
  if (error) throw error;
  return data;
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

export async function requestMutualOverridePlayNow(fixtureId) {
  const { data, error } = await supabase.rpc("fixture_mutual_override_request", {
    p_fixture_id: fixtureId,
    p_kind: "play_now",
  });
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

export function scheduleActionLabel(fixture, myClubShort) {
  if (!fixture || !myClubShort) return null;
  if (fixture.status !== "scheduled") return null;
  const catchUp = isCatchUpFixture(fixture);
  if (fixture.schedule_status === "agreed" && fixture.agreed_kickoff_at) {
    const kickoff = new Date(fixture.agreed_kickoff_at).getTime();
    const stale = Number.isFinite(kickoff) && kickoff < Date.now();
    if (catchUp && stale) {
      return { label: "Catch-up · re-schedule", href: scheduleUrl(fixture.id) };
    }
    return {
      label: catchUp ? "Catch-up · match day" : "Match day",
      href: scheduleUrl(fixture.id),
      muted: true,
    };
  }
  const isHome =
    (fixture.home_club_short_name || "").toUpperCase() ===
    (myClubShort || "").toUpperCase();
  if (fixture.schedule_status === "unscheduled" && isHome) {
    return {
      label: catchUp ? "Catch-up · propose" : "Propose time",
      href: scheduleUrl(fixture.id),
    };
  }
  if (
    fixture.schedule_status === "negotiating" &&
    fixture.schedule_pending_proposal_id
  ) {
    return {
      label: catchUp ? "Catch-up · respond" : "Respond",
      href: scheduleUrl(fixture.id),
    };
  }
  if (fixture.schedule_status === "negotiating" && isHome) {
    return {
      label: catchUp ? "Catch-up · schedule" : "Schedule",
      href: scheduleUrl(fixture.id),
    };
  }
  if (fixture.schedule_status === "unscheduled" && !isHome) {
    return {
      label: catchUp ? "Catch-up · awaiting home" : "Awaiting home",
      href: scheduleUrl(fixture.id),
      muted: true,
    };
  }
  return {
    label: catchUp ? "Catch-up · schedule" : "Schedule",
    href: scheduleUrl(fixture.id),
  };
}
