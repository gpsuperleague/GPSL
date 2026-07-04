import { supabase, initGlobal } from "./global.js";
import {
  loadLeagueFixtures,
  loadCupFixtures,
  GPSL_MONTH_LABELS,
  formatFixtureCompetition,
  fixtureInvolvesClub,
  submitFixtureResult,
  confirmFixtureResult,
  rejectFixtureResult,
  loadPendingSubmission,
  canSubmitResult,
  needsInboxConfirm,
  normalizeClubKey,
  LEAGUE_DIVISIONS,
} from "./competition.js";
import {
  loadCalendarStatus,
  calendarStatusBanner,
} from "./competition_calendar.js";
import { formatMatchConditions } from "./competition_conditions.js";
import {
  loadHolidayPlayContext,
  isFixtureHolidayPlayable,
} from "./owner_holidays.js";
import {
  initMatchdaySquadPanel,
  getDefaultStarters,
  getDefaultBenchIds,
  getSquadPlayerIds,
} from "./matchday_squad.js";
import { playerNameLinkHtml } from "./player_links.js";

let myClub = { short: null, name: null };
let calendarStatus = null;
let holidayContext = null;
let confirmMode = null;
let myDivision = null;
let upcomingFixtures = [];
let allLeagueFixtures = [];
let allSquadPlayers = [];
let squadPlayers = [];
let matchdaySquadRows = [];
let matchdayPitchLayout = null;
let matchdaySavedFormations = [];
let squadPanelApi = null;

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
  const confirming = !!confirmMode;
  const showStats = enabled || confirming;
  document.getElementById("homeGoals").disabled = !enabled || confirming;
  document.getElementById("awayGoals").disabled = !enabled || confirming;
  document.getElementById("submitResultBtn").disabled = !showStats;
  for (const id of ["etHomeGoals", "etAwayGoals"]) {
    const el = document.getElementById(id);
    if (el) el.disabled = !enabled || confirming;
  }
  for (const id of ["penWinnerHome", "penWinnerAway"]) {
    const el = document.getElementById(id);
    if (el) el.disabled = !enabled || confirming;
  }
  const statsPanel = document.getElementById("playerStatsPanel");
  if (statsPanel) statsPanel.style.display = showStats ? "block" : "none";
}

function getPendingScoreContext(fixture, submission) {
  const home90 = Number(submission?.home_goals ?? fixture?.proposed_home_goals ?? 0);
  const away90 = Number(submission?.away_goals ?? fixture?.proposed_away_goals ?? 0);
  const etRawHome = submission?.et_home_goals ?? fixture?.proposed_et_home_goals;
  const etRawAway = submission?.et_away_goals ?? fixture?.proposed_et_away_goals;
  const hasEt = etRawHome != null && etRawAway != null;
  const etHome = hasEt ? Number(etRawHome) : null;
  const etAway = hasEt ? Number(etRawAway) : null;
  const penWinner =
    submission?.pen_winner_club_short_name ?? fixture?.proposed_pen_winner_club ?? null;
  const openPlay = hasEt
    ? { home: etHome, away: etAway }
    : { home: home90, away: away90 };

  return { home90, away90, etHome, etAway, hasEt, penWinner, openPlay };
}

function penWinnerDisplayName(fixture, penWinnerClub) {
  if (!penWinnerClub || !fixture) return penWinnerClub || "";
  const penKey = normalizeClubKey(penWinnerClub);
  if (penKey === normalizeClubKey(fixture.home_club_short_name)) {
    return fixture.home_club_name;
  }
  if (penKey === normalizeClubKey(fixture.away_club_short_name)) {
    return fixture.away_club_name;
  }
  return penWinnerClub;
}

