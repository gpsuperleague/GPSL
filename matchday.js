import { supabase, initGlobal } from "./global.js";
import {
  loadLeagueFixtures,
  loadCupFixtures,
  GPSL_MONTH_LABELS,
  fixtureInvolvesClub,
  submitFixtureResult,
  canSubmitResult,
  LEAGUE_DIVISIONS,
} from "./competition.js";
let myClub = { short: null, name: null };
let myDivision = null;
let upcomingFixtures = [];
let allLeagueFixtures = [];
let squadPlayers = [];

const MAX_STARTERS = 11;
const MAX_SUBS = 5;

/** Squad picker order on Match Day (GK → CF). */
const MATCHDAY_POSITION_ORDER = [
  "GK",
  "LB",
  "CB",
  "RB",
  "DMF",
  "LMF",
  "CMF",
  "RMF",
  "AMF",
  "LWF",
  "LW",
  "SS",
  "RWF",
  "RW",
  "CF",
];

function positionSortIndex(position) {
  const p = String(position || "").trim().toUpperCase();
  const i = MATCHDAY_POSITION_ORDER.indexOf(p);
  return i >= 0 ? i : 999;
}

function sortPlayersByPosition(players) {
  return [...players].sort((a, b) => {
    const pos = positionSortIndex(a.Position) - positionSortIndex(b.Position);
    if (pos !== 0) return pos;
    return String(a.Name || "").localeCompare(String(b.Name || ""), "en", {
      sensitivity: "base",
    });
  });
}

function setStatus(elId, msg, isError = false) {
  const el = document.getElementById(elId);
  if (!el) return;
  el.textContent = msg;
  el.style.color = isError ? "#f66" : "#ffcc00";
}

function selectedFixture() {
  const id = document.getElementById("fixtureSelect").value;
  if (!id) return null;
  return upcomingFixtures.find((f) => String(f.id) === id) || null;
}

function setScoreInputsEnabled(enabled) {
  document.getElementById("homeGoals").disabled = !enabled;
  document.getElementById("awayGoals").disabled = !enabled;
  document.getElementById("submitResultBtn").disabled = !enabled;
  for (const id of ["etHomeGoals", "etAwayGoals"]) {
    const el = document.getElementById(id);
    if (el) el.disabled = !enabled;
  }
  for (const id of ["penWinnerHome", "penWinnerAway"]) {
    const el = document.getElementById(id);
    if (el) el.disabled = !enabled;
  }
  const statsPanel = document.getElementById("playerStatsPanel");
  if (statsPanel) statsPanel.style.display = enabled ? "block" : "none";
}

function isCupFixture(fixture) {
  return fixture?.competition_type === "cup";
}

function readScoreInput(id) {
  const el = document.getElementById(id);
  if (!el || el.disabled) return NaN;
  const raw = String(el.value).trim();
  if (raw === "") return NaN;
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : NaN;
}

function clearScoreFields() {
  for (const id of ["homeGoals", "awayGoals", "etHomeGoals", "etAwayGoals"]) {
    const el = document.getElementById(id);
    if (el) el.value = "";
  }
  document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
    el.checked = false;
  });
  const preview = document.getElementById("cupOpenPlayPreview");
  if (preview) preview.textContent = "";
  const etRow = document.getElementById("cupEtRow");
  const penRow = document.getElementById("cupPenRow");
  if (etRow) etRow.style.display = "none";
  if (penRow) penRow.style.display = "none";
}

function resetCupExtraScores() {
  for (const id of ["etHomeGoals", "etAwayGoals"]) {
    const el = document.getElementById(id);
    if (el) el.value = "";
  }
  document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
    el.checked = false;
  });
  const preview = document.getElementById("cupOpenPlayPreview");
  if (preview) preview.textContent = "";
}

