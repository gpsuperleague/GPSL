import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();
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
let compFixtureBusy = false;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("compFixtureDivision").onchange = () => {
    renderCompSlotTable();
  };
  document.getElementById("compShuffleSlotsBtn").onclick = shuffleCompSlots;
  document.getElementById("compSaveSlotsBtn").onclick = saveCompSlots;
  document.getElementById("compGenerateFixturesBtn").onclick = generateCompFixtures;
  document.getElementById("compDeleteFixturesBtn").onclick = deleteCompFixtures;

  await refreshCompetitionFixturesAdmin();
});

function setCompFixtureStatus(msg, ok = true) {
  setStatus("compFixtureStatus", msg, ok);
}

function setCompFixtureBusy(busy, statusMsg = "") {
  compFixtureBusy = busy;
  const ids = [
    "compShuffleSlotsBtn",
    "compSaveSlotsBtn",
    "compGenerateFixturesBtn",
    "compDeleteFixturesBtn",
    "compFixtureDivision",
    "compShuffleOnGenerate",
  ];
  for (const id of ids) {
    const el = document.getElementById(id);
    if (el) el.disabled = busy;
  }
  if (statusMsg) setCompFixtureStatus(statusMsg);
}

function divisionSlotSummary(division) {
  const clubs = clubsInDivision(compFixtureRegs, division);
  const slots = slotsFromRegistrations(compFixtureRegs, division);
  const assigned = slots.filter((s) => s.club_short_name).length;
  return { clubs: clubs.length, assigned };
}

function updateCompFixtureSlotNote() {
  const note = document.getElementById("compFixtureSlotNote");
  if (!note) return;

  if (!compFixtureSeasonId) {
    note.textContent = "";
    return;
  }

  const division = getCompFixtureDivision();
  const { clubs, assigned } = divisionSlotSummary(division);
  const label = DIVISION_LABELS[division] || division;

  if (clubs === 0) {
    note.textContent = `No ${label} clubs on the active season — assign divisions (20 SL / 20 CH A / 20 CH B) before fixtures.`;
    note.style.color = "#ff8888";
    return;
  }

  note.style.color = assigned === 20 ? "#9cdc9c" : "#ffcc00";
  note.textContent =
    `${label}: ${clubs} clubs · slots assigned ${assigned}/20` +
    (assigned < 20
      ? " — use Shuffle slots or pick a club in each row, then Save slots (or Generate with shuffle checked)."
      : " — ready to generate fixtures.");
}

async function refreshCompetitionFixturesAdmin() {
  const active = await loadCurrentSeason(supabase);
  const note = document.getElementById("compFixtureSeasonNote");

  if (!active) {
    compFixtureSeasonId = null;
    compFixtureRegs = [];
    note.textContent = "Start a competition season before generating league fixtures (Kickoff → Start season).";
    document.getElementById("compFixtureCounts").textContent = "";
    updateCompFixtureSlotNote();
    renderCompSlotTable();
    return;
  }

  compFixtureSeasonId = active.id;
  note.textContent = `Active season: ${active.label} (id ${active.id})`;
  compFixtureRegs = await loadSeasonRegistrations(supabase, compFixtureSeasonId);

  const counts = await loadFixtureCountsForSeason(supabase, compFixtureSeasonId);
  document.getElementById("compFixtureCounts").textContent = LEAGUE_DIVISIONS.map(
    (d) => `${DIVISION_LABELS[d]}: ${counts[d] || 0}/380 fixtures`
  ).join(" · ");

  updateCompFixtureSlotNote();
  renderCompSlotTable();
}

function getCompFixtureDivision() {
  return document.getElementById("compFixtureDivision").value;
}

