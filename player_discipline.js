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
 *   appeal_pending?: boolean,
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

/** @param {ActiveSuspension[]} rows */
function anyAppealPending(rows) {
  return (rows || []).some((s) => !!s?.appeal_pending);
}

/** @param {ActiveSuspension[]} rows */
function pendingMatchLabels(rows) {
  const labels = [];
  for (const s of rows || []) {
    for (const m of s.pending_matches || []) {
      if (m?.label) labels.push(m.label);
    }
  }
  return [...new Set(labels)];
}

/**
 * Short squad/GPDB label: "Suspended — MD12 vs X, MD13 vs Y"
 * @param {ActiveSuspension[]} rows
 */
export function formatSuspensionStatusLabel(rows) {
  if (!rows?.length) return null;
  if (anyAppealPending(rows)) {
    return "Suspended — Pending review";
  }
  const unique = pendingMatchLabels(rows);
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
  const pendingReview = anyAppealPending(rows);
  const title = (pendingReview ? `${reason} — appeal pending review` : reason).replace(
    /"/g,
    "&quot;"
  );
  const unique = pendingMatchLabels(rows);
  const head = pendingReview ? "Suspended — Pending review" : "Suspended";
  if (unique.length) {
    return `<div class="squad-status-lines squad-miss-block" title="${title}">
      <span class="status-pill status-suspended">${head}</span>
      ${missSectionHtml("squad-miss-susp", "Misses", unique)}
    </div>`;
  }
  return `<div class="squad-status-lines"><span class="status-pill status-suspended" title="${title}">${label}</span></div>`;
}

