import { supabase, initGlobal } from "./global.js";
import {
  loadCurrentSeason,
  loadLeagueFixtures,
  loadCupFixtures,
  groupFixturesByMatchday,
  CUP_CODES,
  CUP_LABELS,
  formatFixtureScore,
  fixtureInvolvesClub,
  DIVISION_LABELS,
  LEAGUE_DIVISIONS,
  GPSL_MONTH_LABELS,
  canSubmitResult,
  needsInboxConfirm,
} from "./competition.js";
import {
  loadCalendarStatus,
  calendarStatusBanner,
} from "./competition_calendar.js";
import { loadClubsMap, clubWithOwnerHtml } from "./clubs_lookup.js";
import { loadHolidayPlayContext } from "./owner_holidays.js";

let calendarStatus = null;
let holidayContext = null;

let myClub = { short: null, name: null };
let currentDivision = "superleague";
let fixtureView = "league";
let currentCup = "league_cup";
let allFixtures = [];

function matchdayUrl(fixtureId) {
  return `matchday.html?fixture=${encodeURIComponent(String(fixtureId))}`;
}

function actionCell(fixture) {
  if (!myClub.short || !fixtureInvolvesClub(fixture, myClub)) {
    return "";
  }

  if (canSubmitResult(fixture, myClub, calendarStatus, holidayContext)) {
    return `<a href="${matchdayUrl(fixture.id)}" class="btn-result" style="text-decoration:none;display:inline-block;">Enter result</a>`;
  }

  if (needsInboxConfirm(fixture, myClub)) {
    return `<a href="${matchdayUrl(fixture.id)}" class="btn-result secondary" style="text-decoration:none;display:inline-block;">Confirm result</a>`;
  }

  if (
    fixture.submission_status === "pending" &&
    fixture.submitted_by_club &&
    fixture.submitted_by_club.toUpperCase() === (myClub.short || "").toUpperCase()
  ) {
    return `<span style="color:#888;font-size:12px;">Awaiting confirm</span>`;
  }

  if (fixture.status === "played") {
    return `<span style="color:#888;font-size:12px;">Played</span>`;
  }

  return "";
}

