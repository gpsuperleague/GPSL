// Shared competition helpers (Phase 0+)

export const DIVISION_LABELS = {
  unassigned: "Unassigned",
  superleague: "SuperLeague",
  championship_pool: "Championship (pool)",
  championship_a: "Championship A",
  championship_b: "Championship B",
};

export const SETUP_DIVISION_OPTIONS = [
  { value: "unassigned", label: "Unassigned" },
  { value: "superleague", label: "SuperLeague" },
  { value: "championship_pool", label: "Championship pool" },
];

export const ACTIVE_DIVISIONS = [
  "superleague",
  "championship_a",
  "championship_b",
];

export const LEAGUE_DIVISIONS = ACTIVE_DIVISIONS;

export const GPSL_MONTH_LABELS = {
  august: "August",
  september: "September",
  october: "October",
  november: "November",
  december: "December",
  january: "January",
  february: "February",
  march: "March",
  april: "April",
  may: "May",
};

export const GPSL_MONTH_ORDER = [
  "august",
  "september",
  "october",
  "november",
  "december",
  "january",
  "february",
  "march",
  "april",
  "may",
];

export async function loadCurrentSeason(supabase) {
  const { data, error } = await supabase
    .from("competition_season_public")
    .select("*")
    .eq("is_current", true)
    .maybeSingle();

  if (error) {
    console.error("loadCurrentSeason:", error);
    return null;
  }
  return data;
}

export async function loadActiveSeasonRegistrations(supabase) {
  const { data, error } = await supabase
    .from("competition_club_season_public")
    .select("*")
    .order("club_name", { ascending: true });

  if (error) {
    console.error("loadActiveSeasonRegistrations:", error);
    return [];
  }
  return data || [];
}

export async function loadSeasonRegistrations(supabase, seasonId) {
  const { data, error } = await supabase
    .from("competition_club_seasons")
    .select("club_short_name, division, league_position, Clubs(Club)")
    .eq("season_id", seasonId)
    .order("club_short_name", { ascending: true });

  if (error) {
    console.error("loadSeasonRegistrations:", error);
    return [];
  }

  return (data || []).map((row) => ({
    club_short_name: row.club_short_name,
    club_name: row.Clubs?.Club || row.club_short_name,
    division: row.division,
    league_position: row.league_position,
  }));
}

export async function loadSetupSeasons(supabase) {
  const { data, error } = await supabase
    .from("competition_seasons")
    .select("*")
    .eq("status", "setup")
    .order("created_at", { ascending: false });

  if (error) {
    console.error("loadSetupSeasons:", error);
    return [];
  }
  return data || [];
}

export function groupByDivision(registrations) {
  const groups = {
    superleague: [],
    championship_a: [],
    championship_b: [],
    championship_pool: [],
    unassigned: [],
  };

  for (const row of registrations) {
    const bucket = groups[row.division];
    if (bucket) bucket.push(row);
  }

  for (const key of Object.keys(groups)) {
    groups[key].sort((a, b) =>
      (a.club_name || a.club_short_name).localeCompare(
        b.club_name || b.club_short_name
      )
    );
  }

  return groups;
}

export function countSetupDivisions(registrations) {
  const counts = {
    unassigned: 0,
    superleague: 0,
    championship_pool: 0,
    championship_a: 0,
    championship_b: 0,
  };

  for (const row of registrations) {
    if (counts[row.division] !== undefined) counts[row.division] += 1;
  }

  return counts;
}

export function canDrawChampionshipAb(counts) {
  return counts.superleague === 20 && counts.championship_pool === 40;
}

export function canActivateSeason(counts) {
  return (
    counts.superleague === 20 &&
    counts.championship_a === 20 &&
    counts.championship_b === 20 &&
    counts.unassigned === 0 &&
    counts.championship_pool === 0
  );
}

export function divisionForClub(registrations, clubShortName) {
  const row = registrations.find((r) => r.club_short_name === clubShortName);
  return row ? DIVISION_LABELS[row.division] || row.division : null;
}

