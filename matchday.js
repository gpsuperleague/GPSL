import { supabase, initGlobal } from "./global.js";
import { initGpslInfoTips } from "./gpsl_info_tips.js";
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
  whyCantSubmitResult,
  isFixtureResultMonthOpen,
  isFixtureMonthPlayable,
  canSimulateMatchResult,
  needsInboxConfirm,
  normalizeClubKey,
  LEAGUE_DIVISIONS,
  deferredResultNote,
  leagueBadgeHtml,
} from "./competition.js?v=20261023-submit-checkin-month";
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
  loadMatchSimStatus,
  runMatchSimulation,
  formatMatchSimFailure,
} from "./match_sim_ui.js?v=20260924-sim-notice";
import { wireNetworkIncidentsPanel } from "./network_incidents_ui.js?v=20260922";
import {
  initMatchdaySquadPanel,
  getDefaultStarters,
  getDefaultBenchIds,
  getSquadPlayerIds,
} from "./matchday_squad.js?v=20261012-md-picker";
import { loadGpslFormations } from "./gpsl_formations.js?v=20260926-catalogue-xy";
import { renderMatchdaySquadRules } from "./matchday_rules.js?v=20261012-12subs";
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260806-squad-rules2";
import {
  matchConsoleStripHtml,
  pitchBehaviourPanelHtml,
  wirePitchAck,
  getMatchdayConsoleRulesCards,
} from "./matchday_console_rules.js?v=20261012-console-text2";
import { playerNameLinkHtml } from "./player_links.js";
import { fullClubName } from "./clubs_lookup.js";
import { fetchMatchdayChecklist } from "./matchday_checklist.js?v=20261020-blackbox";
import {
  loadActiveSuspensions,
  suspensionsByPlayerId,
  formatSuspensionStatusLabel,
  playerSuspendedForFixture,
  loadFixtureUnavailable,
  formatFixtureUnavailableHtml,
  unavailablePlayerIdsForClub,
  unavailableStatusByPlayerId,
  loadClubSquadDiscipline,
  injuriesByPlayerId,
} from "./player_discipline.js";

let myClub = { short: null, name: null, nation: null };
let calendarStatus = null;
let holidayContext = null;
/** @type {{ enabled: boolean, isAdmin: boolean, error: string|null }} */
let matchSimStatus = { enabled: false, isAdmin: false, error: null };
let confirmMode = null;
let myDivision = null;
let upcomingFixtures = [];
let allLeagueFixtures = [];
/** @type {Map<string, import("./player_discipline.js").ActiveSuspension[]>} */
let suspensionsByPlayer = new Map();
/** @type {Map<string, any[]>} */
let injuriesByPlayer = new Map();
/** @type {import("./player_discipline.js").FixtureUnavailablePayload|null} */
let fixtureUnavailable = null;
/** @type {Set<string>} */
let myUnavailableIds = new Set();
let allSquadPlayers = [];
let squadPlayers = [];
let matchdaySquadRows = [];
let matchdayPitchLayout = null;
let matchdaySavedFormations = [];
let squadPanelApi = null;

const MAX_STARTERS = 11;
const MAX_SUBS = 5;

/** localStorage key prefix for in-progress result entry (survives race / refresh). */
const RESULT_DRAFT_PREFIX = "gpsl_matchday_result_draft_v1:";
let resultDraftSaveTimer = null;
let resultDraftRestoreNotice = null;

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
  const connPanel = document.getElementById("connectionRatingPanel");
  if (connPanel) connPanel.style.display = showStats ? "block" : "none";
  if (!showStats) {
    const sel = document.getElementById("connectionStars");
    if (sel) sel.value = "";
    syncConnectionStarsVisual();
  }
}

const CONNECTION_STAR_LABELS = {
  5: "Perfect",
  4: "Great",
  3: "Playable",
  2: "Hard work",
  1: "Unplayable",
};

const BAD_CONNECTIONS_HANDBOOK_HREF =
  "learning_gpsl.html#matchday--bad-connections-in-match";

function syncConnectionStarsVisual() {
  const el = document.getElementById("connectionStarsVisual");
  const sel = document.getElementById("connectionStars");
  if (!el || !sel) return;
  const n = Number(sel.value);
  if (!n || n < 1 || n > 5) {
    el.textContent = "";
    return;
  }
  el.textContent = `${"★".repeat(n)}${"☆".repeat(5 - n)}  ${CONNECTION_STAR_LABELS[n] || ""}`;
}

function showUnplayableConnectionNote() {
  let overlay = document.getElementById("connectionUnplayableOverlay");
  if (!overlay) {
    overlay = document.createElement("div");
    overlay.id = "connectionUnplayableOverlay";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.setAttribute("aria-labelledby", "connectionUnplayableTitle");
    overlay.style.cssText =
      "position:fixed;inset:0;z-index:10000;display:flex;align-items:center;justify-content:center;" +
      "background:rgba(0,0,0,0.72);padding:16px;";
    overlay.innerHTML = `
      <div style="max-width:440px;width:100%;background:#1a1a1a;border:1px solid #664400;border-radius:10px;padding:18px 20px;box-shadow:0 12px 40px rgba(0,0,0,0.5);">
        <h3 id="connectionUnplayableTitle" style="margin:0 0 10px;color:#fc6;font-size:17px;">Unplayable connection</h3>
        <p style="margin:0 0 10px;color:#ddd;font-size:14px;line-height:1.45;">
          You rated this match’s connection as <b>Unplayable</b>.
          Remember: you are rating the <b>online link</b>, not your opponent.
        </p>
        <p style="margin:0 0 14px;color:#ccc;font-size:14px;line-height:1.45;">
          Matches <b>can be stopped</b> when the connection is this bad — do not feel you must finish an unplayable game.
          See the GPSL handbook for what to do next (rearrange, network report if needed).
        </p>
        <div style="display:flex;flex-wrap:wrap;gap:8px;justify-content:flex-end;">
          <a class="button secondary" href="${BAD_CONNECTIONS_HANDBOOK_HREF}" target="_blank" rel="noopener"
            style="text-decoration:none;display:inline-block;">Open handbook — bad connections</a>
          <button type="button" class="button" id="connectionUnplayableOk">Got it</button>
        </div>
      </div>`;
    document.body.appendChild(overlay);
    overlay.addEventListener("click", (e) => {
      if (e.target === overlay) overlay.remove();
    });
    overlay.querySelector("#connectionUnplayableOk")?.addEventListener("click", () => {
      overlay.remove();
    });
  }
  overlay.style.display = "flex";
}

function onConnectionStarsChange() {
  syncConnectionStarsVisual();
  if (Number(document.getElementById("connectionStars")?.value) === 1) {
    showUnplayableConnectionNote();
  }
}

