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

export const CUP_CODES = [
  "super8",
  "plate",
  "shield",
  "bowl",
  "league_cup",
  "po_sl_1617",
  "po_ch_a",
  "po_ch_b",
  "po_ch_sb_a",
  "po_ch_sb_b",
  "po_ch_final",
  "po_sl_final",
];

export const CUP_LABELS = {
  super8: "Super8",
  plate: "Plate",
  shield: "Shield",
  bowl: "Bowl",
  league_cup: "League Cup",
  po_sl_1617: "SL playoff 16v17",
  po_ch_a: "CH A promotion playoff",
  po_ch_b: "CH B promotion playoff",
  po_ch_sb_a: "CH A Shield/Bowl playoff",
  po_ch_sb_b: "CH B Shield/Bowl playoff",
  po_ch_final: "Championships playoff final",
  po_sl_final: "SuperLeague playoff final",
};

/** Pastel bar colours — matched to GPSL cup nav (Bowl gold · Shield green · Plate orange · Super8 navy). */
export const PRESTIGE_CUP_BAR_COLORS = {
  super8: "#5a7db5",
  plate: "#c98652",
  shield: "#6d9f7a",
  bowl: "#c9a84c",
};

/** Pastel legend chips for league outcome row tints. */
export const LEAGUE_TINT_LEGEND_COLORS = {
  champion: "#c9a84c",
  runner_up: "#9ca3b8",
  promotion: "#6d9f7a",
  playoffs: "#9b87b8",
  playoff: "#c98652",
  relegation: "#b86a6a",
};

export const GPSL_MONTH_LABELS = {
  june: "June",
  july: "July",
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
  playoffs: "Playoffs",
};

export const GPSL_MONTH_ORDER = [
  "june",
  "july",
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
  "playoffs",
];

/** Human-readable competition name for a fixture (league division or cup). */
export function formatFixtureCompetition(f) {
  if (!f) return "";
  if (f.competition_type === "cup" || f.cup_code) {
    return CUP_LABELS[f.cup_code] || f.cup_code || "Cup";
  }
  if (f.division) {
    return DIVISION_LABELS[f.division] || f.division;
  }
  return "League";
}

/** e.g. "Championship A · Arsenal vs Chelsea" */
export function formatFixtureCompetitionLine(f) {
  const comp = formatFixtureCompetition(f);
  const home = f.home_club_name || f.home_club_short_name || "Home";
  const away = f.away_club_name || f.away_club_short_name || "Away";
  return `${comp} · ${home} vs ${away}`;
}

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
    .in("status", ["setup", "preseason"])
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

export function divisionSlugForClub(registrations, clubShortName) {
  const key = normalizeClubKey(clubShortName);
  const row = registrations.find(
    (r) => normalizeClubKey(r.club_short_name) === key
  );
  return row?.division || null;
}

