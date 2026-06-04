import { initAdminPage, setStatus, supabase } from "./admin_common.js";
import {
  loadCurrentSeason,
  loadSeasonRegistrations,
  DIVISION_LABELS,
  LEAGUE_DIVISIONS,
  clubsInDivision,
  slotsFromRegistrations,
  loadFixtureCountsForSeason,
} from "./competition.js";

let compFixtureSeasonId = null;
let compFixtureRegs = [];

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage("fixtures-league", "League fixtures"))) return;

  document.getElementById("compFixtureDivision").onchange = renderCompSlotTable;
  document.getElementById("compShuffleSlotsBtn").onclick = shuffleCompSlots;
  document.getElementById("compSaveSlotsBtn").onclick = saveCompSlots;
  document.getElementById("compGenerateFixturesBtn").onclick = generateCompFixtures;
  document.getElementById("compDeleteFixturesBtn").onclick = deleteCompFixtures;

  await refreshCompetitionFixturesAdmin();
});

function setCompFixtureStatus(msg, ok = true) {
  setStatus("compFixtureStatus", msg, ok);
}

async function refreshCompetitionFixturesAdmin() {
  const active = await loadCurrentSeason(supabase);
  const note = document.getElementById("compFixtureSeasonNote");

  if (!active) {
    compFixtureSeasonId = null;
    compFixtureRegs = [];
    note.textContent = "Start a competition season before generating league fixtures.";
    document.getElementById("compFixtureCounts").textContent = "";
    document.getElementById("compSlotBody").innerHTML = "";
    return;
  }

  compFixtureSeasonId = active.id;
  note.textContent = `Active season: ${active.label} (id ${active.id})`;
  compFixtureRegs = await loadSeasonRegistrations(supabase, compFixtureSeasonId);

  const counts = await loadFixtureCountsForSeason(supabase, compFixtureSeasonId);
  document.getElementById("compFixtureCounts").textContent = LEAGUE_DIVISIONS.map(
    (d) => `${DIVISION_LABELS[d]}: ${counts[d] || 0}/380`
  ).join(" · ");

  renderCompSlotTable();
}

function getCompFixtureDivision() {
  return document.getElementById("compFixtureDivision").value;
}

function renderCompSlotTable() {
  const tbody = document.getElementById("compSlotBody");
  tbody.innerHTML = "";
  if (!compFixtureSeasonId) return;

  const division = getCompFixtureDivision();
  const clubs = clubsInDivision(compFixtureRegs, division);
  const slots = slotsFromRegistrations(compFixtureRegs, division);

  for (const slot of slots) {
    const tr = document.createElement("tr");
    const options = ['<option value="">— pick club —</option>']
      .concat(
        clubs.map(
          (c) =>
            `<option value="${c.club_short_name}"${
              c.club_short_name === slot.club_short_name ? " selected" : ""
            }>${c.club_name}</option>`
        )
      )
      .join("");

    tr.innerHTML = `
          <td style="padding:8px;border:1px solid #333;width:48px;">${slot.position}</td>
          <td style="padding:8px;border:1px solid #333;">
            <select data-pos="${slot.position}" class="comp-slot-select" style="width:100%;padding:6px;background:#222;border:1px solid #444;color:#ddd;">
              ${options}
            </select>
          </td>
        `;
    tbody.appendChild(tr);
  }
}

function collectCompSlotsFromUI() {
  return [...document.querySelectorAll(".comp-slot-select")].map((sel) => ({
    position: Number(sel.dataset.pos),
    club: sel.value,
  }));
}

async function shuffleCompSlots() {
  if (!compFixtureSeasonId) return;
  const division = getCompFixtureDivision();
  setCompFixtureStatus("Shuffling…");
  const { error } = await supabase.rpc("competition_shuffle_division_slots", {
    p_season_id: compFixtureSeasonId,
    p_division: division,
  });
  if (error) {
    setCompFixtureStatus("❌ " + error.message, false);
    return;
  }
  setCompFixtureStatus("✅ Slots shuffled.");
  compFixtureRegs = await loadSeasonRegistrations(supabase, compFixtureSeasonId);
  renderCompSlotTable();
}

async function saveCompSlots() {
  if (!compFixtureSeasonId) return;
  const division = getCompFixtureDivision();
  const slots = collectCompSlotsFromUI();
  if (slots.some((s) => !s.club)) {
    setCompFixtureStatus("Fill all 20 slot dropdowns.", false);
    return;
  }
  setCompFixtureStatus("Saving…");
  const { error } = await supabase.rpc("competition_set_division_slots", {
    p_season_id: compFixtureSeasonId,
    p_division: division,
    p_slots: slots,
  });
  if (error) {
    setCompFixtureStatus("❌ " + error.message, false);
    return;
  }
  setCompFixtureStatus("✅ Slots saved.");
  compFixtureRegs = await loadSeasonRegistrations(supabase, compFixtureSeasonId);
  renderCompSlotTable();
}

async function generateCompFixtures() {
  if (!compFixtureSeasonId) return;
  const division = getCompFixtureDivision();
  const shuffle = document.getElementById("compShuffleOnGenerate").checked;
  if (
    !confirm(
      `Generate 380 fixtures for ${DIVISION_LABELS[division]}? Existing fixtures for this division will be replaced.`
    )
  ) {
    return;
  }
  setCompFixtureStatus("Generating…");
  const { data, error } = await supabase.rpc("competition_generate_league_fixtures", {
    p_season_id: compFixtureSeasonId,
    p_division: division,
    p_shuffle_slots: shuffle,
  });
  if (error) {
    setCompFixtureStatus("❌ " + error.message, false);
    return;
  }
  setCompFixtureStatus(
    `✅ Created ${data.fixtures_created} fixtures (${data.matchdays} matchdays).`
  );
  await refreshCompetitionFixturesAdmin();
}

async function deleteCompFixtures() {
  if (!compFixtureSeasonId) return;
  const division = getCompFixtureDivision();
  if (!confirm(`Delete all league fixtures for ${DIVISION_LABELS[division]}?`)) return;
  setCompFixtureStatus("Deleting…");
  const { data, error } = await supabase.rpc("competition_delete_league_fixtures", {
    p_season_id: compFixtureSeasonId,
    p_division: division,
  });
  if (error) {
    setCompFixtureStatus("❌ " + error.message, false);
    return;
  }
  setCompFixtureStatus(`✅ Deleted ${data} fixtures.`);
  await refreshCompetitionFixturesAdmin();
}
