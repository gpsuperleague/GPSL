import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { LEAGUE_DIVISIONS } from "./competition.js";

primeAdminPageChrome();

const LEAGUE_PRIZE_POSITIONS = 20;

let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadCurrentSeasonId();
  buildLeaguePrizeGrid();
  await loadLeaguePrizeSettings();
  await loadWageSettings();
  await loadStadiumCostSettings();
  await loadAttendanceSettings();
  await loadGovSubsidySettings();
  await loadTvSettings();
  await loadUpkeepTaxSettings();

  document.getElementById("saveWagePctBtn").onclick = saveWagePct;
  document.getElementById("saveStadiumCostBtn").onclick = saveStadiumCosts;
  document.getElementById("saveAttendanceSettingsBtn").onclick = saveAttendanceSettings;
  document.getElementById("recomputeClubRankingsBtn").onclick = recomputeClubRankings;
  document.getElementById("syncStadiumFillBtn").onclick = syncStadiumFill;
  document.getElementById("compBackfillGatesBtn").onclick = backfillGates;
  document.getElementById("saveLeaguePrizesBtn").onclick = saveLeaguePrizes;
  document.getElementById("seedLeaguePrizesBtn").onclick = seedLeaguePrizes;
  document.getElementById("payLeaguePrizesBtn").onclick = payLeaguePrizes;
  document.getElementById("leaguePrizeDivision").onchange = loadLeaguePrizeSettings;
  document.getElementById("saveGovSubsidyBtn").onclick = saveGovSubsidySettings;
  document.getElementById("payGovSubsidyBtn").onclick = payGovSubsidies;
  document.getElementById("saveTvSettingsBtn").onclick = saveTvSettings;
  document.getElementById("selectTvMonthBtn").onclick = selectTvMonth;
  document.getElementById("selectTvSeasonBtn").onclick = selectTvSeason;
  document.getElementById("backfillTvBtn").onclick = backfillTvRevenue;
  document.getElementById("saveUpkeepTaxBtn").onclick = saveUpkeepTaxSettings;
  document.getElementById("postWageBillsBtn").onclick = postSeasonWageBills;
  document.getElementById("applyEmergencyTacBtn").onclick = applyEmergencyTac;
});

async function loadCurrentSeasonId() {
  const { data } = await supabase
    .from("competition_seasons")
    .select("id")
    .eq("is_current", true)
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();
  currentSeasonId = data?.id ?? null;
}

function buildLeaguePrizeGrid() {
  const grid = document.getElementById("leaguePrizeGrid");
  if (!grid) return;
  const rows = [];
  for (let pos = 1; pos <= LEAGUE_PRIZE_POSITIONS; pos++) {
    rows.push(`
      <label class="league-prize-cell">
        <span>#${pos}</span>
        <input type="number" id="leaguePrizePos${pos}" min="0" step="100000" value="0" style="width:120px;">
      </label>
    `);
  }
  grid.innerHTML = rows.join("");
}

async function loadLeaguePrizeSettings() {
  if (!currentSeasonId) {
    setStatus("leaguePrizeStatus", "No current competition season.", false);
    return;
  }

  const division = document.getElementById("leaguePrizeDivision").value;
  for (let pos = 1; pos <= LEAGUE_PRIZE_POSITIONS; pos++) {
    const el = document.getElementById(`leaguePrizePos${pos}`);
    if (el) el.value = "0";
  }

  const { data, error } = await supabase
    .from("competition_league_prize_config_public")
    .select("position, amount")
    .eq("season_id", currentSeasonId)
    .eq("division", division);

  if (error) {
    setStatus(
      "leaguePrizeStatus",
      "❌ " + error.message + " — run competition_league_prizes.sql",
      false
    );
    return;
  }

  for (const row of data || []) {
    const el = document.getElementById(`leaguePrizePos${row.position}`);
    if (el) el.value = String(row.amount ?? 0);
  }

  setStatus("leaguePrizeStatus", `Loaded ${division} prizes for season ${currentSeasonId}.`, true);
}

function leaguePrizeAmountsPayload() {
  /** @type {Record<string, number>} */
  const amounts = {};
  for (let pos = 1; pos <= LEAGUE_PRIZE_POSITIONS; pos++) {
    const el = document.getElementById(`leaguePrizePos${pos}`);
    amounts[String(pos)] = Number(el?.value) || 0;
  }
  return amounts;
}

