import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadCurrentSeasonId();
  await loadGovSubsidySettings();

  document.getElementById("saveGovSubsidyBtn").onclick = saveGovSubsidySettings;
  document.getElementById("payGovSubsidyBtn").onclick = payGovSubsidies;
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

  setInput("hgBand1Max", data.hg_sub_band1_max ?? 5);
  setInput("hgBand1Rate", data.hg_sub_band1_per_player ?? 250000);
  setInput("hgBand2Max", data.hg_sub_band2_max ?? 8);
  setInput("hgBand2Rate", data.hg_sub_band2_per_player ?? 1500000);
  setInput("hgBand3Rate", data.hg_sub_band3_per_player ?? 2000000);
  setInput("youthBand1Max", data.youth_sub_band1_max ?? 3);
  setInput("youthBand1Rate", data.youth_sub_band1_per_player ?? 200000);
  setInput("youthBand2Max", data.youth_sub_band2_max ?? 5);
  setInput("youthBand2Rate", data.youth_sub_band2_per_player ?? 750000);
  setInput("youthBand3Max", data.youth_sub_band3_max ?? 7);
  setInput("youthBand3Rate", data.youth_sub_band3_per_player ?? 1250000);
  setInput("youthBand4Rate", data.youth_sub_band4_per_player ?? 2000000);
  setInput("bnbMaxRating", data.bnb_max_rating ?? 72);
  setInput("bnbMinPlayers", data.bnb_min_players ?? 14);
  setInput("bnbPerPlayer", data.bnb_per_player ?? 10000000);

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