function readConnectionStars() {
  const n = Number(document.getElementById("connectionStars")?.value);
  if (!Number.isFinite(n) || n < 1 || n > 5) return null;
  return n;
}

async function saveConnectionRating(fixtureId) {
  const stars = readConnectionStars();
  if (stars == null) {
    return { error: { message: "Select a connection quality rating (1–5 stars)." } };
  }
  const { data, error } = await supabase.rpc("fixture_connection_rating_upsert", {
    p_fixture_id: fixtureId,
    p_stars: stars,
  });
  if (error) return { error };
  if (data && data.ok === false) {
    return {
      error: {
        message:
          data.reason === "bad_stars"
            ? "Select a connection quality rating (1–5 stars)."
            : data.reason || "Could not save connection rating.",
      },
    };
  }
  return { data };
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
  updateOgBalanceHint();
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

/** First leg of a two-legged cup tie (Super8 / Bowl QF, etc.). */
function isTwoLegFirstLeg(fixture, allFixtures = []) {
  if (!isCupFixture(fixture) || Number(fixture.cup_leg || 1) !== 1) return false;
  if (
    allFixtures.some(
      (x) =>
        x.competition_type === "cup" &&
        x.cup_code === fixture.cup_code &&
        x.cup_round === fixture.cup_round &&
        x.cup_match === fixture.cup_match &&
        Number(x.cup_leg || 1) === 2
    )
  ) {
    return true;
  }
  // Fallback when sibling isn't in this club's open list
  return fixture.cup_code === "super8" || fixture.cup_code === "bowl";
}

function isTwoLegSecondLeg(fixture) {
  return isCupFixture(fixture) && Number(fixture.cup_leg || 1) === 2;
}

/** Aggregate from tie-home (1st-leg home) perspective after 2nd-leg open-play totals. */
function twoLegAggregate(leg1, leg2HomeOpen, leg2AwayOpen) {
  const l1h = Number(leg1?.home_goals);
  const l1a = Number(leg1?.away_goals);
  if (!Number.isFinite(l1h) || !Number.isFinite(l1a)) return null;
  return {
    tieHome: l1h + Number(leg2AwayOpen || 0),
    tieAway: l1a + Number(leg2HomeOpen || 0),
  };
}

function cupNeedsEtPens(fixture, home90, away90, leg1Companion = null) {
  if (!isCupFixture(fixture)) return false;
  if (isTwoLegFirstLeg(fixture, upcomingFixtures)) return false;
  if (isTwoLegSecondLeg(fixture)) {
    if (!leg1Companion || leg1Companion.status !== "played") return false;
    const agg = twoLegAggregate(leg1Companion, home90, away90);
    return !!agg && agg.tieHome === agg.tieAway;
  }
  return (
    Number.isFinite(home90) && Number.isFinite(away90) && home90 === away90
  );
}

let leg1CompanionFixture = null;

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

function resultDraftStorageKey(fixtureId) {
  const club = normalizeClubKey(myClub?.short || "");
  if (!fixtureId || !club) return null;
  return `${RESULT_DRAFT_PREFIX}${club}:${fixtureId}`;
}

function readResultDraft(fixtureId) {
  const key = resultDraftStorageKey(fixtureId);
  if (!key) return null;
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return null;
    const draft = JSON.parse(raw);
    if (!draft || typeof draft !== "object") return null;
    return draft;
  } catch {
    return null;
  }
}

function resultDraftHasContent(draft) {
  if (!draft || typeof draft !== "object") return false;
  if (draft.home_goals != null && String(draft.home_goals).trim() !== "") return true;
  if (draft.away_goals != null && String(draft.away_goals).trim() !== "") return true;
  if (draft.et_home_goals != null && String(draft.et_home_goals).trim() !== "") return true;
  if (draft.et_away_goals != null && String(draft.et_away_goals).trim() !== "") return true;
  if (draft.pen_winner) return true;
  if (Number(draft.opponent_own_goals) > 0) return true;
  if (draft.connection_stars != null && String(draft.connection_stars) !== "") return true;
  const stats = Array.isArray(draft.player_stats) ? draft.player_stats : [];
  return stats.some(
    (r) =>
      r?.started ||
      r?.subbed_on ||
      r?.appeared ||
      (r?.goals || 0) > 0 ||
      (r?.own_goals || 0) > 0 ||
      (r?.assists || 0) > 0 ||
      r?.potm ||
      r?.yellow_card ||
      r?.red_card ||
      (r?.rating != null && String(r.rating) !== "")
  );
}

function collectResultDraftPayload(fixtureId) {
  const fId = fixtureId ?? selectedFixture()?.id;
  if (!fId) return null;
  const pen =
    document.querySelector('input[name="penWinner"]:checked')?.value || null;
  return {
    fixture_id: Number(fId),
    saved_at: new Date().toISOString(),
    home_goals: document.getElementById("homeGoals")?.value ?? "",
    away_goals: document.getElementById("awayGoals")?.value ?? "",
    et_home_goals: document.getElementById("etHomeGoals")?.value ?? "",
    et_away_goals: document.getElementById("etAwayGoals")?.value ?? "",
    pen_winner: pen,
    opponent_own_goals: readOpponentOwnGoals(),
    connection_stars: document.getElementById("connectionStars")?.value ?? "",
    player_stats: collectPlayerStats(),
  };
}

function saveResultDraft(fixtureId = null) {
  const payload = collectResultDraftPayload(fixtureId);
  if (!payload) return false;
  if (!resultDraftHasContent(payload)) return false;
  const key = resultDraftStorageKey(payload.fixture_id);
  if (!key) return false;
  try {
    localStorage.setItem(key, JSON.stringify(payload));
    return true;
  } catch (err) {
    console.warn("saveResultDraft:", err);
    return false;
  }
}

function clearResultDraft(fixtureId) {
  const key = resultDraftStorageKey(fixtureId);
  if (!key) return;
  try {
    localStorage.removeItem(key);
  } catch {
    /* ignore */
  }
}

function scheduleResultDraftSave() {
  if (resultDraftSaveTimer) clearTimeout(resultDraftSaveTimer);
  resultDraftSaveTimer = setTimeout(() => {
    resultDraftSaveTimer = null;
    saveResultDraft();
  }, 400);
}