async function saveLeaguePrizes() {
  if (!currentSeasonId) {
    setStatus("leaguePrizeStatus", "No current season.", false);
    return;
  }

  const division = document.getElementById("leaguePrizeDivision").value;
  if (!LEAGUE_DIVISIONS.includes(division)) {
    setStatus("leaguePrizeStatus", "Invalid division.", false);
    return;
  }

  setStatus("leaguePrizeStatus", "Saving…");
  const { data, error } = await supabase.rpc("competition_admin_save_league_prizes", {
    p_season_id: currentSeasonId,
    p_division: division,
    p_amounts: leaguePrizeAmountsPayload(),
  });

  if (error) {
    setStatus("leaguePrizeStatus", "❌ " + error.message, false);
    return;
  }

  setStatus("leaguePrizeStatus", `✅ Saved ${data ?? 0} position(s) for ${division}.`, true);
}

async function seedLeaguePrizes() {
  if (!currentSeasonId) {
    setStatus("leaguePrizeStatus", "No current season.", false);
    return;
  }

  setStatus("leaguePrizeStatus", "Loading defaults…");
  const { data, error } = await supabase.rpc("competition_admin_seed_league_prize_defaults", {
    p_season_id: currentSeasonId,
  });

  if (error) {
    setStatus("leaguePrizeStatus", "❌ " + error.message, false);
    return;
  }

  await loadLeaguePrizeSettings();
  setStatus(
    "leaguePrizeStatus",
    `✅ Default prize table applied (${data ?? 0} new rows). Edit and Save per division if needed.`,
    true
  );
}

async function payLeaguePrizes() {
  setStatus("leaguePrizeStatus", "Paying…");
  const { data, error } = await supabase.rpc("competition_admin_pay_league_prizes", {
    p_season_id: currentSeasonId,
  });

  if (error) {
    setStatus("leaguePrizeStatus", "❌ " + error.message, false);
    return;
  }

  const paid = data?.clubs_paid ?? 0;
  const byDiv = data?.by_division ?? {};
  setStatus(
    "leaguePrizeStatus",
    `✅ Paid ${paid} club(s). SL: ${byDiv.superleague ?? 0}, CH A: ${byDiv.championship_a ?? 0}, CH B: ${byDiv.championship_b ?? 0}. (Only divisions with 38/38 played.)`,
    true
  );
}

async function loadWageSettings() {
  const { data } = await supabase.from("global_settings").select("*").eq("id", 1).single();
  if (!data) return;
  document.getElementById("wagePctSL").value = data.wage_pct_superleague ?? 5;
  document.getElementById("wagePctCH").value = data.wage_pct_championship ?? 4;
}

async function saveWagePct() {
  const sl = Number(document.getElementById("wagePctSL").value);
  const ch = Number(document.getElementById("wagePctCH").value);

  if (!Number.isFinite(sl) || sl < 0 || sl > 100) {
    setStatus("wagePctStatus", "SuperLeague % must be 0–100.", false);
    return;
  }
  if (!Number.isFinite(ch) || ch < 0 || ch > 100) {
    setStatus("wagePctStatus", "Championship % must be 0–100.", false);
    return;
  }

  setStatus("wagePctStatus", "Saving…");
  const { error: rpcError } = await supabase.rpc("admin_update_wage_settings", {
    p_wage_pct_superleague: sl,
    p_wage_pct_championship: ch,
  });

  if (rpcError) {
    const { error: updError } = await supabase
      .from("global_settings")
      .update({
        wage_pct_superleague: sl,
        wage_pct_championship: ch,
        updated_at: new Date().toISOString(),
      })
      .eq("id", 1);

    if (updError) {
      setStatus("wagePctStatus", "❌ " + (updError.message || rpcError.message), false);
      return;
    }
    setStatus("wagePctStatus", "✅ Saved (direct update). Run player_wage_settings.sql for RPCs.", true);
    return;
  }

  setStatus("wagePctStatus", `✅ Wage % saved — SL ${sl}%, CH ${ch}%.`, true);
}

async function loadStadiumCostSettings() {
  const { data } = await supabase.from("global_settings").select("*").eq("id", 1).single();
  if (!data) return;
  const set = (id, val) => {
    const el = document.getElementById(id);
    if (el && val != null) el.value = val;
  };
  set("stadiumCostTier1", data.stadium_cost_tier1 ?? 5000);
  set("stadiumCostTier2", data.stadium_cost_tier2 ?? 7500);
  set("stadiumCostTier3", data.stadium_cost_tier3 ?? 10000);
  set("stadiumTierMid", data.stadium_capacity_tier_mid ?? 30000);
  set("stadiumTierHigh", data.stadium_capacity_tier_high ?? 50000);
  set("stadiumCancelPenalty", data.stadium_expansion_cancel_penalty ?? 1000000);
}

