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
  "spoon",
  "league_cup",
];

export const CUP_LABELS = {
  super8: "Super8",
  plate: "Plate",
  shield: "Shield",
  spoon: "Spoon",
  league_cup: "League Cup",
};

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
    .order("match_no", { ascending: true });

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
    .map(([round_no, matches]) => ({ round_no, matches }));
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
  const params = {
    p_fixture_id: fixtureId,
    p_home_goals: homeGoals,
    p_away_goals: awayGoals,
    p_player_stats: playerStats,
  };
  if (cupExtra) {
    if (cupExtra.etHome != null) params.p_et_home_goals = cupExtra.etHome;
    if (cupExtra.etAway != null) params.p_et_away_goals = cupExtra.etAway;
    if (cupExtra.penHome != null) params.p_pen_home_goals = cupExtra.penHome;
    if (cupExtra.penAway != null) params.p_pen_away_goals = cupExtra.penAway;
  }
  return supabase.rpc("competition_submit_result", params);
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

export function formatMoney(amount) {
  const n = Number(amount);
  if (!Number.isFinite(n)) return "₿ —";
  return `₿ ${n.toLocaleString("en-GB", { maximumFractionDigits: 0 })}`;
}

export const GATE_ENTRY_LABELS = {
  gate_league_home: "Gate receipts (league home)",
  gate_cup_share: "Gate receipts (cup 50%)",
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
  infra_maintenance: "Stadium maintenance",
  infra_purchase: "Infrastructure purchase",
  infra_expansion: "Stadium expansion",
  gov_fine_compensation: "Fines & compensation",
  gov_hg_subsidy: "Homegrown subsidy",
  gov_youth_subsidy: "Youth subsidy",
  gov_bnb_subsidy: "Built not bought",
  gov_emergency_tax: "Emergency tax",
  gov_income_tax: "Income tax",
  wage_squad: "Wages",
  wage_renewal_34plus: "34+ renewals",
  wage_star_tax: "Star tax",
  staff_manager_salary: "Manager salary",
  contract_signing_offer: "Contract offers",
  contract_release_comp: "Contract release (paid)",
  contract_release_comp_received: "Contract release (received)",
  contract_termination: "Contract termination",
  eos_debt_interest: "Debt interest",
  eos_ffp_charge: "FFP charge",
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
  "prize",
  "adjustment",
  "admin_one_off_injection",
  "transfer_sale",
  "transfer_foreign_sale",
  "transfer_overflow_release",
  "loan_drawdown",
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