function updateCupScoreSections() {
  const f = selectedFixture();
  const isCup = isCupFixture(f);
  const hint = document.getElementById("scorePeriodHint");
  const etRow = document.getElementById("cupEtRow");
  const penRow = document.getElementById("cupPenRow");

  if (hint) hint.style.display = isCup ? "block" : "none";

  if (!isCup || !etRow || !penRow) {
    if (etRow) etRow.style.display = "none";
    if (penRow) penRow.style.display = "none";
    return;
  }

  const home90 = readScoreInput("homeGoals");
  const away90 = readScoreInput("awayGoals");
  const level90 =
    Number.isFinite(home90) && Number.isFinite(away90) && home90 === away90;

  if (!level90) {
    etRow.style.display = "none";
    penRow.style.display = "none";
    resetCupExtraScores();
    return;
  }

  etRow.style.display = "block";
  document.getElementById("etHomeLabel").textContent =
    document.getElementById("homeLabel").textContent + " ET";
  document.getElementById("etAwayLabel").textContent =
    document.getElementById("awayLabel").textContent + " ET";

  const etHome = readScoreInput("etHomeGoals");
  const etAway = readScoreInput("etAwayGoals");
  const etEntered = Number.isFinite(etHome) && Number.isFinite(etAway);
  const preview = document.getElementById("cupOpenPlayPreview");

  if (!etEntered) {
    penRow.style.display = "none";
    document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
      el.checked = false;
    });
    if (preview) preview.textContent = "";
    return;
  }

  const { home: homeTotal, away: awayTotal } = openPlayTotals(home90, away90, {
    etHome,
    etAway,
  });

  if (preview) {
    preview.textContent = `After extra time: ${homeTotal}–${awayTotal} (90 min was ${home90}–${away90})`;
  }

  const levelAfterOpenPlay = homeTotal === awayTotal;

  if (levelAfterOpenPlay) {
    penRow.style.display = "block";
    const homeName = document.getElementById("homeLabel").textContent;
    const awayName = document.getElementById("awayLabel").textContent;
    document.getElementById("penWinnerHomeLabel").textContent = homeName;
    document.getElementById("penWinnerAwayLabel").textContent = awayName;
  } else {
    penRow.style.display = "none";
    document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
      el.checked = false;
    });
  }
}

function readPenWinnerClub(fixture) {
  const homeRb = document.getElementById("penWinnerHome");
  const awayRb = document.getElementById("penWinnerAway");
  if (!fixture || !homeRb?.checked && !awayRb?.checked) return null;
  if (homeRb?.checked) return fixture.home_club_short_name;
  if (awayRb?.checked) return fixture.away_club_short_name;
  return null;
}

function openPlayTotals(home90, away90, cupExtra) {
  const etHome = cupExtra?.etHome;
  const etAway = cupExtra?.etAway;
  if (Number.isFinite(etHome) && Number.isFinite(etAway)) {
    return { home: etHome, away: etAway };
  }
  return { home: home90, away: away90 };
}

function validateEtNotBelow90(home90, away90, etHome, etAway) {
  if (etHome < home90 || etAway < away90) {
    return "Score after extra time cannot be less than the 90 minute score.";
  }
  return null;
}

function validateCupScores(home90, away90, cupExtra) {
  if (home90 !== away90) {
    if (
      cupExtra?.etHome != null ||
      cupExtra?.etAway != null ||
      cupExtra?.penWinner
    ) {
      return "Extra time and penalties only when level after 90 minutes.";
    }
    return null;
  }

  if (cupExtra?.etHome == null || cupExtra?.etAway == null) {
    return "Cup draw after 90 minutes — enter total score after extra time.";
  }

  const etErr = validateEtNotBelow90(home90, away90, cupExtra.etHome, cupExtra.etAway);
  if (etErr) return etErr;

  const { home, away } = openPlayTotals(home90, away90, cupExtra);
  if (home === away && !cupExtra.penWinner) {
    return "Still level after extra time — select who won the penalty shootout.";
  }
  if (home !== away && cupExtra.penWinner) {
    return "Penalty shootout only when still level after extra time.";
  }
  return null;
}

