/**
 * Admin — per-club season finance forecast (posted ledger + pending estimates),
 * using the same line structure as the owner Finances page.
 * Current season only (competition_finance_ledger_public is current-season scoped).
 */

import { aggregateLedgerByLine } from "./finance_ui.js?v=20260919-isvideo-fix";
import {
  loadCupFixtures,
  loadCurrentSeason,
  loadLeagueFixtures,
  loadStandingsWithPrizes,
  normalizeClubKey,
} from "./competition.js";

const STADIUM_VALUE_PER_SEAT = 1500;
const MAINTENANCE_RATE = 0.125;
const RPC_CONCURRENCY = 6;

/** Column layout — mirrors the owner Finances sections. */
export const FORECAST_SECTIONS = [
  {
    id: "prizes",
    title: "Prize money & TV",
    lines: [
      { id: "prize_league", label: "League prize" },
      { id: "prize_cup", label: "Cup prize" },
      { id: "prize_challenge", label: "Challenge prize" },
      { id: "prize_tv", label: "TV revenue" },
    ],
  },
  {
    id: "infra",
    title: "Infrastructure",
    lines: [
      { id: "gate_cup", label: "Gates (cup 50%)" },
      { id: "gate_league", label: "Gates (league home)" },
      { id: "infra_maintenance", label: "Stadium maint." },
    ],
  },
  {
    id: "gov",
    title: "Government",
    lines: [
      { id: "gov_hg", label: "HG subsidy" },
      { id: "gov_youth", label: "Youth subsidy" },
      { id: "gov_bnb", label: "Weak squad" },
      { id: "gov_emergency_tax", label: "Emergency tax" },
      { id: "gov_income_tax", label: "Income tax" },
    ],
  },
  {
    id: "upkeep",
    title: "Player upkeep",
    lines: [
      { id: "upkeep_wages", label: "Wages" },
      { id: "upkeep_34plus", label: "34+ age fee" },
      { id: "upkeep_star_tax", label: "Star tax" },
      { id: "upkeep_release", label: "Contract releases" },
    ],
  },
  {
    id: "staff",
    title: "Staff",
    lines: [
      { id: "staff_manager", label: "Manager salary" },
      { id: "staff_offers", label: "Contract offers" },
    ],
  },
  {
    id: "eos",
    title: "End of season",
    lines: [
      { id: "eos_debt_interest", label: "Debt interest" },
      { id: "eos_ffp", label: "FFP charges" },
    ],
  },
];

export const FORECAST_LINE_IDS = FORECAST_SECTIONS.flatMap((s) =>
  s.lines.map((l) => l.id)
);

async function mapLimit(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i], i);
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, worker)
  );
  return out;
}

async function loadAllCurrentLedger(supabase) {
  const pageSize = 1000;
  const all = [];
  let from = 0;
  while (true) {
    const { data, error } = await supabase
      .from("competition_finance_ledger_public")
      .select("club_short_name, entry_type, amount, metadata, description")
      .order("id", { ascending: true })
      .range(from, from + pageSize - 1);
    if (error) throw error;
    const batch = data || [];
    all.push(...batch);
    if (batch.length < pageSize) break;
    from += pageSize;
  }
  return all;
}

async function loadBankEosSettings(supabase) {
  const settings = { ratePct: 5, ffpThreshold: 100000000, ffpFine: 50000000 };
  const { data, error } = await supabase
    .from("gpsl_bank_account")
    .select(
      "eos_debt_interest_pct, policy_interest_rate_pct, eos_ffp_debt_threshold, eos_ffp_flat_fine"
    )
    .eq("id", 1)
    .maybeSingle();
  if (!error && data) {
    const rate =
      Number(data.eos_debt_interest_pct) || Number(data.policy_interest_rate_pct);
    if (rate > 0) settings.ratePct = rate;
    if (data.eos_ffp_debt_threshold != null) {
      settings.ffpThreshold = Math.max(0, Number(data.eos_ffp_debt_threshold));
    }
    if (data.eos_ffp_flat_fine != null) {
      settings.ffpFine = Math.max(0, Number(data.eos_ffp_flat_fine));
    }
    return settings;
  }
  const { data: pub } = await supabase
    .from("gpsl_bank_public")
    .select("policy_interest_rate_pct")
    .maybeSingle();
  if (Number(pub?.policy_interest_rate_pct) > 0) {
    settings.ratePct = Number(pub.policy_interest_rate_pct);
  }
  return settings;
}

