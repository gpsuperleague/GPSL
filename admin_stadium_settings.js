import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

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

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadAttendanceSettings();

  document.getElementById("saveAttendanceSettingsBtn").onclick = saveAttendanceSettings;
  document.getElementById("recomputeClubRankingsBtn").onclick = recomputeClubRankings;
  document.getElementById("syncStadiumFillBtn").onclick = syncStadiumFill;
  document.getElementById("compBackfillGatesBtn").onclick = backfillGates;
});

async function backfillGates() {
  setStatus("compGateStatus", "Backfilling…");
  const { data, error } = await supabase.rpc("competition_admin_backfill_gates");
  setStatus(
    "compGateStatus",
    error ? "❌ " + error.message : `✅ Processed ${data ?? 0} fixture(s).`,
    !error
  );
}

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
