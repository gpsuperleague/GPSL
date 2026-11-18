import { supabase, initGlobal, isGpslAdminUser, fetchIsGpslModUser } from "./global.js";
import { initGpslInfoTips } from "./gpsl_info_tips.js";
import {
  loadCurrentSeason,
  loadLeagueFixtures,
  loadCupFixtures,
  groupFixturesByMatchday,
  CUP_CODES,
  CUP_LABELS,
  formatFixtureScore,
  isVoidFixture,
  fixtureInvolvesClub,
  DIVISION_LABELS,
  LEAGUE_DIVISIONS,
  GPSL_MONTH_LABELS,
  canSubmitResult,
  canSimulateMatchResult,
  needsInboxConfirm,
  deferredResultNote,
  leagueBadgeHtml,
  divisionLabelWithBadgeHtml,
  isFixtureMonthPlayable,
} from "./competition.js?v=20261104-miss-result";
import {
  loadCalendarStatus,
  loadSeasonCalendarMonths,
  calendarStatusBanner,
} from "./competition_calendar.js";
import { loadClubsMap, clubWithOwnerHtml, stadiumName, fixtureOwnerOccupancy } from "./clubs_lookup.js";
import {
  formatMatchConditionsHtml,
  formatFixtureContinentStackedHtml,
  fixtureStadiumLabelStackedHtml,
} from "./competition_conditions.js?v=20261029-cond-icons";
import { matchdaySeasonDecorHtml } from "./matchday_season_decor.js?v=20261030-intl";
import { loadHolidayPlayContext } from "./owner_holidays.js";
import {
  scheduleActionLabel,
  formatKickoff,
  UK_TZ,
  catchUpBadgeHtml,
  catchUpKickoffPrefix,
  isCatchUpFixture,
  fixtureOpponentIsInactive,
  vacantOpponentKickoffNoteHtml,
  fixtureNewOwnerArrangeGrace,
  newOwnerGraceKickoffNoteHtml,
  fixtureHolidayArrangeNote,
  holidayKickoffNoteHtml,
  fixtureExpiryWarningHtml,
  setSeasonCalendarMonths,
} from "./match_scheduling.js?v=20261114-cup-both";
import { loadTvFixtureIds, tvFixtureBadgeHtml } from "./tv_fixtures.js";
import { matchCentreButtonHtml } from "./match_centre_link.js";
import {
  loadMatchSimStatus,
  matchSimBannerHtml,
  matchSimButtonHtml,
  wireMatchSimBannerToggle,
  wireMatchSimButtons,
  runMatchSimulation,
  showMatchSimFailure,
} from "./match_sim_ui.js?v=20260924-sim-notice";
import {
  loadFixtureMatchVideos,
  loadMatchVideoReportedSides,
  loadMatchVideoAdminClearedSides,
  matchVideoTicksHtml,
  MATCH_VIDEO_TICK_CSS,
  wireMatchVideoReportButtons,
} from "./match_videos_ui.js?v=20261118-watch-no-after";

let calendarStatus = null;
let holidayContext = null;

let myClub = { short: null, name: null };
/** @type {{ short: string, name: string, division: string }[]} */
let seasonClubs = [];
/** "" all, "__mine__" my club, or an opponent short name (matches against my club). */
let clubFilter = "";
let canReportMatchVideos = false;
let videoAdmin = false;
let currentDivision = "superleague";
let fixtureView = "league";
let currentCup = "league_cup";
/** @type {{ enabled: boolean, isAdmin: boolean, error: string|null }} */
let matchSimStatus = { enabled: false, isAdmin: false, isStaff: false, error: null };
let allFixtures = [];
/** @type {Map<string, { home_url?: string|null, away_url?: string|null }>} */
let matchVideoMap = new Map();
/** @type {Set<string>} */
let matchVideoReportedSides = new Set();
/** @type {Set<string>} */
let matchVideoAdminCleared = new Set();

function ensureMatchVideoStyles() {
  let el = document.getElementById("matchVideoTickStyles");
  if (!el) {
    el = document.createElement("style");
    el.id = "matchVideoTickStyles";
    document.head.appendChild(el);
  }
  el.textContent = MATCH_VIDEO_TICK_CSS;
}