function applyPlayerStatsDraft(stats) {
  if (!Array.isArray(stats) || !stats.length) return false;
  const byId = new Map(stats.map((r) => [String(r.player_id), r]));
  let applied = 0;
  for (const tr of document.querySelectorAll(
    "#playerStatsBody tr[data-stat-player]"
  )) {
    const row = byId.get(String(tr.dataset.statPlayer));
    if (!row) continue;
    const started = tr.querySelector(".stat-started");
    const subbed = tr.querySelector(".stat-subbed");
    if (started && !started.disabled) started.checked = !!row.started;
    if (subbed && !subbed.disabled) subbed.checked = !!row.subbed_on;
    const goals = tr.querySelector(".stat-goals");
    const ogs = tr.querySelector(".stat-own-goals");
    const assists = tr.querySelector(".stat-assists");
    const rating = tr.querySelector(".stat-rating");
    const potm = tr.querySelector(".stat-potm");
    const yellow = tr.querySelector(".stat-yellow");
    const red = tr.querySelector(".stat-red");
    if (goals) goals.value = String(row.goals ?? 0);
    if (ogs) ogs.value = String(row.own_goals ?? 0);
    if (assists) assists.value = String(row.assists ?? 0);
    if (rating && row.rating != null) rating.value = String(row.rating);
    if (potm && !potm.disabled) potm.checked = !!row.potm;
    if (yellow && !yellow.disabled) yellow.checked = !!row.yellow_card;
    if (red && !red.disabled) red.checked = !!row.red_card;
    started?.dispatchEvent(new Event("change"));
    applied += 1;
  }
  updateLineupCounter();
  updateOgBalanceHint();
  return applied > 0;
}

function restoreResultDraft(fixtureId, { restoreScores = true } = {}) {
  const draft = readResultDraft(fixtureId);
  if (!resultDraftHasContent(draft)) return false;

  if (restoreScores && !confirmMode) {
    const setVal = (id, v) => {
      const el = document.getElementById(id);
      if (el && v != null && String(v).trim() !== "") el.value = String(v);
    };
    setVal("homeGoals", draft.home_goals);
    setVal("awayGoals", draft.away_goals);
    setVal("etHomeGoals", draft.et_home_goals);
    setVal("etAwayGoals", draft.et_away_goals);
    if (draft.pen_winner) {
      const pen = document.querySelector(
        `input[name="penWinner"][value="${draft.pen_winner}"]`
      );
      if (pen) pen.checked = true;
    }
    updateCupScoreSections();
  }

  if (draft.opponent_own_goals != null) {
    setOpponentOwnGoals(draft.opponent_own_goals);
  }
  if (draft.connection_stars != null && String(draft.connection_stars) !== "") {
    const sel = document.getElementById("connectionStars");
    if (sel) {
      sel.value = String(draft.connection_stars);
      syncConnectionStarsVisual();
    }
  }

  applyPlayerStatsDraft(draft.player_stats);
  return true;
}

function isResultAlreadyPendingError(message) {
  const m = String(message || "").toLowerCase();
  return (
    m.includes("already awaiting confirmation") ||
    m.includes("duplicate key") ||
    m.includes("one_pending") ||
    (m.includes("unique") && m.includes("pending"))
  );
}

