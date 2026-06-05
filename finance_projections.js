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

  const postedLeaguePrize = byLine.get("prize_league")?.amount || 0;
  if (postedLeaguePrize < 0.5) {
    const standings = await loadStandingsWithPrizes(supabase);
    const row = standings.find(
      (s) => normalizeClubKey(s.club_short_name) === clubKey
    );
    const prizeAmt = Number(row?.league_prize_amount || 0);
    if (prizeAmt > 0 && !row?.league_prize_paid) {
      pendingByLine.set("prize_league", {
        amount: prizeAmt,
        note: `Position ${row.table_position} prize (if table held at season end)`,
      });
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
        pendingByLine.set("prize_tv", {
          amount: tvPending,
          note: `${tvUpcoming.length} selected TV match${tvUpcoming.length === 1 ? "" : "es"} remaining`,
        });
      }
    } else if (postedTv < 0.5) {
      const { data: tvPreview, error: tvPreviewErr } = await supabase.rpc(
        "competition_tv_club_preview",
        { p_club_short_name: clubShortName }
      );
      if (!tvPreviewErr && Number(tvPreview?.pending_amount) > 0.5) {
        pendingByLine.set("prize_tv", {
          amount: Number(tvPreview.pending_amount),
          note: `${tvPreview.pending_count ?? 0} TV match${tvPreview.pending_count === 1 ? "" : "es"} selected`,
        });
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
        pendingByLine.set(lineId, {
          amount: amt,
          note: status && status !== "—"
            ? `${label} — ${status} (paid when all divisions 38/38)`
            : `${label} subsidy (paid when all divisions 38/38)`,
        });
      }
    }
  }

  let totalPending = 0;
  for (const { amount } of pendingByLine.values()) {
    totalPending += Number(amount) || 0;
  }

  return { pendingByLine, totalPending };
}