const LEAGUE_COLGROUP = `
  <colgroup>
    <col class="col-home">
    <col class="col-score">
    <col class="col-away">
    <col class="col-stadium">
    <col class="col-continent">
    <col class="col-conditions">
    <col class="col-actions">
  </colgroup>
`;

const CUP_COLGROUP = `
  <colgroup>
    <col class="col-match">
    <col class="col-home">
    <col class="col-score">
    <col class="col-away">
    <col class="col-stadium">
    <col class="col-continent">
    <col class="col-conditions">
    <col class="col-actions">
  </colgroup>
`;

const FIXTURE_TABLE_HEAD = `
  <th>Home</th>
  <th></th>
  <th>Away</th>
  <th>Stadium</th>
  <th>Continent</th>
  <th>Conditions</th>
  <th class="my-actions">Kick-off</th>
`;

function homeStadium(fixture) {
  const venue = String(fixture?.venue_name || "").trim();
  if (venue) return venue;
  return stadiumName(fixture.home_club_short_name);
}

function fixtureStadiumCell(fixture) {
  return fixtureStadiumLabelStackedHtml(
    fixture,
    myClub.short,
    homeStadium(fixture)
  );
}

function fixtureContinentCell(fixture) {
  return formatFixtureContinentStackedHtml(fixture);
}

function fixtureConditionsCell(fixture) {
  return formatMatchConditionsHtml(fixture);
}

function matchdayUrl(fixtureId) {
  return `matchday.html?fixture=${encodeURIComponent(String(fixtureId))}`;
}

function escapeStatus(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;");
}

/** Awarded / void results: short label for the score column, full note for the kick-off column. */
function awardedResultKind(fixture) {
  if (!fixture || fixture.status !== "played") return null;
  const note = String(fixture.award_note || "").trim();
  if (fixture.is_forfeit === true) return { label: "Awarded", note };
  if (isVoidFixture(fixture)) return { label: "Void", note };
  const nil =
    Number(fixture.home_goals) === 0 && Number(fixture.away_goals) === 0 && note;
  if (nil) return { label: "Awarded 0–0", note };
  return null;
}

function catchUpReplyDeadline(fixture) {
  if (!isCatchUpFixture(fixture) || fixture.status === "played") return "";
  const status = String(fixture.schedule_status || "unscheduled").toLowerCase();
  if (status !== "negotiating" || !fixture.schedule_response_due_at) return "";
  const when = formatKickoff(fixture.schedule_response_due_at, UK_TZ);
  const dueMs = new Date(fixture.schedule_response_due_at).getTime();
  const overdue = Number.isFinite(dueMs) && dueMs <= Date.now();
  return overdue ? `Reply was ${when} UK` : `Reply by ${when} UK`;
}

