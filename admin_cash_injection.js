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
  wireScope();
  document.getElementById("injectSelectAllBtn").onclick = () =>
    setAllClubChecks(document.getElementById("injectClubList"), true);
  document.getElementById("injectClearBtn").onclick = () =>
    setAllClubChecks(document.getElementById("injectClubList"), false);
  document.getElementById("injectCashBtn").onclick = injectCash;
});

function wireScope() {
  const picker = document.getElementById("injectClubPicker");
  document.querySelectorAll('input[name="injectScope"]').forEach((el) => {
    el.addEventListener("change", () => {
      const scope = document.querySelector('input[name="injectScope"]:checked')?.value || "all";
      syncClubPickerVisibility(scope, picker);
    });
  });
}

async function loadClubs() {
  const { data, error } = await supabase.from("Clubs").select("ShortName, Club").order("Club");
  if (error) {
    setStatus("injectCashStatus", "❌ " + error.message, false);
    return;
  }
  renderClubChecklist(document.getElementById("injectClubList"), data || []);
}

async function injectCash() {
  const amount = parsePositiveAmount(document.getElementById("injectAmount"));
  if (amount == null) {
    setStatus("injectCashStatus", "Enter a positive amount.", false);
    return;
  }

  const scope = document.querySelector('input[name="injectScope"]:checked')?.value || "all";
  let clubs = null;
  if (scope === "selected") {
    clubs = selectedClubShortNames(document.getElementById("injectClubList"));
    if (!clubs.length) {
      setStatus("injectCashStatus", "Select at least one club.", false);
      return;
    }
  }

  if (
    !confirmFinanceApply({
      actionLabel: "Inject cash (credit clubs)",
      amount,
      scope,
      clubs: clubs || [],
    })
  ) {
    return;
  }

  const note = document.getElementById("injectNote")?.value?.trim() || null;
  setStatus("injectCashStatus", "Posting cash injections…");

  const { data, error } = await supabase.rpc("competition_admin_inject_cash", {
    p_amount: amount,
    p_club_short_names: clubs,
    p_note: note,
    p_season_id: currentSeasonId,
  });

  if (error) {
    setStatus(
      "injectCashStatus",
      "❌ " + error.message + " — run patches/admin_cash_inject_emergency_tax_flat.sql",
      false
    );
    return;
  }

  setStatus(
    "injectCashStatus",
    `✅ Credited ${formatMoney(data?.amount ?? amount)} to ${data?.clubs_posted ?? 0} club(s); ` +
      `${data?.inbox_notified ?? 0} inbox notification(s).`,
    true
  );
}
