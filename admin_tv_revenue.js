import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadCurrentSeasonId();
  await loadTvSettings();

  document.getElementById("saveTvSettingsBtn").onclick = saveTvSettings;
  document.getElementById("selectTvMonthBtn").onclick = selectTvMonth;
  document.getElementById("selectTvSeasonBtn").onclick = selectTvSeason;
  document.getElementById("backfillTvBtn").onclick = backfillTvRevenue;
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

function setInput(id, val) {
  const el = document.getElementById(id);
  if (el && val != null) el.value = val;
}

async function loadTvSettings() {
  const { data, error } = await supabase.from("global_settings").select("*").eq("id", 1).single();

  if (error) {
    setStatus("tvRevenueStatus", "❌ " + error.message + " — run competition_tv_revenue.sql", false);
    return;
  }

  if (!data) return;

  setInput("tvPerMatch", data.tv_per_match_amount ?? 1000000);
  setInput("tvPerMonth", data.tv_matches_per_month ?? 5);
  setInput("tvClubMin", data.tv_club_min_season ?? 4);
  setInput("tvClubMax", data.tv_club_max_season ?? 12);
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