function formatProposedScoreHtml(fixture, submission) {
  if (!fixture) return "";
  const ctx = getPendingScoreContext(fixture, submission);
  if (!Number.isFinite(ctx.home90) || !Number.isFinite(ctx.away90)) return "";

  let html = `<b>Proposed result</b> (from opponent)<br>`;
  html += `90 minutes: ${fixture.home_club_name} <b>${ctx.home90}–${ctx.away90}</b> ${fixture.away_club_name}`;

  if (ctx.hasEt) {
    html += `<br>After extra time (total goals): <b>${ctx.openPlay.home}–${ctx.openPlay.away}</b>`;
  }

  if (ctx.penWinner) {
    html += `<br><b>Penalty shootout winner:</b> ${penWinnerDisplayName(fixture, ctx.penWinner)}`;
  }

  return html;
}

function myTeamGoalsForConfirm() {
  if (!confirmMode?.fixture || !myClub.short) return 0;
  const ctx = getPendingScoreContext(confirmMode.fixture, confirmMode.submission);
  return myTeamGoalsForFixture(
    confirmMode.fixture,
    ctx.openPlay.home,
    ctx.openPlay.away
  );
}

function updateConfirmStatsHint() {
  const el = document.getElementById("confirmStatsHint");
  if (!el) return;

  if (!confirmMode?.fixture) {
    el.style.display = "none";
    return;
  }

  const ctx = getPendingScoreContext(confirmMode.fixture, confirmMode.submission);
  const expected = myTeamGoalsForConfirm();
  let text = `Your player goals must total <b>${expected}</b>`;
  text += ctx.hasEt
    ? " (use the <b>after extra time</b> total for your club, not 90 min only)."
    : " (90 minute score for your club).";
  if (ctx.penWinner) {
    text += ` Match decided on penalties — winner: <b>${penWinnerDisplayName(confirmMode.fixture, ctx.penWinner)}</b> (pen goals are not counted in player stats).`;
  }
  el.innerHTML = text;
  el.style.display = "block";
}

function applyConfirmModeUI() {
  const on = !!confirmMode;
  const panelTitle = document.querySelector("#submitPanel h2");
  const panelIntro = document.querySelector("#submitPanel > p.meta");
  const scoreRow = document.getElementById("scoreEntryRow");
  const etRow = document.getElementById("cupEtRow");
  const penRow = document.getElementById("cupPenRow");
  const hint = document.getElementById("scorePeriodHint");
  const banner = document.getElementById("proposedScoreBanner");
  const confirmActions = document.getElementById("confirmActions");
  const submitBtn = document.getElementById("submitResultBtn");
  const statsHeading = document.querySelector("#playerStatsPanel h3");

  if (panelTitle) {
    panelTitle.textContent = on ? "Confirm result — your squad stats" : "Submit result";
  }
  if (panelIntro) {
    panelIntro.style.display = on ? "none" : "";
  }
  if (scoreRow) scoreRow.style.display = on ? "none" : "";
  if (hint) hint.style.display = on ? "none" : hint.style.display;
  if (etRow && on) etRow.style.display = "none";
  if (penRow && on) penRow.style.display = "none";
  if (banner) {
    banner.style.display = on ? "block" : "none";
    if (on && confirmMode?.fixture) {
      banner.innerHTML = formatProposedScoreHtml(
        confirmMode.fixture,
        confirmMode.submission
      );
    }
  }
  if (on) updateConfirmStatsHint();
  else {
    const hintEl = document.getElementById("confirmStatsHint");
    if (hintEl) hintEl.style.display = "none";
  }
  if (confirmActions) confirmActions.style.display = on ? "block" : "none";
  if (submitBtn) {
    submitBtn.textContent = on ? "Confirm result" : "Submit for confirmation";
  }
  if (statsHeading) {
    statsHeading.textContent = on
      ? "Your squad — enter match stats to confirm"
      : "Your squad — match stats";
  }
}

