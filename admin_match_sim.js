import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

function updateBadge(enabled) {
  const badge = document.getElementById("armBadge");
  if (!badge) return;
  badge.textContent = enabled ? "ON" : "OFF";
  badge.className = enabled ? "arm-badge arm-on" : "arm-badge arm-off";
}

async function loadStatus() {
  const { data, error } = await supabase.rpc("match_result_simulation_status");
  if (error) {
    setStatus("status", "Run match_result_simulation.sql — " + error.message, false);
    return;
  }
  updateBadge(!!data?.enabled);
  setStatus(
    "status",
    data?.enabled
      ? "Simulation enabled — owners can Simulate from My Club Fixtures."
      : "Simulation disabled.",
    true
  );
}

async function setEnabled(enabled) {
  const msg = enabled
    ? "Enable match simulation for owners? Use for full test seasons only."
    : "Disable match simulation? Simulate buttons will hide.";
  if (!confirm(msg)) return;

  setStatus("status", "Updating…");
  const { data, error } = await supabase.rpc("admin_set_match_result_simulation_enabled", {
    p_enabled: enabled,
  });
  if (error) {
    setStatus("status", error.message, false);
    return;
  }
  updateBadge(!!data?.match_result_simulation_enabled);
  setStatus(
    "status",
    data?.match_result_simulation_enabled ? "Simulation ON." : "Simulation OFF.",
    true
  );
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  await loadStatus();
  document.getElementById("enableBtn")?.addEventListener("click", () => setEnabled(true));
  document.getElementById("disableBtn")?.addEventListener("click", () => setEnabled(false));
});