function buildCupExtraForSubmit(fixture, home90, away90) {
  if (home90 !== away90) return { cupExtra: null };

  const etHome = readScoreInput("etHomeGoals");
  const etAway = readScoreInput("etAwayGoals");
  if (!Number.isFinite(etHome) || !Number.isFinite(etAway)) {
    return { error: "Enter valid total score after extra time." };
  }

  const etErr = validateEtNotBelow90(home90, away90, etHome, etAway);
  if (etErr) return { error: etErr };

  const cupExtra = { etHome, etAway };
  const { home, away } = openPlayTotals(home90, away90, cupExtra);

  if (home === away) {
    const penWinner = readPenWinnerClub(fixture);
    if (!penWinner) {
      return { error: "Select who won the penalty shootout." };
    }
    cupExtra.penWinner = penWinner;
  }

  return { cupExtra };
}

function myTeamGoalsForFixture(fixture, homeGoals, awayGoals) {
  if (!fixture || !myClub.short) return 0;
  const home =
    (fixture.home_club_short_name || "").toUpperCase() ===
    (myClub.short || "").toUpperCase();
  return home ? homeGoals : awayGoals;
}

const DEFAULT_MATCH_RATING = "6.0";

function ratingOptionsHtml(selected) {
  let html = '<option value="">—</option>';
  for (let i = 1; i <= 100; i++) {
    const v = (i / 10).toFixed(1);
    const sel =
      selected != null && Math.abs(Number(selected) - Number(v)) < 0.001
        ? " selected"
        : "";
    html += `<option value="${v}"${sel}>${v}</option>`;
  }
  return html;
}

function wireRatingSelect(select) {
  if (!select) return;
  const applyDefault = () => {
    if (!select.value) select.value = DEFAULT_MATCH_RATING;
  };
  select.addEventListener("mousedown", applyDefault);
  select.addEventListener("focus", applyDefault);
}

function countLineupFromDom() {
  let started = 0;
  let subbed = 0;
  document.querySelectorAll("#playerStatsBody tr[data-stat-player]").forEach((tr) => {
    if (tr.querySelector(".stat-started")?.checked) started++;
    if (tr.querySelector(".stat-subbed")?.checked) subbed++;
  });
  return { started, subbed };
}

function updateLineupCounter() {
  const el = document.getElementById("lineupCounter");
  if (!el) return;

  const { started, subbed } = countLineupFromDom();
  el.textContent = `Starters: ${started}/${MAX_STARTERS} · Subs: ${subbed}/${MAX_SUBS}`;
  el.classList.remove("lineup-warn", "lineup-ok");

  if (started === MAX_STARTERS && subbed <= MAX_SUBS) {
    el.classList.add("lineup-ok");
  } else if (started > 0 || subbed > 0) {
    el.classList.add("lineup-warn");
  }

  document.querySelectorAll("#playerStatsBody tr[data-stat-player]").forEach((tr) => {
    const startCb = tr.querySelector(".stat-started");
    const subCb = tr.querySelector(".stat-subbed");
    if (startCb) startCb.disabled = !startCb.checked && started >= MAX_STARTERS;
    if (subCb) subCb.disabled = !subCb.checked && subbed >= MAX_SUBS;
  });
}

async function loadSquadPlayers() {
  if (!myClub.short) {
    squadPlayers = [];
    return;
  }
  const { data, error } = await supabase
    .from("Players")
    .select("Konami_ID, Name, Position, Rating")
    .eq("Contracted_Team", myClub.short);

  if (error) {
    console.error("loadSquadPlayers:", error);
    squadPlayers = [];
    return;
  }
  squadPlayers = sortPlayersByPosition(data || []);
}

function renderPlayerStatsTable() {
  const tbody = document.getElementById("playerStatsBody");
  if (!tbody) return;

  tbody.innerHTML = "";
  if (!squadPlayers.length) {
    tbody.innerHTML =
      '<tr><td colspan="7" style="color:#888;">No squad players found.</td></tr>';
    return;
  }

  for (const p of squadPlayers) {
    const id = String(p.Konami_ID);
    const tr = document.createElement("tr");
    tr.dataset.statPlayer = id;
    tr.innerHTML = `
      <td class="name">${p.Name} <span style="color:#666;">${p.Position || ""}</span></td>
      <td><input type="checkbox" class="stat-started" aria-label="Started"></td>
      <td><input type="checkbox" class="stat-subbed" aria-label="Subbed on"></td>
      <td><input type="number" class="stat-goals" min="0" max="20" value="0"></td>
      <td><input type="number" class="stat-assists" min="0" max="20" value="0"></td>
      <td><select class="stat-rating">${ratingOptionsHtml(null)}</select></td>
      <td><input type="radio" name="potm" class="stat-potm" value="${id}"></td>
    `;
    wirePlayedCheckboxes(tr);
    wireRatingSelect(tr.querySelector(".stat-rating"));
    tbody.appendChild(tr);
  }
  updateLineupCounter();
}