export function divisionForClub(registrations, clubShortName) {
  const slug = divisionSlugForClub(registrations, clubShortName);
  return slug ? DIVISION_LABELS[slug] || slug : null;
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

/** All cup fixtures for current season (optional cup_code filter). */
export async function loadCupFixtures(supabase, cupCode = null) {
  let query = supabase
    .from("competition_fixtures_public")
    .select("*")
    .eq("competition_type", "cup")
    .order("cup_code", { ascending: true })
    .order("cup_round", { ascending: true })
    .order("cup_match", { ascending: true });

  if (cupCode) query = query.eq("cup_code", cupCode);

  const { data, error } = await query;
  if (error) {
    console.error("loadCupFixtures:", error);
    return [];
  }
  return data || [];
}

export async function loadCupBracket(supabase, cupCode) {
  const { data, error } = await supabase
    .from("competition_cup_bracket_public")
    .select("*")
    .eq("cup_code", cupCode)
    .order("round_no", { ascending: true })
    .order("match_no", { ascending: true })
    .order("cup_leg", { ascending: true });

  if (error) {
    console.error("loadCupBracket:", error);
    return [];
  }
  return data || [];
}

export async function loadCupQualified(supabase, cupCode) {
  const { data, error } = await supabase
    .from("competition_cup_qualified_public")
    .select("club_short_name")
    .eq("cup_code", cupCode);

  if (error) {
    console.error("loadCupQualified:", error);
    return [];
  }
  return (data || []).map((r) => r.club_short_name);
}

export function groupCupBracketByRound(nodes) {
  const map = new Map();
  for (const n of nodes || []) {
    if (!map.has(n.round_no)) map.set(n.round_no, []);
    map.get(n.round_no).push(n);
  }
  return [...map.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([round_no, matches]) => ({
      round_no,
      matches: matches.sort((a, b) => {
        const ma = a.match_no || 0;
        const mb = b.match_no || 0;
        if (ma !== mb) return ma - mb;
        return (a.cup_leg || 1) - (b.cup_leg || 1);
      }),
    }));
}

/** Ties in a bracket round (leg 1 + leg 2 share the same match_no). */
export function cupRoundTieCount(matches) {
  return new Set((matches || []).map((m) => m.match_no)).size;
}

/** Super8 & Bowl QF: one round, two legs (Sep + Oct). */
export function isTwoLegCupQuarterFinal(cupCode, roundNo) {
  return (cupCode === "super8" || cupCode === "bowl") && roundNo === 1;
}

/** Placeholder leg-2 node when bracket data predates the two-leg schedule. */
export function syntheticCupLeg2Node(leg1) {
  if (!leg1) return null;
  return {
    ...leg1,
    id: null,
    cup_leg: 2,
    leg1_node_id: leg1.id,
    fixture_id: null,
    fixture_status: null,
    home_goals: null,
    away_goals: null,
    winner_club_short_name: null,
    winner_club_name: null,
    home_club_short_name: leg1.away_club_short_name,
    home_club_name: leg1.away_club_name,
    away_club_short_name: leg1.home_club_short_name,
    away_club_name: leg1.home_club_name,
    round_gpsl_month: "october",
    fixture_gpsl_month: "october",
  };
}

/** Pull mis-placed leg-2 QF nodes (old schedule used round_no 2) into round 1. */
export function preprocessCupBracketRounds(nodes, cupCode) {
  let rounds = groupCupBracketByRound(nodes);

  if (cupCode === "league_cup") {
    const firstRoundNo = rounds[0]?.round_no ?? 1;
    rounds = rounds
      .map((round) => ({
        ...round,
        matches:
          round.round_no === firstRoundNo
            ? round.matches.filter(
                (m) =>
                  m.home_club_short_name ||
                  m.away_club_short_name ||
                  m.winner_club_short_name ||
                  m.fixture_id
              )
            : round.matches,
      }))
      .filter((round) => round.matches.length > 0);
  }

  if (cupCode !== "super8" && cupCode !== "bowl") return rounds;

  const orphanLeg2 = [];
  const out = [];

  for (const round of rounds) {
    const orphans = round.matches.filter(
      (m) => round.round_no !== 1 && m.leg1_node_id
    );
    const keep = round.matches.filter((m) => !orphans.includes(m));
    orphanLeg2.push(...orphans);
    if (keep.length) out.push({ ...round, matches: keep });
  }

  if (!orphanLeg2.length) return out.length ? out : rounds;

  let qf = out.find((r) => r.round_no === 1);
  if (!qf) {
    qf = { round_no: 1, matches: [] };
    out.unshift(qf);
  }
  qf.matches = [...qf.matches, ...orphanLeg2];
  return out.sort((a, b) => a.round_no - b.round_no);
}

/** Group bracket nodes into ties (leg1 + leg2) for two-legged QF. */
export function groupCupBracketTies(matches, cupCode, roundNo) {
  const rows = matches || [];
  if (!isTwoLegCupQuarterFinal(cupCode, roundNo)) {
    return rows.map((m) => ({
      match_no: m.match_no,
      leg1: m,
      leg2: null,
      twoLeg: false,
    }));
  }

  const leg1Nodes = rows.filter(
    (m) => !m.leg1_node_id && (m.cup_leg || 1) === 1
  );
  const leg2Nodes = rows.filter((m) => m.leg1_node_id || (m.cup_leg || 1) === 2);
  const leg2ByLeg1Id = new Map(
    leg2Nodes.filter((m) => m.leg1_node_id).map((m) => [m.leg1_node_id, m])
  );
  const leg2ByMatchNo = new Map(leg2Nodes.map((m) => [m.match_no, m]));

  const matchNos = [...new Set(rows.map((m) => m.match_no))].sort(
    (a, b) => a - b
  );

  return matchNos.map((matchNo) => {
    const leg1 =
      leg1Nodes.find((m) => m.match_no === matchNo) ||
      rows.find((m) => m.match_no === matchNo && !m.leg1_node_id);
    let leg2 = leg1
      ? leg2ByLeg1Id.get(leg1.id) || leg2ByMatchNo.get(matchNo)
      : null;
    if (!leg2 && leg1) leg2 = syntheticCupLeg2Node(leg1);
    return { match_no: matchNo, leg1, leg2, twoLeg: true };
  });
}

function cupLegGoals(node, extras) {
  if (!node || node.fixture_status !== "played") return null;
  const fid = Number(node.fixture_id);
  if (!fid) return null;
  const sub = extras?.submissionsByFixture?.get(fid);
  const fix = extras?.fixturesById?.get(fid);
  const home = sub?.home_goals ?? node.home_goals ?? fix?.home_goals;
  const away = sub?.away_goals ?? node.away_goals ?? fix?.away_goals;
  if (home == null || away == null) return null;
  return { home: Number(home), away: Number(away) };
}

/** Aggregate score for a two-legged tie (leg1 home club = tie "home"). */
export function cupTwoLegAggregate(leg1, leg2, extras) {
  if (!leg1) return null;
  const g1 = cupLegGoals(leg1, extras);
  const g2 = leg2 ? cupLegGoals(leg2, extras) : null;
  if (!g1 && !g2) return null;

  const homeAgg = (g1?.home ?? 0) + (g2?.away ?? 0);
  const awayAgg = (g1?.away ?? 0) + (g2?.home ?? 0);
  const tieHome = leg1.home_club_short_name;
  const tieAway = leg1.away_club_short_name;

  let winnerKey = null;
  let winnerName = null;
  if (g1 && g2) {
    if (homeAgg > awayAgg) {
      winnerKey = tieHome;
      winnerName = leg1.home_club_name || tieHome;
    } else if (awayAgg > homeAgg) {
      winnerKey = tieAway;
      winnerName = leg1.away_club_name || tieAway;
    }
  } else if (leg2?.winner_club_name) {
    winnerName = leg2.winner_club_name;
    winnerKey = leg2.winner_club_short_name;
  }

  return {
    homeClub: leg1.home_club_name || tieHome || "TBD",
    awayClub: leg1.away_club_name || tieAway || "TBD",
    homeAgg,
    awayAgg,
    leg1Played: !!g1,
    leg2Played: !!g2,
    complete: !!g1 && !!g2,
    winnerKey,
    winnerName,
  };
}

/** Knockout round name from teams still in the competition (2 × ties in that round). */
export function cupRoundLabel(matchCount) {
  const teams = (Number(matchCount) || 0) * 2;
  if (teams === 2) return "Final";
  if (teams === 4) return "Semi-final";
  if (teams === 8) return "Quarter-final";
  if (teams === 16) return "Last 16";
  if (teams === 32) return "Round of 32";
  if (teams === 64) return "Round of 64";
  if (teams > 0) return `Round of ${teams}`;
  return "Round";
}

/** Confirmed scores + gate/prize lines for cup bracket cards. */
export async function loadCupMatchExtras(supabase, fixtureIds) {
  const ids = [...new Set((fixtureIds || []).map((id) => Number(id)).filter(Boolean))];
  const empty = {
    submissionsByFixture: new Map(),
    financeByFixture: new Map(),
    fixturesById: new Map(),
  };
  if (!ids.length) return empty;

  const [subsRes, ledgerRes, fixRes] = await Promise.all([
    supabase
      .from("competition_result_submissions")
      .select(
        "fixture_id, home_goals, away_goals, et_home_goals, et_away_goals, pen_winner_club_short_name"
      )
      .in("fixture_id", ids)
      .eq("status", "confirmed"),
    supabase
      .from("competition_finance_ledger_public")
      .select("fixture_id, club_short_name, club_name, entry_type, amount, description")
      .in("fixture_id", ids)
      .in("entry_type", ["gate_cup_share", "prize", "prize_cup", "tv_revenue"]),
    supabase
      .from("competition_fixtures")
      .select("id, cup_pen_winner_club_short_name, home_goals, away_goals, home_club_short_name, away_club_short_name")
      .in("id", ids),
  ]);

  if (subsRes.error) console.error("loadCupMatchExtras submissions:", subsRes.error);
  if (ledgerRes.error) console.error("loadCupMatchExtras ledger:", ledgerRes.error);
  if (fixRes.error) console.error("loadCupMatchExtras fixtures:", fixRes.error);

  const submissionsByFixture = new Map();
  for (const row of subsRes.data || []) {
    submissionsByFixture.set(Number(row.fixture_id), row);
  }

  const financeByFixture = new Map();
  for (const row of ledgerRes.data || []) {
    const fid = Number(row.fixture_id);
    if (!financeByFixture.has(fid)) financeByFixture.set(fid, []);
    financeByFixture.get(fid).push(row);
  }

  const fixturesById = new Map();
  for (const row of fixRes.data || []) {
    fixturesById.set(Number(row.id), row);
  }

  return { submissionsByFixture, financeByFixture, fixturesById };
}

export function formatCupScoreLines(match, extras) {
  const fid = Number(match.fixture_id);
  if (!fid || match.fixture_status !== "played") return null;

  const sub = extras?.submissionsByFixture?.get(fid);
  const fix = extras?.fixturesById?.get(fid);
  const penClub =
    sub?.pen_winner_club_short_name || fix?.cup_pen_winner_club_short_name || null;

  const home90 = sub?.home_goals ?? match.home_goals;
  const away90 = sub?.away_goals ?? match.away_goals;
  const hasEt = sub?.et_home_goals != null && sub?.et_away_goals != null;

  const lines = [];
  if (home90 != null && away90 != null) {
    lines.push({ label: "90 min", text: `${home90}–${away90}` });
  }
  if (hasEt) {
    lines.push({
      label: "After ET",
      text: `${sub.et_home_goals}–${sub.et_away_goals}`,
    });
  }
  if (penClub) {
    let penName = penClub;
    if (normalizeClubKey(penClub) === normalizeClubKey(match.home_club_short_name)) {
      penName = match.home_club_name || penClub;
    } else if (normalizeClubKey(penClub) === normalizeClubKey(match.away_club_short_name)) {
      penName = match.away_club_name || penClub;
    }
    lines.push({ label: "Pens", text: `${penName} won` });
  } else if (match.winner_club_name && !hasEt) {
    lines.push({ label: "Winner", text: match.winner_club_name });
  } else if (match.winner_club_name && hasEt) {
    const etH = Number(sub.et_home_goals);
    const etA = Number(sub.et_away_goals);
    if (etH !== etA) {
      lines.push({ label: "Winner", text: match.winner_club_name });
    }
  }

  return lines.length ? lines : null;
}

export function formatCupMatchFinance(match, extras) {
  const fid = Number(match.fixture_id);
  const rows = extras?.financeByFixture?.get(fid) || [];
  if (!rows.length) return [];

  const byClub = new Map();
  for (const row of rows) {
    const key = row.club_short_name;
    if (!byClub.has(key)) {
      byClub.set(key, { club: row.club_name || key, gate: 0, prize: 0, tv: 0 });
    }
    const bucket = byClub.get(key);
    const amt = Number(row.amount) || 0;
    if (row.entry_type === "gate_cup_share") bucket.gate += amt;
    else if (row.entry_type === "prize" || row.entry_type === "prize_cup") bucket.prize += amt;
    else if (row.entry_type === "tv_revenue") bucket.tv += amt;
  }

  return [...byClub.values()].filter((c) => c.gate > 0 || c.prize > 0 || c.tv > 0);
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

export function formatFixtureScore(f, clubIdentity = null) {
  if (f.status === "played" && f.home_goals != null && f.away_goals != null) {
    return `${f.home_goals} – ${f.away_goals}`;
  }
  if (
    f.submission_status === "pending" &&
    f.proposed_home_goals != null &&
    (!clubIdentity || fixtureInvolvesClub(f, clubIdentity))
  ) {
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
  playerStats = [],
  cupExtra = null
) {
  // Always pass cup ET/pen args (null for league / score-only) so PostgREST picks the
  // single 7-arg RPC, not the legacy 4-arg overload.
  return supabase.rpc("competition_submit_result", {
    p_fixture_id: fixtureId,
    p_home_goals: homeGoals,
    p_away_goals: awayGoals,
    p_player_stats: playerStats ?? [],
    p_et_home_goals: cupExtra?.etHome ?? null,
    p_et_away_goals: cupExtra?.etAway ?? null,
    p_pen_winner_club: cupExtra?.penWinner ?? null,
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

export async function loadPlayerCupStats(supabase, cupCode = null) {
  let query = supabase.from("competition_player_cup_stats_public").select("*");

  if (cupCode) query = query.eq("cup_code", cupCode);

  const { data, error } = await query;
  if (error) {
    console.error("loadPlayerCupStats:", error);
    return [];
  }
  return data || [];
}

export async function loadInternationalPlayerStats(supabase) {
  const { data, error } = await supabase
    .from("international_player_career_public")
    .select("*")
    .order("goals", { ascending: false });

  if (error) {
    console.error("loadInternationalPlayerStats:", error);
    return [];
  }
  return data || [];
}

/** Squad page: only stats for these Konami IDs at one club (fast). */
export async function loadPlayerSeasonStatsForSquad(
  supabase,
  playerIds,
  clubShortName
) {
  const ids = (playerIds || []).map((id) => String(id)).filter(Boolean);
  if (!ids.length || !clubShortName) return [];

  const { data, error } = await supabase
    .from("competition_player_season_stats_public")
    .select("*")
    .eq("club_short_name", clubShortName)
    .in("player_id", ids);

  if (error) {
    console.error("loadPlayerSeasonStatsForSquad:", error);
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

/** Pending result row for opponent confirm UI (full ET / pen fields). */
export async function loadPendingSubmission(supabase, submissionId) {
  if (!submissionId) return null;

  const { data, error } = await supabase
    .from("competition_result_submissions")
    .select(
      "id, fixture_id, home_goals, away_goals, et_home_goals, et_away_goals, pen_winner_club_short_name, submitted_by_club, status"
    )
    .eq("id", submissionId)
    .eq("status", "pending")
    .maybeSingle();

  if (error) {
    console.error("loadPendingSubmission:", error);
    return null;
  }
  return data;
}

export async function confirmFixtureResult(
  supabase,
  submissionId,
  playerStats = []
) {
  return supabase.rpc("competition_confirm_result", {
    p_submission_id: submissionId,
    p_confirmer_player_stats: playerStats,
  });
}

export async function rejectFixtureResult(supabase, submissionId, reason = null) {
  return supabase.rpc("competition_reject_result", {
    p_submission_id: submissionId,
    p_reason: reason,
  });
}

/**
 * @param {object} fixture
 * @param {string|{ short?: string }} clubIdentity
 * @param {{ calendar_configured?: boolean, active_gpsl_month?: string|null }|null} [calendarStatus]
 * @param {{ holidays?: object[], calendarMonths?: object[] }|null} [holidayContext]
 */
export function canSubmitResult(
  fixture,
  clubIdentity,
  calendarStatus = null,
  holidayContext = null
) {
  if (!fixture || !clubIdentity) return false;
  if (!fixtureInvolvesClub(fixture, clubIdentity)) return false;
  if (fixture.status !== "scheduled" || fixture.submission_id) return false;

  if (calendarStatus?.calendar_configured) {
    const active = calendarStatus.active_gpsl_month;
    const inActiveMonth =
      active &&
      String(fixture.gpsl_month || "").toLowerCase() ===
        String(active).toLowerCase();
    const catchUp = fixture.is_catch_up === true;

    if (
      !inActiveMonth &&
      !catchUp &&
      !isFixtureHolidayPlayable(fixture, clubIdentity, holidayContext)
    ) {
      return false;
    }

    if (catchUp && !active) {
      return false;
    }
  }

  if (
    fixture.schedule_status != null &&
    fixture.schedule_status !== "agreed"
  ) {
    return false;
  }

  if (fixture.schedule_status === "agreed") {
    const kickoff = fixture.agreed_kickoff_at
      ? new Date(fixture.agreed_kickoff_at).getTime()
      : NaN;
    const now = Date.now();
    const blockEnd = kickoff + 30 * 60 * 1000;
    if (!Number.isFinite(kickoff) || now < kickoff || now >= blockEnd) {
      return false;
    }
    if (!fixture.home_checked_in || !fixture.away_checked_in) {
      return false;
    }
  }

  return true;
}

function rangesOverlap(aStart, aEnd, bStart, bEnd) {
  return aStart < bEnd && bStart < aEnd;
}

export function isFixtureHolidayPlayable(fixture, clubIdentity, ctx) {
  if (!ctx?.holidays?.length || !ctx?.calendarMonths?.length) return false;

  const monthRow = ctx.calendarMonths.find(
    (m) =>
      String(m.gpsl_month || "").toLowerCase() ===
      String(fixture.gpsl_month || "").toLowerCase()
  );
  if (!monthRow?.unlock_at || !monthRow?.lock_at) return false;

  const now = Date.now();
  const unlock = new Date(monthRow.unlock_at).getTime();
  const lock = new Date(monthRow.lock_at).getTime();

  if (now >= lock) return false;
  if (now >= unlock && now < lock) return false;

  const me =
    typeof clubIdentity === "string"
      ? normalizeClubKey(clubIdentity)
      : normalizeClubKey(clubIdentity.short);

  for (const h of ctx.holidays) {
    if (normalizeClubKey(h.club_short_name) !== me) continue;

    const hStart = new Date(h.starts_at).getTime();
    const hEnd = new Date(h.ends_at).getTime();
    const bookStart = new Date(h.created_at).getTime();

    if (now < bookStart || now >= hEnd) continue;
    if (!rangesOverlap(hStart, hEnd, unlock, lock)) continue;

    return true;
  }

  return false;
}

export function needsInboxConfirm(fixture, clubIdentity) {
  if (!fixture || !clubIdentity) return false;
  if (!fixtureInvolvesClub(fixture, clubIdentity)) return false;
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

/** Standings with league_prize_amount + league_prize_paid (requires competition_league_prizes.sql). */
export async function loadStandingsWithPrizes(supabase, division = null) {
  let query = supabase
    .from("competition_standings_prizes_public")
    .select("*")
    .order("table_position", { ascending: true });

  if (division) query = query.eq("division", division);

  const { data, error } = await query;
  if (error) {
    console.error("loadStandingsWithPrizes:", error);
    return loadStandings(supabase, division);
  }
  return data || [];
}

/** Prestige cup qualification from final league position. */
export function prestigeCupForPosition(division, position) {
  if (division === "superleague") {
    if (position <= 8) return "Super8";
    if (position <= 16) return "Plate";
    if (position <= 20) return "Shield";
    return null;
  }
  if (position <= 4) return "Plate";
  if (position >= 5 && position <= 15) return "Shield";
  if (position >= 18) return "Bowl";
  return null;
}

const CH_PLAYOFF_DIVISIONS = ["championship_a", "championship_b"];

/** CH 16v17 Shield/Bowl playoff results saved in admin (per division). */
export function parseShieldSpoonPlayoffQualifiers(rows) {
  const map = {
    championship_a: {},
    championship_b: {},
  };
  for (const row of rows || []) {
    if (!map[row.division]) continue;
    if (row.cup_code === "shield") map[row.division].shield = row.club_short_name;
    if (row.cup_code === "bowl") map[row.division].bowl = row.club_short_name;
  }
  return map;
}

export async function loadShieldSpoonPlayoffQualifiers(supabase, seasonId) {
  const empty = parseShieldSpoonPlayoffQualifiers([]);
  if (!seasonId) return empty;

  const { data, error } = await supabase
    .from("competition_cup_manual_qualifiers")
    .select("division, cup_code, club_short_name")
    .eq("season_id", seasonId)
    .in("division", CH_PLAYOFF_DIVISIONS)
    .in("cup_code", ["shield", "bowl"]);

  if (error) {
    console.error("loadShieldSpoonPlayoffQualifiers:", error);
    return empty;
  }
  return parseShieldSpoonPlayoffQualifiers(data);
}

/** Prestige cup for one club — uses CH 16v17 playoff result when table position alone is ambiguous. */
export function prestigeCupForStanding(
  division,
  position,
  clubShortName,
  playoffQualifiers = null
) {
  const fromTable = prestigeCupForPosition(division, position);
  if (fromTable) return fromTable;

  if (
    !CH_PLAYOFF_DIVISIONS.includes(division) ||
    (position !== 16 && position !== 17)
  ) {
    return null;
  }

  const divQ = playoffQualifiers?.[division];
  if (!divQ) return null;

  const me = normalizeClubKey(clubShortName);
  if (divQ.shield && normalizeClubKey(divQ.shield) === me) return "Shield";
  if (divQ.bowl && normalizeClubKey(divQ.bowl) === me) return "Bowl";
  return null;
}

/**
 * Status column: Champion (1st) · prestige cup · league movement.
 * SuperLeague places 17–20 qualify for Shield.
 */
export function statusForPosition(division, position) {
  return statusForStanding(division, position, null, null);
}

export function statusForStanding(
  division,
  position,
  clubShortName,
  playoffQualifiers = null
) {
  const tags = [];
  if (position === 1) tags.push("Champion");
  if (position === 2) tags.push("Runner-up");

  const playoffCup =
    clubShortName && playoffQualifiers
      ? prestigeCupForStanding(division, position, clubShortName, playoffQualifiers)
      : null;
  const cup = playoffCup || prestigeCupForPosition(division, position);
  if (cup) tags.push(cup);

  if (division === "superleague") {
    if (position >= 16 && position <= 17) tags.push("SL playoff");
    if (position >= 18) tags.push("Relegation");
    return tags;
  }

  if (position >= 16 && position <= 17 && !playoffCup) tags.push("Shield/Bowl PO");
  if (position <= 2) tags.push("Promotion");
  if (position >= 3 && position <= 6) tags.push("Playoffs");
  return tags;
}

/** @deprecated Use statusForPosition — kept for callers expecting the old name. */
export function zonesForPosition(division, position) {
  return statusForPosition(division, position);
}

/** Left bar colour: prestige cup (Super8 / Plate / Shield / Bowl). */
export function prestigeBarKey(division, position) {
  return prestigeBarKeyForStanding(division, position, null, null);
}

export function prestigeBarKeyForStanding(
  division,
  position,
  clubShortName,
  playoffQualifiers = null
) {
  const cup = prestigeCupForStanding(
    division,
    position,
    clubShortName,
    playoffQualifiers
  );
  return cup ? cup.toLowerCase() : "none";
}

/** Row background tint: league outcome (champion, promotion, relegation, etc.). */
export function leagueTintKey(division, position) {
  if (position === 1) return "champion";
  if (position === 2) return "runner_up";
  if (division === "superleague") {
    if (position >= 18) return "relegation";
    if (position >= 16) return "playoff";
    return "safe";
  }
  if (position >= 18) return "bowl";
  if (position >= 16) return "playoff";
  if (position >= 3 && position <= 6) return "playoffs";
  if (position <= 2) return "promotion";
  return "safe";
}

/** @deprecated Use prestigeBarKey — kept for any legacy callers. */
export function primaryZoneKey(division, position) {
  const key = prestigeBarKey(division, position);
  return key === "none" ? "plate" : key;
}

/** League movement boundary (relegation / playoff lines). */
export function leagueBoundaryKey(division, position) {
  if (division === "superleague") {
    if (position >= 18) return "relegation";
    if (position >= 16) return "playoff";
    return "safe";
  }
  if (position >= 18) return "bowl";
  if (position >= 16) return "playoff";
  if (position >= 3 && position <= 6) return "playoffs";
  if (position <= 2) return "promotion";
  return "mid";
}

export function formatFormHtml(formStr) {
  if (!formStr) return "—";
  return [...formStr]
    .map((ch) => `<span class="form-${ch.toLowerCase()}">${ch}</span>`)
    .join("");
}

/** Sort standings rows best → worst (pts, GD, GF, name). */
export function compareStandingsRows(a, b) {
  return (
    (b.pts ?? 0) - (a.pts ?? 0) ||
    (b.gd ?? 0) - (a.gd ?? 0) ||
    (b.gf ?? 0) - (a.gf ?? 0) ||
    String(a.club_name || "").localeCompare(String(b.club_name || ""))
  );
}

/**
 * Build home or away-only records from played league fixtures.
 * Keeps overall table_position for Status column; stats/form are venue-only.
 */
export function buildVenueStandings(baseRows, fixtures, venue) {
  const byKey = new Map();
  for (const row of baseRows || []) {
    byKey.set(`${row.division}:${row.club_short_name}`, {
      season_id: row.season_id,
      division: row.division,
      club_short_name: row.club_short_name,
      club_name: row.club_name,
      table_position: row.table_position,
      league_prize_amount: row.league_prize_amount,
      league_prize_paid: row.league_prize_paid,
      mp: 0,
      w: 0,
      d: 0,
      l: 0,
      gf: 0,
      ga: 0,
      gd: 0,
      pts: 0,
      formEntries: [],
    });
  }

  const homeVenue = venue === "home";
  for (const f of fixtures || []) {
    if (f.competition_type !== "league" || f.status !== "played") continue;
    if (f.home_goals == null || f.away_goals == null) continue;

    const club = homeVenue ? f.home_club_short_name : f.away_club_short_name;
    const key = `${f.division}:${club}`;
    const entry = byKey.get(key);
    if (!entry) continue;

    const gf = Number(homeVenue ? f.home_goals : f.away_goals);
    const ga = Number(homeVenue ? f.away_goals : f.home_goals);
    let r = "L";
    if (gf > ga) r = "W";
    else if (gf === ga) r = "D";

    entry.mp += 1;
    if (r === "W") {
      entry.w += 1;
      entry.pts += 3;
    } else if (r === "D") {
      entry.d += 1;
      entry.pts += 1;
    } else {
      entry.l += 1;
    }
    entry.gf += gf;
    entry.ga += ga;
    entry.formEntries.push({ matchday: f.matchday, r });
  }

  const rows = [];
  for (const entry of byKey.values()) {
    entry.gd = entry.gf - entry.ga;
    entry.form_last10 = entry.formEntries
      .sort((a, b) => a.matchday - b.matchday)
      .slice(-10)
      .map((x) => x.r)
      .join("");
    delete entry.formEntries;
    rows.push(entry);
  }
  return rows;
}

/** Rank venue rows 1–20 per division (best home/away record first). */
export function rankVenueStandings(rows) {
  const groups = groupStandingsByDivision(rows);
  const ranked = [];
  for (const div of LEAGUE_DIVISIONS) {
    const sorted = [...(groups[div] || [])].sort(compareStandingsRows);
    sorted.forEach((row, idx) => {
      ranked.push({ ...row, venue_rank: idx + 1 });
    });
  }
  return ranked;
}

export function groupStandingsByDivision(rows) {
  const groups = {};
  for (const div of LEAGUE_DIVISIONS) groups[div] = [];
  for (const row of rows) {
    if (groups[row.division]) groups[row.division].push(row);
  }
  return groups;
}

export function formatMoney(amount) {
  const n = Number(amount);
  if (!Number.isFinite(n)) return "₿ —";
  return `₿ ${n.toLocaleString("en-GB", { maximumFractionDigits: 0 })}`;
}

export const GATE_ENTRY_LABELS = {
  gate_league_home: "Gate receipts (league home)",
  gate_cup_share: "Gate receipts (cup 50%)",
  gate_friendlies: "Gate receipts (friendlies)",
  prize: "Prize money",
  prize_league: "League prize money",
  prize_cup: "Cup prize money",
  prize_challenge: "Challenge prize money",
  tv_revenue: "TV revenue",
  adjustment: "Adjustment",
  admin_one_off_injection: "End of season / bank injection",
  admin_purchase_payment: "Admin purchase payment",
  transfer_sale: "Player sale",
  transfer_purchase: "Player purchase",
  transfer_agent_fee: "Agent fee",
  transfer_foreign_sale: "Foreign sale",
  transfer_overflow_release: "Squad release (MV)",
  special_auction_fee: "Special auction fee",
  special_auction_prize: "Special auction prize",
  infra_maintenance: "Stadium maintenance",
  infra_purchase: "Infrastructure purchase",
  infra_expansion: "Stadium expansion",
  infra_expansion_refund: "Stadium expansion refund",
  infra_expansion_penalty: "Rapid Build cancellation fee",
  gov_fine_compensation: "Fines & compensation",
  gov_hg_subsidy: "Homegrown subsidy",
  gov_youth_subsidy: "Youth subsidy",
  gov_bnb_subsidy: "Weak squad bonus",
  gov_emergency_tax: "Emergency tax",
  gov_income_tax: "Income tax",
  wage_squad: "Wages",
  wage_renewal_34plus: "34+ renewals",
  wage_star_tax: "Star tax",
  staff_manager_salary: "Manager salary",
  contract_signing_offer: "Manager signing / contract offers",
  contract_release_comp: "Contract release (paid)",
  contract_release_comp_received: "Contract release (received)",
  new_owner_release: "New Owner release",
  contract_termination: "Contract termination",
  eos_debt_interest: "Debt interest",
  eos_ffp_charge: "FFP charge",
  eos_balance_interest: "Balance interest",
  eos_injection: "End of season injection",
  loan_drawdown: "Loan drawdown",
  loan_repayment_principal: "Loan repayment",
  loan_interest_payment: "Loan interest",
};

/** @deprecated use FINANCE_ENTRY_LABELS */
export const FINANCE_ENTRY_LABELS = GATE_ENTRY_LABELS;

const INCOME_TYPES = new Set([
  "gate_league_home",
  "gate_cup_share",
  "gate_friendlies",
  "prize",
  "prize_league",
  "prize_cup",
  "prize_challenge",
  "tv_revenue",
  "gov_hg_subsidy",
  "gov_youth_subsidy",
  "gov_bnb_subsidy",
  "adjustment",
  "admin_one_off_injection",
  "transfer_sale",
  "transfer_foreign_sale",
  "transfer_overflow_release",
  "loan_drawdown",
  "eos_balance_interest",
  "eos_injection",
  "contract_release_comp_received",
  "special_auction_prize",
]);

export function financeEntryLabel(type) {
  return FINANCE_ENTRY_LABELS[type] || type;
}

export function isFinanceIncomeEntry(type, amount) {
  if (INCOME_TYPES.has(type)) return true;
  return Number(amount) > 0;
}

export async function loadGpslBankPublic(supabase) {
  const { data, error } = await supabase
    .from("gpsl_bank_public")
    .select("*")
    .maybeSingle();

  if (error) {
    console.error("loadGpslBankPublic:", error);
    return null;
  }
  return data;
}

export async function loadClubBalance(supabase, clubShortName) {
  const { data, error } = await supabase
    .from("Club_Finances")
    .select("balance, club_name")
    .eq("club_name", clubShortName)
    .maybeSingle();

  if (error) {
    console.error("loadClubBalance:", error);
    return null;
  }
  return data;
}

export async function loadFinanceLedger(supabase, clubShortName, limit = 50) {
  let query = supabase
    .from("competition_finance_ledger_public")
    .select("*")
    .order("created_at", { ascending: false })
    .limit(limit);

  if (clubShortName) query = query.eq("club_short_name", clubShortName);

  const { data, error } = await query;
  if (error) {
    console.error("loadFinanceLedger:", error);
    return [];
  }
  return data || [];
}

export async function loadClubSeasonArchive(supabase, clubShortName) {
  const { data, error } = await supabase
    .from("competition_club_season_archive_public")
    .select("*")
    .eq("club_short_name", clubShortName)
    .order("created_at", { ascending: false })
    .limit(5);

  if (error) {
    console.error("loadClubSeasonArchive:", error);
    return [];
  }
  return data || [];
}

/** Map archived club season row → standings table row shape. */
export function mapArchiveRowToStanding(row) {
  return {
    club_short_name: row.club_short_name,
    club_name: row.club_name,
    division: row.division,
    table_position: row.final_position,
    mp: row.mp,
    w: row.won,
    d: row.drawn,
    l: row.lost,
    gf: row.gf,
    ga: row.ga,
    gd: row.gd,
    pts: row.pts,
    form_last10: "",
    league_prize_amount: 0,
    league_prize_paid: true,
  };
}

export async function loadArchivedSeasonStandings(supabase, seasonLabel) {
  const label = String(seasonLabel || "").trim();
  if (!label) return [];

  const { data, error } = await supabase
    .from("competition_club_season_archive_public")
    .select("*")
    .eq("season_label", label)
    .order("division", { ascending: true })
    .order("final_position", { ascending: true });

  if (error) {
    console.error("loadArchivedSeasonStandings:", error);
    return [];
  }
  return (data || []).map(mapArchiveRowToStanding);
}

/** Cup bracket for a completed season (by season label). */
export async function loadCupBracketForSeason(
  supabase,
  cupCode,
  seasonLabel,
  clubNameFn = (short) => short
) {
  const label = String(seasonLabel || "").trim();
  if (!label || !cupCode) return [];

  const { data: season, error: seasonErr } = await supabase
    .from("competition_seasons")
    .select("id, label, status")
    .eq("label", label)
    .maybeSingle();

  if (seasonErr || !season?.id) {
    console.error("loadCupBracketForSeason season:", seasonErr);
    return [];
  }

  const { data: nodes, error: nodeErr } = await supabase
    .from("competition_cup_bracket_nodes")
    .select(
      "id, season_id, cup_code, round_no, match_no, cup_leg, leg1_node_id, home_club_short_name, away_club_short_name, winner_club_short_name, fixture_id, child_node_id, child_slot"
    )
    .eq("season_id", season.id)
    .eq("cup_code", cupCode)
    .order("round_no", { ascending: true })
    .order("match_no", { ascending: true })
    .order("cup_leg", { ascending: true });

  if (nodeErr) {
    console.error("loadCupBracketForSeason nodes:", nodeErr);
    return [];
  }
  if (!nodes?.length) return [];

  const fixtureIds = [...new Set(nodes.map((n) => n.fixture_id).filter(Boolean))];
  let fixMap = new Map();
  if (fixtureIds.length) {
    const { data: fixtures, error: fixErr } = await supabase
      .from("competition_fixtures")
      .select(
        "id, status, home_goals, away_goals, gpsl_month, weather, pitch_condition, kit_season"
      )
      .in("id", fixtureIds);
    if (fixErr) {
      console.error("loadCupBracketForSeason fixtures:", fixErr);
    } else {
      fixMap = new Map((fixtures || []).map((f) => [f.id, f]));
    }
  }

  return nodes.map((n) => {
    const f = fixMap.get(n.fixture_id) || {};
    return {
      ...n,
      season_label: season.label,
      home_club_name: clubNameFn(n.home_club_short_name),
      away_club_name: clubNameFn(n.away_club_short_name),
      winner_club_name: clubNameFn(n.winner_club_short_name),
      fixture_status: f.status ?? null,
      home_goals: f.home_goals ?? null,
      away_goals: f.away_goals ?? null,
      fixture_gpsl_month: f.gpsl_month ?? null,
      weather: f.weather ?? null,
      pitch_condition: f.pitch_condition ?? null,
      kit_season: f.kit_season ?? null,
      round_gpsl_month: f.gpsl_month ?? null,
    };
  });
}

export async function loadClubLoans(supabase) {
  const { data, error } = await supabase
    .from("club_loans_public")
    .select("*")
    .order("created_at", { ascending: false });

  if (error) {
    console.error("loadClubLoans:", error);
    return [];
  }
  return data || [];
}

export async function loadClubLoanInstallments(supabase, loanId = null) {
  let query = supabase
    .from("club_loan_installments_public")
    .select("*")
    .order("installment_no", { ascending: true });

  if (loanId != null) query = query.eq("loan_id", loanId);

  const { data, error } = await query;
  if (error) {
    console.error("loadClubLoanInstallments:", error);
    return [];
  }
  return data || [];
}

/** Post due scheduled installments (current + overdue GPSL months). */
export async function processMyDueLoanInstallments(supabase) {
  const { data, error } = await supabase.rpc(
    "club_loan_process_my_due_installments"
  );
  if (error) {
    console.warn("processMyDueLoanInstallments:", error);
    return null;
  }
  return data;
}

export async function loadLeagueLoans(supabase) {
  const { data, error } = await supabase
    .from("club_loans_league_public")
    .select("*")
    .order("created_at", { ascending: false });

  if (error) {
    console.error("loadLeagueLoans:", error);
    return [];
  }
  return data || [];
}

export async function loadBankLedger(supabase, limit = 100) {
  const { data, error } = await supabase
    .from("bank_ledger_public")
    .select("*")
    .order("created_at", { ascending: false })
    .limit(limit);

  if (error) {
    console.error("loadBankLedger:", error);
    return [];
  }
  return data || [];
}

/** @returns {{ loanId: number } | { error: string }} */
export async function takeClubLoan(supabase, amount) {
  const { data, error } = await supabase.rpc("club_take_loan", {
    p_amount: amount,
  });

  if (error) return { error: error.message || "Loan failed" };
  return { loanId: data };
}

/** @returns {{ repaid: number } | { error: string }} */
export async function repayClubLoan(supabase, amount, loanId = null) {
  const params = { p_amount: amount };
  if (loanId != null) params.p_loan_id = loanId;

  const { data, error } = await supabase.rpc("club_repay_loan", params);

  if (error) return { error: error.message || "Repayment failed" };
  return { repaid: Number(data) };
}

export function clubLoanHeadroom(bank, outstanding) {
  if (!bank?.loans_enabled) return 0;
  const max = Number(bank.loan_max_outstanding_per_club || 0);
  const out = Number(outstanding || 0);
  return Math.max(0, max - out);
}

export async function estimateGateForClub(supabase, clubShortName) {
  const { data, error } = await supabase.rpc("competition_estimate_gate_for_club", {
    p_club_short_name: clubShortName,
  });

  if (error) {
    console.error("estimateGateForClub:", error);
    return null;
  }
  if (data?.error) return null;
  return data;
}
