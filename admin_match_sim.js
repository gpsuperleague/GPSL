import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const DEFAULTS = {
  yellow_per_month: 15,
  red_per_month: 1,
  cards_enabled: true,
  injuries_enabled: true,
  max_subs_on: 5,
};

function updateBadge(enabled) {
  const badge = document.getElementById("armBadge");
  if (!badge) return;
  badge.textContent = enabled ? "ON" : "OFF";
  badge.className = enabled ? "arm-badge arm-on" : "arm-badge arm-off";
}

function applySettingsToForm(settings) {
  const s = { ...DEFAULTS, ...(settings || {}) };
  const yellow = document.getElementById("yellowPerMonth");
  const red = document.getElementById("redPerMonth");
  const cards = document.getElementById("cardsEnabled");
  const injuries = document.getElementById("injuriesEnabled");
  const maxSubs = document.getElementById("maxSubsOn");
  if (yellow) yellow.value = String(s.yellow_per_month ?? 15);
  if (red) red.value = String(s.red_per_month ?? 1);
  if (cards) cards.checked = s.cards_enabled !== false;
  if (injuries) injuries.checked = s.injuries_enabled !== false;
  if (maxSubs) maxSubs.value = String(s.max_subs_on ?? 5);
}

function readSettingsFromForm() {
  return {
    yellow_per_month: Math.max(0, Math.min(200, Math.trunc(Number(document.getElementById("yellowPerMonth")?.value || 15)))),
    red_per_month: Math.max(0, Math.min(50, Math.trunc(Number(document.getElementById("redPerMonth")?.value || 1)))),
    cards_enabled: !!document.getElementById("cardsEnabled")?.checked,
    injuries_enabled: !!document.getElementById("injuriesEnabled")?.checked,
    max_subs_on: Math.max(0, Math.min(5, Math.trunc(Number(document.getElementById("maxSubsOn")?.value || 5)))),
  };
}

async function loadStatus() {
  const { data, error } = await supabase.rpc("match_result_simulation_status");
  if (error) {
    setStatus("status", "Run match_result_simulation_settings.sql — " + error.message, false);
    return;
  }
  updateBadge(!!data?.enabled);
  applySettingsToForm(data?.settings);
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

async function saveSettings() {
  const settings = readSettingsFromForm();
  setStatus("settingsStatus", "Saving…");
  const { data, error } = await supabase.rpc("admin_set_match_sim_settings", {
    p_settings: settings,
  });
  if (error) {
    setStatus(
      "settingsStatus",
      `Failed: ${error.message}. Run match_result_simulation_settings.sql if missing.`,
      false
    );
    return;
  }
  applySettingsToForm(data?.settings);
  const s = data?.settings || settings;
  setStatus(
    "settingsStatus",
    `Saved: ${s.yellow_per_month} yellow / ${s.red_per_month} red per month` +
      `${s.cards_enabled ? "" : " · cards off"}` +
      `${s.injuries_enabled ? "" : " · injuries off"}` +
      ` · max ${s.max_subs_on} subs.`,
    true
  );
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  await loadStatus();
  document.getElementById("enableBtn")?.addEventListener("click", () => setEnabled(true));
  document.getElementById("disableBtn")?.addEventListener("click", () => setEnabled(false));
  document.getElementById("saveSettingsBtn")?.addEventListener("click", () => saveSettings());
  document.getElementById("resetDefaultsBtn")?.addEventListener("click", () => {
    applySettingsToForm(DEFAULTS);
    setStatus("settingsStatus", "Defaults loaded in form — click Save settings to apply.", true);
  });
});