function wirePlayedCheckboxes(tr) {
  const started = tr.querySelector(".stat-started");
  const subbed = tr.querySelector(".stat-subbed");
  if (!started || !subbed) return;

  started.addEventListener("change", () => {
    if (started.checked) {
      subbed.checked = false;
      const { started: n } = countLineupFromDom();
      if (n > MAX_STARTERS) started.checked = false;
    }
    updateLineupCounter();
  });
  subbed.addEventListener("change", () => {
    if (subbed.checked) {
      started.checked = false;
      const { subbed: n } = countLineupFromDom();
      if (n > MAX_SUBS) subbed.checked = false;
    }
    updateLineupCounter();
  });
}

function collectPlayerStats() {
  const rows = document.querySelectorAll("#playerStatsBody tr[data-stat-player]");
  const out = [];
  for (const tr of rows) {
    const player_id = tr.dataset.statPlayer;
    const started = tr.querySelector(".stat-started")?.checked ?? false;
    const subbed_on = tr.querySelector(".stat-subbed")?.checked ?? false;
    const appeared = started || subbed_on;
    const goals = Number(tr.querySelector(".stat-goals")?.value) || 0;
    const assists = Number(tr.querySelector(".stat-assists")?.value) || 0;
    const ratingRaw = tr.querySelector(".stat-rating")?.value;
    const rating = ratingRaw ? Number(ratingRaw) : null;
    const potm = tr.querySelector(".stat-potm")?.checked ?? false;

    if (!appeared && goals === 0 && assists === 0 && rating == null && !potm) {
      continue;
    }

    out.push({
      player_id,
      started,
      subbed_on,
      appeared,
      goals,
      assists,
      rating: rating != null && !Number.isNaN(rating) ? rating : null,
      potm,
    });
  }
  return out;
}

function validateLineupRequired() {
  const { started, subbed } = countLineupFromDom();
  if (started !== MAX_STARTERS) {
    return `You must tick exactly ${MAX_STARTERS} players as Started (currently ${started}).`;
  }
  if (subbed > MAX_SUBS) {
    return `Maximum ${MAX_SUBS} players can be Subbed on (currently ${subbed}).`;
  }
  return null;
}

function validatePlayerStats(fixture, homeGoals, awayGoals, playerStats, cupExtra = null) {
  const totals = cupExtra
    ? openPlayTotals(homeGoals, awayGoals, cupExtra)
    : { home: homeGoals, away: awayGoals };
  const expected = myTeamGoalsForFixture(fixture, totals.home, totals.away);
  let teamGoals = 0;
  let potmCount = 0;

  const lineupErr = validateLineupRequired();
  if (lineupErr) return lineupErr;

  for (const row of playerStats) {
    teamGoals += row.goals || 0;
    if (row.potm) potmCount += 1;
    if (row.rating != null && (row.rating < 0.1 || row.rating > 10)) {
      return "Ratings must be between 0.1 and 10.";
    }
    if (row.started && row.subbed_on) {
      return "A player cannot be both started and subbed on.";
    }
    if (!row.appeared && (row.goals > 0 || row.assists > 0)) {
      return "Players with goals or assists must be started or subbed on.";
    }
    if (!row.appeared && row.potm) {
      return "Player of the Match must be started or subbed on.";
    }
  }

  if (potmCount > 1) return "Only one Player of the Match allowed.";
  if (teamGoals > 0 && teamGoals !== expected) {
    return `Player goals (${teamGoals}) must match your team score (${expected}).`;
  }
  return null;
}

