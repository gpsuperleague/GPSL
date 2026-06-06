/**
 * Forecast pending income/costs per finance UI line (not yet on the ledger).
 */

import {
  estimateGateForClub,
  formatMoney,
  loadCupFixtures,
  loadCurrentSeason,
  loadLeagueFixtures,
  loadStandingsWithPrizes,
  normalizeClubKey,
} from "./competition.js";

const STADIUM_VALUE_PER_SEAT = 1500;
const MAINTENANCE_RATE = 0.125;

function setPendingForecast(map, lineId, amount, note, byLine) {
  const n = Number(amount) || 0;
  if (Math.abs(n) < 0.5) return;
  const posted = Number(byLine.get(lineId)?.amount || 0);
  if (n > 0 && posted > 0.5 && posted >= n - 0.5) return;
  if (n < 0 && posted < -0.5 && Math.abs(posted) >= Math.abs(n) - 0.5) return;
  map.set(lineId, { amount: n, note });
}

function filterPendingAgainstLedger(map, byLine) {
  const filtered = new Map();
  let totalPending = 0;
  for (const [lineId, pending] of map.entries()) {
    const posted = Number(byLine.get(lineId)?.amount || 0);
    const amt = Number(pending.amount) || 0;
    if (Math.abs(amt) < 0.5) continue;
    if (amt > 0 && posted > 0.5 && posted >= amt - 0.5) continue;
    if (amt < 0 && posted < -0.5 && Math.abs(posted) >= Math.abs(amt) - 0.5) {
      continue;
    }
    filtered.set(lineId, pending);
    totalPending += amt;
  }
  return { pendingByLine: filtered, totalPending };
}

/**
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {string} clubShortName
 * @param {{ byLine: Map<string, { amount: number }> }} ctx
 * @returns {Promise<{ pendingByLine: Map<string, { amount: number, note?: string }>, totalPending: number }>}
 */