/** Small-print schedule status for every fixture (no link). */
function kickoffStatusNoteHtml(fixture) {
  if (!fixture) return "";
  if (fixture.status === "played") {
    const awarded = awardedResultKind(fixture);
    if (!awarded) return "";
    const title = escapeStatus(awarded.note || awarded.label);
    const detail = awarded.note
      ? `<span class="ko-status-detail">${escapeStatus(awarded.note)}</span>`
      : "";
    return `<span class="ko-status ko-status--vacant" title="${title}">${awarded.label}</span>${detail}`;
  }

  const catchUp = isCatchUpFixture(fixture);
  const prefix = catchUp ? catchUpKickoffPrefix() : "";
  const occ = fixtureOwnerOccupancy(
    fixture.home_club_short_name,
    fixture.away_club_short_name
  );

  // Owned club vs vacant / season-absent → walkover messaging (not home-only)
  if (occ.isPartialVacant || occ.involvesSeasonAbsent) {
    if (!occ.isVacantVsVacant) {
      const forOwned = Boolean(
        myClub.short && fixtureOpponentIsInactive(fixture, myClub.short, occ)
      );
      const seasonAbsent = forOwned
        ? (String(fixture.home_club_short_name || "").toUpperCase() ===
          String(myClub.short || "").toUpperCase()
            ? occ.awayAbsent
            : occ.homeAbsent)
        : occ.involvesSeasonAbsent && !occ.isPartialVacant;
      return vacantOpponentKickoffNoteHtml({
        forOwnedClub: forOwned,
        catchUp,
        seasonAbsent: Boolean(seasonAbsent),
      });
    }
    return `<span class="ko-status ko-status--vacant" title="Neither club has an active owner — settled at GPSL month end">${prefix}Vacant vs vacant · settled at month end</span>`;
  }

  if (fixture.manual_black_box === true) {
    return `<span class="ko-status ko-status--pending" title="Both clubs GPSL match system OFF">${prefix}Manual arrange</span>`;
  }

  const status = String(fixture.schedule_status || "unscheduled").toLowerCase();

  if (status === "agreed" && fixture.agreed_kickoff_at) {
    const when = formatKickoff(fixture.agreed_kickoff_at, UK_TZ);
    const ci =
      fixture.home_checked_in && fixture.away_checked_in
        ? " · both checked in"
        : "";
    return `<span class="ko-status ko-status--agreed">${prefix}Agreed · ${when} UK${ci}</span>`;
  }

  const newOwnerGrace = fixtureNewOwnerArrangeGrace(fixture);
  if (newOwnerGrace && status !== "agreed") {
    return newOwnerGraceKickoffNoteHtml(newOwnerGrace, { catchUp });
  }

  if (status === "negotiating") {
    const replyBy = catchUp ? catchUpReplyDeadline(fixture) : "";
    const dueBit = replyBy ? ` · ${replyBy}` : "";
    return `<span class="ko-status ko-status--pending" title="${
      catchUp ? "Catch-up / replay — accept or counter the proposed kick-off" : ""
    }">${prefix}Proposal pending${dueBit}</span>`;
  }

  const holidayNote = fixtureHolidayArrangeNote(fixture);
  if (holidayNote) {
    return holidayKickoffNoteHtml(holidayNote, { catchUp });
  }

  return `<span class="ko-status ko-status--open" title="${
    catchUp
      ? "Play month finished — re-arrange a new kick-off (catch-up / replay)"
      : ""
  }">${prefix}${
    catchUp ? "Not scheduled — re-arrange kick-off" : "Not scheduled"
  }</span>`;
}

async function enrichManualBlackBoxFlags(fixtures) {
  const list = fixtures || [];
  // Prefer column from competition_fixtures_public when present
  if (list.some((f) => typeof f.manual_black_box === "boolean")) {
    return list.map((f) => ({
      ...f,
      manual_black_box: f.manual_black_box === true,
    }));
  }
  const ids = list
    .map((f) => Number(f.id))
    .filter((id) => Number.isFinite(id));
  if (!ids.length) return list;
  try {
    const { data, error } = await supabase.rpc("fixtures_manual_black_box_map", {
      p_fixture_ids: ids,
    });
    if (error || !data || typeof data !== "object") {
      if (error) console.warn("fixtures_manual_black_box_map:", error.message);
      return list;
    }
    return list.map((f) => ({
      ...f,
      manual_black_box: data[String(f.id)] === true,
    }));
  } catch (err) {
    console.warn("enrichManualBlackBoxFlags:", err);
    return list;
  }
}

