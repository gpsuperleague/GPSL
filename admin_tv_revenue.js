import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let currentSeasonId = null;

const THREE_MD_MONTHS = new Set(["august", "may"]);

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadCurrentSeasonId();
  await loadTvSettings();

  document.getElementById("saveTvSettingsBtn").onclick = saveTvSettings;
  document.getElementById("selectTvMonthBtn").onclick = selectTvMonth;
  document.getElementById("selectTvSeasonBtn").onclick = selectTvSeason;
  document.getElementById("backfillTvBtn").onclick = backfillTvRevenue;
  document.getElementById("tvPerMonth").addEventListener("input", updateMatchdayHint);
  document.getElementById("tvSelectMonth").addEventListener("change", updateMatchdayHint);
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

function num(id, fallback = 0) {
  const n = Number(document.getElementById(id)?.value);
  return Number.isFinite(n) ? n : fallback;
}

function updateMatchdayHint() {
  const el = document.getElementById("tvMatchdayHint");
  if (!el) return;
  const total = Math.max(0, Math.floor(num("tvPerMonth", 12)));
  const month = document.getElementById("tvSelectMonth")?.value || "august";
  const mds = THREE_MD_MONTHS.has(month) ? 3 : 4;
  const base = Math.floor(total / mds);
  const rem = total % mds;
  const parts = [];
  for (let i = 0; i < mds; i++) {
    parts.push(base + (i < rem ? 1 : 0));
  }
  el.textContent =
    `${month}: ${mds} league matchdays → aim ${parts.join(" + ")} = ${total} league TV picks` +
    (THREE_MD_MONTHS.has(month)
      ? " (Aug/May pattern)."
      : " (Sep–Apr pattern).");
}

async function loadTvSettings() {
  const { data, error } = await supabase.from("global_settings").select("*").eq("id", 1).single();

  if (error) {
    setStatus(
      "tvRevenueStatus",
      "❌ " + error.message + " — run competition_tv_revenue.sql / tv_revenue_matchday_and_cup.sql",
      false
    );
    return;
  }

  if (!data) return;

  setInput("tvPerMatch", data.tv_per_match_amount ?? 1000000);
  setInput("tvPerMonth", data.tv_matches_per_month ?? 12);
  setInput("tvClubMin", data.tv_club_min_season ?? 4);
  setInput("tvClubMax", data.tv_club_max_season ?? 12);
  setInput(
    "tvCupPerMatch",
    data.tv_cup_per_match_amount ?? data.tv_per_match_amount ?? 1000000
  );
  setInput("tvCupPerMonth", data.tv_cup_matches_per_month ?? 2);

  setInput("tvWTop8", data.tv_weight_top8_clash ?? 100);
  setInput("tvWTitle", data.tv_weight_title_race ?? 80);
  setInput("tvWSuper8", data.tv_weight_super8 ?? 60);
  setInput("tvWPlayoff", data.tv_weight_playoff ?? 50);
  setInput("tvWPromo", data.tv_weight_promotion ?? 70);
  setInput("tvWRel", data.tv_weight_relegation ?? 70);
  setInput("tvWDry", data.tv_weight_dry_spell ?? 40);
  setInput("tvWBelowMin", data.tv_weight_below_min ?? 200);

  setInput("tvWCupFinal", data.tv_weight_cup_final ?? 120);
  setInput("tvWCupSf", data.tv_weight_cup_sf ?? 80);
  setInput("tvWCupQf", data.tv_weight_cup_qf ?? 100);
  setInput("tvWCupR2", data.tv_weight_cup_r2 ?? 60);
  setInput("tvWCupR1", data.tv_weight_cup_r1 ?? 30);

  updateMatchdayHint();
}

async function saveTvSettings() {
  setStatus("tvRevenueStatus", "Saving…");
  const { error } = await supabase.rpc("admin_update_tv_settings", {
    p_settings: {
      tv_per_match_amount: num("tvPerMatch"),
      tv_matches_per_month: num("tvPerMonth"),
      tv_club_min_season: num("tvClubMin"),
      tv_club_max_season: num("tvClubMax"),
      tv_cup_per_match_amount: num("tvCupPerMatch"),
      tv_cup_matches_per_month: num("tvCupPerMonth"),
      tv_weight_top8_clash: num("tvWTop8"),
      tv_weight_title_race: num("tvWTitle"),
      tv_weight_super8: num("tvWSuper8"),
      tv_weight_playoff: num("tvWPlayoff"),
      tv_weight_promotion: num("tvWPromo"),
      tv_weight_relegation: num("tvWRel"),
      tv_weight_dry_spell: num("tvWDry"),
      tv_weight_below_min: num("tvWBelowMin"),
      tv_weight_cup_final: num("tvWCupFinal"),
      tv_weight_cup_sf: num("tvWCupSf"),
      tv_weight_cup_qf: num("tvWCupQf"),
      tv_weight_cup_r2: num("tvWCupR2"),
      tv_weight_cup_r1: num("tvWCupR1"),
    },
  });

  if (error) {
    setStatus("tvRevenueStatus", "❌ " + error.message, false);
    return;
  }

  setStatus("tvRevenueStatus", "✅ TV settings saved.", true);
  updateMatchdayHint();
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
  setStatus("tvRevenueStatus", "Backfilling split corrections + missing payouts…");
  const { data, error } = await supabase.rpc("competition_admin_backfill_tv_revenue", {
    p_season_id: currentSeasonId,
  });

  if (error) {
    setStatus("tvRevenueStatus", "❌ " + error.message, false);
    return;
  }

  const split = data?.split ?? {};
  const adjusted = split.fixtures_adjusted ?? 0;
  const corrections = split.corrections_posted ?? 0;
  const settled = data?.fixtures_settled ?? 0;

  setStatus(
    "tvRevenueStatus",
    `✅ Split backfill: ${adjusted} fixture(s) adjusted (${corrections} correction line(s)). ` +
      `Settled scan: ${settled} played TV fixture(s).`,
    true
  );
}
