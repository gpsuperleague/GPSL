import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { loadCurrentSeason } from "./competition.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";

primeAdminPageChrome();

let compSelectedSeasonId = null;
let byeContext = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadClubsMap();

  document.getElementById("compCupSelect").onchange = onCupSelectChange;
  document.getElementById("compSaveByesBtn").onclick = saveCupByes;
  document.getElementById("compDrawCupBtn").onclick = drawCompetitionCup;
  document.getElementById("compDeleteCupBtn").onclick = deleteCompetitionCup;

  const active = await loadCurrentSeason(supabase);
  compSelectedSeasonId = active?.id ?? null;

  const cupParam = new URLSearchParams(window.location.search).get("cup");
  if (cupParam) {
    const select = document.getElementById("compCupSelect");
    const valid = Array.from(select.options).some((o) => o.value === cupParam);
    if (valid) select.value = cupParam;
  }

  await onCupSelectChange();
});

async function onCupSelectChange() {
  await loadCupByePanel();
}

async function getSeasonId() {
  if (compSelectedSeasonId) return compSelectedSeasonId;
  const active = await loadCurrentSeason(supabase);
  compSelectedSeasonId = active?.id ?? null;
  return compSelectedSeasonId;
}

async function loadCupByePanel() {
  const panel = document.getElementById("compByePanel");
  const summary = document.getElementById("compByeSummary");
  const grid = document.getElementById("compByeClubGrid");
  const countEl = document.getElementById("compByeCount");
  const cup = document.getElementById("compCupSelect").value;
  const seasonId = await getSeasonId();

  setStatus("compByeStatus", "");
  byeContext = null;

  if (!seasonId) {
    panel.hidden = true;
    summary.textContent = "No active season.";
    return;
  }

  const { data, error } = await supabase.rpc("competition_cup_byes_get", {
    p_season_id: seasonId,
    p_cup_code: cup,
  });

  if (error) {
    panel.hidden = false;
    summary.textContent =
      "Could not load bye requirements — run patches/competition_cup_byes_admin.sql in Supabase.";
    grid.innerHTML = "";
    countEl.textContent = "";
    setStatus("compByeStatus", error.message, false);
    return;
  }

  byeContext = data;
  const required = Number(data?.required_byes) || 0;
  const qualified = Array.isArray(data?.qualified_clubs) ? data.qualified_clubs : [];
  const selected = new Set(
    Array.isArray(data?.selected_byes) ? data.selected_byes.map((c) => String(c).toUpperCase()) : []
  );
  const slots = Number(data?.first_round_slots) || 0;
  const r1Fixtures = Number(data?.r1_fixtures) || Math.floor(slots / 2);

  panel.hidden = false;

  if (required === 0) {
    summary.textContent = `${qualified.length} qualified clubs — first round is full (${slots} slots, ${r1Fixtures} fixtures). No byes needed.`;
    grid.innerHTML = "";
    countEl.textContent = "Ready to draw";
    countEl.className = "bye-count ready";
    document.getElementById("compSaveByesBtn").disabled = true;
    return;
  }

  document.getElementById("compSaveByesBtn").disabled = false;
  summary.textContent = `${qualified.length} qualified clubs · ${slots} first-round slots (${r1Fixtures} fixtures) → pick exactly ${required} club(s) to receive a bye into round 2.`;

  grid.innerHTML = qualified
    .map((shortName) => {
      const code = String(shortName).toUpperCase();
      const label = fullClubName(code) || code;
      const checked = selected.has(code) ? "checked" : "";
      return (
        `<label class="bye-club-option">` +
        `<input type="checkbox" class="bye-club-cb" value="${code}" ${checked}>` +
        `<span>${label}</span></label>`
      );
    })
    .join("");

  grid.querySelectorAll(".bye-club-cb").forEach((cb) => {
    cb.addEventListener("change", updateByeCountLabel);
  });

  updateByeCountLabel();
}

function getSelectedByeClubs() {
  return Array.from(document.querySelectorAll(".bye-club-cb:checked")).map((cb) => cb.value);
}

function updateByeCountLabel() {
  const countEl = document.getElementById("compByeCount");
  const required = Number(byeContext?.required_byes) || 0;
  const picked = getSelectedByeClubs().length;
  countEl.textContent = `${picked} / ${required} bye clubs selected`;
  countEl.className =
    picked === required ? "bye-count ready" : picked > required ? "bye-count warn" : "bye-count";
}

async function saveCupByes() {
  const cup = document.getElementById("compCupSelect").value;
  const seasonId = await getSeasonId();
  if (!seasonId) return;

  const clubs = getSelectedByeClubs();
  const required = Number(byeContext?.required_byes) || 0;
  if (clubs.length !== required) {
    setStatus("compByeStatus", `Select exactly ${required} bye club(s).`, false);
    return;
  }

  setStatus("compByeStatus", "Saving…");
  const { data, error } = await supabase.rpc("competition_admin_set_cup_byes", {
    p_season_id: seasonId,
    p_cup_code: cup,
    p_clubs: clubs,
  });

  if (error) {
    setStatus("compByeStatus", "❌ " + error.message, false);
    return;
  }

  byeContext = data;
  setStatus("compByeStatus", `✅ Saved ${clubs.length} bye club(s) for ${cup}.`, true);
  updateByeCountLabel();
}

async function drawCompetitionCup() {
  const cup = document.getElementById("compCupSelect").value;
  const seasonId = await getSeasonId();
  if (!seasonId) {
    setStatus("compCupStatus", "No active season.", false);
    return;
  }

  const required = Number(byeContext?.required_byes) || 0;
  const ready = byeContext?.ready_to_draw === true;
  if (required > 0 && !ready) {
    setStatus(
      "compCupStatus",
      `Save exactly ${required} bye club(s) before drawing.`,
      false
    );
    return;
  }

  if (!confirm(`Draw ${cup}? This replaces any existing bracket.`)) return;

  setStatus("compCupStatus", "Drawing…");
  const result =
    cup === "league_cup"
      ? await supabase.rpc("competition_draw_league_cup", { p_season_id: seasonId })
      : await supabase.rpc("competition_draw_prestige_cup", {
          p_season_id: seasonId,
          p_cup_code: cup,
        });

  if (result.error) {
    setStatus("compCupStatus", "❌ " + result.error.message, false);
    return;
  }
  const d = result.data;
  const byeList = Array.isArray(d?.bye_clubs) ? d.bye_clubs.join(", ") : "";
  setStatus(
    "compCupStatus",
    `✅ ${cup}: ${d.clubs} clubs, ${d.byes} byes${byeList ? ` (${byeList})` : ""}, ${d.r1_fixtures} R1 fixtures.`
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
