import { initAdminPage, setStatus, supabase } from "./admin_common.js";
import { loadCurrentSeason } from "./competition.js";

let compSelectedSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage("fixtures-cups", "Cup fixtures"))) return;

  document.getElementById("compCupSelect").onchange = toggleLeagueCupByes;
  document.getElementById("compDrawCupBtn").onclick = drawCompetitionCup;
  document.getElementById("compDeleteCupBtn").onclick = deleteCompetitionCup;
  document.getElementById("compSavePrizeBtn").onclick = saveCompetitionCupPrize;

  const active = await loadCurrentSeason(supabase);
  compSelectedSeasonId = active?.id ?? null;
  toggleLeagueCupByes();
});

function toggleLeagueCupByes() {
  const row = document.getElementById("compLeagueCupByesRow");
  row.style.display =
    document.getElementById("compCupSelect").value === "league_cup" ? "block" : "none";
}

async function getSeasonId() {
  if (compSelectedSeasonId) return compSelectedSeasonId;
  const active = await loadCurrentSeason(supabase);
  return active?.id ?? null;
}

async function drawCompetitionCup() {
  const cup = document.getElementById("compCupSelect").value;
  const seasonId = await getSeasonId();
  if (!seasonId) {
    setStatus("compCupStatus", "No active season.", false);
    return;
  }
  if (!confirm(`Draw ${cup}? This replaces any existing bracket.`)) return;

  setStatus("compCupStatus", "Drawing…");
  let result;
  if (cup === "league_cup") {
    const byes = Number(document.getElementById("compLeagueCupByes").value) || 4;
    result = await supabase.rpc("competition_draw_league_cup", {
      p_season_id: seasonId,
      p_byes: byes,
    });
  } else {
    result = await supabase.rpc("competition_draw_prestige_cup", {
      p_season_id: seasonId,
      p_cup_code: cup,
    });
  }

  if (result.error) {
    setStatus("compCupStatus", "❌ " + result.error.message, false);
    return;
  }
  const d = result.data;
  setStatus(
    "compCupStatus",
    `✅ ${cup}: ${d.clubs} clubs, ${d.byes} byes, ${d.rounds} rounds, ${d.r1_fixtures} R1 fixtures.`
  );
}

async function deleteCompetitionCup() {
  const cup = document.getElementById("compCupSelect").value;
  const seasonId = await getSeasonId();
  if (!seasonId) return;
  if (!confirm(`Delete all ${cup} fixtures and bracket?`)) return;

  const { error } = await supabase.rpc("competition_delete_cup_bracket", {
    p_season_id: seasonId,
    p_cup_code: cup,
  });
  setStatus("compCupStatus", error ? "❌ " + error.message : `✅ Deleted ${cup} bracket.`, !error);
}

async function saveCompetitionCupPrize() {
  const seasonId = await getSeasonId();
  const cup = document.getElementById("compCupSelect").value;
  const { error } = await supabase.rpc("competition_admin_set_cup_prize", {
    p_season_id: seasonId,
    p_cup_code: cup,
    p_stage: document.getElementById("compPrizeStage").value,
    p_amount: Number(document.getElementById("compPrizeAmount").value) || 0,
  });
  setStatus("compPrizeStatus", error ? "❌ " + error.message : "✅ Prize saved.", !error);
}