async function saveStadiumCosts() {
  const t1 = Number(document.getElementById("stadiumCostTier1").value);
  const t2 = Number(document.getElementById("stadiumCostTier2").value);
  const t3 = Number(document.getElementById("stadiumCostTier3").value);
  const mid = Number(document.getElementById("stadiumTierMid").value);
  const high = Number(document.getElementById("stadiumTierHigh").value);
  const penalty = Number(document.getElementById("stadiumCancelPenalty").value);

  if (![t1, t2, t3].every((n) => Number.isFinite(n) && n > 0)) {
    setStatus("stadiumCostStatus", "Tier costs must be positive numbers.", false);
    return;
  }

  setStatus("stadiumCostStatus", "Saving…");
  const { error } = await supabase.rpc("admin_update_stadium_cost_settings", {
    p_tier1: t1,
    p_tier2: t2,
    p_tier3: t3,
    p_tier_mid: Number.isFinite(mid) ? mid : null,
    p_tier_high: Number.isFinite(high) ? high : null,
    p_cancel_penalty: Number.isFinite(penalty) ? penalty : null,
  });

  if (error) {
    setStatus(
      "stadiumCostStatus",
      "❌ " + error.message + " — run stadium_expansion.sql in Supabase.",
      false
    );
    return;
  }

  setStatus("stadiumCostStatus", "✅ Stadium costs saved.", true);
}

async function backfillGates() {
  setStatus("compGateStatus", "Backfilling…");
  const { data, error } = await supabase.rpc("competition_admin_backfill_gates");
  setStatus(
    "compGateStatus",
    error ? "❌ " + error.message : `✅ Processed ${data ?? 0} fixture(s).`,
    !error
  );
}

function setGovInput(id, val) {
  const el = document.getElementById(id);
  if (el && val != null) el.value = val;
}

async function loadGovSubsidySettings() {
  const { data, error } = await supabase.from("global_settings").select("*").eq("id", 1).single();

  if (error) {
    setStatus(
      "govSubsidyStatus",
      "❌ " + error.message + " — run government_subsidies.sql",
      false
    );
    return;
  }

  if (!data) return;

  setGovInput("hgBand1Max", data.hg_sub_band1_max ?? 5);
  setGovInput("hgBand1Rate", data.hg_sub_band1_per_player ?? 250000);
  setGovInput("hgBand2Max", data.hg_sub_band2_max ?? 8);
  setGovInput("hgBand2Rate", data.hg_sub_band2_per_player ?? 1500000);
  setGovInput("hgBand3Rate", data.hg_sub_band3_per_player ?? 2000000);
  setGovInput("youthBand1Max", data.youth_sub_band1_max ?? 3);
  setGovInput("youthBand1Rate", data.youth_sub_band1_per_player ?? 200000);
  setGovInput("youthBand2Max", data.youth_sub_band2_max ?? 5);
  setGovInput("youthBand2Rate", data.youth_sub_band2_per_player ?? 750000);
  setGovInput("youthBand3Max", data.youth_sub_band3_max ?? 7);
  setGovInput("youthBand3Rate", data.youth_sub_band3_per_player ?? 1250000);
  setGovInput("youthBand4Rate", data.youth_sub_band4_per_player ?? 2000000);
  setGovInput("bnbMaxRating", data.bnb_max_rating ?? 70);
  setGovInput("bnbMinPlayers", data.bnb_min_players ?? 8);
  setGovInput("bnbPerPlayer", data.bnb_per_player ?? 1250000);

  setStatus("govSubsidyStatus", "Subsidy settings loaded.", true);
}

