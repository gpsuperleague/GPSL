import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadWageSettings();
  await loadStadiumCostSettings();
  document.getElementById("saveWagePctBtn").onclick = saveWagePct;
  document.getElementById("saveStadiumCostBtn").onclick = saveStadiumCosts;
  document.getElementById("compBackfillGatesBtn").onclick = backfillGates;
});

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
