import { supabase, initGlobal } from "./global.js";
import {
  loadCurrentSeason,
  loadPlayerSeasonStats,
  DIVISION_LABELS,
} from "./competition.js";

const DIVISION_TITLES = {
  superleague: "SuperLeague",
  championship_a: "Championship A",
  championship_b: "Championship B",
};

let myClubShort = null;
let allRows = [];

function renderLeaderboard(containerId, rows, valueKey, formatValue) {
  const el = document.getElementById(containerId);
  if (!el) return;

  if (!rows.length) {
    el.innerHTML = '<p class="empty">No stats yet for this filter.</p>';
    return;
  }

  const top = rows.slice(0, 25);
  const body = top
    .map((r, i) => {
      const mine =
        myClubShort &&
        (r.club_short_name || "").toUpperCase() === myClubShort.toUpperCase();
      const div = r.division
        ? DIVISION_TITLES[r.division] || r.division
        : "—";
      return `
        <tr class="${mine ? "highlight" : ""}">
          <td class="num">${i + 1}</td>
          <td>${r.player_name || r.player_id}</td>
          <td>${r.club_name || r.club_short_name}</td>
          <td>${div}</td>
          <td class="num">${formatValue(r)}</td>
          <td class="num">${r.appearances ?? 0}</td>
        </tr>
      `;
    })
    .join("");

  el.innerHTML = `
    <table class="lb">
      <thead>
        <tr>
          <th>#</th>
          <th>Player</th>
          <th>Club</th>
          <th>Div</th>
          <th>${valueKey}</th>
          <th>Apps</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>
  `;
}

function filterRows(division) {
  if (!division) return [...allRows];
  return allRows.filter((r) => r.division === division);
}

function renderAll() {
  const division = document.getElementById("divisionFilter").value;
  const rows = filterRows(division);

  const byGoals = [...rows]
    .filter((r) => (r.goals || 0) > 0)
    .sort((a, b) => b.goals - a.goals || b.assists - a.assists);
  const byAssists = [...rows]
    .filter((r) => (r.assists || 0) > 0)
    .sort((a, b) => b.assists - a.assists || b.goals - a.goals);
  const byRating = [...rows]
    .filter((r) => r.avg_rating != null && (r.appearances || 0) >= 3)
    .sort((a, b) => Number(b.avg_rating) - Number(a.avg_rating));
  const byPotm = [...rows]
    .filter((r) => (r.potm_awards || 0) > 0)
    .sort((a, b) => b.potm_awards - a.potm_awards);
  const byCleanSheets = [...rows]
    .filter(
      (r) => r.stat_role === "goalkeeper" && (r.clean_sheets || 0) > 0
    )
    .sort(
      (a, b) =>
        b.clean_sheets - a.clean_sheets ||
        (b.starts || 0) - (a.starts || 0) ||
        Number(b.avg_rating || 0) - Number(a.avg_rating || 0)
    );

  renderLeaderboard("scorersTable", byGoals, "Goals", (r) => r.goals);
  renderLeaderboard("assistsTable", byAssists, "Assists", (r) => r.assists);
  renderLeaderboard("ratingsTable", byRating, "Avg", (r) =>
    Number(r.avg_rating).toFixed(2)
  );
  renderLeaderboard("potmTable", byPotm, "POTM", (r) => r.potm_awards);
  renderLeaderboard("cleanSheetsTable", byCleanSheets, "CS", (r) => r.clean_sheets);
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (club?.ShortName) myClubShort = club.ShortName;

  const season = await loadCurrentSeason(supabase);
  const meta = document.getElementById("pageMeta");
  if (!season) {
    meta.textContent = "No active competition season.";
    return;
  }
  meta.textContent = `${season.label || "Season"} — league goals, assists, ratings, POTM, and GK clean sheets`;

  allRows = await loadPlayerSeasonStats(supabase);
  document.getElementById("divisionFilter").onchange = renderAll;
  renderAll();
});