export async function buildFinanceProjections(supabase, clubShortName, { byLine }) {
  /** @type {Map<string, { amount: number, note?: string }>} */
  const pendingByLine = new Map();
  const clubKey = normalizeClubKey(clubShortName);

  const gateEst = await estimateGateForClub(supabase, clubShortName);
  const perMatch = Number(gateEst?.total_gate || 0);
  const capacity = Number(gateEst?.capacity || 0);

  const { data: reg } = await supabase
    .from("competition_club_season_public")
    .select("division")
    .eq("club_short_name", clubShortName)
    .maybeSingle();

  const division = reg?.division;

  if (perMatch > 0 && division) {
    const leagueFixtures = await loadLeagueFixtures(supabase, division);
    const leagueHome = leagueFixtures.filter(
      (f) =>
        f.status === "scheduled" &&
        normalizeClubKey(f.home_club_short_name) === clubKey
    ).length;

    const cupFixtures = await loadCupFixtures(supabase);
    const cupHome = cupFixtures.filter(
      (f) =>
        f.status === "scheduled" &&
        normalizeClubKey(f.home_club_short_name) === clubKey
    ).length;

    const gatePending =
      leagueHome * perMatch + cupHome * perMatch * 0.5;

    if (gatePending > 0.5) {
      const parts = [];
      if (leagueHome) parts.push(`${leagueHome} league home`);
      if (cupHome) parts.push(`${cupHome} cup home (50%)`);
      setPendingForecast(
        pendingByLine,
        "infra_gates",
        gatePending,
        `${parts.join(", ")} @ ${formatMoney(perMatch)}/match est.`,
        byLine
      );
    }
  }

  const postedMaint = Math.abs(byLine.get("infra_maintenance")?.amount || 0);
  if (postedMaint < 0.5 && capacity > 0) {
    const stadiumValue = capacity * STADIUM_VALUE_PER_SEAT;
    const cost = -Math.round(stadiumValue * MAINTENANCE_RATE);
    setPendingForecast(
      pendingByLine,
      "infra_maintenance",
      cost,
      "12.5% × capacity × ₿1,500 (season charge, not posted yet)",
      byLine
    );
  }

  const { data: upkeepPreview, error: upkeepErr } = await supabase.rpc(
    "competition_club_upkeep_preview",
    { p_club_short_name: clubShortName }
  );

  if (!upkeepErr && upkeepPreview) {
    const postedWages = Math.abs(byLine.get("upkeep_wages")?.amount || 0);
    const wageBill = Number(upkeepPreview.wage_bill || 0);
    if (wageBill > postedWages + 0.5) {
      setPendingForecast(
        pendingByLine,
        "upkeep_wages",
        -(wageBill - postedWages),
        `Remaining wage bill est. ${formatMoney(wageBill - postedWages)} (${formatMoney(postedWages)} already posted)`,
        byLine
      );
    }

    const posted34 = Math.abs(byLine.get("upkeep_34plus")?.amount || 0);
    const amt34 = Number(upkeepPreview.amount_34plus || 0);
    if (amt34 > posted34 + 0.5) {
      setPendingForecast(
        pendingByLine,
        "upkeep_34plus",
        -(amt34 - posted34),
        `${upkeepPreview.players_34plus ?? 0} player(s) rated ${upkeepPreview.settings?.wage_34plus_min_rating ?? 34}+`,
        byLine
      );
    }

    const postedStar = Math.abs(byLine.get("upkeep_star_tax")?.amount || 0);
    const amtStar = Number(upkeepPreview.amount_star_tax || 0);
    if (amtStar > postedStar + 0.5) {
      setPendingForecast(
        pendingByLine,
        "upkeep_star_tax",
        -(amtStar - postedStar),
        `${upkeepPreview.players_star_tax ?? 0} player(s) rated ${upkeepPreview.settings?.star_tax_min_rating ?? 70}+`,
        byLine
      );
    }

    const postedTac = Math.abs(byLine.get("gov_emergency_tax")?.amount || 0);
    const tacAmt = Number(upkeepPreview.emergency_tac_amount || 0);
    const tacRemain = Math.max(0, tacAmt - postedTac);
    if (tacRemain > 0.5) {
      setPendingForecast(
        pendingByLine,
        "gov_emergency_tax",
        -tacRemain,
        `If admin applies TAC (${upkeepPreview.settings?.emergency_tac_pct ?? 0}% above ${formatMoney(upkeepPreview.settings?.emergency_tac_threshold ?? 0)})`,
        byLine
      );
    }
  } else {
    const { data: players, error: playersErr } = await supabase
      .from("Players")
      .select("contract_wage")
      .eq("Contracted_Team", clubShortName);

    if (!playersErr && players?.length) {
      const squadWage = players.reduce(
        (s, p) => s + (Number(p.contract_wage) || 0),
        0
      );
      const postedWages = Math.abs(byLine.get("upkeep_wages")?.amount || 0);
      const remaining = squadWage - postedWages;
      if (remaining > 0.5) {
        setPendingForecast(
          pendingByLine,
          "upkeep_wages",
          -remaining,
          `Remaining squad wages est. ${formatMoney(remaining)} (${formatMoney(squadWage)} total)`,
          byLine
        );
      }
    }
  }

  const postedLeaguePrize = byLine.get("prize_league")?.amount || 0;
  if (postedLeaguePrize < 0.5) {
    const standings = await loadStandingsWithPrizes(supabase);
    const row = standings.find(
      (s) => normalizeClubKey(s.club_short_name) === clubKey
    );
    const prizeAmt = Number(row?.league_prize_amount || 0);
    if (prizeAmt > 0 && !row?.league_prize_paid) {
      setPendingForecast(
        pendingByLine,
        "prize_league",
        prizeAmt,
        `Position ${row.table_position} prize (if table held at season end)`,
        byLine
      );
    }
  }

  const govLines = [
    { lineId: "gov_hg", type: "gov_hg_subsidy", key: "homegrown", label: "HG" },
    { lineId: "gov_youth", type: "gov_youth_subsidy", key: "youth", label: "Youth" },
    { lineId: "gov_bnb", type: "gov_bnb_subsidy", key: "bnb", label: "BnB" },
  ];

  const season = await loadCurrentSeason(supabase);
  let paidGovTypes = new Set();
  if (season?.id) {
    const { data: paidRows } = await supabase
      .from("competition_gov_subsidy_paid")
      .select("subsidy_type")
      .eq("season_id", season.id)
      .eq("club_short_name", clubShortName);
    paidGovTypes = new Set((paidRows || []).map((r) => r.subsidy_type));
  }

  const { data: govPreview, error: govPreviewErr } = await supabase.rpc(
    "gov_subsidy_club_preview",
    { p_club_short_name: clubShortName }
  );

  const postedTv = byLine.get("prize_tv")?.amount || 0;
  if (season?.id) {
    const { data: tvUpcoming, error: tvErr } = await supabase
      .from("competition_tv_fixtures_public")
      .select("fixture_id, amount_per_club, matchday, gpsl_month_label")
      .eq("season_id", season.id)
      .eq("status", "scheduled")
      .or(
        `home_club_short_name.eq.${clubShortName},away_club_short_name.eq.${clubShortName}`
      );

    if (!tvErr && tvUpcoming?.length) {
      const tvPending = tvUpcoming.reduce(
        (s, r) => s + (Number(r.amount_per_club) || 0),
        0
      );
      if (tvPending > 0.5) {
        setPendingForecast(
          pendingByLine,
          "prize_tv",
          tvPending,
          `${tvUpcoming.length} selected TV match${tvUpcoming.length === 1 ? "" : "es"} remaining`,
          byLine
        );
      }
    } else if (postedTv < 0.5) {
      const { data: tvPreview, error: tvPreviewErr } = await supabase.rpc(
        "competition_tv_club_preview",
        { p_club_short_name: clubShortName }
      );
      if (!tvPreviewErr && Number(tvPreview?.pending_amount) > 0.5) {
        setPendingForecast(
          pendingByLine,
          "prize_tv",
          Number(tvPreview.pending_amount),
          `${tvPreview.pending_count ?? 0} TV match${tvPreview.pending_count === 1 ? "" : "es"} selected`,
          byLine
        );
      }
    }
  }

  if (!govPreviewErr && govPreview) {
    for (const { lineId, type, key, label } of govLines) {
      if ((byLine.get(lineId)?.amount || 0) > 0.5 || paidGovTypes.has(type)) {
        continue;
      }
      const block = govPreview[key];
      const amt = Number(block?.amount || 0);
      const status = block?.status;
      if (amt > 0.5) {
        setPendingForecast(
          pendingByLine,
          lineId,
          amt,
          status && status !== "—"
            ? `${label} — ${status} (paid when all divisions 38/38)`
            : `${label} subsidy (paid when all divisions 38/38)`,
          byLine
        );
      }
    }
  }

  const { data: loanInst, error: loanInstErr } = await supabase
    .from("club_loan_installments_public")
    .select("principal_due, interest_due, total_due, status")
    .eq("status", "pending");

  if (!loanInstErr && loanInst?.length) {
    const loanPending = loanInst.reduce((s, r) => {
      const total =
        Number(r.total_due) ||
        Number(r.principal_due || 0) + Number(r.interest_due || 0);
      return s + total;
    }, 0);
    if (loanPending > 0.5) {
      setPendingForecast(
        pendingByLine,
        "other_loans",
        -loanPending,
        `${loanInst.length} scheduled loan installment${loanInst.length === 1 ? "" : "s"} (principal + interest)`,
        byLine
      );
    }
  }

  return filterPendingAgainstLedger(pendingByLine, byLine);
}
