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

const BUYER_COMMITTED_STATUSES = ["Active", "Review", "Seller Review"];

/**
 * Unsettled player/manager listings this club leads (winning bids).
 * Soft exposure only — drops when outbid or the listing settles/closes.
 */
export async function loadClubWinningBidExposure(supabase, clubShortName) {
  if (!clubShortName) {
    return { total: 0, count: 0, players: [], managers: [] };
  }

  const [playerRes, managerRes] = await Promise.all([
    supabase
      .from("Player_Transfer_Listings")
      .select(
        "id, player_id, listing_type, status, current_highest_bid"
      )
      .eq("current_highest_bidder", clubShortName)
      .in("status", BUYER_COMMITTED_STATUSES)
      .gt("current_highest_bid", 0),
    supabase
      .from("Manager_Transfer_Listings")
      .select(
        "id, manager_id, listing_type, status, current_highest_bid"
      )
      .eq("current_highest_bidder", clubShortName)
      .in("status", BUYER_COMMITTED_STATUSES)
      .gt("current_highest_bid", 0),
  ]);

  if (playerRes.error) {
    console.warn("winning bid exposure (players):", playerRes.error);
  }
  if (managerRes.error) {
    console.warn("winning bid exposure (managers):", managerRes.error);
  }

  const players = (playerRes.data || []).map((row) => ({
    id: row.id,
    player_id: row.player_id,
    listing_type: row.listing_type,
    status: row.status,
    amount: Number(row.current_highest_bid) || 0,
  }));
  const managers = (managerRes.data || []).map((row) => ({
    id: row.id,
    manager_id: row.manager_id,
    listing_type: row.listing_type,
    status: row.status,
    amount: Number(row.current_highest_bid) || 0,
  }));

  const total =
    players.reduce((s, r) => s + r.amount, 0) +
    managers.reduce((s, r) => s + r.amount, 0);

  return {
    total,
    count: players.length + managers.length,
    players,
    managers,
  };
}

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
 * @param {{ byLine: Map<string, { amount: number }>, winningBidExposure?: { total: number, count: number, players?: any[], managers?: any[] } }} ctx
 * @returns {Promise<{ pendingByLine: Map<string, { amount: number, note?: string }>, totalPending: number, bidExposure?: object }>}
 */
