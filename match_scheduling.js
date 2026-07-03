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

export function scheduleUrl(fixtureId) {
  return `fixture_schedule.html?fixture=${encodeURIComponent(String(fixtureId))}`;
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

export async function emergencyDrop(fixtureId) {
  const { error } = await supabase.rpc("fixture_emergency_drop", {
    p_fixture_id: fixtureId,
  });
  if (error) return { ok: false, msg: error.message };
  return { ok: true };
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
  if (fixture.schedule_status === "agreed" && fixture.agreed_kickoff_at) {
    return { label: "Match day", href: scheduleUrl(fixture.id), muted: true };
  }
  const isHome =
    (fixture.home_club_short_name || "").toUpperCase() ===
    (myClubShort || "").toUpperCase();
  if (fixture.schedule_status === "unscheduled" && isHome) {
    return { label: "Propose time", href: scheduleUrl(fixture.id) };
  }
  if (
    fixture.schedule_status === "negotiating" &&
    fixture.schedule_pending_proposal_id
  ) {
    return { label: "Respond", href: scheduleUrl(fixture.id) };
  }
  if (fixture.schedule_status === "negotiating" && isHome) {
    return { label: "Schedule", href: scheduleUrl(fixture.id) };
  }
  if (fixture.schedule_status === "unscheduled" && !isHome) {
    return { label: "Awaiting home", href: scheduleUrl(fixture.id), muted: true };
  }
  return { label: "Schedule", href: scheduleUrl(fixture.id) };
}
