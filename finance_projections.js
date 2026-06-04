/**
 * Forecast pending income/costs per finance UI line (not yet on the ledger).
 */

import {
  estimateGateForClub,
  formatMoney,
  loadCupFixtures,
  loadLeagueFixtures,
  normalizeClubKey,
} from "./competition.js";

const STADIUM_VALUE_PER_SEAT = 1500;
const MAINTENANCE_RATE = 0.125;

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
      pendingByLine.set("infra_gates", {
        amount: gatePending,
        note: `${parts.join(", ")} @ ${formatMoney(perMatch)}/match est.`,
      });
    }
  }

  const postedMaint = Math.abs(byLine.get("infra_maintenance")?.amount || 0);
  if (postedMaint < 0.5 && capacity > 0) {
    const stadiumValue = capacity * STADIUM_VALUE_PER_SEAT;
    const cost = -Math.round(stadiumValue * MAINTENANCE_RATE);
    pendingByLine.set("infra_maintenance", {
      amount: cost,
      note: "12.5% × capacity × ₿1,500 (season charge, not posted yet)",
    });
  }

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
      pendingByLine.set("upkeep_wages", {
        amount: -remaining,
        note: `Squad contract wages est. ${formatMoney(squadWage)}/season`,
      });
    }
  }

  let totalPending = 0;
  for (const { amount } of pendingByLine.values()) {
    totalPending += Number(amount) || 0;
  }

  return { pendingByLine, totalPending };
}
