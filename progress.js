import { supabase, initGlobal } from "./global.js";
import {
  loadCurrentSeason,
  loadActiveSeasonRegistrations,
  DIVISION_LABELS,
  groupByDivision,
} from "./competition.js";

const DIVISION_META = [
  {
    key: "superleague",
    title: "SuperLeague",
    zones: "Zones (Phase 2): Super8 · Plate · 16v17 playoff · Relegation",
  },
  {
    key: "championship_a",
    title: "Championship A",
    zones: "Promotion · Playoffs · Plate · Shield · Spoon",
  },
  {
    key: "championship_b",
    title: "Championship B",
    zones: "Promotion · Playoffs · Plate · Shield · Spoon",
  },
];

function renderDivisionTable(title, zones, rows, myClubShort) {
  const panel = document.createElement("div");
  panel.className = "division-panel";

  panel.innerHTML = `
    <h2>${title}</h2>
    <div class="zone-note">${zones}</div>
  `;

  if (!rows.length) {
    panel.innerHTML += `<p class="empty-msg">No clubs registered.</p>`;
    return panel;
  }

  const tbody = rows
    .map((row, idx) => {
      const mine =
        myClubShort && row.club_short_name === myClubShort ? " my-club" : "";
      return `
        <tr class="${mine.trim()}">
          <td class="pos-col">${idx + 1}</td>
          <td>${row.club_name || row.club_short_name}</td>
        </tr>
      `;
    })
    .join("");

  panel.innerHTML += `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th class="pos-col">#</th>
          <th>Club</th>
        </tr>
      </thead>
      <tbody>${tbody}</tbody>
    </table>
  `;

  return panel;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  let myClubShort = null;
  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();
  myClubShort = club?.ShortName || null;

  const season = await loadCurrentSeason(supabase);
  const meta = document.getElementById("seasonMeta");
  const grid = document.getElementById("tablesGrid");

  if (!season) {
    meta.textContent = "No active competition season yet.";
    grid.innerHTML =
      '<p class="empty-msg">The league admin will set up the season from GPSL Admin.</p>';
    return;
  }

  meta.textContent = `${season.label} · ${season.status}${
    season.started_at
      ? ` · started ${new Date(season.started_at).toLocaleDateString()}`
      : ""
  }`;

  const registrations = await loadActiveSeasonRegistrations(supabase);
  const groups = groupByDivision(registrations);

  grid.innerHTML = "";

  for (const div of DIVISION_META) {
    grid.appendChild(
      renderDivisionTable(
        div.title,
        div.zones,
        groups[div.key] || [],
        myClubShort
      )
    );
  }
});
