import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { loadCurrentSeason } from "./competition.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("compSavePlayoffBtn").onclick = saveCompetitionPlayoffQualifier;
  document.getElementById("genPlayoffsBtn").onclick = () =>
    runGen(false).catch((e) => setStatus("genPlayoffStatus", e.message || String(e), false));
  document.getElementById("forcePlayoffsBtn").onclick = () => {
    if (!confirm("Delete existing playoff ties/fixtures and regenerate?")) return;
    runGen(true).catch((e) => setStatus("genPlayoffStatus", e.message || String(e), false));
  };
  document.getElementById("applyMovementsBtn").onclick = () =>
    runApply().catch((e) => setStatus("genPlayoffStatus", e.message || String(e), false));
});

async function runGen(force) {
  setStatus("genPlayoffStatus", force ? "Force regenerating…" : "Generating…");
  const { data, error } = await supabase.rpc("admin_competition_generate_playoffs", {
    p_season_id: null,
    p_force: !!force,
  });
  if (error) {
    setStatus(
      "genPlayoffStatus",
      error.message.includes("admin_competition_generate_playoffs")
        ? "❌ Run competition_phase7_playoffs.sql (+ gpsl_playoffs_week_calendar.sql) first."
        : "❌ " + error.message,
      false
    );
    return;
  }
  if (!data?.ok) {
    setStatus("genPlayoffStatus", data?.reason || data?.error || "Failed", false);
    return;
  }
  setStatus(
    "genPlayoffStatus",
    data.already
      ? `✅ Already generated · scheduled ${data.scheduled_now ?? 0} ready fixture(s).`
      : `✅ Created ${data.ties_created ?? 0} ties, scheduled ${data.fixtures_scheduled ?? 0} fixtures.`
  );
}

async function runApply() {
  setStatus("genPlayoffStatus", "Applying movements…");
  const { data, error } = await supabase.rpc("admin_competition_apply_playoff_movements", {
    p_season_id: null,
  });
  if (error) {
    setStatus("genPlayoffStatus", "❌ " + error.message, false);
    return;
  }
  if (!data?.ok) {
    setStatus(
      "genPlayoffStatus",
      data?.reason === "sl_final_not_played"
        ? "❌ SuperLeague playoff final not played yet."
        : "❌ " + (data?.reason || "Failed"),
      false
    );
    return;
  }
  setStatus("genPlayoffStatus", `✅ Recorded ${data.movements ?? 0} movement(s).`);
}

async function saveCompetitionPlayoffQualifier() {
  const active = await loadCurrentSeason(supabase);
  if (!active?.id) {
    setStatus("compPlayoffStatus", "No active season.", false);
    return;
  }

  const cup =
    document.getElementById("compPlayoffRole").value === "shield_playoff_winner"
      ? "shield"
      : "bowl";

  const { error } = await supabase.rpc("competition_admin_set_playoff_qualifier", {
    p_season_id: active.id,
    p_cup_code: cup,
    p_division: document.getElementById("compPlayoffDiv").value,
    p_club_short_name: document.getElementById("compPlayoffClub").value.trim(),
    p_role: document.getElementById("compPlayoffRole").value,
  });

  setStatus(
    "compPlayoffStatus",
    error ? "❌ " + error.message : "✅ Playoff qualifier saved.",
    !error
  );
}