function actionCell(fixture) {
  const occ = fixtureOwnerOccupancy(
    fixture.home_club_short_name,
    fixture.away_club_short_name
  );
  const staffOk =
    matchSimStatus.isStaff === true || matchSimStatus.isAdmin === true;
  const vacantPairStaff = occ.isVacantVsVacant && staffOk;
  const involvesMe = Boolean(myClub.short && fixtureInvolvesClub(fixture, myClub));
  const note = kickoffStatusNoteHtml(fixture) + fixtureExpiryWarningHtml(fixture);

  // Everyone sees kick-off status; only involved clubs get action buttons
  if (!involvesMe && !vacantPairStaff) {
    return note;
  }

  const parts = [];

  if (involvesMe) {
    if (canSubmitResult(fixture, myClub, calendarStatus, holidayContext)) {
      parts.push(
        `<a href="${matchdayUrl(fixture.id)}" class="btn-result" style="text-decoration:none;display:inline-block;">Enter result</a>`
      );
    } else if (needsInboxConfirm(fixture, myClub)) {
      parts.push(
        `<a href="${matchdayUrl(fixture.id)}" class="btn-result secondary" style="text-decoration:none;display:inline-block;">Confirm result</a>`
      );
    } else if (
      fixture.submission_status === "pending" &&
      fixture.submitted_by_club &&
      fixture.submitted_by_club.toUpperCase() === (myClub.short || "").toUpperCase()
    ) {
      parts.push(`<span style="color:#888;font-size:12px;">Awaiting confirm</span>`);
    } else if (fixture.status === "played") {
      const deferred = deferredResultNote(fixture, calendarStatus);
      if (deferred) {
        parts.push(
          `<span style="color:#c9a227;font-size:12px;" title="${deferred}">Played · pending table</span>`
        );
      } else {
        parts.push(`<span style="color:#888;font-size:12px;">Played</span>`);
      }
    } else if (fixture.manual_black_box === true) {
      parts.push(
        `<a href="${matchdayUrl(fixture.id)}" class="btn-result secondary" style="text-decoration:none;display:inline-block;">Manual · Match Day</a>`
      );
    } else if (fixtureOpponentIsInactive(fixture, myClub.short, occ)) {
      // Kick-off note explains walkover — no propose/reply button
    } else {
      const sched = scheduleActionLabel(fixture, myClub.short);
      if (sched && !sched.vacantWalkover && !sched.newOwnerGrace) {
        const cls = sched.muted ? "btn-result secondary" : "btn-result";
        parts.push(
          `<a href="${sched.href}" class="${cls}" style="text-decoration:none;display:inline-block;">${sched.label}</a>`
        );
      }
    }
  }

  if (
    matchSimStatus.enabled &&
    fixture.status === "scheduled" &&
    !fixture.submission_id &&
    !(involvesMe && needsInboxConfirm(fixture, myClub)) &&
    (involvesMe || vacantPairStaff)
  ) {
    if (!occ.isVacantVsVacant || staffOk) {
      const monthOk = isFixtureMonthPlayable(
        fixture,
        involvesMe ? myClub : { short: fixture.home_club_short_name },
        calendarStatus,
        holidayContext
      );
      const canSim = vacantPairStaff
        ? monthOk
        : canSimulateMatchResult(
            fixture,
            myClub,
            calendarStatus,
            holidayContext
          );
      parts.push(
        matchSimButtonHtml(fixture.id, {
          disabled: !canSim,
          title: canSim
            ? vacantPairStaff
              ? "Admin/mod: simulate vacant vs vacant"
              : ""
            : "Available when this fixture’s GPSL month is active",
        })
      );
    }
  }

  const actions = parts.join(" ");
  if (actions && note) {
    return `${actions}<div class="ko-status-wrap">${note}</div>`;
  }
  return actions || note;
}

function fixtureRowHtml(fixture) {
  const catchUp = isCatchUpFixture(fixture);
  const replyBy = catchUpReplyDeadline(fixture);
  const awarded = awardedResultKind(fixture);
  const catchUpCell = catchUp
    ? `<span class="catch-up-cell">${catchUpBadgeHtml()}${
        replyBy
          ? `<span class="fixture-status-note">${escapeStatus(replyBy)}</span>`
          : ""
      }</span>`
    : awarded
      ? `<span class="fixture-status-note awarded">${escapeStatus(awarded.label)}</span>`
      : "";
  return `
    <td>${clubWithOwnerHtml(fixture.home_club_name, fixture.home_club_short_name, "block")}${matchCentreButtonHtml(fixture)}</td>
    <td class="score">${tvFixtureBadgeHtml(fixture.id)}${formatFixtureScore(fixture, myClub)}${matchVideoTicksHtml(matchVideoMap.get(String(fixture.id)), {
      fixtureId: fixture.id,
      fixture,
      myClubShort: myClub.short,
      allowReport: canReportMatchVideos,
      reportedSides: matchVideoReportedSides,
      adminView: videoAdmin,
      clearedSides: matchVideoAdminCleared,
    })}${catchUpCell}</td>
    <td>${clubWithOwnerHtml(fixture.away_club_name, fixture.away_club_short_name, "block")}</td>
    <td class="fixture-stadium">${fixtureStadiumCell(fixture)}</td>
    <td class="fixture-continent">${fixtureContinentCell(fixture)}</td>
    <td class="fixture-conditions">${fixtureConditionsCell(fixture)}</td>
    <td class="my-actions">${actionCell(fixture)}</td>
  `;
}

