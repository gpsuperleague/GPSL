import { supabase, initGlobal } from "./global.js";
import {
  loadWcCycles,
  loadQualStandings,
  loadFinalsStandings,
  loadMyNation,
  groupStandingsTable,
  WC_QUAL_GROUPS,
  WC_FINALS_GROUPS,
} from "./international.js";

const QUAL_LETTERS = "ABCDEFGHIJKL".split("");
const FINALS_LETTERS = "ABCDEFGH".split("");

function renderCycle(cycles) {
  const el = document.getElementById("cycleInfo");
  if (!el) return;
  const c = cycles[0];
  if (!c) {
    el.innerHTML =
      '<span class="empty">No World Cup cycle configured yet — admin can set this up.</span>';
    return;
  }
  el.innerHTML = `
    <b>${c.label}</b> — status: <b>${c.status}</b><br>
    Qualifying seasons: ${c.qual_season_1_label || "—"} &amp; ${c.qual_season_2_label || "—"}<br>
    Finals window: after ${c.finals_after_season_label || "—"} (season ${c.finals_after_season_ordinal || "—"})
  `;
}

function renderGroupGrid(containerId, letters, rows) {
  const el = document.getElementById(containerId);
  if (!el) return;
  if (!rows.length) {
    el.innerHTML = letters
      .map(
        (g) =>
          `<div class="intl-group-card"><h4>Group ${g}</h4><p class="empty">Not drawn yet.</p></div>`
      )
      .join("");
    return;
  }
  el.innerHTML = letters
    .map(
      (g) => `
      <div class="intl-group-card">
        <h4>Group ${g}</h4>
        ${groupStandingsTable(rows, g)}
      </div>`
    )
    .join("");
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const myNation = await loadMyNation(supabase);
  const link = document.getElementById("myNationLink");
  if (link && myNation?.code) {
    link.href = `national_team.html?nation=${encodeURIComponent(myNation.code)}`;
    link.hidden = false;
  }

  const cycles = await loadWcCycles(supabase);
  renderCycle(cycles);
  const cycleNo = cycles[0]?.cycle_no ?? null;

  const qual = await loadQualStandings(cycleNo, supabase);
  renderGroupGrid("qualGroups", QUAL_LETTERS.slice(0, WC_QUAL_GROUPS), qual);

  const finals = await loadFinalsStandings(cycleNo, supabase);
  renderGroupGrid("finalsGroups", FINALS_LETTERS.slice(0, WC_FINALS_GROUPS), finals);
});