async function enterConfirmMode(fixture) {
  if (!fixture || !needsInboxConfirm(fixture, myClub)) {
    confirmMode = null;
    applyConfirmModeUI();
    return;
  }

  const submission = await loadPendingSubmission(supabase, fixture.submission_id);

  confirmMode = {
    submissionId: fixture.submission_id,
    fixture,
    submission,
  };
  applyConfirmModeUI();
  setScoreInputsEnabled(false);
  const statsPanel = document.getElementById("playerStatsPanel");
  if (statsPanel) statsPanel.style.display = "block";
  document.getElementById("submitResultBtn").disabled = false;
  setStatus(
    "submitStatus",
    "Check the proposed score below, enter your 11 starters and stats, then confirm."
  );
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
const STAT_COUNT_MAX = 20;

let statDatalistsReady = false;

function ensureStatDatalists() {
  if (statDatalistsReady) return;
  const ratingList = document.getElementById("statRatingList");
  if (!ratingList) return;

  for (let i = 1; i <= 100; i++) {
    ratingList.appendChild(new Option((i / 10).toFixed(1), (i / 10).toFixed(1)));
  }
  statDatalistsReady = true;
}

function statCountSelectHtml(className, ariaLabel, selected = 0) {
  const sel = Math.min(
    STAT_COUNT_MAX,
    Math.max(0, Number(selected) || 0)
  );
  let html = `<select class="${className} stat-count-select" aria-label="${ariaLabel}">`;
  for (let i = 0; i <= STAT_COUNT_MAX; i++) {
    html += `<option value="${i}"${i === sel ? " selected" : ""}>${i}</option>`;
  }
  html += "</select>";
  return html;
}

function normalizeStatCountInput(raw, max = STAT_COUNT_MAX) {
  const digits = String(raw ?? "").trim();
  if (digits === "") return 0;
  const n = parseInt(digits, 10);
  if (!Number.isFinite(n) || n < 0) return 0;
  return Math.min(max, n);
}

function normalizeRatingInput(raw) {
  const s = String(raw ?? "").trim();
  if (!s) return null;
  const n = Number(s);
  if (!Number.isFinite(n)) return null;
  const clamped = Math.min(10, Math.max(0.1, Math.round(n * 10) / 10));
  return clamped.toFixed(1);
}

/** Click/focus selects all text so a new value can be typed immediately. */
function wireSelectAllOnFocus(input) {
  if (!input || input.dataset.gpslSelectAll === "1") return;
  input.dataset.gpslSelectAll = "1";

  const selectAll = () => {
    requestAnimationFrame(() => {
      const len = (input.value ?? "").length;
      try {
        input.setSelectionRange(0, len);
      } catch {
        try {
          input.select();
        } catch {
          /* ignore */
        }
      }
    });
  };

  input.addEventListener("focus", selectAll);
  input.addEventListener("click", selectAll);
  input.addEventListener("mouseup", (e) => {
    if (document.activeElement === input) e.preventDefault();
  });
}

function wireRatingInput(input) {
  if (!input) return;
  input.addEventListener("focus", () => {
    if (!String(input.value).trim()) input.value = DEFAULT_MATCH_RATING;
  });
  wireSelectAllOnFocus(input);
  input.addEventListener("blur", () => {
    const norm = normalizeRatingInput(input.value);
    input.value = norm || "";
  });
  input.addEventListener("paste", () => {
    requestAnimationFrame(() => input.dispatchEvent(new Event("blur")));
  });
}

function wireAllMatchdaySelectOnFocus() {
  for (const id of [
    "homeGoals",
    "awayGoals",
    "etHomeGoals",
    "etAwayGoals",
  ]) {
    wireSelectAllOnFocus(document.getElementById(id));
  }
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

function shuffleArray(items) {
  const arr = [...items];
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}

function expectedTeamGoalsForStats() {
  if (confirmMode?.fixture) {
    return myTeamGoalsForConfirm();
  }

  const f = selectedFixture();
  if (!f) return null;

  const homeGoals = readScoreInput("homeGoals");
  const awayGoals = readScoreInput("awayGoals");
  if (!Number.isFinite(homeGoals) || !Number.isFinite(awayGoals)) {
    return null;
  }

  let cupExtra = null;
  if (isCupFixture(f) && homeGoals === awayGoals) {
    const etHome = readScoreInput("etHomeGoals");
    const etAway = readScoreInput("etAwayGoals");
    if (!Number.isFinite(etHome) || !Number.isFinite(etAway)) {
      return null;
    }
    cupExtra = { etHome, etAway };
  }

  const totals = cupExtra
    ? openPlayTotals(homeGoals, awayGoals, cupExtra)
    : { home: homeGoals, away: awayGoals };
  return myTeamGoalsForFixture(f, totals.home, totals.away);
}

function distributeCountAcross(total, keys) {
  const map = new Map(keys.map((k) => [k, 0]));
  if (total <= 0 || !keys.length) return map;

  for (let i = 0; i < total; i++) {
    const key = keys[Math.floor(Math.random() * keys.length)];
    map.set(key, (map.get(key) || 0) + 1);
  }
  return map;
}

function resetPlayerStatsDom() {
  document.querySelectorAll("#playerStatsBody tr[data-stat-player]").forEach((tr) => {
    const started = tr.querySelector(".stat-started");
    const subbed = tr.querySelector(".stat-subbed");
    if (started) started.checked = false;
    if (subbed) subbed.checked = false;
    const goals = tr.querySelector(".stat-goals");
    const assists = tr.querySelector(".stat-assists");
    const rating = tr.querySelector(".stat-rating");
    const potm = tr.querySelector(".stat-potm");
    if (goals) goals.value = "0";
    if (assists) assists.value = "0";
    if (rating) rating.value = "";
    if (potm) potm.checked = false;
  });
}

function fillTestMatchStats() {
  const rows = [...document.querySelectorAll("#playerStatsBody tr[data-stat-player]")];
  if (!rows.length) {
    setStatus("submitStatus", "No squad players to fill.", true);
    return;
  }

  const expectedGoals = expectedTeamGoalsForStats();
  if (expectedGoals === null) {
    const msg = confirmMode
      ? "Select a fixture awaiting your confirm."
      : "Enter the match score first (and extra time if cup level after 90).";
    setStatus("submitStatus", msg, true);
    return;
  }

  if (rows.length < MAX_STARTERS) {
    setStatus(
      "submitStatus",
      `Need at least ${MAX_STARTERS} squad players (have ${rows.length}).`,
      true
    );
    return;
  }

  resetPlayerStatsDom();

  const shuffled = shuffleArray(rows.map((tr) => tr.dataset.statPlayer));
  const starterIds = new Set(shuffled.slice(0, MAX_STARTERS));
  const subIds = new Set(
    shuffled.slice(MAX_STARTERS, MAX_STARTERS + MAX_SUBS)
  );
  const appearedIds = [...starterIds, ...subIds];

  for (const tr of rows) {
    const id = tr.dataset.statPlayer;
    const started = tr.querySelector(".stat-started");
    const subbed = tr.querySelector(".stat-subbed");
    const rating = tr.querySelector(".stat-rating");

    if (starterIds.has(id)) {
      if (started) started.checked = true;
      if (rating) rating.value = DEFAULT_MATCH_RATING;
    } else if (subIds.has(id)) {
      if (subbed) subbed.checked = true;
      if (rating) rating.value = DEFAULT_MATCH_RATING;
    }
  }

  const goalMap = distributeCountAcross(expectedGoals, appearedIds);
  const assistTotal =
    expectedGoals > 0
      ? Math.floor(Math.random() * (expectedGoals + 1))
      : 0;
  const assistMap = distributeCountAcross(assistTotal, appearedIds);

  for (const tr of rows) {
    const id = tr.dataset.statPlayer;
    const goals = tr.querySelector(".stat-goals");
    const assists = tr.querySelector(".stat-assists");
    if (goals) goals.value = String(goalMap.get(id) || 0);
    if (assists) assists.value = String(assistMap.get(id) || 0);
  }

  const potmId = [...starterIds][Math.floor(Math.random() * starterIds.size)];
  for (const tr of rows) {
    const potm = tr.querySelector(".stat-potm");
    if (potm) potm.checked = tr.dataset.statPlayer === potmId;
  }

  updateLineupCounter();
  setStatus(
    "submitStatus",
    `Test stats filled — 11 starters, ${subIds.size} subs, ${expectedGoals} goal(s), ratings 6.0. Review then submit/confirm.`
  );
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
    allSquadPlayers = [];
    squadPlayers = [];
    return;
  }
  const { data, error } = await supabase
    .from("Players")
    .select("Konami_ID, Name, Position, Rating")
    .eq("Contracted_Team", myClub.short);

  if (error) {
    console.error("loadSquadPlayers:", error);
    allSquadPlayers = [];
    squadPlayers = [];
    return;
  }
  allSquadPlayers = sortPlayersByPosition(data || []);
  applyMatchdaySquadFilter();
}

async function loadMatchdaySquad() {
  matchdaySquadRows = [];
  matchdayPitchLayout = null;
  matchdaySavedFormations = [];

  const [squadRes, layoutRes, formationsRes] = await Promise.all([
    supabase.from("club_matchday_squad_public").select("*"),
    supabase.from("club_matchday_pitch_layout_public").select("pitch_layout").maybeSingle(),
    supabase.from("club_matchday_saved_formation_public").select("*"),
  ]);

  if (squadRes.error) {
    if (squadRes.error.code !== "PGRST205") {
      console.error("loadMatchdaySquad:", squadRes.error);
    }
  } else {
    matchdaySquadRows = squadRes.data || [];
  }

  if (layoutRes.error) {
    if (layoutRes.error.code !== "PGRST205") {
      console.error("loadMatchdayPitchLayout:", layoutRes.error);
    }
  } else if (layoutRes.data?.pitch_layout) {
    matchdayPitchLayout = layoutRes.data.pitch_layout;
  }

  if (formationsRes.error) {
    if (formationsRes.error.code !== "PGRST205") {
      console.error("loadMatchdaySavedFormations:", formationsRes.error);
    }
  } else {
    matchdaySavedFormations = formationsRes.data || [];
  }
}

function applyMatchdaySquadFilter() {
  const ids = getSquadPlayerIds(matchdaySquadRows);
  if (!ids?.size) {
    squadPlayers = [...allSquadPlayers];
    return;
  }
  squadPlayers = allSquadPlayers.filter((p) =>
    ids.has(String(p.Konami_ID))
  );
}

function applyDefaultLineupFromSquad() {
  const starters = getDefaultStarters(matchdaySquadRows);
  if (!starters.length) return;

  for (const tr of document.querySelectorAll("#playerStatsBody tr[data-stat-player]")) {
    const id = tr.dataset.statPlayer;
    const startCb = tr.querySelector(".stat-started");
    const subCb = tr.querySelector(".stat-subbed");
    if (!startCb) continue;
    const isStarter = starters.includes(id);
    startCb.checked = isStarter;
    if (isStarter && subCb) subCb.checked = false;
  }
  updateLineupCounter();
}

async function saveMatchdayFormation(slotNo, name, pitchLayout) {
  const { data, error } = await supabase.rpc("club_save_matchday_formation", {
    p_slot_no: slotNo,
    p_name: name,
    p_pitch_layout: pitchLayout,
  });
  if (error) throw new Error(error.message);
  await loadMatchdaySquad();
  squadPanelApi?.refreshSavedFormations(matchdaySavedFormations);
  return data;
}

async function loadMatchdayFormation(slotNo) {
  const { data, error } = await supabase
    .from("club_matchday_saved_formation_public")
    .select("slot_no, name, pitch_layout")
    .eq("slot_no", slotNo)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return data;
}

async function deleteMatchdayFormation(slotNo) {
  const { data, error } = await supabase.rpc("club_delete_matchday_formation", {
    p_slot_no: slotNo,
  });
  if (error) throw new Error(error.message);
  await loadMatchdaySquad();
  squadPanelApi?.refreshSavedFormations(matchdaySavedFormations);
  return data;
}

async function saveMatchdaySquad(slots, pitchLayout = null) {
  const { data, error } = await supabase.rpc("club_save_matchday_squad", {
    p_slots: slots,
    p_pitch_layout: pitchLayout,
  });
  if (error) throw new Error(error.message);
  await loadMatchdaySquad();
  applyMatchdaySquadFilter();
  squadPanelApi?.setSavedRows(matchdaySquadRows, matchdayPitchLayout);
  renderPlayerStatsTable();
  const squadStatus = document.getElementById("squadPanelStatus");
  if (squadStatus) {
    squadStatus.textContent =
      `${matchdaySquadRows.length} players saved — stats table filtered to your 23; pitch XI auto-tick Started.`;
  }
  return data;
}

function initSquadPanel() {
  const root = document.getElementById("matchdaySquadRoot");
  if (!root) return;

  squadPanelApi = initMatchdaySquadPanel({
    root,
    allPlayers: allSquadPlayers,
    savedRows: matchdaySquadRows,
    savedPitchLayout: matchdayPitchLayout,
    savedFormations: matchdaySavedFormations,
    onSave: saveMatchdaySquad,
    onSaveFormation: saveMatchdayFormation,
    onLoadFormation: loadMatchdayFormation,
    onDeleteFormation: deleteMatchdayFormation,
    onChange: () => {},
  });
}

function setMatchdayTab(tab) {
  const squadPanel = document.getElementById("squadPanel");
  const submitPanel = document.getElementById("submitPanel");
  document.querySelectorAll(".matchday-tabs button").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.tab === tab);
  });
  if (squadPanel) {
    squadPanel.classList.toggle("active", tab === "squad");
  }
  if (submitPanel) {
    submitPanel.classList.toggle("hidden", tab !== "submit");
  }
}

