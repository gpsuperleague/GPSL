/**
 * Player yellow/red cards and match suspensions (shared UI helpers).
 */

/**
 * @typedef {{ fixture_id: number, sequence_no: number, served?: boolean, label?: string, matchday?: number }} SuspensionMatch
 * @typedef {{
 *   suspension_id: number,
 *   player_id: string,
 *   club_short_name?: string,
 *   reason: string,
 *   yellow_count_at_issue?: number|null,
 *   pending_matches?: SuspensionMatch[],
 *   season_yellows?: number,
 *   season_reds?: number,
 * }} ActiveSuspension
 */

/** @param {import("@supabase/supabase-js").SupabaseClient} supabase */
export async function loadActiveSuspensions(supabase, { club = null, playerIds = null } = {}) {
  const { data, error } = await supabase.rpc("competition_active_suspensions", {
    p_club: club || null,
    p_player_ids: playerIds?.length ? playerIds.map(String) : null,
  });
  if (error) {
    if (
      /competition_active_suspensions|schema cache|Could not find/i.test(
        error.message || ""
      )
    ) {
      console.warn(
        "competition_active_suspensions missing — run competition_player_discipline.sql"
      );
      return [];
    }
    console.error("competition_active_suspensions:", error);
    return [];
  }
  return Array.isArray(data) ? data : [];
}

/** @param {ActiveSuspension[]} list */
export function suspensionsByPlayerId(list) {
  /** @type {Map<string, ActiveSuspension[]>} */
  const map = new Map();
  for (const row of list || []) {
    const id = String(row.player_id);
    if (!map.has(id)) map.set(id, []);
    map.get(id).push(row);
  }
  return map;
}

/** @param {ActiveSuspension} s */
export function suspensionReasonLabel(s) {
  if (s?.reason === "red_card") return "Red card";
  if (s?.reason === "yellow_accumulation") {
    const n = s.yellow_count_at_issue || 8;
    return `${n} yellows`;
  }
  return s?.reason || "Suspension";
}

/**
 * Short squad/GPDB label: "Suspended — MD12 vs X, MD13 vs Y"
 * @param {ActiveSuspension[]} rows
 */
export function formatSuspensionStatusLabel(rows) {
  if (!rows?.length) return null;
  const labels = [];
  for (const s of rows) {
    for (const m of s.pending_matches || []) {
      if (m?.label) labels.push(m.label);
    }
  }
  const unique = [...new Set(labels)];
  if (!unique.length) {
    return `Suspended (${suspensionReasonLabel(rows[0])})`;
  }
  if (unique.length === 1) {
    return `Suspended for ${unique[0]}`;
  }
  if (unique.length === 2) {
    return `Suspended for ${unique[0]} and ${unique[1]}`;
  }
  return `Suspended for ${unique.slice(0, 2).join(" and ")} (+${unique.length - 2})`;
}

/** @param {ActiveSuspension[]} rows */
export function formatSuspensionStatusHtml(rows) {
  const label = formatSuspensionStatusLabel(rows);
  if (!label) return "";
  const reason = suspensionReasonLabel(rows[0]);
  return `<div class="squad-status-lines"><span class="status-pill status-suspended" title="${reason}">${label}</span></div>`;
}

/** Compact badge for name cells (GPDB / club). */
export function formatSuspensionBadgeHtml(rows) {
  const label = formatSuspensionStatusLabel(rows);
  if (!label) return "";
  return `<span class="suspension-badge" title="${label}">${label}</span>`;
}

/** True if player is suspended for a specific fixture id. */
export function playerSuspendedForFixture(rows, fixtureId) {
  if (!rows?.length || fixtureId == null) return false;
  const fid = Number(fixtureId);
  return rows.some((s) =>
    (s.pending_matches || []).some((m) => Number(m.fixture_id) === fid && !m.served)
  );
}