function applyFixtureRowClasses(tr, fixture) {
  if (fixtureInvolvesClub(fixture, myClub)) tr.classList.add("my-fixture");
  const occ = fixtureOwnerOccupancy(
    fixture.home_club_short_name,
    fixture.away_club_short_name
  );
  if (occ.involvesSeasonAbsent) tr.classList.add("fixture-season-absent");
  if (occ.isPartialVacant) tr.classList.add("fixture-sim");
  else if (occ.isVacantVsVacant) tr.classList.add("fixture-vacant-pair");
}

function divisionFromUrl() {
  const div = new URLSearchParams(window.location.search).get("division")?.trim() || "";
  return LEAGUE_DIVISIONS.includes(div) ? div : null;
}

function viewFromUrl() {
  const v = (new URLSearchParams(window.location.search).get("view") || "")
    .trim()
    .toLowerCase();
  if (v === "cups" || v === "cup") return "cups";
  if (v === "league") return "league";
  return null;
}

function cupFromUrl() {
  const cup = (new URLSearchParams(window.location.search).get("cup") || "").trim();
  return CUP_CODES.includes(cup) ? cup : null;
}

function locateIdFromUrl() {
  const id = (new URLSearchParams(window.location.search).get("locate") || "").trim();
  return id || null;
}

function applyLocateTarget() {
  const id = locateIdFromUrl();
  if (!id) return;
  const fix = allFixtures.find((f) => String(f.id) === id);
  if (!fix) return;
  if (fix.competition_type === "cup") {
    fixtureView = "cups";
    if (CUP_CODES.includes(fix.cup_code)) currentCup = fix.cup_code;
    return;
  }
  if (LEAGUE_DIVISIONS.includes(fix.division)) {
    fixtureView = "league";
    currentDivision = fix.division;
  }
}

function scrollToLocatedFixture() {
  const id = locateIdFromUrl();
  if (!id) return;
  const row = document.getElementById(`fixture-${id}`);
  if (!row) return;
  row.classList.add("fixture-located");
  requestAnimationFrame(() => {
    row.scrollIntoView({ behavior: "smooth", block: "center" });
  });
}

function clubKey(value) {
  return String(value || "").trim().toUpperCase();
}

function clubsInDivision(division) {
  const fromSeason = seasonClubs.filter((c) => c.division === division);
  if (fromSeason.length) return fromSeason;
  const map = new Map();
  for (const f of allFixtures) {
    if (f.division !== division) continue;
    if (f.competition_type && f.competition_type !== "league") continue;
    for (const [short, name] of [
      [f.home_club_short_name, f.home_club_name],
      [f.away_club_short_name, f.away_club_name],
    ]) {
      if (!short || map.has(clubKey(short))) continue;
      map.set(clubKey(short), { short, name: name || short, division });
    }
  }
  return [...map.values()].sort((a, b) =>
    a.name.localeCompare(b.name, undefined, { sensitivity: "base" })
  );
}

function opponentClubs(division) {
  const mine = clubKey(myClub.short);
  return clubsInDivision(division).filter((c) => clubKey(c.short) !== mine);
}

function selectedOpponentName() {
  const club = clubsInDivision(currentDivision).find(
    (c) => clubKey(c.short) === clubKey(clubFilter)
  );
  return club?.name || clubFilter;
}

