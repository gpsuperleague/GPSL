import { initAdminPage, setStatus, supabase } from "./admin_common.js";
import { loadCurrentSeason } from "./competition.js";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage("fixtures-playoffs", "Playoff fixtures"))) return;
  document.getElementById("compSavePlayoffBtn").onclick = saveCompetitionPlayoffQualifier;
});

async function saveCompetitionPlayoffQualifier() {
  const active = await loadCurrentSeason(supabase);
  if (!active?.id) {
    setStatus("compPlayoffStatus", "No active season.", false);
    return;
  }

  const cup =
    document.getElementById("compPlayoffRole").value === "shield_playoff_winner"
      ? "shield"
      : "spoon";

  const { error } = await supabase.rpc("competition_admin_set_playoff_qualifier", {
    p_season_id: active.id,
    p_cup_code: cup,
    p_division: document.getElementById("compPlayoffDiv").value,
    p_club_short_name: document.getElementById("compPlayoffClub").value.trim(),
    p_role: document.getElementById("compPlayoffRole").value,
  });

  setStatus("compPlayoffStatus", error ? "❌ " + error.message : "✅ Playoff qualifier saved.", !error);
}
