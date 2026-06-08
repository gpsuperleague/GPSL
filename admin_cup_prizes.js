import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { CUP_LABELS, formatMoney, loadCurrentSeason } from "./competition.js";

primeAdminPageChrome();

const CUP_PRIZE_STAGE_LABELS = {
  appearance: "Appearance",
  r1: "Round 1",
  r2: "Round 2",
  qf: "Quarter-final",
  sf: "Semi-final",
  final: "Final",
};

let compSelectedSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("compCupSelect").onchange = loadCupPrizeConfig;
  document.getElementById("compSavePrizeBtn").onclick = saveCompetitionCupPrize;
  document.getElementById("compAwardCupPrizeBtn").onclick = awardCupRoundPrize;

  const active = await loadCurrentSeason(supabase);
  compSelectedSeasonId = active?.id ?? null;
  await loadCupPrizeConfig();
});

async function getSeasonId() {
  if (compSelectedSeasonId) return compSelectedSeasonId;
  const active = await loadCurrentSeason(supabase);
  return active?.id ?? null;
}

async function loadCupPrizeConfig() {
  const listEl = document.getElementById("compCupPrizeList");
  const seasonId = await getSeasonId();
  const cup = document.getElementById("compCupSelect").value;

  if (!listEl) return;

  if (!seasonId) {
    listEl.textContent = "No active season.";
    return;
  }

  const { data, error } = await supabase
    .from("competition_cup_prize_config_public")
    .select("stage, amount")
    .eq("season_id", seasonId)
    .eq("cup_code", cup)
    .order("stage");

  if (error) {
    listEl.textContent = `Could not load prizes — run competition_cup_prizes_fix.sql (${error.message})`;
    return;
  }

  if (!data?.length) {
    listEl.textContent = `No prizes saved for ${CUP_LABELS[cup] || cup} yet.`;
    return;
  }

  const order = ["appearance", "r1", "r2", "qf", "sf", "final"];
  const sorted = [...data].sort(
    (a, b) => order.indexOf(a.stage) - order.indexOf(b.stage)
  );

  listEl.innerHTML = sorted
    .map(
      (row) =>
        `<div><b>${CUP_PRIZE_STAGE_LABELS[row.stage] || row.stage}</b>: ${formatMoney(row.amount)}</div>`
    )
    .join("");
}

async function saveCompetitionCupPrize() {
  const seasonId = await getSeasonId();
  const cup = document.getElementById("compCupSelect").value;
  const stage = document.getElementById("compPrizeStage").value;
  const amount = Number(document.getElementById("compPrizeAmount").value) || 0;

  const { error } = await supabase.rpc("competition_admin_set_cup_prize", {
    p_season_id: seasonId,
    p_cup_code: cup,
    p_stage: stage,
    p_amount: amount,
  });

  if (error) {
    setStatus("compPrizeStatus", "❌ " + error.message, false);
    return;
  }

  await loadCupPrizeConfig();
  setStatus("compPrizeStatus", `✅ ${CUP_PRIZE_STAGE_LABELS[stage] || stage} prize saved for ${cup}.`, true);
}

async function awardCupRoundPrize() {
  const fixtureId = Number(document.getElementById("compOverrideFixtureId").value);
  const club = document.getElementById("compOverrideClub").value.trim();
  const stage = document.getElementById("compOverrideStage").value.trim();
  const note = document.getElementById("compOverrideNote").value.trim();

  if (!Number.isFinite(fixtureId) || fixtureId <= 0) {
    setStatus("compOverrideStatus", "Enter a valid fixture ID.", false);
    return;
  }
  if (!club) {
    setStatus("compOverrideStatus", "Enter club ShortName.", false);
    return;
  }

  if (!confirm(`Award cup round prize to ${club} for fixture ${fixtureId}?`)) return;

  setStatus("compOverrideStatus", "Awarding…");
  const { data, error } = await supabase.rpc("competition_admin_award_cup_round_prize", {
    p_fixture_id: fixtureId,
    p_club_short_name: club,
    p_stage: stage || null,
    p_note: note || null,
  });

  if (error) {
    setStatus("compOverrideStatus", "❌ " + error.message, false);
    return;
  }

  if (data?.paid === false) {
    setStatus(
      "compOverrideStatus",
      `Already paid for ${club} at stage ${data?.stage || stage}.`,
      false
    );
    return;
  }

  setStatus(
    "compOverrideStatus",
    `✅ Paid ${formatMoney(data?.amount)} to ${club} (${data?.stage}).`,
    true
  );
}