function applyLeagueClubFilter(fixtures) {
  if (!clubFilter) return fixtures;
  if (clubFilter === "__mine__") {
    return myClub.short ? fixtures.filter((f) => fixtureInvolvesClub(f, myClub)) : fixtures;
  }
  const opponent = { short: clubFilter };
  if (myClub.short) {
    return fixtures.filter(
      (f) => fixtureInvolvesClub(f, myClub) && fixtureInvolvesClub(f, opponent)
    );
  }
  return fixtures.filter((f) => fixtureInvolvesClub(f, opponent));
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
    btn.innerHTML = divisionLabelWithBadgeHtml(div, { size: "xs" });
    btn.className = currentDivision === div ? "active" : "";
    btn.onclick = () => {
      currentDivision = div;
      if (
        clubFilter &&
        clubFilter !== "__mine__" &&
        !opponentClubs(div).some((c) => clubKey(c.short) === clubKey(clubFilter))
      ) {
        clubFilter = "";
      }
      renderDivisionToolbar();
      renderFixtures();
    };
    bar.appendChild(btn);
  }

  const label = document.createElement("label");
  label.className = "fixture-filter";
  label.htmlFor = "fixtureClubFilter";
  label.textContent = "Show";
  const sel = document.createElement("select");
  sel.id = "fixtureClubFilter";
  sel.title = "My club shows your matches. Another club shows when you play them.";
  const all = document.createElement("option");
  all.value = "";
  all.textContent = "All matches";
  sel.appendChild(all);
  if (myClub.short) {
    const mine = document.createElement("option");
    mine.value = "__mine__";
    mine.textContent = "My club";
    sel.appendChild(mine);
  }
  for (const club of opponentClubs(currentDivision)) {
    const opt = document.createElement("option");
    opt.value = club.short;
    opt.textContent = `vs ${club.name}`;
    sel.appendChild(opt);
  }
  if (clubFilter && ![...sel.options].some((opt) => opt.value === clubFilter)) {
    clubFilter = "";
  }
  sel.value = clubFilter;
  sel.onchange = () => {
    clubFilter = sel.value;
    renderFixtures();
  };
  label.appendChild(sel);
  bar.appendChild(label);
}