function wireResultDraftAutosave() {
  const panel = document.getElementById("submitPanel");
  if (!panel || panel.dataset.draftAutosave === "1") return;
  panel.dataset.draftAutosave = "1";
  panel.addEventListener("input", scheduleResultDraftSave);
  panel.addEventListener("change", scheduleResultDraftSave);
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

  if (hint) {
    if (!isCup) {
      hint.style.display = "none";
    } else if (isTwoLegFirstLeg(f, upcomingFixtures)) {
      hint.style.display = "block";
      hint.innerHTML =
        "1st leg — enter the score after <b>90 minutes</b>. Draws are allowed; no extra time or penalties.";
    } else if (isTwoLegSecondLeg(f)) {
      hint.style.display = "block";
      hint.innerHTML =
        "2nd leg — enter the score after <b>90 minutes</b>. If the <b>tie is level on aggregate</b>, play a <b>5-minute</b> match with ET + pens; enter those scores here (combined with both legs).";
    } else {
      hint.style.display = "block";
      hint.innerHTML =
        "Cup knockout — enter the score after <b>90 minutes</b> first. Level → Extra Time, then pens if still level.";
    }
  }

  if (!isCup || !etRow || !penRow) {
    if (etRow) etRow.style.display = "none";
    if (penRow) penRow.style.display = "none";
    return;
  }

  const home90 = readScoreInput("homeGoals");
  const away90 = readScoreInput("awayGoals");
  const needsDecider = cupNeedsEtPens(f, home90, away90, leg1CompanionFixture);

  if (!needsDecider) {
    etRow.style.display = "none";
    penRow.style.display = "none";
    resetCupExtraScores();
    return;
  }

  etRow.style.display = "block";
  const etHint = etRow.querySelector(".stats-hint");
  if (etHint && isTwoLegSecondLeg(f)) {
    const agg = twoLegAggregate(leg1CompanionFixture, home90, away90);
    etHint.innerHTML =
      `Level on aggregate${agg ? ` (${agg.tieHome}–${agg.tieAway})` : ""} after 90 min — play a <b>5-minute</b> match with ET (+ pens if needed). ` +
      `Enter the <b>total score after extra time</b> (90 min goals carry over; e.g. 2–2 then <b>4–4</b> here). Scores combine with the 1st leg.`;
  } else if (etHint) {
    etHint.innerHTML =
      "Level after 90 min — enter the <b>total score after extra time</b> " +
      "(90 min goals carry over; e.g. 2–2 then <b>4–4</b> here, not 2–2 again).";
  }

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
    if (isTwoLegSecondLeg(f) && leg1CompanionFixture) {
      const aggEt = twoLegAggregate(leg1CompanionFixture, homeTotal, awayTotal);
      preview.textContent =
        `After extra time: ${homeTotal}–${awayTotal} (90 min was ${home90}–${away90})` +
        (aggEt ? ` · Aggregate ${aggEt.tieHome}–${aggEt.tieAway}` : "");
    } else {
      preview.textContent = `After extra time: ${homeTotal}–${awayTotal} (90 min was ${home90}–${away90})`;
    }
  }

  const stillLevel = isTwoLegSecondLeg(f)
    ? cupNeedsEtPens(f, homeTotal, awayTotal, leg1CompanionFixture)
    : homeTotal === awayTotal;

  if (stillLevel) {
    penRow.style.display = "block";
    const penHint = penRow.querySelector(".stats-hint");
    if (penHint) {
      penHint.innerHTML = isTwoLegSecondLeg(f)
        ? "Still level on aggregate after extra time — who won the <b>penalty shootout</b>?"
        : "Still level on open play — who won the <b>penalty shootout</b>?";
    }
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
  refreshMatchdayConsoleMount();
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

function validateCupScores(fixture, home90, away90, cupExtra, leg1 = null) {
  if (isTwoLegFirstLeg(fixture, upcomingFixtures)) {
    if (
      cupExtra?.etHome != null ||
      cupExtra?.etAway != null ||
      cupExtra?.penWinner
    ) {
      return "Extra time and penalties are only used in the 2nd leg (if aggregate is level).";
    }
    return null;
  }

  const needsAfter90 = cupNeedsEtPens(fixture, home90, away90, leg1);

  if (!needsAfter90) {
    if (
      cupExtra?.etHome != null ||
      cupExtra?.etAway != null ||
      cupExtra?.penWinner
    ) {
      return isTwoLegSecondLeg(fixture)
        ? "Extra time and penalties only when the tie is level on aggregate after 90 minutes."
        : "Extra time and penalties only when level after 90 minutes.";
    }
    return null;
  }

  if (cupExtra?.etHome == null || cupExtra?.etAway == null) {
    return isTwoLegSecondLeg(fixture)
      ? "Tie level on aggregate after 90 minutes — enter total score after extra time."
      : "Cup draw after 90 minutes — enter total score after extra time.";
  }

  const etErr = validateEtNotBelow90(home90, away90, cupExtra.etHome, cupExtra.etAway);
  if (etErr) return etErr;

  const { home, away } = openPlayTotals(home90, away90, cupExtra);
  const stillLevel = cupNeedsEtPens(fixture, home, away, leg1);

  if (stillLevel && !cupExtra.penWinner) {
    return isTwoLegSecondLeg(fixture)
      ? "Still level on aggregate after extra time — select who won the penalty shootout."
      : "Still level after extra time — select who won the penalty shootout.";
  }
  if (!stillLevel && cupExtra.penWinner) {
    return isTwoLegSecondLeg(fixture)
      ? "Penalty shootout only when still level on aggregate after extra time."
      : "Penalty shootout only when still level after extra time.";
  }
  return null;
}

function buildCupExtraForSubmit(fixture, home90, away90, leg1 = null) {
  if (!cupNeedsEtPens(fixture, home90, away90, leg1)) {
    return { cupExtra: null };
  }

  const etHome = readScoreInput("etHomeGoals");
  const etAway = readScoreInput("etAwayGoals");
  if (!Number.isFinite(etHome) || !Number.isFinite(etAway)) {
    return { error: "Enter valid total score after extra time." };
  }

  const etErr = validateEtNotBelow90(home90, away90, etHome, etAway);
  if (etErr) return { error: etErr };

  const cupExtra = { etHome, etAway };
  const { home, away } = openPlayTotals(home90, away90, cupExtra);

  if (cupNeedsEtPens(fixture, home, away, leg1)) {
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

const DEFAULT_MATCH_RATING = "3.0";
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

function ensureOpponentOwnGoalsSelect() {
  const sel = document.getElementById("opponentOwnGoals");
  if (!sel || sel.options.length) return;
  for (let i = 0; i <= STAT_COUNT_MAX; i++) {
    sel.appendChild(new Option(String(i), String(i)));
  }
  sel.value = "0";
  sel.addEventListener("change", updateOgBalanceHint);
}

function readOpponentOwnGoals() {
  ensureOpponentOwnGoalsSelect();
  return normalizeStatCountInput(
    document.getElementById("opponentOwnGoals")?.value
  );
}

function setOpponentOwnGoals(n) {
  ensureOpponentOwnGoalsSelect();
  const sel = document.getElementById("opponentOwnGoals");
  if (!sel) return;
  sel.value = String(
    Math.min(STAT_COUNT_MAX, Math.max(0, Number(n) || 0))
  );
}

function updateOgBalanceHint() {
  const el = document.getElementById("ogBalanceHint");
  if (!el) return;
  const expected = expectedTeamGoalsForStats();
  if (expected === null) {
    el.textContent = "";
    return;
  }
  let playerGoals = 0;
  for (const tr of document.querySelectorAll(
    "#playerStatsBody tr[data-stat-player]"
  )) {
    playerGoals += normalizeStatCountInput(
      tr.querySelector(".stat-goals")?.value
    );
  }
  const ogFor = readOpponentOwnGoals();
  const total = playerGoals + ogFor;
  if (total === expected) {
    el.textContent = `G ${playerGoals} + OG+ ${ogFor} = ${expected} ✓`;
    el.style.color = "#8c8";
  } else {
    el.textContent = `G ${playerGoals} + OG+ ${ogFor} = ${total} (need ${expected})`;
    el.style.color = "#c9a227";
  }
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
  // Rating is optional — leave blank; submit applies DEFAULT_MATCH_RATING for appeared players.
  wireSelectAllOnFocus(input);
  input.addEventListener("blur", () => {
    const raw = String(input.value ?? "").trim();
    if (!raw) {
      input.value = "";
      return;
    }
    const norm = normalizeRatingInput(raw);
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
  if (isCupFixture(f) && cupNeedsEtPens(f, homeGoals, awayGoals, leg1CompanionFixture)) {
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
  setOpponentOwnGoals(0);
  document.querySelectorAll("#playerStatsBody tr[data-stat-player]").forEach((tr) => {
    const started = tr.querySelector(".stat-started");
    const subbed = tr.querySelector(".stat-subbed");
    if (started) started.checked = false;
    if (subbed) subbed.checked = false;
    const goals = tr.querySelector(".stat-goals");
    const ownGoals = tr.querySelector(".stat-own-goals");
    const assists = tr.querySelector(".stat-assists");
    const rating = tr.querySelector(".stat-rating");
    const potm = tr.querySelector(".stat-potm");
    if (goals) goals.value = "0";
    if (ownGoals) ownGoals.value = "0";
    if (assists) assists.value = "0";
    if (rating) rating.value = "";
    if (potm) potm.checked = false;
    const yellow = tr.querySelector(".stat-yellow");
    const red = tr.querySelector(".stat-red");
    if (yellow) yellow.checked = false;
    if (red) red.checked = false;
  });
  updateOgBalanceHint();
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

  const shuffled = shuffleArray(
    rows
      .filter((tr) => !tr.querySelector(".stat-started")?.disabled)
      .map((tr) => tr.dataset.statPlayer)
  );
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
    const ownGoals = tr.querySelector(".stat-own-goals");
    const assists = tr.querySelector(".stat-assists");
    if (goals) goals.value = String(goalMap.get(id) || 0);
    if (ownGoals) ownGoals.value = "0";
    if (assists) assists.value = String(assistMap.get(id) || 0);
  }

  const potmId = [...starterIds][Math.floor(Math.random() * starterIds.size)];
  for (const tr of rows) {
    const potm = tr.querySelector(".stat-potm");
    if (potm) potm.checked = tr.dataset.statPlayer === potmId;
  }

  setOpponentOwnGoals(0);
  updateLineupCounter();
  updateOgBalanceHint();
  setStatus(
    "submitStatus",
    `Test stats filled — 11 starters, ${subIds.size} subs, ${expectedGoals} goal(s), ratings ${DEFAULT_MATCH_RATING}. Review then submit/confirm.`
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
    .select("Konami_ID, Name, Position, Rating, Age, Nation")
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
    if (!startCb || startCb.disabled) continue;
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
  void renderNextFixtureSquadCheck();
  return data;
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** "Valid for your next match vs X?" banner above the squad pitch. */
async function renderNextFixtureSquadCheck() {
  const el = document.getElementById("nextFixtureSquadCheck");
  if (!el) return;
  const { data, error } = await supabase.rpc("my_next_fixture_squad_check");
  if (error || !data?.ok || !data.has_fixture) {
    el.hidden = true;
    return;
  }
  const opp = fullClubName(data.opponent_short_name) || data.opponent_short_name;
  const vs = `${data.side === "home" ? "vs" : "at"} ${escapeHtml(opp)}`;
  const when = data.kickoff_at
    ? `kick-off ${escapeHtml(
        new Date(data.kickoff_at).toLocaleString("en-GB", {
          timeZone: "Europe/London",
          weekday: "short",
          day: "2-digit",
          month: "short",
          hour: "2-digit",
          minute: "2-digit",
        })
      )} UK`
    : "kick-off not agreed yet";
  const issues = Array.isArray(data.issues) ? data.issues.filter(Boolean) : [];
  el.hidden = false;
  if (data.squad_ready) {
    el.className = "next-fx-check ok";
    el.innerHTML = `<b>✓ Your saved squad is ready for your next match</b> — ${vs} (${when}).`;
  } else {
    el.className = "next-fx-check bad";
    el.innerHTML = `<b>Your saved squad would not pass check-in for your next match</b> — ${vs} (${when}).
      <ul>${issues.map((i) => `<li>${escapeHtml(i)}</li>`).join("")}</ul>
      Fix it below and press <b>Save default squad</b>.`;
  }
}

function initSquadPanel() {
  renderMatchdaySquadRules();
  renderRulesPanel(
    document.getElementById("matchdayConsoleRules"),
    getMatchdayConsoleRulesCards()
  );
  refreshMatchdayConsoleMount();
  const root = document.getElementById("matchdaySquadRoot");
  if (!root) return;

  squadPanelApi = initMatchdaySquadPanel({
    root,
    allPlayers: allSquadPlayers,
    savedRows: matchdaySquadRows,
    savedPitchLayout: matchdayPitchLayout,
    matchdayComposition: true,
    clubNation: myClub.nation,
    slotPicker: true,
    onSave: saveMatchdaySquad,
    onChange: () => {},
  });
}

/** Console strip + pitch ack for the selected fixture (submit tab). */
function refreshMatchdayConsoleMount() {
  const mount = document.getElementById("matchdayConsoleMount");
  if (!mount) return;
  const f = selectedFixture();
  const home90 = readScoreInput("homeGoals");
  const away90 = readScoreInput("awayGoals");
  const levelAgg =
    isTwoLegSecondLeg(f) &&
    cupNeedsEtPens(f, home90, away90, leg1CompanionFixture);
  mount.innerHTML =
    matchConsoleStripHtml({
      isCup: isCupFixture(f),
      isTwoLegFirst: isTwoLegFirstLeg(f, upcomingFixtures),
      isTwoLegSecond: isTwoLegSecondLeg(f),
      levelOnAggregate: levelAgg,
    }) +
    pitchBehaviourPanelHtml({
      fixtureId: f?.id || null,
      requireAck: !!f?.id,
    });
  wirePitchAck(mount);
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

async function loadClubSuspensions() {
  suspensionsByPlayer = new Map();
  injuriesByPlayer = new Map();
  if (!myClub.short) return;
  const [list, discipline] = await Promise.all([
    loadActiveSuspensions(supabase, { club: myClub.short }),
    loadClubSquadDiscipline(supabase, myClub.short),
  ]);
  suspensionsByPlayer = suspensionsByPlayerId(list);
  injuriesByPlayer = injuriesByPlayerId(discipline?.injuries);
  refreshSquadCardStatuses();
}

/** Red = suspended, purple = injured / recovery (matchday pitch cards). */
function refreshSquadCardStatuses() {
  const map = unavailableStatusByPlayerId(fixtureUnavailable, myClub.short);
  for (const [id, rows] of suspensionsByPlayer) {
    if (rows?.length) map.set(id, "suspended");
  }
  for (const [id, rows] of injuriesByPlayer) {
    if (map.get(id) === "suspended") continue;
    const injuredOut = (rows || []).some(
      (i) => (Number(i.matches_out_remaining) || 0) > 0 || i.phase === "out"
    );
    const recovery = (rows || []).some(
      (i) => i.phase === "recovery" || (Number(i.recovery_remaining) || 0) > 0
    );
    if (injuredOut) map.set(id, "injured");
    else if (recovery) map.set(id, "recovery");
  }
  squadPanelApi?.setPlayerStatuses(map);
}

function renderPlayerStatsTable() {
  const tbody = document.getElementById("playerStatsBody");
  if (!tbody) return;

  ensureStatDatalists();
  ensureOpponentOwnGoalsSelect();
  tbody.innerHTML = "";
  if (!squadPlayers.length) {
    tbody.innerHTML =
      '<tr><td colspan="9" style="color:#888;">No squad players found.</td></tr>';
    return;
  }

  const benchIds = getDefaultBenchIds(matchdaySquadRows);
  const fixture = selectedFixture();
  const fixtureId = fixture?.id;

  for (const p of squadPlayers) {
    const id = String(p.Konami_ID);
    const tr = document.createElement("tr");
    tr.dataset.statPlayer = id;
    if (benchIds.has(id)) tr.classList.add("squad-bench-stat");

    const suspRows = suspensionsByPlayer.get(id) || [];
    const suspendedHere =
      myUnavailableIds.has(id) ||
      playerSuspendedForFixture(suspRows, fixtureId);
    const suspLabel =
      formatSuspensionStatusLabel(suspRows) ||
      (myUnavailableIds.has(id) ? "Unavailable this match" : null);
    if (suspendedHere || suspRows.length) {
      tr.classList.add("stat-suspended");
    }

    const benchTag = benchIds.has(id)
      ? ' <span class="squad-bench-tag">Sub</span>'
      : "";
    const suspTag = suspLabel
      ? ` <span class="suspension-tag" title="${suspLabel}">${
          suspendedHere ? "Suspended this match" : suspLabel
        }</span>`
      : "";

    tr.innerHTML = `
      <td class="name">${playerNameLinkHtml(id, p.Name)} <span style="color:#666;">${p.Position || ""}</span>${benchTag}${suspTag}</td>
      <td><input type="checkbox" class="stat-started" aria-label="Started" ${suspendedHere ? "disabled" : ""}></td>
      <td><input type="checkbox" class="stat-subbed" aria-label="Subbed on" ${suspendedHere ? "disabled" : ""}></td>
      <td>${statCountSelectHtml("stat-goals", "Goals", 0)}</td>
      <td>${statCountSelectHtml("stat-own-goals", "Own goals", 0)}</td>
      <td>${statCountSelectHtml("stat-assists", "Assists", 0)}</td>
      <td><input type="text" class="stat-rating stat-combo stat-rating-combo" list="statRatingList" inputmode="decimal" autocomplete="off" value="" placeholder="opt." aria-label="Rating (optional)" ${suspendedHere ? "disabled" : ""}></td>
      <td><input type="radio" name="potm" class="stat-potm" value="${id}" ${suspendedHere ? "disabled" : ""}></td>
      <td><input type="checkbox" class="stat-yellow" aria-label="Yellow card" ${suspendedHere ? "disabled" : ""}></td>
      <td><input type="checkbox" class="stat-red" aria-label="Red card" ${suspendedHere ? "disabled" : ""}></td>
    `;
    if (!suspendedHere) {
      wirePlayedCheckboxes(tr);
      wireCardCheckboxes(tr);
    }
    wireRatingInput(tr.querySelector(".stat-rating"));
    tr.querySelector(".stat-goals")?.addEventListener("change", updateOgBalanceHint);
    tbody.appendChild(tr);
  }
  const draft = readResultDraft(fixtureId);
  if (resultDraftHasContent(draft) && Array.isArray(draft.player_stats) && draft.player_stats.length) {
    applyPlayerStatsDraft(draft.player_stats);
  } else {
    applyDefaultLineupFromSquad();
  }
  updateLineupCounter();
  updateOgBalanceHint();
}

function wireCardCheckboxes(tr) {
  const yellow = tr.querySelector(".stat-yellow");
  const red = tr.querySelector(".stat-red");
  const started = tr.querySelector(".stat-started");
  const subbed = tr.querySelector(".stat-subbed");
  const sync = () => {
    const appeared = !!(started?.checked || subbed?.checked);
    if (!appeared) {
      if (yellow) yellow.checked = false;
      if (red) red.checked = false;
    }
    if (yellow) yellow.disabled = !appeared;
    if (red) red.disabled = !appeared;
  };
  started?.addEventListener("change", sync);
  subbed?.addEventListener("change", sync);
  yellow?.addEventListener("change", sync);
  red?.addEventListener("change", sync);
  sync();
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
    const own_goals = normalizeStatCountInput(tr.querySelector(".stat-own-goals")?.value);
    const assists = normalizeStatCountInput(tr.querySelector(".stat-assists")?.value);
    const ratingRaw = tr.querySelector(".stat-rating")?.value;
    const ratingNorm = normalizeRatingInput(ratingRaw);
    let rating = ratingNorm ? Number(ratingNorm) : null;
    // Starters / introduced subs without a rating get an automatic 3.0
    if (appeared && (rating == null || Number.isNaN(rating))) {
      rating = Number(DEFAULT_MATCH_RATING);
    }
    const potm = tr.querySelector(".stat-potm")?.checked ?? false;
    const yellow_card = tr.querySelector(".stat-yellow")?.checked ?? false;
    const red_card = tr.querySelector(".stat-red")?.checked ?? false;

    if (
      !appeared &&
      goals === 0 &&
      own_goals === 0 &&
      assists === 0 &&
      rating == null &&
      !potm &&
      !yellow_card &&
      !red_card
    ) {
      continue;
    }

    out.push({
      player_id,
      started,
      subbed_on,
      appeared,
      goals,
      own_goals,
      assists,
      rating: rating != null && !Number.isNaN(rating) ? rating : null,
      potm,
      yellow_card,
      red_card,
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
    if (!row.appeared && (row.goals > 0 || row.own_goals > 0 || row.assists > 0)) {
      return "Players with goals, own goals, or assists must be started or subbed on.";
    }
    if (!row.appeared && row.potm) {
      return "Player of the Match must be started or subbed on.";
    }
    if (!row.appeared && (row.yellow_card || row.red_card)) {
      return "Players with yellow or red cards must be started or subbed on.";
    }
    const suspRows = suspensionsByPlayer.get(String(row.player_id)) || [];
    if (
      row.appeared &&
      (myUnavailableIds.has(String(row.player_id)) ||
        playerSuspendedForFixture(suspRows, fixture?.id))
    ) {
      return "A suspended or injured player cannot appear in this match.";
    }
  }

  if (potmCount > 1) return "Only one Player of the Match allowed.";
  const ogFor = readOpponentOwnGoals();
  if (teamGoals + ogFor !== expected) {
    return `Goals by your players (${teamGoals}) + opponent OGs for you (${ogFor}) must equal your team score (${expected}).`;
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

async function loadLeg1Companion(fixture) {
  leg1CompanionFixture = null;
  if (!isTwoLegSecondLeg(fixture)) return null;

  const fromList = upcomingFixtures.find(
    (x) =>
      x.competition_type === "cup" &&
      x.cup_code === fixture.cup_code &&
      x.cup_round === fixture.cup_round &&
      x.cup_match === fixture.cup_match &&
      Number(x.cup_leg || 1) === 1
  );
  if (fromList?.status === "played" && fromList.home_goals != null) {
    leg1CompanionFixture = fromList;
    return leg1CompanionFixture;
  }

  const { data, error } = await supabase
    .from("competition_fixtures_public")
    .select(
      "id, status, home_goals, away_goals, home_club_short_name, away_club_short_name, home_club_name, away_club_name, cup_code, cup_round, cup_match, cup_leg, season_id"
    )
    .eq("season_id", fixture.season_id)
    .eq("competition_type", "cup")
    .eq("cup_code", fixture.cup_code)
    .eq("cup_round", fixture.cup_round)
    .eq("cup_match", fixture.cup_match)
    .eq("cup_leg", 1)
    .maybeSingle();

  if (error) {
    console.warn("loadLeg1Companion:", error.message);
    return null;
  }
  leg1CompanionFixture = data || null;
  return leg1CompanionFixture;
}

async function updateFixturePreview() {
  const f = selectedFixture();
  const preview = document.getElementById("fixturePreview");

  if (!f) {
    preview.textContent = "Select a fixture from the list above.";
    fixtureUnavailable = null;
    myUnavailableIds = new Set();
    refreshSquadCardStatuses();
    leg1CompanionFixture = null;
    setScoreInputsEnabled(false);
    confirmMode = null;
    applyConfirmModeUI();
    const niMount = document.getElementById("networkIncidentsMount");
    if (niMount) niMount.innerHTML = "";
    return;
  }

  await loadLeg1Companion(f);

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

  let aggregateHtml = "";
  if (isTwoLegSecondLeg(f) && leg1CompanionFixture?.status === "played") {
    const l1 = leg1CompanionFixture;
    aggregateHtml =
      `<br><span style="color:#9cf;font-size:13px;">1st leg: ${l1.home_club_name || l1.home_club_short_name} ` +
      `${l1.home_goals}–${l1.away_goals} ${l1.away_club_name || l1.away_club_short_name}</span>`;
  }

  fixtureUnavailable = await loadFixtureUnavailable(supabase, f.id);
  myUnavailableIds = unavailablePlayerIdsForClub(fixtureUnavailable, myClub.short);
  refreshSquadCardStatuses();
  const unavailableHtml = formatFixtureUnavailableHtml(fixtureUnavailable, {
    homeName: f.home_club_name,
    awayName: f.away_club_name,
  });

  preview.innerHTML = `
    ${leagueBadgeHtml(f.division, { size: "sm" })}<b>${comp}</b>${f.competition_type === "league" ? ` · Matchday ${f.matchday}` : ""} · ${month}<br>
    ${f.home_club_name} vs ${f.away_club_name}<br>
    <span style="color:#aaa;font-size:13px;">${formatMatchConditions(f)}</span>${extra}${aggregateHtml}
    ${unavailableHtml}
  `;

  try {
    await wireNetworkIncidentsPanel(f, myClub.short);
  } catch (niErr) {
    console.warn("Network incidents panel:", niErr);
  }

  document.getElementById("homeLabel").textContent = f.home_club_name;
  document.getElementById("awayLabel").textContent = f.away_club_name;

  renderPlayerStatsTable();

  if (needsInboxConfirm(f, myClub)) {
    await enterConfirmMode(f);
    if (restoreResultDraft(f.id, { restoreScores: false })) {
      if (resultDraftRestoreNotice) {
        setStatus("submitStatus", resultDraftRestoreNotice);
        resultDraftRestoreNotice = null;
      } else {
        setStatus(
          "submitStatus",
          "Opponent already submitted — your saved squad stats were restored. Confirm or reject below."
        );
      }
    } else if (resultDraftRestoreNotice) {
      setStatus("submitStatus", resultDraftRestoreNotice);
      resultDraftRestoreNotice = null;
    }
    return;
  }

  confirmMode = null;
  applyConfirmModeUI();

  const canSubmit = canSubmitResult(f, myClub, calendarStatus, holidayContext);
  clearScoreFields();
  setScoreInputsEnabled(canSubmit);
  updateCupScoreSections();
  const restoredDraft = restoreResultDraft(f.id, { restoreScores: true });

  const simWrap = document.getElementById("simulateActions");
  const simBtn = document.getElementById("simulateResultBtn");
  const instantBtn = document.getElementById("instantResultBtn");
  if (simWrap) {
    const showSim =
      matchSimStatus.enabled &&
      f.status === "scheduled" &&
      !f.submission_id &&
      !needsInboxConfirm(f, myClub) &&
      fixtureInvolvesClub(f, myClub);
    const canSim =
      showSim &&
      canSimulateMatchResult(f, myClub, calendarStatus, holidayContext);
    simWrap.style.display = showSim ? "inline-flex" : "none";
    const lockTitle = canSim
      ? ""
      : "Available when this fixture’s GPSL month is active";
    if (simBtn) {
      simBtn.disabled = !canSim;
      simBtn.textContent = "Simulate match";
      simBtn.title = lockTitle;
      simBtn.classList.toggle("sim-month-locked", showSim && !canSim);
    }
    if (instantBtn) {
      instantBtn.disabled = !canSim;
      instantBtn.textContent = "Instant result";
      instantBtn.title = lockTitle;
      instantBtn.classList.toggle("sim-month-locked", showSim && !canSim);
    }
  }

  if (resultDraftRestoreNotice) {
    setStatus("submitStatus", resultDraftRestoreNotice);
    resultDraftRestoreNotice = null;
  } else if (
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
        ? "Holiday unlock — arrange/play this match in the current GPSL week (before its month). Both clubs need min 24 players. Result will not count on the table until that GPSL month."
        : restoredDraft
          ? "Draft restored — check scores and stats, then submit."
          : "Enter home and away goals, then submit."
    );
  } else if (f.status === "played") {
    const deferred = deferredResultNote(f, calendarStatus);
    setStatus(
      "submitStatus",
      deferred || "Result confirmed."
    );
  } else {
    const why =
      whyCantSubmitResult(f, myClub, calendarStatus, holidayContext) ||
      "This fixture cannot accept a new result.";
    const canSim =
      matchSimStatus.enabled &&
      canSimulateMatchResult(f, myClub, calendarStatus, holidayContext);
    setStatus(
      "submitStatus",
      canSim
        ? `${why} You can still use Instant result or Simulate match (test mode) when the month is open.`
        : why,
      true
    );
  }
}

function populateFixtureSelect(preferredFixtureId = null) {
  const sel = document.getElementById("fixtureSelect");
  const keepId =
    preferredFixtureId != null
      ? String(preferredFixtureId)
      : sel.value || null;
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
    opt.dataset.baseLabel = opt.textContent;
    sel.appendChild(opt);
  }

  if (keepId && [...sel.options].some((o) => o.value === keepId)) {
    sel.value = keepId;
  }

  sel.onchange = () => {
    void updateFixturePreview();
  };
  void updateFixturePreview();
  void decorateFixtureOptionsWithChecklist(sel);
}

async function decorateFixtureOptionsWithChecklist(sel) {
  const data = await fetchMatchdayChecklist();
  if (!data?.ok || !Array.isArray(data.fixtures)) return;
  const byId = new Map(data.fixtures.map((fx) => [String(fx.fixture_id), fx]));
  for (const opt of sel.options) {
    const fx = byId.get(opt.value);
    if (!fx) continue;
    const base = opt.dataset.baseLabel || opt.textContent;
    const needs = Number(fx.needs_you) || 0;
    let badge = "";
    if (needs > 0) badge = `● ${needs} to do · `;
    else if (fx.all_done) badge = "✓ ";
    else badge = "⏳ ";
    opt.textContent = `${badge}${base}`;
    if (fx.next_action?.label) opt.title = fx.next_action.label;
  }
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
      if (canSubmitResult(f, myClub, calendarStatus, holidayContext)) return true;
      // Keep agreed matches visible when the month window allows (show why submit waits)
      if (f.schedule_status !== "agreed") return false;
      return (
        isFixtureResultMonthOpen(f, calendarStatus) ||
        isFixtureMonthPlayable(f, myClub, calendarStatus, holidayContext)
      );
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

  if (readConnectionStars() == null) {
    setStatus(
      "submitStatus",
      "Select a connection quality rating — rate the online link, not your opponent.",
      true
    );
    document.getElementById("connectionStars")?.focus();
    return;
  }

  saveResultDraft(f.id);
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

  clearResultDraft(f.id);
  const conn = await saveConnectionRating(f.id);
  if (conn.error) {
    setStatus(
      "submitStatus",
      "✅ Result confirmed, but connection rating failed: " + conn.error.message,
      true
    );
  } else {
    setStatus("submitStatus", "✅ Result confirmed.");
  }
  confirmMode = null;
  applyConfirmModeUI();
  await loadUpcomingFixtures();
  populateFixtureSelect();
}

async function rejectPendingResult() {
  if (!confirmMode?.submissionId) return;
  const fixtureId = confirmMode.fixture?.id || selectedFixture()?.id;
  saveResultDraft(fixtureId);
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
  resultDraftRestoreNotice =
    "Result rejected — your saved stats were kept so you can submit again without starting over.";
  confirmMode = null;
  applyConfirmModeUI();
  await loadUpcomingFixtures();
  populateFixtureSelect(fixtureId);
}

async function submitResult() {
  if (confirmMode) {
    await confirmPendingResult();
    return;
  }

  const f = selectedFixture();
  const blocked = whyCantSubmitResult(
    f,
    myClub,
    calendarStatus,
    holidayContext
  );
  if (blocked) {
    setStatus("submitStatus", blocked, true);
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
    const built = buildCupExtraForSubmit(f, homeGoals, awayGoals, leg1CompanionFixture);
    if (built?.error) {
      setStatus("submitStatus", built.error, true);
      return;
    }
    cupExtra = built?.cupExtra ?? null;
    const cupErr = validateCupScores(
      f,
      homeGoals,
      awayGoals,
      cupExtra || {},
      leg1CompanionFixture
    );
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

  if (readConnectionStars() == null) {
    setStatus(
      "submitStatus",
      "Select a connection quality rating — rate the online link, not your opponent.",
      true
    );
    document.getElementById("connectionStars")?.focus();
    return;
  }

  saveResultDraft(f.id);
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
    if (isResultAlreadyPendingError(error.message)) {
      resultDraftRestoreNotice =
        "Opponent submitted first — your score and squad stats were saved. Check their proposed score, then Confirm (or Reject). You do not need to re-enter stats.";
      await loadUpcomingFixtures();
      populateFixtureSelect(f.id);
      return;
    }
    setStatus(
      "submitStatus",
      "❌ " +
        error.message +
        " (Your entries are still on screen and auto-saved — you can fix and submit again.)",
      true
    );
    return;
  }

  clearResultDraft(f.id);
  const conn = await saveConnectionRating(f.id);
  if (conn.error) {
    setStatus(
      "submitStatus",
      "✅ Submitted, but connection rating failed: " +
        conn.error.message +
        " (opponent still notified).",
      true
    );
  } else {
    setStatus("submitStatus", "✅ Submitted. Opponent notified via Inbox.");
  }
  await loadUpcomingFixtures();
  populateFixtureSelect(f.id);
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

function maybeShowCheckinFixNotice() {
  const params = new URLSearchParams(window.location.search);
  if (params.get("fix_checkin_squad") !== "1") return;
  setMatchdayTab("squad");
  const squadStatus = document.getElementById("squadPanelStatus");
  if (squadStatus) {
    squadStatus.innerHTML =
      `<b>Check-in blocked.</b> Fix your saved matchday squad first. ` +
      `Unavailable players are highlighted on the pitch cards and in the stats list.`;
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  initGpslInfoTips();
  await initGlobal();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club, error: clubErr } = await supabase
    .from("Clubs")
    .select("ShortName, Club, Nation")
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

  myClub = { short: club.ShortName, name: club.Club, nation: club.Nation || null };

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
  wireResultDraftAutosave();
  document.getElementById("fillTestStatsBtn")?.addEventListener("click", fillTestMatchStats);
  document
    .getElementById("connectionStars")
    ?.addEventListener("change", onConnectionStarsChange);
  syncConnectionStarsVisual();
  async function runMatchdaySim(mode) {
    const f = selectedFixture();
    if (!f) return;
    if (
      !canSimulateMatchResult(f, myClub, calendarStatus, holidayContext)
    ) {
      setStatus(
        "submitStatus",
        "Available when this fixture’s GPSL month is active.",
        true
      );
      return;
    }
    const play = mode === "play";
    if (
      !confirm(
        play
          ? `Simulate match for ${f.home_club_name} vs ${f.away_club_name}?\n\nPlays a ~45s graphic (20s each half + 5s HT), then finalises.`
          : `Instant result for ${f.home_club_name} vs ${f.away_club_name}?\n\nFinalises immediately.`
      )
    ) {
      return;
    }
    const btn = play
      ? document.getElementById("simulateResultBtn")
      : document.getElementById("instantResultBtn");
    try {
      const data = await runMatchSimulation(f.id, btn, mode, {
        homeName: f.home_club_name,
        awayName: f.away_club_name,
      });
      setStatus(
        "submitStatus",
        data
          ? `Simulated ${data.home_goals}–${data.away_goals}. Refreshing…`
          : "Simulated. Refreshing…"
      );
      f.status = "played";
      f.home_goals = data?.home_goals;
      f.away_goals = data?.away_goals;
      await selectFixture(f);
    } catch (err) {
      const info =
        err?.simFailure ||
        (await formatMatchSimFailure(err?.message || "Simulation failed"));
      // Calm status — no ❌ / alert for expected squad blocks
      setStatus(
        "submitStatus",
        info.kind === "notice"
          ? `${info.title}: ${info.body}`
          : info.summary || info.body || err?.message || "Simulation failed",
        info.kind !== "notice"
      );
    }
  }
  document.getElementById("simulateResultBtn")?.addEventListener("click", () => runMatchdaySim("play"));
  document.getElementById("instantResultBtn")?.addEventListener("click", () => runMatchdaySim("instant"));

  matchSimStatus = await loadMatchSimStatus();

  wireAllMatchdaySelectOnFocus();

  for (const id of ["homeGoals", "awayGoals", "etHomeGoals", "etAwayGoals"]) {
    document.getElementById(id)?.addEventListener("input", () => {
      updateCupScoreSections();
      updateOgBalanceHint();
    });
  }
  document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
    el.addEventListener("change", updateCupScoreSections);
  });

  await loadSquadPlayers();
  await loadMatchdaySquad();
  await loadGpslFormations({ force: true });
  await loadClubSuspensions();
  applyMatchdaySquadFilter();
  initSquadPanel();
  refreshSquadCardStatuses();
  renderPlayerStatsTable();
  void renderNextFixtureSquadCheck();

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
  maybeShowCheckinFixNotice();
});