function showNoFixturesHelp() {
  const el = document.getElementById("noFixturesHelp");
  if (!el) return;

  const mine = allLeagueFixtures.filter((f) => fixtureInvolvesClub(f, myClub));
  const scheduled = mine.filter((f) => f.status === "scheduled");

  if (upcomingFixtures.length > 0) {
    el.style.display = "none";
    return;
  }

  el.style.display = "block";
  if (!allLeagueFixtures.length) {
    el.innerHTML = `
      <b>No fixtures in the database.</b> Admin must activate the season and generate fixtures
      (GPSL Admin → League Fixtures) for each division.
    `;
  } else if (!mine.length) {
    el.innerHTML = `
      <b>Your club has no fixtures on the current season.</b>
      Check you are on an active season with your club in a division.
    `;
  } else if (!scheduled.length) {
    el.innerHTML = `
      <b>All your fixtures are already played or cancelled.</b>
      (${mine.length} total for your club.)
    `;
  } else {
    el.innerHTML = `
      <b>No fixtures ready to submit.</b> Open
      <a href="fixtures.html" style="color:#ff9900;">Fixtures</a> for your highlighted games.
    `;
  }

  setScoreInputsEnabled(false);
}

function updateFixturePreview() {
  const f = selectedFixture();
  const preview = document.getElementById("fixturePreview");

  if (!f) {
    preview.textContent = "Select a fixture from the list above.";
    setScoreInputsEnabled(false);
    return;
  }

  const month = GPSL_MONTH_LABELS[f.gpsl_month] || f.gpsl_month;
  let extra = "";
  if (f.submission_status === "pending") {
    if (
      f.submitted_by_club &&
      f.submitted_by_club.toUpperCase() === (myClub.short || "").toUpperCase()
    ) {
      const oppName =
        (f.home_club_short_name || "").toUpperCase() === (myClub.short || "").toUpperCase()
          ? f.away_club_name
          : f.home_club_name;
      extra = ` · Awaiting confirmation from ${oppName}`;
    } else {
      extra = ` · They submitted ${f.proposed_home_goals}–${f.proposed_away_goals} — <a href="inbox.html" style="color:#ff9900;">confirm in Inbox</a>`;
    }
  }

  preview.innerHTML = `
    <b>Matchday ${f.matchday}</b> · ${month}<br>
    ${f.home_club_name} vs ${f.away_club_name}${extra}
  `;

  document.getElementById("homeLabel").textContent = f.home_club_name;
  document.getElementById("awayLabel").textContent = f.away_club_name;

  const canSubmit = canSubmitResult(f, myClub);
  clearScoreFields();
  setScoreInputsEnabled(canSubmit);
  updateCupScoreSections();

  if (
    f.submission_id &&
    f.submitted_by_club &&
    f.submitted_by_club.toUpperCase() === (myClub.short || "").toUpperCase()
  ) {
    setStatus("submitStatus", "Result submitted — waiting for opponent.");
  } else if (f.submission_id) {
    setStatus("submitStatus", "Opponent submitted — confirm or reject in Inbox.");
  } else if (canSubmit) {
    setStatus("submitStatus", "Enter home and away goals, then submit.");
  } else {
    setStatus("submitStatus", "This fixture cannot accept a new result.");
  }
}

function populateFixtureSelect() {
  const sel = document.getElementById("fixtureSelect");
  sel.innerHTML = "";

  if (!upcomingFixtures.length) {
    sel.innerHTML = '<option value="">— no fixtures to submit —</option>';
    showNoFixturesHelp();
    updateFixturePreview();
    return;
  }

  document.getElementById("noFixturesHelp").style.display = "none";

  for (const f of upcomingFixtures) {
    const opt = document.createElement("option");
    opt.value = f.id;
    const pending =
      f.submission_status === "pending" ? " · pending" : "";
    const label =
      f.competition_type === "cup"
        ? `${(f.cup_code || "cup").toUpperCase()} R${f.cup_round}M${f.cup_match}`
        : `MD${f.matchday}`;
    opt.textContent = `${label}: ${f.home_club_name} vs ${f.away_club_name}${pending}`;
    sel.appendChild(opt);
  }

  sel.onchange = updateFixturePreview;
  updateFixturePreview();
}