function renderPlayerStatsTable() {
  const tbody = document.getElementById("playerStatsBody");
  if (!tbody) return;

  ensureStatDatalists();
  tbody.innerHTML = "";
  if (!squadPlayers.length) {
    tbody.innerHTML =
      '<tr><td colspan="7" style="color:#888;">No squad players found.</td></tr>';
    return;
  }

  const benchIds = getDefaultBenchIds(matchdaySquadRows);

  for (const p of squadPlayers) {
    const id = String(p.Konami_ID);
    const tr = document.createElement("tr");
    tr.dataset.statPlayer = id;
    if (benchIds.has(id)) tr.classList.add("squad-bench-stat");
    const benchTag = benchIds.has(id)
      ? ' <span class="squad-bench-tag">Sub</span>'
      : "";
    tr.innerHTML = `
      <td class="name">${playerNameLinkHtml(id, p.Name)} <span style="color:#666;">${p.Position || ""}</span>${benchTag}</td>
      <td><input type="checkbox" class="stat-started" aria-label="Started"></td>
      <td><input type="checkbox" class="stat-subbed" aria-label="Subbed on"></td>
      <td>${statCountSelectHtml("stat-goals", "Goals", 0)}</td>
      <td>${statCountSelectHtml("stat-assists", "Assists", 0)}</td>
      <td><input type="text" class="stat-rating stat-combo stat-rating-combo" list="statRatingList" inputmode="decimal" autocomplete="off" value="" placeholder="6.0" aria-label="Rating"></td>
      <td><input type="radio" name="potm" class="stat-potm" value="${id}"></td>
    `;
    wirePlayedCheckboxes(tr);
    wireRatingInput(tr.querySelector(".stat-rating"));
    tbody.appendChild(tr);
  }
  applyDefaultLineupFromSquad();
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
    const goals = normalizeStatCountInput(tr.querySelector(".stat-goals")?.value);
    const assists = normalizeStatCountInput(tr.querySelector(".stat-assists")?.value);
    const ratingRaw = tr.querySelector(".stat-rating")?.value;
    const ratingNorm = normalizeRatingInput(ratingRaw);
    const rating = ratingNorm ? Number(ratingNorm) : null;
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
  const expected = confirmMode
    ? myTeamGoalsForConfirm()
    : (() => {
        const totals = cupExtra
          ? openPlayTotals(homeGoals, awayGoals, cupExtra)
          : { home: homeGoals, away: awayGoals };
        return myTeamGoalsForFixture(fixture, totals.home, totals.away);
      })();
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
  } else if (calendarStatus?.calendar_configured && !calendarStatus.active_gpsl_month) {
    el.innerHTML = `
      <b>No fixtures open this GPSL month.</b> ${calendarStatusBanner(calendarStatus)}
      See <a href="fixtures.html" style="color:#ff9900;">Fixtures</a> for the full schedule.
    `;
  } else {
    el.innerHTML = `
      <b>No fixtures ready to submit.</b> Open
      <a href="fixtures.html" style="color:#ff9900;">Fixtures</a> for your highlighted games.
    `;
  }

  setScoreInputsEnabled(false);
}

