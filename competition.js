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
