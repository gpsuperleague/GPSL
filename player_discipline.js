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
  // Prefer multi-line: "Suspended" then match list
  const labels = [];
  for (const s of rows) {
    for (const m of s.pending_matches || []) {
      if (m?.label) labels.push(m.label);
    }
  }
  const unique = [...new Set(labels)];
  if (unique.length) {
    const matches = unique.slice(0, 2).join("<br>") + (unique.length > 2 ? "<br>…" : "");
    return `<div class="squad-status-lines"><span class="status-pill status-suspended" title="${reason}">Suspended<br>${matches}</span></div>`;
  }
  return `<div class="squad-status-lines"><span class="status-pill status-suspended" title="${reason}">${label}</span></div>`;
}

/** Compact badge for name cells (GPDB / club). */
export function formatSuspensionBadgeHtml(rows) {
  const labels = [];
  for (const s of rows || []) {
    for (const m of s.pending_matches || []) {
      if (m?.label) labels.push(m.label);
    }
  }
  const unique = [...new Set(labels)];
  if (!unique.length) {
    const fallback = formatSuspensionStatusLabel(rows);
    if (!fallback) return "";
    return `<span class="suspension-badge" title="${fallback}">${fallback}</span>`;
  }
  const title = `Suspended — ${unique.join(", ")}`;
  const body = `Suspended<br>${unique.slice(0, 2).join("<br>")}${unique.length > 2 ? "<br>…" : ""}`;
  return `<span class="suspension-badge" title="${title}">${body}</span>`;
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
      let cls = "unavailable-suspended";
      let tag = "Suspended";
      if (p.reason === "injured") {
        cls = "unavailable-injured";
        tag = "Injured";
      } else if (p.reason === "recovery") {
        cls = "unavailable-recovery";
        tag = "Gaining match fitness";
      }
      const name = p.player_name || p.player_id;
      const pos = p.position ? ` <span class="unavailable-pos">${p.position}</span>` : "";
      const raw = p.detail || "";
      const detail = raw
        ? ` — ${raw
            .replace(/^Suspended — /, "")
            .replace(/^Injured — /, "")
            .replace(/^Gaining match fitness — /, "")}`
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

/** @param {import("@supabase/supabase-js").SupabaseClient} supabase */
export async function loadClubSquadDiscipline(supabase, club = null) {
  const { data, error } = await supabase.rpc("competition_club_squad_discipline", {
    p_club: club || null,
  });
  if (error) {
    if (
      /competition_club_squad_discipline|schema cache|Could not find/i.test(
        error.message || ""
      )
    ) {
      console.warn(
        "competition_club_squad_discipline missing — run competition_club_squad_discipline.sql"
      );
      return { cards: [], injuries: [] };
    }
    console.error("competition_club_squad_discipline:", error);
    return { cards: [], injuries: [] };
  }
  return {
    cards: Array.isArray(data?.cards) ? data.cards : [],
    injuries: Array.isArray(data?.injuries) ? data.injuries : [],
  };
}

/** @param {{ player_id: string, yellows?: number, reds?: number }[]} cards */
export function cardsByPlayerId(cards) {
  /** @type {Map<string, { yellows: number, reds: number }>} */
  const map = new Map();
  for (const row of cards || []) {
    map.set(String(row.player_id), {
      yellows: Number(row.yellows) || 0,
      reds: Number(row.reds) || 0,
    });
  }
  return map;
}

/** @param {any[]} injuries */
export function injuriesByPlayerId(injuries) {
  /** @type {Map<string, any[]>} */
  const map = new Map();
  for (const row of injuries || []) {
    const id = String(row.player_id);
    if (!map.has(id)) map.set(id, []);
    map.get(id).push(row);
  }
  return map;
}

/** e.g. "6 out · 2 fitness" — always shows both phases. */
function injuryPhaseCountsText(outLeft, recLeft) {
  return `${outLeft} out · ${recLeft} fitness`;
}

/** @param {any[]} injuryRows */
export function formatInjuryStatusHtml(injuryRows) {
  if (!injuryRows?.length) return "";
  return injuryRows
    .map((inj) => {
      const label = inj.label || "Injury";
      const outLeft = Number(inj.matches_out_remaining) || 0;
      const recLeft = Number(inj.recovery_remaining) || 0;
      const counts = injuryPhaseCountsText(outLeft, recLeft);
      const pending = (inj.pending_matches || [])
        .map((m) => m.label)
        .filter(Boolean);
      const pendingText = pending.length
        ? ` — ${pending.slice(0, 2).join(", ")}${pending.length > 2 ? "…" : ""}`
        : "";

      if (outLeft > 0 || inj.phase === "out") {
        return `<div class="squad-status-lines"><span class="status-pill status-injured" title="${label} — ${counts}">Injured — ${label} (${counts})${pendingText}</span></div>`;
      }
      return `<div class="squad-status-lines"><span class="status-pill status-recovery" title="${label} — ${counts}">Gaining match fitness — ${label} (${counts})${pendingText}</span></div>`;
    })
    .join("");
}

/** Compact badge for club.html name cells (multi-line so it wraps in the column). */
export function formatInjuryBadgeHtml(injuryRows) {
  if (!injuryRows?.length) return "";
  return injuryRows
    .map((inj) => {
      const label = inj.label || "Injury";
      const outLeft = Number(inj.matches_out_remaining) || 0;
      const recLeft = Number(inj.recovery_remaining) || 0;
      const counts = injuryPhaseCountsText(outLeft, recLeft);
      if (outLeft > 0 || inj.phase === "out") {
        const title = `Injured — ${label} (${counts})`;
        const body = `Injured<br>${label}<br>${counts}`;
        return `<span class="injury-badge injury-badge-out" title="${title}">${body}</span>`;
      }
      const title = `Gaining match fitness — ${label} (${counts})`;
      const body = `Gaining match fitness<br>${label}<br>${counts}`;
      return `<span class="injury-badge injury-badge-recovery" title="${title}">${body}</span>`;
    })
    .join("");
}

/** @param {{ yellows?: number, reds?: number }|null} cards */
export function formatCardsStatusHtml(cards) {
  if (!cards) return "";
  const y = Number(cards.yellows) || 0;
  const r = Number(cards.reds) || 0;
  if (y <= 0 && r <= 0) return "";
  const yClass =
    y >= 8 ? "status-cards-ban" : y >= 6 ? "status-cards-warn" : "status-cards";
  const parts = [];
  if (y > 0) {
    parts.push(
      `<span class="status-pill ${yClass}" title="Season yellow cards (ban every 8)">YC ${y}/8</span>`
    );
  }
  if (r > 0) {
    parts.push(
      `<span class="status-pill status-cards-red" title="Season red cards">RC ${r}</span>`
    );
  }
  return `<div class="squad-status-lines">${parts.join(" ")}</div>`;
}

/**
 * Active injuries for a club (any club — public squad / club.html view).
 * Prefer SECURITY DEFINER RPC so RLS on competition_player_injuries cannot hide rows
 * (admin_injuries uses the same path via admin RPCs).
 */
export async function loadClubActiveInjuries(supabase, club) {
  if (!club) return [];

  const viaRpc = await loadClubSquadDiscipline(supabase, club);
  if (viaRpc?.injuries?.length) {
    return viaRpc.injuries.map((i) => ({
      ...i,
      injury_id: i.injury_id ?? i.id,
      status: i.status || "active",
    }));
  }

  // Fallback: direct table (needs GRANT + RLS policy). Empty RPC may mean no injuries
  // or missing function — still try table in case RPC failed open with [].
  const { data, error } = await supabase
    .from("competition_player_injuries")
    .select(
      "id, player_id, label, severity, matches_out_remaining, recovery_remaining, status"
    )
    .eq("club_short_name", club)
    .eq("status", "active");

  if (error) {
    if (!/schema cache|Could not find|permission|RLS/i.test(error.message || "")) {
      console.error("loadClubActiveInjuries:", error);
    }
    return viaRpc?.injuries || [];
  }

  return (data || [])
    .filter(
      (i) =>
        (Number(i.matches_out_remaining) || 0) > 0 ||
        (Number(i.recovery_remaining) || 0) > 0
    )
    .map((i) => ({
      ...i,
      injury_id: i.id,
      phase: (Number(i.matches_out_remaining) || 0) > 0 ? "out" : "recovery",
    }));
}