async function updateFixturePreview() {
  const f = selectedFixture();
  const preview = document.getElementById("fixturePreview");

  if (!f) {
    preview.textContent = "Select a fixture from the list above.";
    setScoreInputsEnabled(false);
    confirmMode = null;
    applyConfirmModeUI();
    return;
  }

  const month = GPSL_MONTH_LABELS[f.gpsl_month] || f.gpsl_month;
  const comp = formatFixtureCompetition(f);
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
      extra = ` · They submitted ${f.proposed_home_goals}–${f.proposed_away_goals} — select here or <a href="inbox.html" style="color:#ff9900;">Inbox</a> to enter your stats and confirm`;
    }
  }

  preview.innerHTML = `
    <b>${comp}</b>${f.competition_type === "league" ? ` · Matchday ${f.matchday}` : ""} · ${month}<br>
    ${f.home_club_name} vs ${f.away_club_name}<br>
    <span style="color:#aaa;font-size:13px;">${formatMatchConditions(f)}</span>${extra}
  `;

  document.getElementById("homeLabel").textContent = f.home_club_name;
  document.getElementById("awayLabel").textContent = f.away_club_name;

  if (needsInboxConfirm(f, myClub)) {
    await enterConfirmMode(f);
    return;
  }

  confirmMode = null;
  applyConfirmModeUI();

  const canSubmit = canSubmitResult(f, myClub, calendarStatus, holidayContext);
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
    const holidayEarly =
      holidayContext &&
      isFixtureHolidayPlayable(f, myClub, holidayContext);
    setStatus(
      "submitStatus",
      holidayEarly
        ? "Holiday unlock — pre-play this match before its GPSL month opens."
        : "Enter home and away goals, then submit."
    );
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
    void updateFixturePreview();
    return;
  }

  document.getElementById("noFixturesHelp").style.display = "none";

  for (const f of upcomingFixtures) {
    const opt = document.createElement("option");
    opt.value = f.id;
    const pending =
      f.submission_status === "pending" ? " · pending" : "";
    const comp = formatFixtureCompetition(f);
    const label =
      f.competition_type === "cup"
        ? `${comp} R${f.cup_round}M${f.cup_match}`
        : `${comp} · MD${f.matchday}`;
    opt.textContent = `${label}: ${f.home_club_name} vs ${f.away_club_name}${pending}`;
    sel.appendChild(opt);
  }

  sel.onchange = () => {
    void updateFixturePreview();
  };
  void updateFixturePreview();
}