function govSubsidySettingsPayload() {
  return {
    hg_sub_band1_max: Number(document.getElementById("hgBand1Max")?.value),
    hg_sub_band1_per_player: Number(document.getElementById("hgBand1Rate")?.value),
    hg_sub_band2_max: Number(document.getElementById("hgBand2Max")?.value),
    hg_sub_band2_per_player: Number(document.getElementById("hgBand2Rate")?.value),
    hg_sub_band3_per_player: Number(document.getElementById("hgBand3Rate")?.value),
    youth_sub_band1_max: Number(document.getElementById("youthBand1Max")?.value),
    youth_sub_band1_per_player: Number(document.getElementById("youthBand1Rate")?.value),
    youth_sub_band2_max: Number(document.getElementById("youthBand2Max")?.value),
    youth_sub_band2_per_player: Number(document.getElementById("youthBand2Rate")?.value),
    youth_sub_band3_max: Number(document.getElementById("youthBand3Max")?.value),
    youth_sub_band3_per_player: Number(document.getElementById("youthBand3Rate")?.value),
    youth_sub_band4_per_player: Number(document.getElementById("youthBand4Rate")?.value),
    bnb_max_rating: Number(document.getElementById("bnbMaxRating")?.value),
    bnb_min_players: Number(document.getElementById("bnbMinPlayers")?.value),
    bnb_per_player: Number(document.getElementById("bnbPerPlayer")?.value),
  };
}

async function saveGovSubsidySettings() {
  setStatus("govSubsidyStatus", "Saving…");
  const { error } = await supabase.rpc("admin_update_gov_subsidy_settings", {
    p_settings: govSubsidySettingsPayload(),
  });

  if (error) {
    setStatus("govSubsidyStatus", "❌ " + error.message, false);
    return;
  }

  setStatus("govSubsidyStatus", "✅ Government subsidy settings saved.", true);
}

async function loadUpkeepTaxSettings() {
  const { data, error } = await supabase.from("global_settings").select("*").eq("id", 1).single();
  if (error) {
    setStatus("upkeepTaxStatus", "❌ " + error.message + " — run competition_wages_taxes.sql", false);
    return;
  }
  if (!data) return;
  setGovInput("tax34MinRating", data.wage_34plus_min_rating ?? 34);
  setGovInput("tax34PerPlayer", data.wage_34plus_per_player ?? 500000);
  setGovInput("starTaxMinRating", data.star_tax_min_rating ?? 70);
  setGovInput("starTaxPerPlayer", data.star_tax_per_player ?? 1000000);
  setGovInput("emergencyTacPct", data.emergency_tac_pct ?? 10);
  setGovInput("emergencyTacThreshold", data.emergency_tac_threshold ?? 100000000);
}

async function saveUpkeepTaxSettings() {
  setStatus("upkeepTaxStatus", "Saving…");
  const { error } = await supabase.rpc("admin_update_upkeep_tax_settings", {
    p_settings: {
      wage_34plus_min_rating: Number(document.getElementById("tax34MinRating")?.value),
      wage_34plus_per_player: Number(document.getElementById("tax34PerPlayer")?.value),
      star_tax_min_rating: Number(document.getElementById("starTaxMinRating")?.value),
      star_tax_per_player: Number(document.getElementById("starTaxPerPlayer")?.value),
      emergency_tac_pct: Number(document.getElementById("emergencyTacPct")?.value),
      emergency_tac_threshold: Number(document.getElementById("emergencyTacThreshold")?.value),
    },
  });
  if (error) {
    setStatus("upkeepTaxStatus", "❌ " + error.message, false);
    return;
  }
  setStatus("upkeepTaxStatus", "✅ Wage/tax settings saved.", true);
}

