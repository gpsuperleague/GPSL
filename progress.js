import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, clubWithOwnerHtml } from "./clubs_lookup.js";
import {
  loadCurrentSeason,
  loadStandingsWithPrizes,
  groupStandingsByDivision,
  DIVISION_LABELS,
  LEAGUE_DIVISIONS,
  statusForPosition,
  primaryZoneKey,
  formatFormHtml,
  formatMoney,
  normalizeClubKey,
} from "./competition.js";

const DIVISION_TITLES = {
  superleague: "SuperLeague",
  championship_a: "Championship A",
  championship_b: "Championship B",
};

/** Shared column widths so all three division tables line up. */
const STANDINGS_COLGROUP = `
  <colgroup>
    <col class="col-pos" />
    <col class="col-club" />
    <col class="col-status" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-prize" />
    <col class="col-form" />
  </colgroup>`;

function renderLegend() {
  const el = document.getElementById("zoneLegend");
  const items = [
    { color: "#2ecc71", label: "Super8 / Promotion" },
    { color: "#3498db", label: "Plate / Shield" },
    { color: "#9b59b6", label: "CH Playoffs (3–6)" },
    { color: "#e67e22", label: "16v17 playoff" },
    { color: "#3498db", label: "Shield (SL 17–20)" },
    { color: "#c0392b", label: "Relegation / Spoon" },
  ];
  el.innerHTML = items
    .map(
      (i) =>
        `<span><i style="display:inline-block;width:12px;height:12px;border-radius:2px;background:${i.color};"></i> ${i.label}</span>`
    )
    .join("");
}

function gdDisplay(gd) {
  if (gd > 0) return `+${gd}`;
  return String(gd);
}

function renderStandingsTable(division, rows, myClub) {
  const panel = document.createElement("div");
  panel.className = "division-panel";

  if (!rows.length) {
    panel.innerHTML = `
      <h2>${DIVISION_TITLES[division]}</h2>
      <p class="empty-msg">No standings for this division.</p>
    `;
    return panel;
  }

  let prevZoneKey = null;
  const tbody = rows
    .map((row) => {
      const pos = row.table_position;
      const zoneKey = primaryZoneKey(division, pos);
      const zoneBoundary = prevZoneKey !== null && prevZoneKey !== zoneKey;
      prevZoneKey = zoneKey;
      const statusText = statusForPosition(division, pos).join(" · ");
      const mine =
        myClub?.short &&
        normalizeClubKey(row.club_short_name) === normalizeClubKey(myClub.short)
          ? " my-club"
          : "";

      const prizeAmt = Number(row.league_prize_amount || 0);
      const prizeTitle = row.league_prize_paid ? "Paid at end of league season" : "Projected if season ended now";
      const prizeCell =
        prizeAmt > 0
          ? `<td class="num prize-col" title="${prizeTitle}">${formatMoney(prizeAmt)}</td>`
          : `<td class="num prize-col">—</td>`;

      const leader = pos === 1 ? " row-leader" : "";

      return `
        <tr class="zone-${zoneKey}${zoneBoundary ? " zone-boundary" : ""}${leader}${mine}">
          <td class="num">${pos}</td>
          <td class="club-col">${clubWithOwnerHtml(row.club_name, row.club_short_name)}</td>
          <td class="status-col">${statusText}</td>
          <td class="num">${row.mp}</td>
          <td class="num">${row.w}</td>
          <td class="num">${row.d}</td>
          <td class="num">${row.l}</td>
          <td class="num">${row.gf}</td>
          <td class="num">${row.ga}</td>
          <td class="num">${gdDisplay(row.gd)}</td>
          <td class="num"><b>${row.pts}</b></td>
          ${prizeCell}
          <td class="form-cell">${formatFormHtml(row.form_last10)}</td>
        </tr>
      `;
    })
    .join("");

  panel.innerHTML = `
    <h2>${DIVISION_TITLES[division]}</h2>
    <table class="standings-table">
      ${STANDINGS_COLGROUP}
      <thead>
        <tr>
          <th>#</th>
          <th class="club-col">Club</th>
          <th class="status-col">Status</th>
          <th>MP</th>
          <th>W</th>
          <th>D</th>
          <th>L</th>
          <th>GF</th>
          <th>GA</th>
          <th>GD</th>
          <th>Pts</th>
          <th>Prize</th>
          <th>Form</th>
        </tr>
      </thead>
      <tbody>${tbody}</tbody>
    </table>
  `;

  panel.dataset.division = division;
  return panel;
}

let standingsGroups = {};
let myClubRef = { short: null, name: null };

function divisionFilterState() {
  const state = {};
  for (const div of LEAGUE_DIVISIONS) {
    const el = document.querySelector(`.filter-div[data-division="${div}"]`);
    state[div] = el ? el.checked : true;
  }
  return state;
}

function syncFilterAllCheckbox() {
  const allEl = document.getElementById("filterAll");
  if (!allEl) return;
  const boxes = [...document.querySelectorAll(".filter-div")];
  const checkedCount = boxes.filter((b) => b.checked).length;
  allEl.checked = checkedCount === boxes.length;
  allEl.indeterminate = checkedCount > 0 && checkedCount < boxes.length;
}

function renderTables() {
  const root = document.getElementById("tablesRoot");
  const filter = divisionFilterState();
  const visible = LEAGUE_DIVISIONS.filter((div) => filter[div]);

  root.innerHTML = "";
  if (!visible.length) {
    root.innerHTML =
      '<p class="empty-msg">No divisions selected — tick at least one table above.</p>';
    return;
  }

  for (const div of visible) {
    root.appendChild(
      renderStandingsTable(div, standingsGroups[div] || [], myClubRef)
    );
  }
}

function wireDivisionFilter() {
  const allEl = document.getElementById("filterAll");
  const divBoxes = [...document.querySelectorAll(".filter-div")];

  allEl?.addEventListener("change", () => {
    const on = allEl.checked;
    for (const box of divBoxes) box.checked = on;
    allEl.indeterminate = false;
    renderTables();
  });

  for (const box of divBoxes) {
    box.addEventListener("change", () => {
      syncFilterAllCheckbox();
      renderTables();
    });
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();
  renderLegend();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  let myClub = { short: null, name: null };
  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();
  myClubRef = { short: club?.ShortName || null, name: club?.Club || null };

  const season = await loadCurrentSeason(supabase);
  const meta = document.getElementById("seasonMeta");
  const root = document.getElementById("tablesRoot");

  if (!season) {
    meta.textContent = "No active competition season yet.";
    document.getElementById("divisionFilter")?.remove();
    root.innerHTML =
      '<p class="empty-msg">The league admin will set up the season from GPSL Admin.</p>';
    return;
  }

  meta.textContent = `${season.label} · ${season.status}${
    season.started_at
      ? ` · started ${new Date(season.started_at).toLocaleDateString()}`
      : ""
  } · 3 pts win · 1 pt draw`;

  const standings = await loadStandingsWithPrizes(supabase);
  standingsGroups = groupStandingsByDivision(standings);

  wireDivisionFilter();
  renderTables();
});