export async function buildFinanceProjections(
  supabase,
  clubShortName,
  { byLine, winningBidExposure = null }
) {
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
      "Stadium maintenance — posted at end of season (Close Finances). 12.5% × capacity × ₿1,500.",
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
        `Remaining player wage bill est. ${formatMoney(wageBill - postedWages)} (${formatMoney(postedWages)} already posted)`,
        byLine
      );
    }

    const postedMgr = Math.abs(byLine.get("staff_manager")?.amount || 0);
    const mgrSalary = Number(upkeepPreview.manager_salary || 0);
    if (mgrSalary > postedMgr + 0.5) {
      setPendingForecast(
        pendingByLine,
        "staff_manager",
        -(mgrSalary - postedMgr),
        `Manager season salary est. ${formatMoney(mgrSalary - postedMgr)} (weekly × 52)`,
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
        `${upkeepPreview.players_star_tax ?? 0} designated star player(s)`,
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
        `If admin applies emergency tax (${upkeepPreview.settings?.emergency_tac_pct ?? 0}% above ${formatMoney(upkeepPreview.settings?.emergency_tac_threshold ?? 0)})`,
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
    { lineId: "gov_bnb", type: "gov_bnb_subsidy", key: "bnb", label: "Weak squad" },
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

  /** @type {object|null} */
  let subsidyPreview = null;

  const postedTv = byLine.get("prize_tv")?.amount || 0;
  if (season?.id) {
    const { data: tvUpcoming, error: tvErr } = await supabase
      .from("competition_tv_fixtures_public")
      .select(
        "fixture_id, home_club_short_name, away_club_short_name, home_tv_amount, away_tv_amount, matchday, gpsl_month_label"
      )
      .eq("season_id", season.id)
      .eq("status", "scheduled")
      .or(
        `home_club_short_name.eq.${clubShortName},away_club_short_name.eq.${clubShortName}`
      );

    if (!tvErr && tvUpcoming?.length) {
      const tvPending = tvUpcoming.reduce((s, r) => {
        const share =
          r.home_club_short_name === clubShortName
            ? Number(r.home_tv_amount)
            : Number(r.away_tv_amount);
        return s + (share || 0);
      }, 0);
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

  if (govPreviewErr) {
    console.warn("gov_subsidy_club_preview:", govPreviewErr);
  } else if (govPreview) {
    subsidyPreview = govPreview;
    for (const { lineId, type, key, label } of govLines) {
      if ((byLine.get(lineId)?.amount || 0) > 0.5 || paidGovTypes.has(type)) {
        continue;
      }
      const block = govPreview[key];
      if (!block) {
        console.warn(`gov_subsidy_club_preview missing key: ${key}`);
        continue;
      }
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

  // Loan pending = this season's installment bucket only (Aug–May × 1).
  // Do NOT trust due_season_id: when Season N+1 does not exist yet, the
  // resolver pins the next-season half of a 20-month loan onto this season id,
  // which wrongly showed e.g. ₿50m / 20 instalments as EOS pending.
  // due_season_label / due_season_offset identify the real bucket.
  // Close Finances never collects loans (month lock / Service Counter do).
  const { data: loanInst, error: loanInstErr } = await supabase
    .from("club_loan_installments_public")
    .select(
      "loan_id, principal_due, interest_due, total_due, status, due_season_id, due_season_offset, due_season_label, due_gpsl_month, due_gpsl_month_label"
    )
    .eq("status", "pending");

  if (!loanInstErr && loanInst?.length) {
    const curId = Number(season?.id) || 0;
    const curLabel = String(season?.label || "").trim().toLowerCase();
    const { data: loans } = await supabase
      .from("club_loans_public")
      .select("id, season_id");
    const loanSeasonById = new Map(
      (loans || []).map((l) => [Number(l.id), Number(l.season_id) || 0])
    );

    const dueNow = loanInst.filter((r) => {
      const label = String(r.due_season_label || "").trim().toLowerCase();
      if (curLabel && label && label === curLabel) return true;

      // Label may be a bare year number ("2") while season.label is "Season 2"
      if (curLabel && label && (curLabel === label || curLabel.endsWith(` ${label}`))) {
        return true;
      }

      const offset = Math.max(0, Number(r.due_season_offset) || 0);
      const loanSeasonId = loanSeasonById.get(Number(r.loan_id)) || 0;
      // Drawn this season → only the first 10-month bucket belongs here
      if (curId && loanSeasonId === curId) return offset === 0;
      // Drawn earlier → only the bucket that lands on the current season
      if (curId && loanSeasonId > 0 && loanSeasonId < curId) {
        // Without a full season list, offset 1 is the next GPSL year (typical 20-mo loan)
        return offset === 1;
      }
      return false;
    });

    let principalPending = 0;
    let interestPending = 0;
    for (const r of dueNow) {
      principalPending += Number(r.principal_due || 0);
      interestPending += Number(r.interest_due || 0);
    }

    const futureLeft = loanInst.length - dueNow.length;
    const monthBits = [
      ...new Set(
        dueNow
          .map((r) => r.due_gpsl_month_label || r.due_gpsl_month)
          .filter(Boolean)
      ),
    ];
    const monthHint =
      monthBits.length > 0 && monthBits.length <= 6
        ? ` (${monthBits.join(", ")})`
        : "";
    const dueNote =
      dueNow.length > 0
        ? `${dueNow.length} instalment${dueNow.length === 1 ? "" : "s"} still unpaid for this season${monthHint} (should post on month lock / Service Counter — not Close Finances)`
        : null;
    const futureNote =
      futureLeft > 0 && dueNow.length > 0
        ? `${futureLeft} further instalment${futureLeft === 1 ? "" : "s"} remain for later seasons (not pending here)`
        : null;

    if (principalPending > 0.5) {
      setPendingForecast(
        pendingByLine,
        "loan_repayments",
        -principalPending,
        [dueNote, futureNote].filter(Boolean).join(" · "),
        byLine
      );
    }
    if (interestPending > 0.5) {
      setPendingForecast(
        pendingByLine,
        "loan_interest",
        -interestPending,
        [dueNote, futureNote].filter(Boolean).join(" · "),
        byLine
      );
    }
  }

  const bidExposure =
    winningBidExposure ||
    (await loadClubWinningBidExposure(supabase, clubShortName));
  if (bidExposure.total > 0.5) {
    const count = bidExposure.count;
    const draftCount = (bidExposure.players || []).filter(
      (r) => String(r.listing_type || "").toLowerCase() === "draft"
    ).length;
    const mgrCount = (bidExposure.managers || []).length;
    const bits = [];
    if (count - mgrCount - draftCount > 0) {
      bits.push(`${count - mgrCount - draftCount} market`);
    }
    if (draftCount > 0) bits.push(`${draftCount} draft`);
    if (mgrCount > 0) bits.push(`${mgrCount} manager`);
    setPendingForecast(
      pendingByLine,
      "transfer_purchases",
      -bidExposure.total,
      `${count} winning bid${count === 1 ? "" : "s"} (${bits.join(", ") || "transfer"} — unsettled, drops if outbid)`,
      byLine
    );
  }

  const result = filterPendingAgainstLedger(pendingByLine, byLine);
  return { ...result, subsidyPreview, bidExposure };
}