/** Compact badge for name cells (GPDB / club). Full pending match list. */
export function formatSuspensionBadgeHtml(rows) {
  if (!rows?.length) return "";
  const pendingReview = anyAppealPending(rows);
  const unique = pendingMatchLabels(rows);
  if (pendingReview) {
    const title = unique.length
      ? `Suspended — Pending review (${unique.join(", ")})`
      : "Suspended — Pending review";
    const body = unique.length
      ? `Suspended — Pending review<br>${unique.join("<br>")}`
      : "Suspended — Pending review";
    return `<span class="suspension-badge" title="${title}">${body}</span>`;
  }
  if (!unique.length) {
    const fallback = formatSuspensionStatusLabel(rows);
    if (!fallback) return "";
    return `<span class="suspension-badge" title="${fallback}">${fallback}</span>`;
  }
  const title = `Suspended — ${unique.join(", ")}`;
  const body = `Suspended<br>${unique.join("<br>")}`;
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

/** @param {FixtureUnavailablePlayer[]|undefined} players */
function countUnavailableReasons(players) {
  let suspended = 0;
  let injured = 0;
  let recovery = 0;
  for (const p of players || []) {
    if (p.reason === "injured") injured += 1;
    else if (p.reason === "recovery") recovery += 1;
    else suspended += 1;
  }
  return { suspended, injured, recovery, total: suspended + injured + recovery };
}

/**
 * Players on one side for this fixture (own club).
 * @param {FixtureUnavailablePayload|null} payload
 * @param {string|null|undefined} clubShort
 * @returns {FixtureUnavailablePlayer[]}
 */
export function unavailablePlayersForClub(payload, clubShort) {
  if (!payload || !clubShort) return [];
  const key = String(clubShort).toUpperCase();
  if ((payload.home_club_short_name || "").toUpperCase() === key) {
    return payload.home || [];
  }
  if ((payload.away_club_short_name || "").toUpperCase() === key) {
    return payload.away || [];
  }
  return [];
}

/**
 * One-line summary for Club Wire / dashboard / inbox.
 * e.g. "Your unavailable (2): Smith (susp), Jones (inj)"
 * @param {FixtureUnavailablePayload|null} payload
 * @param {string|null|undefined} clubShort
 * @param {{ maxNames?: number, prefix?: string }} opts
 */
export function formatOwnUnavailableLine(payload, clubShort, opts = {}) {
  const side = unavailablePlayersForClub(payload, clubShort);
  if (!side.length) return "";
  const maxNames = opts.maxNames ?? 4;
  const prefix = opts.prefix ?? "Your unavailable";
  const counts = countUnavailableReasons(side);
  const bits = [];
  if (counts.suspended) bits.push(`${counts.suspended} susp`);
  if (counts.injured) bits.push(`${counts.injured} inj`);
  if (counts.recovery) bits.push(`${counts.recovery} fitness`);
  const names = side.slice(0, maxNames).map((p) => {
    const name = p.player_name || p.player_id;
    const tag =
      p.reason === "injured"
        ? "inj"
        : p.reason === "recovery"
          ? "fit"
          : "susp";
    return `${name} (${tag})`;
  });
  const more =
    side.length > maxNames ? ` +${side.length - maxNames} more` : "";
  return `${prefix} (${counts.total}: ${bits.join(", ")}): ${names.join(", ")}${more}`;
}

/**
 * Compact both-clubs line when you don't need the full panel.
 * @param {FixtureUnavailablePayload|null} payload
 */
export function formatFixtureUnavailableCompact(payload) {
  if (!payload) return "";
  const home = payload.home || [];
  const away = payload.away || [];
  if (!home.length && !away.length) return "";
  const homeKey = payload.home_club_short_name || "Home";
  const awayKey = payload.away_club_short_name || "Away";
  const parts = [];
  if (home.length) parts.push(`${homeKey} ${home.length} out`);
  if (away.length) parts.push(`${awayKey} ${away.length} out`);
  return parts.join(" · ");
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
  return `<div class="fixture-unavailable has-outs">
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
 * Prominent schedule / check-in banner — hidden when nobody is out.
 * Own club called out first when `clubShort` is set.
 * @param {FixtureUnavailablePayload|null} payload
 * @param {{ homeName?: string, awayName?: string, clubShort?: string|null }} opts
 */
export function formatFixtureUnavailableBannerHtml(payload, opts = {}) {
  if (!payload) return "";
  const home = payload.home || [];
  const away = payload.away || [];
  if (!home.length && !away.length) return "";

  const homeLabel = opts.homeName || payload.home_club_short_name || "Home";
  const awayLabel = opts.awayName || payload.away_club_short_name || "Away";
  const ownLine = formatOwnUnavailableLine(payload, opts.clubShort);
  const alert = ownLine
    ? `<div class="fixture-unavailable-alert">${ownLine
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")}</div>`
    : `<div class="fixture-unavailable-alert">Players unavailable for this match — check both clubs below before proposing or checking in.</div>`;

  return `<div class="fixture-unavailable has-outs" role="status">
    ${alert}
    <div class="fixture-unavailable-title">Unavailable for this match</div>
    <div class="fixture-unavailable-grid">
      <div class="${
        opts.clubShort &&
        (payload.home_club_short_name || "").toUpperCase() ===
          String(opts.clubShort).toUpperCase()
          ? "fixture-unavailable-own"
          : ""
      }">
        <div class="fixture-unavailable-club">${homeLabel}${
          home.length ? ` · ${home.length} out` : ""
        }</div>
        <ul class="unavailable-list">${formatUnavailableSideList(home)}</ul>
      </div>
      <div class="${
        opts.clubShort &&
        (payload.away_club_short_name || "").toUpperCase() ===
          String(opts.clubShort).toUpperCase()
          ? "fixture-unavailable-own"
          : ""
      }">
        <div class="fixture-unavailable-club">${awayLabel}${
          away.length ? ` · ${away.length} out` : ""
        }</div>
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

/**
 * Map player_id → 'suspended' | 'injured' | 'recovery' for one club on a fixture.
 * Suspension wins if both apply.
 * @param {FixtureUnavailablePayload|null} payload
 * @param {string|null} clubShort
 * @returns {Map<string, 'suspended'|'injured'|'recovery'>}
 */
export function unavailableStatusByPlayerId(payload, clubShort) {
  /** @type {Map<string, 'suspended'|'injured'|'recovery'>} */
  const map = new Map();
  if (!payload || !clubShort) return map;
  const side =
    (payload.home_club_short_name || "").toUpperCase() ===
    String(clubShort).toUpperCase()
      ? payload.home
      : (payload.away_club_short_name || "").toUpperCase() ===
          String(clubShort).toUpperCase()
        ? payload.away
        : [];
  for (const p of side || []) {
    const id = String(p.player_id);
    const reason = String(p.reason || "").toLowerCase();
    let status = "suspended";
    if (reason === "injured") status = "injured";
    else if (reason === "recovery") status = "recovery";
    const prev = map.get(id);
    if (prev === "suspended") continue;
    if (status === "suspended" || !prev) map.set(id, status);
  }
  return map;
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

function matchWord(n) {
  return `${n} match${n === 1 ? "" : "es"}`;
}

function injuryPendingLabelGroups(pendingMatches) {
  const pending = Array.isArray(pendingMatches) ? pendingMatches : [];
  const outLabels = pending
    .filter((m) => m?.phase === "out" && m.label)
    .map((m) => m.label);
  const recLabels = pending
    .filter((m) => m?.phase === "recovery" && m.label)
    .map((m) => m.label);
  const otherLabels = pending
    .filter((m) => m?.label && m.phase !== "out" && m.phase !== "recovery")
    .map((m) => m.label);
  if (!outLabels.length && !recLabels.length && !otherLabels.length) {
    const fallback = pending.map((m) => m?.label).filter(Boolean);
    return { outLabels: [], recLabels: [], otherLabels: fallback };
  }
  return { outLabels, recLabels, otherLabels };
}

/** Full pending fixture labels (no truncation) — used by club.html badges. */
function injuryPendingMatchesHtml(pendingMatches) {
  const { outLabels, recLabels, otherLabels } =
    injuryPendingLabelGroups(pendingMatches);
  const lines = [];
  if (outLabels.length) {
    lines.push(`Out: ${outLabels.join(", ")}`);
  }
  if (recLabels.length) {
    lines.push(`Light training: ${recLabels.join(", ")}`);
  }
  if (otherLabels.length) {
    lines.push(otherLabels.join(", "));
  }
  if (!lines.length) return "";
  return `<br>${lines.join("<br>")}`;
}

function missChip(label) {
  return `<span class="squad-miss-chip">${label}</span>`;
}

function missSectionHtml(phaseClass, head, labels) {
  if (!labels?.length) return "";
  return `<div class="squad-miss-section ${phaseClass}">
    <div class="squad-miss-head">${head}</div>
    <div class="squad-miss-chips">${labels.map(missChip).join("")}</div>
  </div>`;
}

/** Compact horizontal unavailable-match chips for squad Status column. */
function injuryPendingMatchesStatusHtml(pendingMatches) {
  const { outLabels, recLabels, otherLabels } =
    injuryPendingLabelGroups(pendingMatches);
  const parts = [
    missSectionHtml("squad-miss-out", "Unavailable through injury", outLabels),
    missSectionHtml(
      "squad-miss-light",
      "Light training (building fitness, unavailable)",
      recLabels
    ),
    missSectionHtml("squad-miss-other", "Unavailable", otherLabels),
  ].filter(Boolean);
  return parts.join("");
}

function injuryDurationShort(outLeft, recLeft, phase) {
  if (outLeft > 0 || phase === "out") {
    if (recLeft > 0) {
      return `Out ${matchWord(outLeft)} · then ${matchWord(recLeft)} light`;
    }
    return `Out ${matchWord(outLeft)} · then available`;
  }
  return `${matchWord(recLeft)} light training left`;
}

/**
 * Injury type + duration for the Match Fitness column (above the meter).
 * @param {any[]} injuryRows
 */
export function formatInjuryMatchFitnessHtml(injuryRows) {
  if (!injuryRows?.length) return "";
  return injuryRows
    .map((inj) => {
      const label = inj.label || "Injury";
      const outLeft = Number(inj.matches_out_remaining) || 0;
      const recLeft = Number(inj.recovery_remaining) || 0;
      const dur = injuryDurationShort(outLeft, recLeft, inj.phase);
      if (outLeft > 0 || inj.phase === "out") {
        const title = `Injured — ${label} — ${injuryOutPhaseTitle(outLeft, recLeft)}`;
        return `<div class="squad-fit-injury squad-fit-injury-out" title="${title.replace(
          /"/g,
          "&quot;"
        )}">
          <div class="squad-fit-injury-kicker">Injured</div>
          <div class="squad-fit-injury-type">${label}</div>
          <div class="squad-fit-injury-dur">${dur}</div>
        </div>`;
      }
      const title = `Building Fitness & Match sharpness — ${label} — Returning to match availability in ${matchWord(recLeft)}`;
      return `<div class="squad-fit-injury squad-fit-injury-rec" title="${title.replace(
        /"/g,
        "&quot;"
      )}">
        <div class="squad-fit-injury-kicker">Building fitness</div>
        <div class="squad-fit-injury-type">${label}</div>
        <div class="squad-fit-injury-dur">${dur}</div>
      </div>`;
    })
    .join("");
}

function injuryOutPhaseDetail(outLeft, recLeft) {
  const back = `Returning to light training in ${matchWord(outLeft)}`;
  if (recLeft > 0) {
    return `${back}<br>then ${matchWord(recLeft)} of light training before available`;
  }
  return `${back}<br>then available (no light-training matches left)`;
}

function injuryOutPhaseTitle(outLeft, recLeft) {
  const back = `Returning to light training in ${matchWord(outLeft)}`;
  if (recLeft > 0) {
    return `${back}; then ${matchWord(recLeft)} of light training before available`;
  }
  return `${back}; then available`;
}

/**
 * Squad Status column: unavailable fixtures only (injury detail lives in Match Fitness).
 * @param {any[]} injuryRows
 */
export function formatInjuryStatusHtml(injuryRows) {
  if (!injuryRows?.length) return "";
  return injuryRows
    .map((inj) => {
      const matchesHtml = injuryPendingMatchesStatusHtml(inj.pending_matches);
      if (!matchesHtml) return "";
      const label = inj.label || "Injury";
      const outLeft = Number(inj.matches_out_remaining) || 0;
      const recLeft = Number(inj.recovery_remaining) || 0;
      const isOut = outLeft > 0 || inj.phase === "out";
      const title = isOut
        ? `Injured — ${label} — ${injuryOutPhaseTitle(outLeft, recLeft)}`
        : `Building Fitness & Match sharpness — ${label} — Returning to match availability in ${matchWord(recLeft)}`;
      return `<div class="squad-status-lines squad-miss-block" title="${title.replace(
        /"/g,
        "&quot;"
      )}">${matchesHtml}</div>`;
    })
    .join("");
}