function renderCompSlotTable() {
  const tbody = document.getElementById("compSlotBody");
  tbody.innerHTML = "";

  if (!compFixtureSeasonId) {
    tbody.innerHTML =
      `<tr><td colspan="2" style="padding:12px;color:#888;">No active season — go live first.</td></tr>`;
    return;
  }

  const division = getCompFixtureDivision();
  const clubs = clubsInDivision(compFixtureRegs, division);
  const slots = slotsFromRegistrations(compFixtureRegs, division);
  const label = DIVISION_LABELS[division] || division;

  if (clubs.length === 0) {
    tbody.innerHTML =
      `<tr><td colspan="2" style="padding:12px;color:#f88;">No ${label} clubs found for this season.</td></tr>`;
    return;
  }

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

  updateCompFixtureSlotNote();
}

function collectCompSlotsFromUI() {
  return [...document.querySelectorAll(".comp-slot-select")].map((sel) => ({
    position: Number(sel.dataset.pos),
    club: sel.value,
  }));
}

async function shuffleCompSlots() {
  if (!compFixtureSeasonId || compFixtureBusy) return;
  const division = getCompFixtureDivision();
  setCompFixtureBusy(true, `Shuffling ${DIVISION_LABELS[division]} slots…`);
  const { error } = await supabase.rpc("competition_shuffle_division_slots", {
    p_season_id: compFixtureSeasonId,
    p_division: division,
  });
  setCompFixtureBusy(false);
  if (error) {
    setCompFixtureStatus("❌ " + error.message, false);
    return;
  }
  setCompFixtureStatus("✅ Slots shuffled.");
  compFixtureRegs = await loadSeasonRegistrations(supabase, compFixtureSeasonId);
  renderCompSlotTable();
}

async function saveCompSlots() {
  if (!compFixtureSeasonId || compFixtureBusy) return;
  const division = getCompFixtureDivision();
  const slots = collectCompSlotsFromUI();
  if (slots.some((s) => !s.club)) {
    setCompFixtureStatus("Fill all 20 slot dropdowns.", false);
    return;
  }
  setCompFixtureBusy(true, `Saving ${DIVISION_LABELS[division]} slots…`);
  const { error } = await supabase.rpc("competition_set_division_slots", {
    p_season_id: compFixtureSeasonId,
    p_division: division,
    p_slots: slots,
  });
  setCompFixtureBusy(false);
  if (error) {
    setCompFixtureStatus("❌ " + error.message, false);
    return;
  }
  setCompFixtureStatus("✅ Slots saved.");
  compFixtureRegs = await loadSeasonRegistrations(supabase, compFixtureSeasonId);
  renderCompSlotTable();
}

async function generateCompFixtures() {
  if (!compFixtureSeasonId || compFixtureBusy) return;
  const division = getCompFixtureDivision();
  const shuffle = document.getElementById("compShuffleOnGenerate").checked;
  if (
    !confirm(
      `Generate 380 fixtures for ${DIVISION_LABELS[division]}? Existing fixtures for this division will be replaced.`
    )
  ) {
    return;
  }
  setCompFixtureBusy(
    true,
    `Generating 380 ${DIVISION_LABELS[division]} fixtures — this can take a few seconds…`
  );
  const { data, error } = await supabase.rpc("competition_generate_league_fixtures", {
    p_season_id: compFixtureSeasonId,
    p_division: division,
    p_shuffle_slots: shuffle,
  });
  setCompFixtureBusy(false);
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
  if (!compFixtureSeasonId || compFixtureBusy) return;
  const division = getCompFixtureDivision();
  if (!confirm(`Delete all league fixtures for ${DIVISION_LABELS[division]}?`)) return;
  setCompFixtureBusy(true, `Deleting ${DIVISION_LABELS[division]} fixtures…`);
  const { data, error } = await supabase.rpc("competition_delete_league_fixtures", {
    p_season_id: compFixtureSeasonId,
    p_division: division,
  });
  setCompFixtureBusy(false);
  if (error) {
    setCompFixtureStatus("❌ " + error.message, false);
    return;
  }
  setCompFixtureStatus(`✅ Deleted ${data} fixtures.`);
  await refreshCompetitionFixturesAdmin();
}
