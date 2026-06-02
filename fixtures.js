import { supabase, initGlobal } from "./global.js";
import {
  loadCurrentSeason,
  loadLeagueFixtures,
  groupFixturesByMatchday,
  formatFixtureScore,
  fixtureInvolvesClub,
  DIVISION_LABELS,
  LEAGUE_DIVISIONS,
  GPSL_MONTH_LABELS,
} from "./competition.js";

let myClubShort = null;
let currentDivision = "superleague";
let allFixtures = [];

function renderDivisionToolbar() {
  const bar = document.getElementById("divisionToolbar");
  bar.innerHTML = "";

  for (const div of LEAGUE_DIVISIONS) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = DIVISION_LABELS[div];
    btn.className = currentDivision === div ? "active" : "";
    btn.onclick = () => {
      currentDivision = div;
      renderDivisionToolbar();
      renderFixtures();
    };
    bar.appendChild(btn);
  }
}

function renderFixtures() {
  const root = document.getElementById("fixturesRoot");
  const fixtures = allFixtures.filter((f) => f.division === currentDivision);

  if (!fixtures.length) {
    root.innerHTML =
      '<p class="empty">No league fixtures for this division yet. Admin generates them from GPSL Admin.</p>';
    return;
  }

  const groups = groupFixturesByMatchday(fixtures);
  root.innerHTML = "";

  for (const { matchday, fixtures: rows } of groups) {
    const sample = rows[0];
    const monthLabel = GPSL_MONTH_LABELS[sample.gpsl_month] || sample.gpsl_month;
    const block = document.createElement("div");
    block.className = "matchday-block";

    block.innerHTML = `
      <div class="matchday-head">
        <span>Matchday ${matchday}</span>
        <span>${monthLabel} · week ${sample.week_in_month} · <span class="weather">${sample.weather || "—"}</span></span>
      </div>
      <table class="gpsl-table">
        <thead>
          <tr>
            <th>Home</th>
            <th></th>
            <th>Away</th>
          </tr>
        </thead>
        <tbody></tbody>
      </table>
    `;

    const tbody = block.querySelector("tbody");
    for (const f of rows) {
      const tr = document.createElement("tr");
      if (fixtureInvolvesClub(f, myClubShort)) tr.className = "my-fixture";
      tr.innerHTML = `
        <td>${f.home_club_name}</td>
        <td class="score">${formatFixtureScore(f)}</td>
        <td>${f.away_club_name}</td>
      `;
      tbody.appendChild(tr);
    }

    root.appendChild(block);
  }
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
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();
  myClubShort = club?.ShortName || null;

  const season = await loadCurrentSeason(supabase);
  const meta = document.getElementById("seasonMeta");

  if (!season) {
    meta.textContent = "No active competition season.";
    document.getElementById("fixturesRoot").innerHTML =
      '<p class="empty">Fixtures appear once the league admin activates a season and generates the calendar.</p>';
    return;
  }

  meta.textContent = `${season.label} · league fixtures (38 matchdays per division)`;

  if (myClubShort) {
    const { data: reg } = await supabase
      .from("competition_club_season_public")
      .select("division")
      .eq("club_short_name", myClubShort)
      .maybeSingle();
    if (reg?.division && LEAGUE_DIVISIONS.includes(reg.division)) {
      currentDivision = reg.division;
    }
  }

  allFixtures = await loadLeagueFixtures(supabase);
  renderDivisionToolbar();
  renderFixtures();
});