async function rpcOrNull(supabase, fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error || data?.error) return null;
  return data;
}

function postedGateSplit(rows) {
  let cup = 0;
  let league = 0;
  for (const r of rows) {
    const amt = Number(r.amount || 0);
    if (r.entry_type === "gate_cup_share") cup += amt;
    else if (
      r.entry_type === "gate_league_home" ||
      r.entry_type === "gate_friendlies" ||
      r.entry_type === "gate_match_video"
    ) {
      league += amt;
    }
  }
  return { cup, league };
}

/** Remaining cost/income still to post, never double-counting what is already on the ledger. */
function remaining(estimateTotal, posted) {
  const est = Number(estimateTotal) || 0;
  const done = Number(posted) || 0;
  if (est < 0) return Math.min(0, est - done);
  if (est > 0) return Math.max(0, est - done);
  return 0;
}

/**
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {{ onProgress?: (done: number, total: number) => void }} [opts]
 */
export async function buildLeagueFinanceForecast(supabase, opts = {}) {
  const season = await loadCurrentSeason(supabase);
  if (!season?.id) throw new Error("No current season found.");

  const [
    regsRes,
    balancesRes,
    ledger,
    leagueFixtures,
    cupFixtures,
    standings,
    tvRes,
    govPaidRes,
    bank,
  ] = await Promise.all([
    supabase
      .from("competition_club_season_public")
      .select("club_short_name, club_name, division"),
    supabase.from("Club_Finances").select("club_name, balance"),
    loadAllCurrentLedger(supabase),
    loadLeagueFixtures(supabase),
    loadCupFixtures(supabase),
    loadStandingsWithPrizes(supabase),
    supabase
      .from("competition_tv_fixtures_public")
      .select("home_club_short_name, away_club_short_name, home_tv_amount, away_tv_amount")
      .eq("season_id", season.id)
      .eq("status", "scheduled"),
    supabase
      .from("competition_gov_subsidy_paid")
      .select("club_short_name, subsidy_type")
      .eq("season_id", season.id),
    loadBankEosSettings(supabase),
  ]);

  if (regsRes.error) throw regsRes.error;
  const clubs = (regsRes.data || []).filter((r) => r.club_short_name);

  const balanceByClub = new Map(
    (balancesRes.data || []).map((r) => [
      normalizeClubKey(r.club_name),
      Number(r.balance || 0),
    ])
  );

  const ledgerByClub = new Map();
  for (const r of ledger) {
    const k = normalizeClubKey(r.club_short_name);
    if (!ledgerByClub.has(k)) ledgerByClub.set(k, []);
    ledgerByClub.get(k).push(r);
  }

  const leagueHomeLeft = new Map();
  for (const f of leagueFixtures) {
    if (f.status !== "scheduled") continue;
    const k = normalizeClubKey(f.home_club_short_name);
    leagueHomeLeft.set(k, (leagueHomeLeft.get(k) || 0) + 1);
  }
  const cupHomeLeft = new Map();
  for (const f of cupFixtures) {
    if (f.status !== "scheduled") continue;
    const k = normalizeClubKey(f.home_club_short_name);
    cupHomeLeft.set(k, (cupHomeLeft.get(k) || 0) + 1);
  }

  const standingByClub = new Map(
    (standings || []).map((s) => [normalizeClubKey(s.club_short_name), s])
  );

  const tvLeft = new Map();
  for (const r of tvRes.data || []) {
    const h = normalizeClubKey(r.home_club_short_name);
    const a = normalizeClubKey(r.away_club_short_name);
    tvLeft.set(h, (tvLeft.get(h) || 0) + (Number(r.home_tv_amount) || 0));
    tvLeft.set(a, (tvLeft.get(a) || 0) + (Number(r.away_tv_amount) || 0));
  }

  const govPaid = new Set(
    (govPaidRes.data || []).map(
      (r) => `${normalizeClubKey(r.club_short_name)}|${r.subsidy_type}`
    )
  );

  let done = 0;
  const rows = await mapLimit(clubs, RPC_CONCURRENCY, async (reg) => {
    const short = reg.club_short_name;
    const key = normalizeClubKey(short);
    const [gateEst, upkeep, gov] = await Promise.all([
      rpcOrNull(supabase, "competition_estimate_gate_for_club", {
        p_club_short_name: short,
      }),
      rpcOrNull(supabase, "competition_club_upkeep_preview", {
        p_club_short_name: short,
      }),
      rpcOrNull(supabase, "gov_subsidy_club_preview", {
        p_club_short_name: short,
      }),
    ]);

    const clubLedger = ledgerByClub.get(key) || [];
    const byLine = aggregateLedgerByLine(clubLedger);
    const postedAmt = (id) => Number(byLine.get(id)?.amount || 0);
    const gates = postedGateSplit(clubLedger);

    const posted = {};
    for (const id of FORECAST_LINE_IDS) posted[id] = postedAmt(id);
    posted.gate_cup = gates.cup;
    posted.gate_league = gates.league;

    const pending = {};
    for (const id of FORECAST_LINE_IDS) pending[id] = 0;

    const perMatch = Number(gateEst?.total_gate || 0);
    const capacity = Number(gateEst?.capacity || 0);
    if (perMatch > 0) {
      pending.gate_league = (leagueHomeLeft.get(key) || 0) * perMatch;
      pending.gate_cup = (cupHomeLeft.get(key) || 0) * perMatch * 0.5;
    }

    if (Math.abs(posted.infra_maintenance) < 0.5 && capacity > 0) {
      pending.infra_maintenance = -Math.round(
        capacity * STADIUM_VALUE_PER_SEAT * MAINTENANCE_RATE
      );
    }

    if (upkeep) {
      pending.upkeep_wages = remaining(-Number(upkeep.wage_bill || 0), posted.upkeep_wages);
      pending.staff_manager = remaining(
        -Number(upkeep.manager_salary || 0),
        posted.staff_manager
      );
      pending.upkeep_34plus = remaining(
        -Number(upkeep.amount_34plus || 0),
        posted.upkeep_34plus
      );
      pending.upkeep_star_tax = remaining(
        -Number(upkeep.amount_star_tax || 0),
        posted.upkeep_star_tax
      );
      pending.gov_emergency_tax = remaining(
        -Number(upkeep.emergency_tac_amount || 0),
        posted.gov_emergency_tax
      );
    }

    if (posted.prize_league < 0.5) {
      const st = standingByClub.get(key);
      const prizeAmt = Number(st?.league_prize_amount || 0);
      if (prizeAmt > 0 && !st?.league_prize_paid) pending.prize_league = prizeAmt;
    }

    pending.prize_tv = tvLeft.get(key) || 0;

    if (gov) {
      const govLines = [
        ["gov_hg", "gov_hg_subsidy", "homegrown"],
        ["gov_youth", "gov_youth_subsidy", "youth"],
        ["gov_bnb", "gov_bnb_subsidy", "bnb"],
      ];
      for (const [lineId, type, k] of govLines) {
        if (posted[lineId] > 0.5 || govPaid.has(`${key}|${type}`)) continue;
        const amt = Number(gov?.[k]?.amount || 0);
        if (amt > 0.5) pending[lineId] = amt;
      }
    }

    const balanceNow = balanceByClub.get(key) ?? 0;
    const preEosPending = FORECAST_LINE_IDS.filter(
      (id) => id !== "eos_debt_interest" && id !== "eos_ffp"
    ).reduce((s, id) => s + pending[id], 0);
    const preClose = balanceNow + preEosPending;

    let afterInterest = preClose;
    if (Math.abs(posted.eos_debt_interest) < 0.5 && preClose < 0) {
      const interest = Math.round((Math.abs(preClose) * bank.ratePct) / 100);
      pending.eos_debt_interest = -interest;
      afterInterest = preClose - interest;
    }
    if (
      Math.abs(posted.eos_ffp) < 0.5 &&
      bank.ffpFine > 0 &&
      afterInterest <= -bank.ffpThreshold
    ) {
      pending.eos_ffp = -bank.ffpFine;
    }

    const forecast = {};
    let net = 0;
    let totalPending = 0;
    for (const id of FORECAST_LINE_IDS) {
      forecast[id] = posted[id] + pending[id];
      net += forecast[id];
      totalPending += pending[id];
    }

    done += 1;
    opts.onProgress?.(done, clubs.length);

    return {
      club: short,
      clubName: reg.club_name || short,
      division: reg.division || null,
      posted,
      pending,
      forecast,
      net,
      balanceNow,
      projectedBalance: balanceNow + totalPending,
      ffpRisk: pending.eos_ffp < 0 || posted.eos_ffp < 0,
    };
  });

  return { season, bank, clubs: rows };
}