/** Trim + uppercase for reliable ShortName comparisons. */
export function normalizeClubKey(value) {
  if (value == null || value === "") return "";
  return String(value).trim().toUpperCase();
}

/**
 * Load all league fixtures (paginated — Supabase default cap is 1000 rows).
 * Pass division to load one league only (380 rows).
 */
export async function loadLeagueFixtures(supabase, division = null) {
  const pageSize = 1000;
  const all = [];
  let from = 0;

  while (true) {
    let query = supabase
      .from("competition_fixtures_public")
      .select("*")
      .order("matchday", { ascending: true })
      .order("id", { ascending: true })
      .range(from, from + pageSize - 1);

    if (division) query = query.eq("division", division);

    const { data, error } = await query;
    if (error) {
      console.error("loadLeagueFixtures:", error);
      break;
    }

    const batch = data || [];
    all.push(...batch);
    if (batch.length < pageSize) break;
    from += pageSize;
  }

  all.sort((a, b) => {
    if (a.matchday !== b.matchday) return a.matchday - b.matchday;
    return (a.home_club_name || "").localeCompare(b.home_club_name || "");
  });
  return all;
}

export async function loadFixtureCountsForSeason(supabase, seasonId) {
  const { data, error } = await supabase
    .from("competition_fixtures")
    .select("division")
    .eq("season_id", seasonId)
    .eq("competition_type", "league");

  if (error) {
    console.error("loadFixtureCountsForSeason:", error);
    return {};
  }

  const counts = {};
  for (const div of LEAGUE_DIVISIONS) counts[div] = 0;
  for (const row of data || []) {
    counts[row.division] = (counts[row.division] || 0) + 1;
  }
  return counts;
}

export function clubsInDivision(registrations, division) {
  return registrations
    .filter((r) => r.division === division)
    .sort((a, b) =>
      (a.club_name || a.club_short_name).localeCompare(
        b.club_name || b.club_short_name
      )
    );
}

export function slotsFromRegistrations(registrations, division) {
  const clubs = clubsInDivision(registrations, division);
  const byPos = new Map();
  for (const row of clubs) {
    if (row.league_position) byPos.set(row.league_position, row);
  }

  const slots = [];
  for (let pos = 1; pos <= 20; pos += 1) {
    const row = byPos.get(pos);
    slots.push({
      position: pos,
      club_short_name: row?.club_short_name || "",
      club_name: row?.club_name || "",
    });
  }
  return slots;
}

export function groupFixturesByMatchday(fixtures) {
  const map = new Map();
  for (const f of fixtures) {
    if (!map.has(f.matchday)) map.set(f.matchday, []);
    map.get(f.matchday).push(f);
  }
  return [...map.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([matchday, rows]) => ({ matchday, fixtures: rows }));
}

export function formatFixtureScore(f) {
  if (f.status === "played" && f.home_goals != null && f.away_goals != null) {
    return `${f.home_goals} – ${f.away_goals}`;
  }
  if (f.submission_status === "pending" && f.proposed_home_goals != null) {
    return `${f.proposed_home_goals} – ${f.proposed_away_goals}?`;
  }
  return "vs";
}

/**
 * @param {object|string} clubIdentity — ShortName string or { short, name }
 */
export function fixtureInvolvesClub(f, clubIdentity) {
  if (!clubIdentity || !f) return false;

  const short =
    typeof clubIdentity === "string"
      ? normalizeClubKey(clubIdentity)
      : normalizeClubKey(clubIdentity.short);
  const fullName =
    typeof clubIdentity === "string"
      ? ""
      : (clubIdentity.name || "").trim();

  const homeS = normalizeClubKey(f.home_club_short_name);
  const awayS = normalizeClubKey(f.away_club_short_name);
  if (short && (homeS === short || awayS === short)) return true;

  if (fullName) {
    const homeN = (f.home_club_name || "").trim();
    const awayN = (f.away_club_name || "").trim();
    if (homeN === fullName || awayN === fullName) return true;
    const key = fullName.toLowerCase();
    if (
      homeN.toLowerCase() === key ||
      awayN.toLowerCase() === key
    ) {
      return true;
    }
  }

  return false;
}

