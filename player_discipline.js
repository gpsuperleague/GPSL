/**
 * Player yellow/red cards, suspensions, and fixture unavailable lists.
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
 * @typedef {{
 *   player_id: string,
 *   player_name?: string,
 *   position?: string,
 *   reason: 'suspended'|'injured'|string,
 *   detail?: string,
 * }} FixtureUnavailablePlayer
 * @typedef {{
 *   fixture_id: number,
 *   home_club_short_name?: string,
 *   away_club_short_name?: string,
 *   home?: FixtureUnavailablePlayer[],
 *   away?: FixtureUnavailablePlayer[],
 * }} FixtureUnavailablePayload
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

/**
 * Unavailable (suspended + injured) for both clubs on one fixture.
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @returns {Promise<FixtureUnavailablePayload|null>}
 */
export async function loadFixtureUnavailable(supabase, fixtureId) {
  if (fixtureId == null) return null;
  const { data, error } = await supabase.rpc(
    "competition_fixture_unavailable_players",
    { p_fixture_id: Number(fixtureId) }
  );
  if (error) {
    if (
      /competition_fixture_unavailable|schema cache|Could not find/i.test(
        error.message || ""
      )
    ) {
      console.warn(
        "competition_fixture_unavailable_players missing — run competition_fixture_unavailable.sql"
      );
      return null;
    }
    console.error("competition_fixture_unavailable_players:", error);
    return null;
  }
  return data || null;
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

/** @param {FixtureUnavailablePlayer[]} players */
function formatUnavailableSideList(players) {
  if (!players?.length) {
    return `<li class="unavailable-none">None</li>`;
  }
  return players
    .map((p) => {
      const cls =
        p.reason === "injured" ? "unavailable-injured" : "unavailable-suspended";
      const tag = p.reason === "injured" ? "Injured" : "Suspended";
      const name = p.player_name || p.player_id;
      const pos = p.position ? ` <span class="unavailable-pos">${p.position}</span>` : "";
      const raw = p.detail || "";
      const detail = raw
        ? ` — ${raw.replace(/^Suspended — |^Injured — /, "")}`
        : "";
      return `<li class="${cls}"><span class="unavailable-tag">${tag}</span> ${name}${pos}<span class="unavailable-detail">${detail}</span></li>`;
    })
    .join("");
}

/**
 * Two-column panel for Match Day / fixture schedule.
 * @param {FixtureUnavailablePayload|null} payload
 * @param {{ homeName?: string, awayName?: string }} names
 */
export function formatFixtureUnavailableHtml(payload, names = {}) {
  if (!payload) return "";
  const home = payload.home || [];
  const away = payload.away || [];
  if (!home.length && !away.length) {
    return `<div class="fixture-unavailable">
      <div class="fixture-unavailable-title">Unavailable for this match</div>
      <p class="unavailable-empty">No suspended or injured players listed for either club.</p>
    </div>`;
  }
  const homeLabel = names.homeName || payload.home_club_short_name || "Home";
  const awayLabel = names.awayName || payload.away_club_short_name || "Away";
  return `<div class="fixture-unavailable">
    <div class="fixture-unavailable-title">Unavailable for this match</div>
    <div class="fixture-unavailable-grid">
      <div>
        <div class="fixture-unavailable-club">${homeLabel}</div>
        <ul class="unavailable-list">${formatUnavailableSideList(home)}</ul>
      </div>
      <div>
        <div class="fixture-unavailable-club">${awayLabel}</div>
        <ul class="unavailable-list">${formatUnavailableSideList(away)}</ul>
      </div>
    </div>
  </div>`;
}

/**
 * Player ids unavailable for this fixture from payload (own club).
 * @param {FixtureUnavailablePayload|null} payload
 * @param {string|null} clubShort
 */
export function unavailablePlayerIdsForClub(payload, clubShort) {
  if (!payload || !clubShort) return new Set();
  const side =
    (payload.home_club_short_name || "").toUpperCase() ===
    String(clubShort).toUpperCase()
      ? payload.home
      : (payload.away_club_short_name || "").toUpperCase() ===
          String(clubShort).toUpperCase()
        ? payload.away
        : [];
  return new Set((side || []).map((p) => String(p.player_id)));
}