async function postSeasonWageBills() {
  setStatus("upkeepTaxStatus", "Posting…");
  const { data, error } = await supabase.rpc("competition_admin_post_season_wage_bills", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus("upkeepTaxStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "upkeepTaxStatus",
    `✅ Posted ${data?.charge_lines ?? 0} charge line(s) for ${data?.clubs_charged ?? 0} club(s). Skips already posted.`,
    true
  );
}

async function applyEmergencyTac() {
  setStatus("upkeepTaxStatus", "Applying TAC…");
  const { data, error } = await supabase.rpc("competition_admin_apply_emergency_tac", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus("upkeepTaxStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "upkeepTaxStatus",
    `✅ Emergency TAC applied to ${data?.clubs_taxed ?? 0} club(s) above threshold. Once per club per season.`,
    true
  );
}

async function loadTvSettings() {
  const { data, error } = await supabase.from("global_settings").select("*").eq("id", 1).single();

  if (error) {
    setStatus("tvRevenueStatus", "❌ " + error.message + " — run competition_tv_revenue.sql", false);
    return;
  }

  if (!data) return;

  setGovInput("tvPerMatch", data.tv_per_match_amount ?? 1000000);
  setGovInput("tvPerMonth", data.tv_matches_per_month ?? 5);
  setGovInput("tvClubMin", data.tv_club_min_season ?? 4);
  setGovInput("tvClubMax", data.tv_club_max_season ?? 12);
}

async function saveTvSettings() {
  setStatus("tvRevenueStatus", "Saving…");
  const { error } = await supabase.rpc("admin_update_tv_settings", {
    p_settings: {
      tv_per_match_amount: Number(document.getElementById("tvPerMatch")?.value),
      tv_matches_per_month: Number(document.getElementById("tvPerMonth")?.value),
      tv_club_min_season: Number(document.getElementById("tvClubMin")?.value),
      tv_club_max_season: Number(document.getElementById("tvClubMax")?.value),
    },
  });

  if (error) {
    setStatus("tvRevenueStatus", "❌ " + error.message, false);
    return;
  }

  setStatus("tvRevenueStatus", "✅ TV settings saved.", true);
}

async function selectTvMonth() {
  if (!currentSeasonId) {
    setStatus("tvRevenueStatus", "No current season.", false);
    return;
  }

  const division = document.getElementById("tvSelectDivision").value;
  const month = document.getElementById("tvSelectMonth").value;

  setStatus("tvRevenueStatus", "Selecting…");
  const { data, error } = await supabase.rpc("competition_admin_select_tv_month", {
    p_season_id: currentSeasonId,
    p_division: division,
    p_gpsl_month: month,
    p_replace: true,
  });

  if (error) {
    setStatus("tvRevenueStatus", "❌ " + error.message, false);
    return;
  }

  setStatus(
    "tvRevenueStatus",
    `✅ Selected ${data?.fixtures_selected ?? 0} TV fixture(s) for ${division} / ${month}.`,
    true
  );
}

async function selectTvSeason() {
  if (!currentSeasonId) {
    setStatus("tvRevenueStatus", "No current season.", false);
    return;
  }

  setStatus("tvRevenueStatus", "Selecting full season (uses table before each month)…");
  const { data, error } = await supabase.rpc("competition_admin_select_tv_season", {
    p_season_id: currentSeasonId,
    p_replace: true,
  });

  if (error) {
    setStatus("tvRevenueStatus", "❌ " + error.message, false);
    return;
  }

  setStatus(
    "tvRevenueStatus",
    `✅ TV selection complete for season ${data?.season_id ?? currentSeasonId}. Re-run per month if the table shifts.`,
    true
  );
}

async function backfillTvRevenue() {
  setStatus("tvRevenueStatus", "Backfilling…");
  const { data, error } = await supabase.rpc("competition_admin_backfill_tv_revenue", {
    p_season_id: currentSeasonId,
  });

  if (error) {
    setStatus("tvRevenueStatus", "❌ " + error.message, false);
    return;
  }

  setStatus(
    "tvRevenueStatus",
    `✅ Processed ${data ?? 0} played TV fixture(s).`,
    true
  );
}

async function payGovSubsidies() {
  setStatus("govSubsidyStatus", "Paying…");
  const { data, error } = await supabase.rpc("competition_admin_pay_government_subsidies", {
    p_season_id: currentSeasonId,
  });

  if (error) {
    setStatus("govSubsidyStatus", "❌ " + error.message, false);
    return;
  }

  const paid = data?.subsidy_lines_paid ?? 0;
  const complete = data?.season_league_complete ? "yes" : "no";
  setStatus(
    "govSubsidyStatus",
    `✅ Paid ${paid} subsidy line(s). All divisions 38/38: ${complete}. (Skips clubs/types already paid.)`,
    true
  );
}

const ATTENDANCE_SETTING_FIELDS = [
  ["attMinFill", "stadium_min_fill_pct"],
  ["attMaxFill", "stadium_max_fill_pct"],
  ["attNeutralFill", "stadium_neutral_fill_pct"],
  ["attRollingSeasons", "stadium_rolling_seasons"],
  ["attBigMaxRank", "stadium_big_club_max_rank"],
  ["attMediumMaxRank", "stadium_medium_club_max_rank"],
  ["attCapWeight", "stadium_capacity_prestige_weight"],
  ["attCapRef", "stadium_capacity_prestige_ref"],
  ["attBigSens", "stadium_big_club_sensitivity"],
  ["attMedSens", "stadium_medium_club_sensitivity"],
  ["attLowSens", "stadium_low_club_sensitivity"],
  ["attOverCap", "stadium_overperform_cap"],
  ["attGapScale", "stadium_points_gap_scale"],
  ["attLeagueExpWt", "stadium_league_expect_weight"],
  ["attCupExpWt", "stadium_cup_expect_weight"],
  ["attLeaguePerfWt", "stadium_league_perf_weight"],
  ["attCupPerfWt", "stadium_cup_perf_weight"],
  ["attMgrThreshold", "stadium_manager_lift_threshold"],
  ["attMgrMaxRating", "stadium_manager_lift_max_rating"],
  ["attMgrLiftMed", "stadium_manager_lift_max_positions_med"],
  ["attMgrLiftLow", "stadium_manager_lift_max_positions_low"],
  ["attExpCupSuper8", "stadium_expected_cup_super8_pts"],
  ["attExpCupPlate", "stadium_expected_cup_plate_pts"],
  ["attExpCupShield", "stadium_expected_cup_shield_pts"],
  ["attExpCupSpoon", "stadium_expected_cup_spoon_pts"],
  ["attExpCupLC", "stadium_expected_cup_league_cup_pts"],
  ["attTargetFill", "stadium_target_fill_pct"],
  ["attMaxDisplayFill", "stadium_max_display_fill_pct"],
  ["attMonthlyDrift", "stadium_monthly_drift_pct"],
  ["attPrestigeStep", "stadium_prestige_fill_step_pct"],
  ["attSeasonGain", "stadium_season_gain_on_target_pct"],
  ["attUnderSlight", "stadium_under_slight_penalty_pct"],
  ["attUnderBad", "stadium_under_bad_penalty_pct"],
  ["attUnderAbysmal", "stadium_under_abysmal_penalty_pct"],
  ["attSlightGap", "stadium_under_slight_gap_ratio"],
  ["attBadGap", "stadium_under_bad_gap_ratio"],
  ["attNewBuildCap", "stadium_new_build_max_capacity"],
];

function setAttendanceInput(id, val) {
  const el = document.getElementById(id);
  if (el && val != null) el.value = val;
}

async function loadAttendanceSettings() {
  const { data, error } = await supabase.from("global_settings").select("*").eq("id", 1).single();
  if (error || !data) {
    setStatus(
      "attendanceSettingsStatus",
      "❌ " + (error?.message || "No settings") + " — run competition_club_stadium_attendance.sql",
      false
    );
    return;
  }

  for (const [inputId, key] of ATTENDANCE_SETTING_FIELDS) {
    setAttendanceInput(inputId, data[key]);
  }
}

function attendanceSettingsPayload() {
  /** @type {Record<string, number>} */
  const payload = {};
  for (const [inputId, key] of ATTENDANCE_SETTING_FIELDS) {
    const raw = document.getElementById(inputId)?.value;
    const num = Number(raw);
    if (Number.isFinite(num)) payload[key] = num;
  }
  return payload;
}

async function saveAttendanceSettings() {
  setStatus("attendanceSettingsStatus", "Saving…");
  const { error } = await supabase.rpc("admin_update_stadium_attendance_settings", {
    p_settings: attendanceSettingsPayload(),
  });

  if (error) {
    setStatus(
      "attendanceSettingsStatus",
      "❌ " + error.message + " — run competition_club_stadium_attendance.sql",
      false
    );
    return;
  }

  setStatus("attendanceSettingsStatus", "✅ Attendance settings saved.", true);
}

async function recomputeClubRankings() {
  setStatus("attendanceSettingsStatus", "Recomputing club rankings…");
  const { data, error } = await supabase.rpc("competition_club_ranking_recompute_all");

  if (error) {
    setStatus(
      "attendanceSettingsStatus",
      "❌ " + error.message + " — run competition_club_stadium_attendance.sql",
      false
    );
    return;
  }

  setStatus(
    "attendanceSettingsStatus",
    `✅ Recomputed ${data ?? 0} club-season row(s).`,
    true
  );
  await syncStadiumFill({ quiet: true });
}

async function syncStadiumFill(opts = {}) {
  if (!opts.quiet) setStatus("attendanceSettingsStatus", "Syncing monthly fill drift…");
  const { data, error } = await supabase.rpc("competition_stadium_sync_all_clubs");

  if (error) {
    if (!opts.quiet) {
      setStatus(
        "attendanceSettingsStatus",
        "❌ " + error.message + " — run stadium_attendance_v2.sql",
        false
      );
    }
    return;
  }

  if (!opts.quiet) {
    setStatus(
      "attendanceSettingsStatus",
      `✅ Synced fill for ${data ?? 0} club(s). Open Club attendance & prestige for the ranked table.`,
      true
    );
  }
}