async function loadUpcomingFixtures() {
  const league = await loadLeagueFixtures(supabase, myDivision);
  const cups = await loadCupFixtures(supabase);
  allLeagueFixtures = [...league, ...cups];
  upcomingFixtures = allLeagueFixtures
    .filter((f) => {
      if (!fixtureInvolvesClub(f, myClub)) return false;
      if (f.submission_status === "pending") return true;
      if (f.status !== "scheduled") return false;
      return canSubmitResult(f, myClub, calendarStatus, holidayContext);
    })
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

async function confirmPendingResult() {
  const f = confirmMode?.fixture || selectedFixture();
  if (!f || !confirmMode) {
    setStatus("submitStatus", "Nothing to confirm.", true);
    return;
  }

  const playerStats = collectPlayerStats();
  const statsErr = validatePlayerStats(f, 0, 0, playerStats);
  if (statsErr) {
    setStatus("submitStatus", statsErr, true);
    return;
  }

  setStatus("submitStatus", "Confirming…");
  const { error } = await confirmFixtureResult(
    supabase,
    confirmMode.submissionId,
    playerStats
  );

  if (error) {
    setStatus("submitStatus", "❌ " + error.message, true);
    return;
  }

  setStatus("submitStatus", "✅ Result confirmed.");
  confirmMode = null;
  applyConfirmModeUI();
  await loadUpcomingFixtures();
  populateFixtureSelect();
}

async function rejectPendingResult() {
  if (!confirmMode?.submissionId) return;
  const reason = prompt("Reason for rejection (optional):") || null;
  setStatus("submitStatus", "Rejecting…");
  const { error } = await rejectFixtureResult(
    supabase,
    confirmMode.submissionId,
    reason
  );
  if (error) {
    setStatus("submitStatus", "❌ " + error.message, true);
    return;
  }
  setStatus("submitStatus", "Result rejected.");
  confirmMode = null;
  applyConfirmModeUI();
  await loadUpcomingFixtures();
  populateFixtureSelect();
}

async function submitResult() {
  if (confirmMode) {
    await confirmPendingResult();
    return;
  }

  const f = selectedFixture();
  if (!f || !canSubmitResult(f, myClub, calendarStatus, holidayContext)) {
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

async function preselectFixtureFromUrl() {
  const params = new URLSearchParams(window.location.search);
  const id = params.get("fixture");
  const confirmId = params.get("confirm");
  if (!id && !confirmId) return;

  const sel = document.getElementById("fixtureSelect");
  if (id && [...sel.options].some((o) => o.value === id)) {
    sel.value = id;
    await updateFixturePreview();
    return;
  }

  if (confirmId) {
    const sub = await loadPendingSubmission(supabase, Number(confirmId));
    if (sub?.fixture_id && [...sel.options].some((o) => o.value === String(sub.fixture_id))) {
      sel.value = String(sub.fixture_id);
      await updateFixturePreview();
    }
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
  document.getElementById("rejectResultBtn").onclick = rejectPendingResult;
  document.getElementById("fillTestStatsBtn")?.addEventListener("click", fillTestMatchStats);

  wireAllMatchdaySelectOnFocus();

  for (const id of ["homeGoals", "awayGoals", "etHomeGoals", "etAwayGoals"]) {
    document.getElementById(id)?.addEventListener("input", updateCupScoreSections);
  }
  document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
    el.addEventListener("change", updateCupScoreSections);
  });

  await loadSquadPlayers();
  await loadMatchdaySquad();
  applyMatchdaySquadFilter();
  initSquadPanel();
  renderPlayerStatsTable();

  document.querySelectorAll(".matchday-tabs button").forEach((btn) => {
    btn.addEventListener("click", () => setMatchdayTab(btn.dataset.tab));
  });

  const squadStatus = document.getElementById("squadPanelStatus");
  if (squadStatus) {
    if (matchdaySquadRows.length) {
      squadStatus.textContent =
        `${matchdaySquadRows.length} players in your default squad — stats table shows only these players; pitch XI auto-tick Started.`;
    } else {
      squadStatus.textContent =
        "No saved squad yet. Set your 23 on the pitch, save, then submit results on the Submit result tab.";
    }
  }

  calendarStatus = await loadCalendarStatus(supabase);
  holidayContext = await loadHolidayPlayContext();
  const calBanner = document.getElementById("calendarBanner");
  if (calBanner && calendarStatus) {
    calBanner.style.display = "block";
    calBanner.textContent = calendarStatusBanner(calendarStatus);
  }

  await loadUpcomingFixtures();
  populateFixtureSelect();
  await preselectFixtureFromUrl();
});
