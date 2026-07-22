import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney, loadCurrentSeason } from "./competition.js";
import {
  confirmFinanceApply,
  parsePositiveAmount,
  renderClubChecklist,
  selectedClubShortNames,
  setAllClubChecks,
  syncClubPickerVisibility,
} from "./admin_finance_club_targets.js";

primeAdminPageChrome();

let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  const season = await loadCurrentSeason(supabase);
  currentSeasonId = season?.id ?? null;

  await loadClubs();
  await loadEmergencyTaxSettings();
  wireScope();

  document.getElementById("flatTaxSelectAllBtn").onclick = () =>
    setAllClubChecks(document.getElementById("flatTaxClubList"), true);
  document.getElementById("flatTaxClearBtn").onclick = () =>
    setAllClubChecks(document.getElementById("flatTaxClubList"), false);
  document.getElementById("flatTaxBtn").onclick = chargeFlatTax;

  document.getElementById("saveEmergencyTaxBtn").onclick = saveEmergencyTaxSettings;
  document.getElementById("applyEmergencyTacBtn").onclick = applyEmergencyTac;
});

function wireScope() {
  const picker = document.getElementById("flatTaxClubPicker");
  document.querySelectorAll('input[name="flatTaxScope"]').forEach((el) => {
    el.addEventListener("change", () => {
      const scope = document.querySelector('input[name="flatTaxScope"]:checked')?.value || "all";
      syncClubPickerVisibility(scope, picker);
    });
  });
}

async function loadClubs() {
  const { data, error } = await supabase.from("Clubs").select("ShortName, Club").order("Club");
  if (error) {
    setStatus("flatTaxStatus", "❌ " + error.message, false);
    return;
  }
  renderClubChecklist(document.getElementById("flatTaxClubList"), data || []);
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

async function chargeFlatTax() {
  const amount = parsePositiveAmount(document.getElementById("flatTaxAmount"));
  if (amount == null) {
    setStatus("flatTaxStatus", "Enter a positive amount.", false);
    return;
  }

  const scope = document.querySelector('input[name="flatTaxScope"]:checked')?.value || "all";
  let clubs = null;
  if (scope === "selected") {
    clubs = selectedClubShortNames(document.getElementById("flatTaxClubList"));
    if (!clubs.length) {
      setStatus("flatTaxStatus", "Select at least one club.", false);
      return;
    }
  }

  if (
    !confirmFinanceApply({
      actionLabel: "Charge emergency tax (debit clubs)",
      amount,
      scope,
      clubs: clubs || [],
    })
  ) {
    return;
  }

  const note = document.getElementById("flatTaxNote")?.value?.trim() || null;
  setStatus("flatTaxStatus", "Charging emergency tax…");

  const { data, error } = await supabase.rpc("competition_admin_charge_emergency_tax_flat", {
    p_amount: amount,
    p_club_short_names: clubs,
    p_note: note,
    p_season_id: currentSeasonId,
  });

  if (error) {
    setStatus(
      "flatTaxStatus",
      "❌ " + error.message + " — run patches/admin_cash_inject_emergency_tax_flat.sql",
      false
    );
    return;
  }

  setStatus(
    "flatTaxStatus",
    `✅ Debited ${formatMoney(data?.amount ?? amount)} from ${data?.clubs_posted ?? 0} club(s); ` +
      `${data?.inbox_notified ?? 0} inbox notification(s).`,
    true
  );
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
  setStatus("emergencyTaxStatus", "✅ Formula settings saved.", true);
}

async function applyEmergencyTac() {
  if (
    !window.confirm(
      "Apply formula emergency tax to all clubs above the threshold?\n(Once per club per season.)"
    )
  ) {
    return;
  }
  setStatus("emergencyTaxStatus", "Applying formula emergency tax…");
  const { data, error } = await supabase.rpc("competition_admin_apply_emergency_tac", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus("emergencyTaxStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "emergencyTaxStatus",
    `✅ Formula tax applied to ${data?.clubs_taxed ?? 0} club(s) above threshold.`,
    true
  );
}
