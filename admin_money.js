import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadCurrentSeasonId();
  await loadWageSettings();
  await loadGovSubsidySettings();
  await loadTvSettings();
  await loadUpkeepTaxSettings();

  document.getElementById("saveWagePctBtn").onclick = saveWagePct;
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
  setGovInput("bnbMaxRating", data.bnb_max_rating ?? 72);
  setGovInput("bnbMinPlayers", data.bnb_min_players ?? 14);
  setGovInput("bnbPerPlayer", data.bnb_per_player ?? 10000000);

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
  setStatus("upkeepTaxStatus", "Applying emergency tax…");
  const { data, error } = await supabase.rpc("competition_admin_apply_emergency_tac", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus("upkeepTaxStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "upkeepTaxStatus",
    `✅ Emergency tax applied to ${data?.clubs_taxed ?? 0} club(s) above threshold. Once per club per season.`,
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