function renderDivisionToolbar() {
  const bar = document.getElementById("divisionToolbar");
  bar.innerHTML = "";

  const leagueBtn = document.createElement("button");
  leagueBtn.type = "button";
  leagueBtn.textContent = "League";
  leagueBtn.className = fixtureView === "league" ? "active" : "";
  leagueBtn.onclick = () => {
    fixtureView = "league";
    renderDivisionToolbar();
    renderFixtures();
  };
  bar.appendChild(leagueBtn);

  const cupBtn = document.createElement("button");
  cupBtn.type = "button";
  cupBtn.textContent = "Cups";
  cupBtn.className = fixtureView === "cups" ? "active" : "";
  cupBtn.onclick = () => {
    fixtureView = "cups";
    renderDivisionToolbar();
    renderFixtures();
  };
  bar.appendChild(cupBtn);

  if (fixtureView === "cups") {
    const sel = document.createElement("select");
    for (const code of CUP_CODES) {
      const opt = document.createElement("option");
      opt.value = code;
      opt.textContent = CUP_LABELS[code] || code;
      if (code === currentCup) opt.selected = true;
      sel.appendChild(opt);
    }
    sel.onchange = () => {
      currentCup = sel.value;
      renderFixtures();
    };
    bar.appendChild(sel);
    return;
  }

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

function renderCupFixtures() {
  const root = document.getElementById("fixturesRoot");
  const fixtures = allFixtures.filter(
    (f) => f.competition_type === "cup" && f.cup_code === currentCup
  );

  if (!fixtures.length) {
    root.innerHTML =
      `<p class="empty">No ${CUP_LABELS[currentCup] || currentCup} fixtures. Draw in <b>GPSL Admin → Cup competitions</b> or see <a href="cups.html" style="color:#ff9900;">Cups</a> bracket.</p>`;
    return;
  }

  const byRound = new Map();
  for (const f of fixtures) {
    const r = f.cup_round || 0;
    if (!byRound.has(r)) byRound.set(r, []);
    byRound.get(r).push(f);
  }

  root.innerHTML = "";
  for (const round of [...byRound.keys()].sort((a, b) => a - b)) {
    const rows = byRound.get(round);
    const block = document.createElement("div");
    block.className = "matchday-block";
    block.innerHTML = `
      <div class="matchday-head"><span>Round ${round}</span></div>
      <table class="gpsl-table">
        <thead>
          <tr>
            <th>Match</th><th>Home</th><th></th><th>Away</th><th>Status</th><th class="my-actions">Your action</th>
          </tr>
        </thead>
        <tbody></tbody>
      </table>
    `;
    const tbody = block.querySelector("tbody");
    for (const f of rows) {
      const tr = document.createElement("tr");
      if (fixtureInvolvesClub(f, myClub)) tr.classList.add("my-fixture");
      tr.innerHTML = `
        <td>M${f.cup_match}</td>
        <td>${clubWithOwnerHtml(f.home_club_name, f.home_club_short_name, "block")}</td>
        <td class="score">${formatFixtureScore(f, myClub)}</td>
        <td>${clubWithOwnerHtml(f.away_club_name, f.away_club_short_name, "block")}</td>
        <td>${f.status}</td>
        <td class="my-actions">${actionCell(f)}</td>
      `;
      tbody.appendChild(tr);
    }
    root.appendChild(block);
  }
}

function renderFixtures() {
  const root = document.getElementById("fixturesRoot");

  if (fixtureView === "cups") {
    renderCupFixtures();
    return;
  }

  const fixtures = allFixtures.filter((f) => f.division === currentDivision);

  if (!fixtures.length) {
    root.innerHTML =
      '<p class="empty">No league fixtures for this division yet. Ask admin to generate fixtures in <b>GPSL Admin → League Fixtures</b>.</p>';
    return;
  }

  const groups = groupFixturesByMatchday(fixtures);
  root.innerHTML = "";

  for (const { matchday, fixtures: rows } of groups) {
    const sample = rows[0];
    const monthLabel = GPSL_MONTH_LABELS[sample.gpsl_month] || sample.gpsl_month;
    const monthLive =
      !calendarStatus?.calendar_configured ||
      calendarStatus.active_gpsl_month === sample.gpsl_month;
    const block = document.createElement("div");
    block.className = "matchday-block";

    block.innerHTML = `
      <div class="matchday-head">
        <span>Matchday ${matchday}</span>
        <span>${monthLabel} · week ${matchday} · <span class="weather">${sample.weather || "—"}</span>${monthLive ? "" : " · <span style=\"color:#888\">locked</span>"}</span>
      </div>
      <table class="gpsl-table">
        <thead>
          <tr>
            <th>Home</th>
            <th></th>
            <th>Away</th>
            <th class="my-actions">Your match</th>
          </tr>
        </thead>
        <tbody></tbody>
      </table>
    `;

    const tbody = block.querySelector("tbody");
    for (const f of rows) {
      const tr = document.createElement("tr");
      if (fixtureInvolvesClub(f, myClub)) tr.className = "my-fixture";
      tr.innerHTML = `
        <td>${clubWithOwnerHtml(f.home_club_name, f.home_club_short_name, "block")}</td>
        <td class="score">${formatFixtureScore(f, myClub)}</td>
        <td>${clubWithOwnerHtml(f.away_club_name, f.away_club_short_name, "block")}</td>
        <td class="my-actions">${actionCell(f)}</td>
      `;
      tbody.appendChild(tr);
    }

    root.appendChild(block);
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  const root = document.getElementById("fixturesRoot");
  try {
  await initGlobal();
  await loadClubsMap();

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
  myClub = { short: club?.ShortName || null, name: club?.Club || null };

  const season = await loadCurrentSeason(supabase);
  const meta = document.getElementById("seasonMeta");
  const hint = document.getElementById("fixturesHint");

  if (!season) {
    meta.textContent = "No active competition season.";
    if (hint) hint.style.display = "none";
    document.getElementById("fixturesRoot").innerHTML =
      '<p class="empty">Fixtures appear once the league admin activates a season and generates the calendar.</p>';
    return;
  }

  if (myClub.short) {
    const { data: regs } = await supabase
      .from("competition_club_season_public")
      .select("club_short_name, club_name, division");

    const key = (myClub.short || "").trim().toUpperCase();
    const reg = (regs || []).find(
      (r) => (r.club_short_name || "").trim().toUpperCase() === key
    );

    if (reg) {
      myClub.short = reg.club_short_name;
      myClub.name = reg.club_name || myClub.name;
      if (LEAGUE_DIVISIONS.includes(reg.division)) {
        currentDivision = reg.division;
      }
    }
  } else if (hint) {
    hint.textContent = "Log in with a club owner account to enter results.";
  }

  calendarStatus = await loadCalendarStatus(supabase);
  holidayContext = await loadHolidayPlayContext();
  const calEl = document.getElementById("calendarBanner");
  if (calEl && calendarStatus?.calendar_configured) {
    calEl.style.display = "block";
    calEl.textContent = calendarStatusBanner(calendarStatus);
  }

  meta.textContent = `${season.label} · ${DIVISION_LABELS[currentDivision]} · your games highlighted in gold`;

  // Load every division so toolbar can switch Super League / Champ A / Champ B.
  const league = await loadLeagueFixtures(supabase);
  const cups = await loadCupFixtures(supabase);
  allFixtures = [...league, ...cups];
  if (!allFixtures.length && season) {
    const root = document.getElementById("fixturesRoot");
    root.innerHTML =
      '<p class="empty">No fixtures loaded. Check an active season and that admin generated fixtures (GPSL Admin → League Fixtures). If the browser console shows a database error, run <code>competition_phase3_matchday.sql</code> after phase 1.</p>';
  }
  renderDivisionToolbar();
  renderFixtures();

  const params = new URLSearchParams(window.location.search);
  const fixtureId = params.get("fixture");
  if (fixtureId && myClub.short) {
    const fix = allFixtures.find((f) => String(f.id) === fixtureId);
    if (
      fix &&
      (canSubmitResult(fix, myClub, calendarStatus, holidayContext) ||
        needsInboxConfirm(fix, myClub))
    ) {
      window.location = matchdayUrl(fixtureId);
      return;
    }
  }
  } catch (err) {
    console.error("fixtures init:", err);
    if (root) {
      root.innerHTML = `<p class="empty" style="color:#f88;">Fixtures failed to load: ${err.message}</p>`;
    }
    const meta = document.getElementById("seasonMeta");
    if (meta) meta.textContent = "Error loading fixtures";
  }
});