async function loadUpcomingFixtures() {
  const league = await loadLeagueFixtures(supabase, myDivision);
  const cups = await loadCupFixtures(supabase);
  allLeagueFixtures = [...league, ...cups];
  upcomingFixtures = allLeagueFixtures
    .filter(
      (f) =>
        fixtureInvolvesClub(f, myClub) &&
        (f.status === "scheduled" || f.submission_status === "pending")
    )
    .sort((a, b) => {
      if (a.competition_type !== b.competition_type) {
        return a.competition_type === "cup" ? -1 : 1;
      }
      if (a.competition_type === "cup") {
        return (
          (a.cup_code || "").localeCompare(b.cup_code || "") ||
          (a.cup_round || 0) - (b.cup_round || 0) ||
          (a.cup_match || 0) - (b.cup_match || 0)
        );
      }
      return a.matchday - b.matchday;
    });
}

async function submitResult() {
  const f = selectedFixture();
  if (!f || !canSubmitResult(f, myClub)) {
    setStatus("submitStatus", "Select a fixture you can submit.", true);
    return;
  }

  const homeGoals = readScoreInput("homeGoals");
  const awayGoals = readScoreInput("awayGoals");

  if (!Number.isFinite(homeGoals) || !Number.isFinite(awayGoals)) {
    setStatus("submitStatus", "Enter both scores after 90 minutes.", true);
    return;
  }

  let cupExtra = null;
  if (isCupFixture(f)) {
    const built = buildCupExtraForSubmit(f, homeGoals, awayGoals);
    if (built?.error) {
      setStatus("submitStatus", built.error, true);
      return;
    }
    cupExtra = built?.cupExtra ?? null;
    const cupErr = validateCupScores(homeGoals, awayGoals, cupExtra || {});
    if (cupErr) {
      setStatus("submitStatus", cupErr, true);
      return;
    }
  }

  const playerStats = collectPlayerStats();
  const statsErr = validatePlayerStats(f, homeGoals, awayGoals, playerStats, cupExtra);
  if (statsErr) {
    setStatus("submitStatus", statsErr, true);
    return;
  }

  setStatus("submitStatus", "Submitting…");
  const { error } = await submitFixtureResult(
    supabase,
    f.id,
    homeGoals,
    awayGoals,
    playerStats,
    cupExtra
  );

  if (error) {
    setStatus("submitStatus", "❌ " + error.message, true);
    return;
  }

  setStatus("submitStatus", "✅ Submitted. Opponent notified via Inbox.");
  await loadUpcomingFixtures();
  populateFixtureSelect();
}

function preselectFixtureFromUrl() {
  const params = new URLSearchParams(window.location.search);
  const id = params.get("fixture");
  if (!id) return;

  const sel = document.getElementById("fixtureSelect");
  if ([...sel.options].some((o) => o.value === id)) {
    sel.value = id;
    updateFixturePreview();
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club, error: clubErr } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (clubErr) {
    console.error("Club lookup:", clubErr);
  }

  if (!club?.ShortName) {
    document.getElementById("pageMeta").innerHTML =
      "No club linked to this account. In Supabase → <b>Clubs</b>, set <b>owner_id</b> " +
      "to this user&apos;s id for the club you are playing as.";
    document.getElementById("submitPanel").style.display = "none";
    return;
  }

  myClub = { short: club.ShortName, name: club.Club };

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
      myDivision = reg.division;
    }
  }

  document.getElementById("pageMeta").textContent =
    `${club.Club} — enter scores below or on Fixtures (highlighted rows)`;

  document.getElementById("submitResultBtn").onclick = submitResult;

  for (const id of ["homeGoals", "awayGoals", "etHomeGoals", "etAwayGoals"]) {
    document.getElementById(id)?.addEventListener("input", updateCupScoreSections);
  }
  document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
    el.addEventListener("change", updateCupScoreSections);
  });

  await loadSquadPlayers();
  renderPlayerStatsTable();

  await loadUpcomingFixtures();
  populateFixtureSelect();
  preselectFixtureFromUrl();
});
