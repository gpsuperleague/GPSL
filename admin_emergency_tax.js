import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadCurrentSeasonId();
  await loadEmergencyTaxSettings();

  document.getElementById("saveEmergencyTaxBtn").onclick = saveEmergencyTaxSettings;
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

function setInput(id, val) {
  const el = document.getElementById(id);
  if (el && val != null) el.value = val;
}

async function loadEmergencyTaxSettings() {
  const { data, error } = await supabase.from("global_settings").select("*").eq("id", 1).single();
  if (error) {
    setStatus("emergencyTaxStatus", "❌ " + error.message + " — run competition_wages_taxes.sql", false);
    return;
  }
  if (!data) return;
  setInput("emergencyTacPct", data.emergency_tac_pct ?? 10);
  setInput("emergencyTacThreshold", data.emergency_tac_threshold ?? 100000000);
}

async function saveEmergencyTaxSettings() {
  setStatus("emergencyTaxStatus", "Saving…");
  const { error } = await supabase.rpc("admin_update_upkeep_tax_settings", {
    p_settings: {
      emergency_tac_pct: Number(document.getElementById("emergencyTacPct")?.value),
      emergency_tac_threshold: Number(document.getElementById("emergencyTacThreshold")?.value),
    },
  });
  if (error) {
    setStatus("emergencyTaxStatus", "❌ " + error.message, false);
    return;
  }
  setStatus("emergencyTaxStatus", "✅ Emergency tax settings saved.", true);
}

async function applyEmergencyTac() {
  setStatus("emergencyTaxStatus", "Applying emergency tax…");
  const { data, error } = await supabase.rpc("competition_admin_apply_emergency_tac", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus("emergencyTaxStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "emergencyTaxStatus",
    `✅ Emergency tax applied to ${data?.clubs_taxed ?? 0} club(s) above threshold. Once per club per season.`,
    true
  );
}
