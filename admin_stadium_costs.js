import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadStadiumCostSettings();
  document.getElementById("saveStadiumCostBtn").onclick = saveStadiumCosts;
});

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