function renderCupFixtures() {
  const root = document.getElementById("fixturesRoot");
  const fixtures = allFixtures.filter(
    (f) => f.competition_type === "cup" && f.cup_code === currentCup
  );

  if (!fixtures.length) {
    root.innerHTML =
      `<p class="empty">No ${CUP_LABELS[currentCup] || currentCup} fixtures. Draw in <b>GPSL Admin → Cup competitions</b> or see <a href="cups.html" style="color:var(--gpsl-accent, #ff9900);">Cups</a> bracket.</p>`;
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
      <div class="matchday-head"><span>${CUP_LABELS[currentCup] || currentCup} · Round ${round}</span></div>
      <table class="gpsl-table">
        ${CUP_COLGROUP}
        <thead><tr><th>Match</th>${FIXTURE_TABLE_HEAD}</tr></thead>
        <tbody></tbody>
      </table>
    `;
    const tbody = block.querySelector("tbody");
    for (const f of rows) {
      const tr = document.createElement("tr");
      tr.id = `fixture-${f.id}`;
      applyFixtureRowClasses(tr, f);
      tr.innerHTML = `<td>M${f.cup_match}</td>${fixtureRowHtml(f)}`;
      tbody.appendChild(tr);
    }
    root.appendChild(block);
  }
  if (locateIdFromUrl()) scrollToLocatedFixture();
  wireFixtureSimButtons(root);
}

function requestedFixturesMonth() {
  const params = new URLSearchParams(window.location.search);
  const raw = (params.get("month") || "").trim().toLowerCase();
  return raw || null;
}

function scrollToActiveMonthFixtures() {
  if (fixtureView !== "league") return;

  const requested = requestedFixturesMonth();
  const activeMonth =
    requested ||
    (calendarStatus?.calendar_configured
      ? calendarStatus?.active_gpsl_month
      : null);
  if (!activeMonth) return;

  const root = document.getElementById("fixturesRoot");
  if (!root) return;

  const monthBlocks = [...root.querySelectorAll(".matchday-block[data-gpsl-month]")].filter(
    (el) =>
      (el.dataset.gpslMonth || "").toLowerCase() ===
      String(activeMonth).toLowerCase()
  );
  if (!monthBlocks.length) {
    if (!clubFilter) return;
    const first = root.querySelector(".matchday-block");
    if (!first) return;
    requestAnimationFrame(() => {
      first.scrollIntoView({ behavior: "smooth", block: "start" });
    });
    return;
  }

  // Scroll to the first matchday of the active (or ?month=) GPSL month.
  const target = monthBlocks.reduce((best, el) => {
    const md = Number(el.dataset.matchday) || 0;
    const bestMd = Number(best?.dataset.matchday) || Infinity;
    return md < bestMd ? el : best;
  }, monthBlocks[0]);

  requestAnimationFrame(() => {
    target.scrollIntoView({ behavior: "smooth", block: "start" });
  });
}

function renderFixtures() {
  const root = document.getElementById("fixturesRoot");

  if (fixtureView === "cups") {
    renderCupFixtures();
    return;
  }

  const divisionFixtures = allFixtures.filter((f) => f.division === currentDivision);
  const fixtures = applyLeagueClubFilter(divisionFixtures);

  if (!fixtures.length) {
    if (!divisionFixtures.length) {
      root.innerHTML =
        '<p class="empty">No league fixtures for this division yet. Ask admin to generate fixtures in <b>GPSL Admin → League Fixtures</b>.</p>';
      return;
    }
    const p = document.createElement("p");
    p.className = "empty";
    p.textContent =
      clubFilter === "__mine__"
        ? "No league matches for your club in this division."
        : `No league match against ${selectedOpponentName()} in this division.`;
    root.replaceChildren(p);
    return;
  }

  const groups = groupFixturesByMatchday(fixtures);
  root.innerHTML = "";

  for (const { matchday, fixtures: rows } of groups) {
    const sample = rows[0];
    const monthLabel = GPSL_MONTH_LABELS[sample.gpsl_month] || sample.gpsl_month;
    const catchUpCount = rows.filter((f) => isCatchUpFixture(f)).length;
    const monthLive =
      !calendarStatus?.calendar_configured ||
      calendarStatus.active_gpsl_month === sample.gpsl_month;
    const monthStatus = monthLive
      ? ""
      : catchUpCount
        ? ` · <span style="color:#888">play month closed</span> · <span class="catch-up-badge">${catchUpCount} catch-up</span>`
        : ' · <span style="color:#888">play month closed</span>';
    const block = document.createElement("div");
    block.className = "matchday-block";
    block.dataset.gpslMonth = sample.gpsl_month || "";
    block.dataset.matchday = String(matchday);

    block.innerHTML = `
      <div class="matchday-head" data-season="${String(sample.gpsl_month || "").toLowerCase()}">
        ${matchdaySeasonDecorHtml(sample.gpsl_month)}
        <span class="matchday-head-label">Matchday ${matchday}</span>
        <span class="matchday-head-meta">${monthLabel} · Week ${matchday}${monthStatus}</span>
      </div>
      <table class="gpsl-table">
        ${LEAGUE_COLGROUP}
        <thead><tr>${FIXTURE_TABLE_HEAD}</tr></thead>
        <tbody></tbody>
      </table>
    `;

    const tbody = block.querySelector("tbody");
    for (const f of rows) {
      const tr = document.createElement("tr");
      tr.id = `fixture-${f.id}`;
      applyFixtureRowClasses(tr, f);
      tr.innerHTML = fixtureRowHtml(f);
      tbody.appendChild(tr);
    }

    root.appendChild(block);
  }

  if (locateIdFromUrl()) scrollToLocatedFixture();
  else scrollToActiveMonthFixtures();
  wireFixtureSimButtons(root);
}

function renderSimBanner() {
  const host = document.getElementById("matchSimBannerHost");
  if (!host) return;
  host.innerHTML = matchSimBannerHtml(matchSimStatus);
  wireMatchSimBannerToggle(async () => {
    matchSimStatus = await loadMatchSimStatus();
    renderSimBanner();
    renderFixtures();
  });
}

function wireFixtureSimButtons(root) {
  wireMatchSimButtons(root, async (id, btn, mode) => {
    const f = allFixtures.find((row) => String(row.id) === String(id));
    const label = f
      ? `${f.home_club_name || f.home_club_short_name} vs ${f.away_club_name || f.away_club_short_name}`
      : `fixture ${id}`;
    const play = mode === "play";
    if (
      !confirm(
        play
          ? `Simulate match for ${label}?\n\nPlays a ~45s graphic (20s each half + 5s HT), then finalises.`
          : `Instant result for ${label}?\n\nFinalises immediately.`
      )
    ) {
      return;
    }
    try {
      const result = await runMatchSimulation(id, btn, mode, {
        homeName: f?.home_club_name || f?.home_club_short_name,
        awayName: f?.away_club_name || f?.away_club_short_name,
      });
      if (f && result) {
        f.status = "played";
        f.home_goals = result.home_goals;
        f.away_goals = result.away_goals;
      }
      renderFixtures();
    } catch (err) {
      console.warn("fixtures sim:", err);
      let host = document.getElementById("fixturesSimNotice");
      if (!host) {
        host = document.createElement("div");
        host.id = "fixturesSimNotice";
        root?.prepend(host);
      }
      showMatchSimFailure(host, err?.simFailure || err);
    }
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  initGpslInfoTips();
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
  const isStaff = isGpslAdminUser(user) || (await fetchIsGpslModUser());
  videoAdmin = isGpslAdminUser(user);
  canReportMatchVideos = Boolean(myClub.short) || isStaff;

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

  const { data: regs } = await supabase
    .from("competition_club_season_public")
    .select("club_short_name, club_name, division");
  seasonClubs = (regs || [])
    .filter((r) => r.club_short_name)
    .map((r) => ({
      short: r.club_short_name,
      name: r.club_name || r.club_short_name,
      division: r.division || "",
    }))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));

  if (myClub.short) {
    const reg = seasonClubs.find((r) => clubKey(r.short) === clubKey(myClub.short));

    if (reg) {
      myClub.short = reg.short;
      myClub.name = reg.name || myClub.name;
      if (LEAGUE_DIVISIONS.includes(reg.division)) {
        currentDivision = reg.division;
      }
    }
  } else if (hint) {
    hint.textContent = "Log in with a club owner account to enter results.";
  }

  const urlDivision = divisionFromUrl();
  if (urlDivision) {
    currentDivision = urlDivision;
  }

  const urlView = viewFromUrl();
  if (urlView) {
    fixtureView = urlView;
  }
  const urlCup = cupFromUrl();
  if (urlCup) currentCup = urlCup;

  calendarStatus = await loadCalendarStatus(supabase);
  try {
    setSeasonCalendarMonths(await loadSeasonCalendarMonths(supabase));
  } catch (err) {
    console.warn("fixtures: season calendar months", err);
  }
  holidayContext = await loadHolidayPlayContext();
  matchSimStatus = await loadMatchSimStatus();
  renderSimBanner();
  const calEl = document.getElementById("calendarBanner");
  if (calEl && calendarStatus?.calendar_configured) {
    calEl.style.display = "block";
    calEl.textContent = calendarStatusBanner(calendarStatus);
  }

  meta.innerHTML = `${leagueBadgeHtml(currentDivision, { size: "sm" })} ${season.label} · ${DIVISION_LABELS[currentDivision]} · your games highlighted in gold`;

  const league = await loadLeagueFixtures(supabase);
  const cups = await loadCupFixtures(supabase);
  allFixtures = await enrichManualBlackBoxFlags([...league, ...cups]);
  await loadTvFixtureIds(supabase, season.id);
  ensureMatchVideoStyles();
  const allIds = allFixtures.map((f) => f.id);
  const [videos, reportedSides, clearedSides] = await Promise.all([
    loadFixtureMatchVideos(supabase, allIds),
    loadMatchVideoReportedSides(supabase, allIds),
    videoAdmin ? loadMatchVideoAdminClearedSides(supabase, allIds) : Promise.resolve(new Set()),
  ]);
  matchVideoMap = videos;
  matchVideoReportedSides = reportedSides;
  matchVideoAdminCleared = clearedSides;
  wireMatchVideoReportButtons(supabase, document.getElementById("fixturesRoot") || document, {
    resolveFixture: (id) => allFixtures.find((f) => Number(f.id) === Number(id)),
    isAdmin: videoAdmin,
    onAdminClear: ({ fixtureId, side, cleared }) => {
      const key = `${fixtureId}:${side}`;
      if (cleared) matchVideoAdminCleared.add(key);
      else matchVideoAdminCleared.delete(key);
    },
    onSubmitted: ({ fixtureId, side }) => {
      matchVideoReportedSides.add(`${fixtureId}:${side}`);
      renderFixtures();
    },
  });
  if (!allFixtures.length && season) {
    root.innerHTML =
      '<p class="empty">No fixtures loaded. Check an active season and that admin generated fixtures (GPSL Admin → League Fixtures). If the browser console shows a database error, run <code>competition_phase3_matchday.sql</code> after phase 1.</p>';
  }
  applyLocateTarget();
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