export async function submitFixtureResult(
  supabase,
  fixtureId,
  homeGoals,
  awayGoals,
  playerStats = []
) {
  return supabase.rpc("competition_submit_result", {
    p_fixture_id: fixtureId,
    p_home_goals: homeGoals,
    p_away_goals: awayGoals,
    p_player_stats: playerStats,
  });
}

export async function loadPlayerSeasonStats(supabase, division = null) {
  let query = supabase
    .from("competition_player_season_stats_public")
    .select("*")
    .order("goals", { ascending: false })
    .order("assists", { ascending: false });

  if (division) query = query.eq("division", division);

  const { data, error } = await query;
  if (error) {
    console.error("loadPlayerSeasonStats:", error);
    return [];
  }
  return data || [];
}

export function statsMapByPlayerId(rows) {
  const map = new Map();
  for (const row of rows || []) {
    map.set(String(row.player_id), row);
  }
  return map;
}

export async function confirmFixtureResult(supabase, submissionId) {
  return supabase.rpc("competition_confirm_result", {
    p_submission_id: submissionId,
  });
}

export async function rejectFixtureResult(supabase, submissionId, reason = null) {
  return supabase.rpc("competition_reject_result", {
    p_submission_id: submissionId,
    p_reason: reason,
  });
}

export function canSubmitResult(fixture, clubIdentity) {
  if (!fixture || !clubIdentity) return false;
  return (
    fixtureInvolvesClub(fixture, clubIdentity) &&
    fixture.status === "scheduled" &&
    !fixture.submission_id
  );
}

export function needsInboxConfirm(fixture, clubIdentity) {
  if (!fixture || !clubIdentity) return false;
  const me =
    typeof clubIdentity === "string"
      ? normalizeClubKey(clubIdentity)
      : normalizeClubKey(clubIdentity.short);
  return (
    fixture.submission_status === "pending" &&
    fixture.submitted_by_club &&
    normalizeClubKey(fixture.submitted_by_club) !== me
  );
}

export async function loadStandings(supabase, division = null) {
  let query = supabase
    .from("competition_standings_public")
    .select("*")
    .order("table_position", { ascending: true });

  if (division) query = query.eq("division", division);

  const { data, error } = await query;
  if (error) {
    console.error("loadStandings:", error);
    return [];
  }
  return data || [];
}

/** Zone labels for table position (may overlap, e.g. CH 3–4 = Plate + Playoffs). */
export function zonesForPosition(division, position) {
  if (division === "superleague") {
    const tags = [];
    if (position <= 8) tags.push("Super8");
    if (position >= 9 && position <= 16) tags.push("Plate");
    if (position >= 16 && position <= 17) tags.push("SL playoff");
    if (position >= 18) tags.push("Relegation");
    return tags;
  }

  const tags = [];
  if (position <= 2) tags.push("Promotion");
  if (position >= 3 && position <= 6) tags.push("Playoffs");
  if (position <= 4) tags.push("Plate");
  if (position >= 5 && position <= 15) tags.push("Shield");
  if (position >= 16 && position <= 17) tags.push("Shield/Spoon PO");
  if (position >= 18) tags.push("Spoon");
  return tags;
}

/** Primary row accent for progress table styling. */
export function primaryZoneKey(division, position) {
  if (division === "superleague") {
    if (position >= 18) return "relegation";
    if (position >= 16) return "playoff";
    if (position >= 9) return "plate";
    return "super8";
  }
  if (position >= 18) return "spoon";
  if (position >= 16) return "playoff";
  if (position >= 5) return "shield";
  if (position >= 3) return "playoffs";
  if (position <= 2) return "promotion";
  return "plate";
}

export function formatFormHtml(formStr) {
  if (!formStr) return "—";
  return [...formStr]
    .map((ch) => `<span class="form-${ch.toLowerCase()}">${ch}</span>`)
    .join("");
}

export function groupStandingsByDivision(rows) {
  const groups = {};
  for (const div of LEAGUE_DIVISIONS) groups[div] = [];
  for (const row of rows) {
    if (groups[row.division]) groups[row.division].push(row);
  }
  return groups;
}