/** Compact badge for club.html name cells (multi-line). Includes full miss list. */
export function formatInjuryBadgeHtml(injuryRows) {
  if (!injuryRows?.length) return "";
  return injuryRows
    .map((inj) => {
      const label = inj.label || "Injury";
      const outLeft = Number(inj.matches_out_remaining) || 0;
      const recLeft = Number(inj.recovery_remaining) || 0;
      const pendingText = injuryPendingMatchesHtml(inj.pending_matches);
      if (outLeft > 0 || inj.phase === "out") {
        const detail = injuryOutPhaseDetail(outLeft, recLeft);
        const title = `Injured — ${label} — ${injuryOutPhaseTitle(outLeft, recLeft)}`;
        const body = `Injured<br>${label}<br>${detail}${pendingText}`;
        return `<span class="injury-badge injury-badge-out" title="${title}">${body}</span>`;
      }
      const detail = `Returning to match availability in ${matchWord(recLeft)}`;
      const title = `Building Fitness & Match sharpness — ${label} — ${detail}`;
      const body = `Building Fitness &amp; Match sharpness<br>${label}<br>${detail}${pendingText}`;
      return `<span class="injury-badge injury-badge-recovery" title="${title}">${body}</span>`;
    })
    .join("");
}

function htmlEscapeText(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function htmlEscapeAttr(s) {
  return htmlEscapeText(s).replace(/"/g, "&quot;");
}

/**
 * Compact single-line injury marker for transfer market / listing name cells.
 * Accepts a squad injury row or competition_active_injuries_for_players payload.
 * @param {any} inj
 */
export function formatListingInjuryMarkerHtml(inj) {
  if (!inj) return "";
  const label = inj.label || "Injury";
  const outLeft = Number(inj.matches_out_remaining) || 0;
  const recLeft = Number(inj.recovery_remaining) || 0;
  const isOut = outLeft > 0 || inj.phase === "out";
  const safeLabel = htmlEscapeText(label);
  if (isOut) {
    const title = htmlEscapeAttr(
      `Injured — ${label} — ${injuryOutPhaseTitle(outLeft, recLeft)}`
    );
    const left =
      recLeft > 0 ? `${outLeft} out then ${recLeft} light` : `${outLeft} left`;
    return `<span class="listing-injury listing-injury-out" title="${title}">Injured · ${safeLabel} · ${left}</span>`;
  }
  const title = htmlEscapeAttr(
    `Building Fitness & Match sharpness — ${label} — Returning to match availability in ${matchWord(recLeft)}`
  );
  return `<span class="listing-injury listing-injury-rec" title="${title}">Recovering · ${safeLabel} · ${recLeft} light</span>`;
}

const MATCH_FITNESS_LABELS = {
  1: "Fully Fit",
  2: "Match Ready",
  3: "Managing Load",
  4: "Fitness Concern",
  5: "Injury Risk",
};

/**
 * Compact match-fitness meter for transfer market / listing name cells.
 * @param {{ level?: number, label?: string, consecutive?: number }|null|undefined} fitness
 * @param {any} [injury] optional active injury payload (overrides status label)
 */
export function formatListingMatchFitnessHtml(fitness, injury = null) {
  const level = Math.max(1, Math.min(5, Number(fitness?.level) || 1));
  const baseLabel =
    fitness?.label || MATCH_FITNESS_LABELS[level] || MATCH_FITNESS_LABELS[1];
  let statusLabel = baseLabel;
  let nameMod = "";
  if (injury) {
    const out =
      (Number(injury.matches_out_remaining) || 0) > 0 || injury.phase === "out";
    statusLabel = out ? "Injured" : "Regaining fitness";
    nameMod = out ? " listing-fit-name--injured" : " listing-fit-name--recovery";
  }
  const title = injury
    ? `${statusLabel} · meter ${baseLabel} (level ${level}/5)`
    : `${statusLabel} (level ${level}/5)`;
  const safeTitle = htmlEscapeAttr(title);
  const pips = [1, 2, 3, 4, 5]
    .map(
      (n) =>
        `<span class="listing-fit-pip listing-fit-pip-${n}${
          n === level ? " is-on" : ""
        }" aria-hidden="true"></span>`
    )
    .join("");
  return `<div class="listing-fit listing-fit-l${level}" title="${safeTitle}">
    <div class="listing-fit-meter" role="img" aria-label="${safeTitle}">${pips}</div>
    <div class="listing-fit-name${nameMod}">${htmlEscapeText(statusLabel)}</div>
  </div>`;
}

/**
 * Match fitness map for listings (player_id → { level, label, consecutive }).
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {Array<string|number>} playerIds
 * @returns {Promise<{ byPlayer: Map<string, any>, matchesToMax: number }>}
 */
export async function loadMatchFitnessForPlayers(supabase, playerIds) {
  /** @type {Map<string, any>} */
  const byPlayer = new Map();
  const ids = [
    ...new Set((playerIds || []).map((id) => String(id)).filter(Boolean)),
  ];
  if (!ids.length) return { byPlayer, matchesToMax: 4 };

  const { data, error } = await supabase.rpc(
    "competition_match_fitness_for_players",
    { p_player_ids: ids }
  );
  if (error) {
    if (
      /competition_match_fitness_for_players|schema cache|Could not find/i.test(
        error.message || ""
      )
    ) {
      console.warn(
        "competition_match_fitness_for_players missing — run listing_match_fitness_for_players_20261027.sql"
      );
      return { byPlayer, matchesToMax: 4 };
    }
    console.error("competition_match_fitness_for_players:", error);
    return { byPlayer, matchesToMax: 4 };
  }

  const by =
    data?.by_player && typeof data.by_player === "object" ? data.by_player : {};
  for (const [pid, payload] of Object.entries(by)) {
    if (payload) byPlayer.set(String(pid), payload);
  }
  const matchesToMax = Math.max(1, Number(data?.matches_to_max) || 4);
  return { byPlayer, matchesToMax };
}

/**
 * Compact injury map for transfer listings (player_id → payload).
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {Array<string|number>} playerIds
 * @returns {Promise<Map<string, any>>}
 */
export async function loadActiveInjuriesForPlayers(supabase, playerIds) {
  /** @type {Map<string, any>} */
  const map = new Map();
  const ids = [
    ...new Set((playerIds || []).map((id) => String(id)).filter(Boolean)),
  ];
  if (!ids.length) return map;

  const { data, error } = await supabase.rpc(
    "competition_active_injuries_for_players",
    { p_player_ids: ids }
  );
  if (error) {
    if (
      /competition_active_injuries_for_players|schema cache|Could not find/i.test(
        error.message || ""
      )
    ) {
      console.warn(
        "competition_active_injuries_for_players missing — run transfer_move_injury_fitness_20261027.sql"
      );
      return map;
    }
    console.error("competition_active_injuries_for_players:", error);
    return map;
  }

  if (data && typeof data === "object" && !Array.isArray(data)) {
    for (const [pid, payload] of Object.entries(data)) {
      if (payload) map.set(String(pid), payload);
    }
  }
  return map;
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


