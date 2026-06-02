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

export async function loadLeagueFixtures(supabase, division = null) {
  let query = supabase
    .from("competition_fixtures_public")
    .select("*")
    .order("matchday", { ascending: true })
    .order("home_club_name", { ascending: true });

  if (division) query = query.eq("division", division);

  const { data, error } = await query;
  if (error) {
    console.error("loadLeagueFixtures:", error);
    return [];
  }
  return data || [];
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
  return "vs";
}

export function fixtureInvolvesClub(f, clubShort) {
  if (!clubShort) return false;
  return (
    f.home_club_short_name === clubShort ||
    f.away_club_short_name === clubShort
  );
}
