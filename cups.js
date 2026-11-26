import { supabase, initGlobal, isGpslAdminUser } from "./global.js?v=20261122-plate-fit";
import { loadClubsMap, fullClubName, clubWithOwnerHtml } from "./clubs_lookup.js";
import {
  CUP_CODES,
  CUP_LABELS,
  GPSL_MONTH_LABELS,
  loadCupBracket,
  loadCupBracketForSeason,
  loadCupQualified,
  loadCurrentSeason,
  loadCupMatchExtras,
  preprocessCupBracketRounds,
  groupCupBracketTies,
  cupRoundLabel,
  cupRoundTieCount,
  cupTwoLegAggregate,
  isTwoLegCupQuarterFinal,
  formatCupScoreLines,
  formatCupMatchFinance,
  formatMoney,
  normalizeClubKey,
  canSubmitResult,
  needsInboxConfirm,
  deferredResultNote,
} from "./competition.js";
import {
  loadCalendarStatus,
  loadSeasonCalendarMonths,
  isGpslMonthCurrentlyPlayable,
} from "./competition_calendar.js";
import { formatMatchConditions } from "./competition_conditions.js";
import { applyCupPageTheme, renderCupHero } from "./trophy_assets.js?v=20261123-super8";
import { loadTvFixtureIds, tvFixtureBadgeHtml } from "./tv_fixtures.js";
import {
  scheduleActionLabel,
  formatKickoff,
  UK_TZ,
  isCatchUpFixture,
  fixtureNewOwnerArrangeGrace,
  newOwnerGraceKickoffNoteHtml,
  fixtureHolidayArrangeNote,
  holidayKickoffNoteHtml,
  fixtureExpiryWarningHtml,
  finalPlayCutoffDateHtml,
  scheduleReplyOwedBy,
  setSeasonCalendarMonths,
} from "./match_scheduling.js?v=20261126-holiday-return";
import { matchCentreButtonHtml } from "./match_centre_link.js";
import {
  loadFixtureMatchVideos,
  loadMatchVideoReportedSides,
  loadMatchVideoAdminClearedSides,
  matchVideoTicksHtml,
  MATCH_VIDEO_TICK_CSS,
  wireMatchVideoReportButtons,
} from "./match_videos_ui.js?v=20261118-watch-no-after";
import { loadHolidayPlayContext } from "./owner_holidays.js";

function cupFromUrl() {
  const raw = new URLSearchParams(window.location.search).get("cup");
  if (raw === "spoon") return "bowl";
  if (raw && CUP_CODES.includes(raw)) return raw;
  return null;
}

function seasonFromUrl() {
  return new URLSearchParams(window.location.search).get("season")?.trim() || "";
}

let myClubShort = null;
let currentCup = "league_cup";
/** "" = every round. Otherwise the bracket round_no. */
let cupRoundFilter = "";
/** "" = every club. Otherwise a club short name in this cup. */
let cupClubFilter = "";
/** @type {object[]} */
let lastBracketNodes = [];
let lastBracketExtras = null;
let calendarStatus = null;
let holidayContext = null;
/** @type {Map<string, { home_url?: string|null, away_url?: string|null }>} */
let matchVideoMap = new Map();
/** @type {Set<string>} */
let matchVideoReportedSides = new Set();
/** @type {Set<string>} */
let matchVideoAdminCleared = new Set();
let videoAdmin = false;
/** @type {Map<number, object>} last fixturesById for report wiring */
let lastCupFixturesById = new Map();
let matchVideoReportsWired = false;
/** @type {Map<string, number>} prize stage → amount for current cup/season */
let cupPrizeByStage = new Map();
/** @type {Map<number, string>} round_no → prize stage */
let cupRoundStageByNo = new Map();
/** @type {Array<Record<string, unknown>>} */
let cupScheduleRows = [];
const previewHiddenCups = new Set();

function ensureMatchVideoStyles() {
  let el = document.getElementById("matchVideoTickStyles");
  if (!el) {
    el = document.createElement("style");
    el.id = "matchVideoTickStyles";
    document.head.appendChild(el);
  }
  el.textContent = MATCH_VIDEO_TICK_CSS;
}

function ensureMatchVideoReportsWired() {
  if (matchVideoReportsWired) return;
  matchVideoReportsWired = true;
  wireMatchVideoReportButtons(supabase, document.getElementById("bracketRoot"), {
    resolveFixture: (fixtureId) => lastCupFixturesById.get(Number(fixtureId)) || null,
    formatMoney,
    isAdmin: videoAdmin,
    onAdminClear: ({ fixtureId, side, cleared }) => {
      const key = `${fixtureId}:${side}`;
      if (cleared) matchVideoAdminCleared.add(key);
      else matchVideoAdminCleared.delete(key);
    },
    onSubmitted: ({ fixtureId, side }) => {
      matchVideoReportedSides.add(`${fixtureId}:${side}`);
      renderCup();
    },
  });
}

function renderToolbar() {
  const bar = document.getElementById("cupToolbar");
  bar.innerHTML = "";
  for (const code of CUP_CODES) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = CUP_LABELS[code] || code;
    btn.className = currentCup === code ? "active" : "";
    btn.onclick = () => {
      currentCup = code;
      cupRoundFilter = "";
      cupClubFilter = "";
      applyCupPageTheme(currentCup);
      const hero = document.getElementById("cupHero");
      if (hero) {
        hero.innerHTML = renderCupHero(currentCup, CUP_LABELS[currentCup]);
      }
      const archiveSeason = seasonFromUrl();
      if (archiveSeason) {
        const u = new URL(window.location.href);
        u.searchParams.set("cup", code);
        u.searchParams.set("season", archiveSeason);
        history.replaceState(null, "", u);
      }
      renderToolbar();
      syncCupDrawReplayLink();
      void renderCup();
    };
    bar.appendChild(btn);
  }
}

function renderQualified(clubs) {
  const el = document.getElementById("qualifiedList");
  if (!clubs.length) {
    el.innerHTML =
      '<span class="empty">No qualifiers — need standings (prestige) or season clubs (league cup).</span>';
    return;
  }
  el.textContent = clubs.map((s) => fullClubName(s) || s).join(" · ");
}

function isMyMatch(m) {
  if (!myClubShort || !m) return false;
  const me = normalizeClubKey(myClubShort);
  return (
    normalizeClubKey(m.home_club_short_name) === me ||
    normalizeClubKey(m.away_club_short_name) === me
  );
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function matchdayUrl(fixtureId) {
  return `matchday.html?fixture=${encodeURIComponent(String(fixtureId))}`;
}

/** Merge bracket node + competition_fixtures_public row for schedule / videos / actions. */
function cupFixtureView(leg, extras) {
  if (!leg?.fixture_id) return null;
  const fid = Number(leg.fixture_id);
  const pub = extras?.fixturesById?.get(fid) || {};
  return {
    id: fid,
    ...pub,
    home_club_short_name: leg.home_club_short_name || pub.home_club_short_name,
    away_club_short_name: leg.away_club_short_name || pub.away_club_short_name,
    home_club_name: leg.home_club_name || pub.home_club_name,
    away_club_name: leg.away_club_name || pub.away_club_name,
    status: pub.status || leg.fixture_status,
    home_goals: pub.home_goals ?? leg.home_goals,
    away_goals: pub.away_goals ?? leg.away_goals,
    competition_type: pub.competition_type || "cup",
    cup_code: pub.cup_code || currentCup,
    gpsl_month: leg.fixture_gpsl_month || leg.round_gpsl_month || pub.gpsl_month,
  };
}

function cupCheckInHtml(f) {
  if (!f || f.status === "played") return "";
  if (String(f.schedule_status || "").toLowerCase() !== "agreed") return "";
  const h = f.home_checked_in ? "H✓" : "H○";
  const a = f.away_checked_in ? "A✓" : "A○";
  const both = f.home_checked_in && f.away_checked_in;
  return `<span class="cup-ci${both ? " cup-ci--both" : ""}" title="Check-in (home / away)">${h} ${a}</span>`;
}

function cupKickoffHtml(f) {
  if (!f || f.status === "played") return "";
  if (f.manual_black_box === true) {
    return `<span class="cup-ko cup-ko--manual" title="Both clubs GPSL match system OFF">Manual arrange</span>`;
  }
  const status = String(f.schedule_status || "unscheduled").toLowerCase();
  const catchUp = isCatchUpFixture(f);
  const catchUpPrefix = catchUp ? "Catch-up · " : "";
  if (status === "agreed" && f.agreed_kickoff_at) {
    return `<span class="cup-ko cup-ko--agreed">${catchUpPrefix}${escapeHtml(formatKickoff(f.agreed_kickoff_at, UK_TZ))} UK</span>`;
  }
  const grace = fixtureNewOwnerArrangeGrace(f);
  if (grace && status !== "agreed") {
    return newOwnerGraceKickoffNoteHtml(grace, { catchUp });
  }
  if (status === "negotiating") {
    const who = scheduleReplyOwedBy(f);
    const whoBit = who ? ` · ${escapeHtml(who)} to reply` : "";
    return `<span class="cup-ko cup-ko--pending">${catchUpPrefix}Proposal pending${whoBit}</span>`;
  }
  const holidayNote = fixtureHolidayArrangeNote(f);
  if (holidayNote) {
    return holidayKickoffNoteHtml(holidayNote, { catchUp });
  }
  if (f.id) {
    return `<span class="cup-ko cup-ko--open">${catchUpPrefix}Not scheduled</span>`;
  }
  return "";
}

function cupVideoTicksHtml(f) {
  if (!f?.id) return "";
  return matchVideoTicksHtml(matchVideoMap.get(String(f.id)), {
    fixtureId: f.id,
    fixture: f,
    myClubShort: myClubShort,
    allowReport: Boolean(myClubShort) || videoAdmin,
    reportedSides: matchVideoReportedSides,
    adminView: videoAdmin,
    clearedSides: matchVideoAdminCleared,
  });
}

function cupOpsHtml(leg, extras) {
  const f = cupFixtureView(leg, extras);
  if (!f) return "";

  const myClub = { short: myClubShort };
  const involvesMe = isMyMatch(leg);
  const parts = [];

  const ko = cupKickoffHtml(f) + finalPlayCutoffDateHtml(f) + fixtureExpiryWarningHtml(f);
  const ci = cupCheckInHtml(f);
  if (ko || ci) {
    parts.push(
      `<div class="cup-ops-meta">${ko}${ci ? ` ${ci}` : ""}${cupVideoTicksHtml(f)}</div>`
    );
  } else if (f.status === "played" || matchVideoMap.has(String(f.id))) {
    parts.push(`<div class="cup-ops-meta cup-ops-meta--videos">${cupVideoTicksHtml(f)}</div>`);
  }

  const actionBits = [];
  if (involvesMe && myClubShort) {
    if (canSubmitResult(f, myClub, calendarStatus, holidayContext)) {
      actionBits.push(
        `<a class="leg-action leg-enter" href="${matchdayUrl(f.id)}">Enter result</a>`
      );
    } else if (needsInboxConfirm(f, myClub)) {
      actionBits.push(
        `<a class="leg-action leg-enter" href="${matchdayUrl(f.id)}">Confirm result</a>`
      );
    } else if (
      f.submission_status === "pending" &&
      f.submitted_by_club &&
      normalizeClubKey(f.submitted_by_club) === normalizeClubKey(myClubShort)
    ) {
      actionBits.push(`<div class="leg-action leg-locked">Awaiting confirm</div>`);
    } else if (f.status === "played") {
      const deferred = deferredResultNote(f, calendarStatus);
      actionBits.push(
        `<div class="leg-action played-tag">${deferred ? "Played · pending table" : "Played"}</div>`
      );
    } else if (f.manual_black_box === true) {
      actionBits.push(
        `<a class="leg-action leg-enter" href="${matchdayUrl(f.id)}">Manual · Match Day</a>`
      );
    } else {
      const sched = scheduleActionLabel(f, myClubShort);
      if (sched && !sched.vacantWalkover && !sched.newOwnerGrace) {
        const cls = sched.muted ? "leg-action leg-sched muted" : "leg-action leg-enter";
        actionBits.push(`<a class="${cls}" href="${sched.href}">${escapeHtml(sched.label)}</a>`);
      }
    }
    if (
      f.status === "scheduled" &&
      !actionBits.some((html) => html.includes("fixture_schedule.html"))
    ) {
      actionBits.push(
        `<a class="leg-action leg-sched muted" href="fixture_schedule.html?fixture=${encodeURIComponent(String(f.id))}">Schedule</a>`
      );
    }
  } else if (f.status === "played") {
    actionBits.push(`<div class="leg-action played-tag">Played</div>`);
  } else if (
    f.id &&
    ["agreed", "negotiating"].includes(String(f.schedule_status || "").toLowerCase())
  ) {
    const schedHref = `fixture_schedule.html?fixture=${encodeURIComponent(String(f.id))}`;
    actionBits.push(
      `<a class="leg-action leg-sched muted" href="${schedHref}">Schedule / check-in</a>`
    );
  }

  if (actionBits.length) {
    parts.push(`<div class="cup-ops-actions">${actionBits.join("")}</div>`);
  }

  return parts.join("");
}

function renderScoreLinesHtml(lines) {
  if (!lines?.length) return "";
  return `<div class="score-lines">${lines
    .map(
      (ln) =>
        `<div><span class="lbl">${escapeHtml(ln.label)}</span> ${escapeHtml(ln.text)}</div>`
    )
    .join("")}</div>`;
}

function renderFinanceHtml(financeRows) {
  if (!financeRows?.length) return "";
  const rows = financeRows
    .map((c) => {
      const parts = [];
      if (c.gate > 0) parts.push(`<span class="fin-gate">Gate ${formatMoney(c.gate)}</span>`);
      if (c.tv > 0) parts.push(`<span class="fin-tv">TV ${formatMoney(c.tv)}</span>`);
      if (c.prize > 0) parts.push(`<span class="fin-prize">Prize ${formatMoney(c.prize)}</span>`);
      return `<div class="club-fin"><b>${escapeHtml(c.club)}</b> — ${parts.join(" · ")}</div>`;
    })
    .join("");
  return `<div class="match-finance">${rows}</div>`;
}

function legPlayable(leg, extras, { leg1Played = true } = {}) {
  if (!leg?.fixture_id) {
    return { playable: false, reason: leg.preview ? "Sample · not a real tie" : "Awaiting draw / teams" };
  }
  if (leg.fixture_status === "played") return { playable: false, reason: "Played" };

  const month = leg.round_gpsl_month || leg.fixture_gpsl_month;
  const monthLabel = GPSL_MONTH_LABELS[month] || month || "later month";
  const monthOpen = isGpslMonthCurrentlyPlayable(month, calendarStatus);

  if (!monthOpen) {
    return { playable: false, reason: `Opens ${monthLabel}` };
  }
  if (!leg1Played) {
    return { playable: false, reason: "After 1st leg" };
  }
  if (myClubShort && isMyMatch(leg)) {
    return { playable: true, reason: "Enter result" };
  }
  return { playable: false, reason: "Scheduled" };
}

function matchVenueLabel(m) {
  return String(m?.venue_name || "").trim();
}

function matchTvBadgeHtml(m) {
  const stage = String(m?.round_stage || "").toLowerCase();
  const label = String(m?.round_label || "").toLowerCase();
  if (stage === "final" || label === "final") {
    return '<span class="tv-fixture-badge" title="Cup final — always on TV">📺</span>';
  }
  return m?.fixture_id ? tvFixtureBadgeHtml(m.fixture_id) : "";
}

function renderVenueHtml(m) {
  const venue = matchVenueLabel(m);
  const tv = matchTvBadgeHtml(m);
  if (!venue && !tv) return "";
  if (!venue) return `<div class="match-venue">${tv}</div>`;
  return `<div class="match-venue">${tv}${tv ? " " : ""}${escapeHtml(venue)}</div>`;
}

function cupSideHtml(name, shortName) {
  const label = name || shortName || "TBD";
  if (!shortName) {
    return `<span class="fixture-club"><span class="fixture-club-body"><span class="fixture-club-name">${escapeHtml(label)}</span></span></span>`;
  }
  return clubWithOwnerHtml(label, shortName, "block");
}

function renderLegPane(leg, extras, opts) {
  if (!leg) {
    return `<div class="leg-pane leg-empty"><div class="leg-label">${escapeHtml(opts.legLabel)}</div><div class="leg-teams">${cupSideHtml("TBD")}<span class="vs">vs</span>${cupSideHtml("TBD")}</div></div>`;
  }

  const home = leg.home_club_name || leg.home_club_short_name || "TBD";
  const away = leg.away_club_name || leg.away_club_short_name || "TBD";
  const played = leg.fixture_status === "played";
  const scoreLines = played ? formatCupScoreLines(leg, extras) : null;
  const finance = played ? formatCupMatchFinance(leg, extras) : [];
  const conditions =
    leg.fixture_id && (leg.weather || leg.pitch_condition || leg.kit_season)
      ? formatMatchConditions(leg)
      : "";
  const f = cupFixtureView(leg, extras);
  const opsHtml = cupOpsHtml(leg, extras);
  const { playable, reason } = legPlayable(leg, extras, opts);
  let fallbackAction = "";
  if (!opsHtml) {
    if (played) {
      fallbackAction = `<div class="leg-action played-tag">Played</div>`;
    } else if (playable && leg.fixture_id) {
      fallbackAction = `<a class="leg-action leg-enter" href="${matchdayUrl(leg.fixture_id)}">Enter result</a>`;
    } else {
      fallbackAction = `<div class="leg-action leg-locked">${escapeHtml(reason)}</div>`;
    }
  }

  return `
    <div class="leg-pane ${isMyMatch(leg) ? "my-club" : ""} ${played ? "played" : ""}">
      <div class="leg-label">${escapeHtml(opts.legLabel)}</div>
      <div class="leg-teams">${cupSideHtml(home, leg.home_club_short_name)}<span class="vs">vs</span>${cupSideHtml(away, leg.away_club_short_name)}${f ? matchCentreButtonHtml(f) : ""}</div>
      ${renderVenueHtml(leg)}
      ${conditions ? `<div class="leg-conditions" style="font-size:11px;color:#888;margin:4px 0;">${escapeHtml(conditions)}</div>` : ""}
      ${renderScoreLinesHtml(scoreLines)}
      ${opsHtml || fallbackAction}
      ${leg?.preview ? previewOpsSampleHtml() : ""}
      ${renderFinanceHtml(finance)}
    </div>`;
}

function previewOpsSampleHtml() {
  return `<div class="cup-ops-meta"><span class="cup-ko cup-ko--open">Kick-off not set</span> <span class="cup-ci">H○ A○</span> <span class="mv-ticks">H · A · R</span></div>`;
}

function renderTwoLegTieCard(tie, extras) {
  const { leg1, leg2, match_no: matchNo } = tie;
  const agg = cupTwoLegAggregate(leg1, leg2, extras);
  const leg1Played = !!agg?.leg1Played;

  const leg1Month = GPSL_MONTH_LABELS.september;
  const leg2Month = GPSL_MONTH_LABELS.october;

  let aggHtml = "";
  if (agg) {
    const aggText = `${agg.homeClub} ${agg.homeAgg}–${agg.awayAgg} ${agg.awayClub}`;
    if (agg.complete && agg.winnerName) {
      aggHtml = `
        <div class="tie-aggregate complete">
          <span class="agg-lbl">Aggregate</span> ${escapeHtml(aggText)}
          <span class="agg-winner">→ ${escapeHtml(agg.winnerName)}</span>
        </div>`;
    } else {
      aggHtml = `
        <div class="tie-aggregate partial">
          <span class="agg-lbl">Aggregate</span> ${escapeHtml(aggText)}
          ${!agg.leg2Played ? `<span class="agg-hint">2nd leg in ${leg2Month}</span>` : ""}
        </div>`;
    }
  }

  const myTie = isMyMatch(leg1) || isMyMatch(leg2);

  return `
    <div class="bracket-tie ${myTie ? "my-club" : ""}">
      <div class="tie-head">Tie ${matchNo}</div>
      <div class="tie-legs">
        ${renderLegPane(leg1, extras, { legLabel: `1st leg · ${leg1Month}`, leg1Played: true })}
        ${renderLegPane(leg2, extras, { legLabel: `2nd leg · ${leg2Month}`, leg1Played })}
      </div>
      ${aggHtml}
    </div>`;
}

function renderMatchCard(m, extras, roundNo) {
  const r1Bye =
    roundNo === 1 &&
    m.home_club_short_name &&
    !m.away_club_short_name &&
    !m.fixture_id;
  const awaitingOpp =
    roundNo > 1 &&
    ((m.home_club_short_name && !m.away_club_short_name) ||
      (!m.home_club_short_name && m.away_club_short_name));
  const homeName = r1Bye
    ? m.home_club_name || m.home_club_short_name || "TBD"
    : m.home_club_name ||
      m.home_club_short_name ||
      (awaitingOpp && !m.home_club_short_name ? "Awaiting opponent" : "TBD");
  const awayName = r1Bye
    ? "Bye"
    : m.away_club_name ||
      m.away_club_short_name ||
      (awaitingOpp && !m.away_club_short_name ? "Awaiting opponent" : "TBD");
  const homeShort = m.home_club_short_name || null;
  const awayShort = r1Bye ? null : m.away_club_short_name || null;
  const played = m.fixture_status === "played";
  const scoreLines = played ? formatCupScoreLines(m, extras) : null;
  const finance = played ? formatCupMatchFinance(m, extras) : [];

  let status = m.preview ? "Sample tie" : "Awaiting draw / teams";
  if (played) status = "Played";
  else if (m.fixture_id) status = "Scheduled";
  else if (r1Bye || (m.winner_club_name && !m.fixture_id && roundNo === 1))
    status = "Bye to next round";
  else if (awaitingOpp) {
    status = "Awaiting opponent";
  }

  let winnerHtml = "";
  if (m.winner_club_name && !scoreLines?.some((l) => l.label === "Pens")) {
    winnerHtml = `<div class="match-winner">→ ${escapeHtml(m.winner_club_name)}</div>`;
  }

  const month = m.fixture_gpsl_month || m.round_gpsl_month;
  const monthOpen = isGpslMonthCurrentlyPlayable(month, calendarStatus);
  const conditions =
    m.fixture_id && (m.weather || m.pitch_condition || m.kit_season)
      ? formatMatchConditions(m)
      : "";
  const f = cupFixtureView(m, extras);
  const opsHtml = cupOpsHtml(m, extras);
  let fallbackAction = "";
  if (!opsHtml && !played && m.fixture_id && monthOpen && isMyMatch(m)) {
    fallbackAction = `<a class="leg-action leg-enter" href="${matchdayUrl(m.fixture_id)}">Enter result</a>`;
  }

  return `
    <div class="bracket-match ${isMyMatch(m) ? "my-club" : ""} ${played ? "played" : ""}">
      <div class="match-status">M${m.match_no} · ${escapeHtml(status)}</div>
      <div class="match-teams">${cupSideHtml(homeName, homeShort)}<span class="vs">vs</span>${cupSideHtml(awayName, awayShort)}${f ? matchCentreButtonHtml(f) : ""}</div>
      ${renderVenueHtml(m)}
      ${conditions ? `<div class="match-conditions" style="font-size:11px;color:#888;margin:4px 0;">${escapeHtml(conditions)}</div>` : ""}
      ${renderScoreLinesHtml(scoreLines)}
      ${opsHtml || fallbackAction}
      ${m.preview ? previewOpsSampleHtml() : ""}
      ${winnerHtml}
      ${renderFinanceHtml(finance)}
    </div>`;
}

function clubsInBracket(nodes) {
  const map = new Map();
  for (const m of nodes || []) {
    for (const [short, name] of [
      [m.home_club_short_name, m.home_club_name],
      [m.away_club_short_name, m.away_club_name],
    ]) {
      const key = normalizeClubKey(short);
      if (!key || map.has(key)) continue;
      map.set(key, { short, name: name || short });
    }
  }
  const mine = normalizeClubKey(myClubShort);
  return [...map.values()].sort((a, b) => {
    const aMine = normalizeClubKey(a.short) === mine ? 0 : 1;
    const bMine = normalizeClubKey(b.short) === mine ? 0 : 1;
    if (aMine !== bMine) return aMine - bMine;
    return a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
  });
}

function roundFilterLabel(round) {
  const sample = round.matches[0] || {};
  return sample.round_label || cupRoundLabel(cupRoundTieCount(round.matches));
}

function matchInvolvesShort(m, key) {
  if (!m || !key) return false;
  return [m.home_club_short_name, m.away_club_short_name].some(
    (s) => normalizeClubKey(s) === key
  );
}

function filterCupRounds(rounds) {
  const key = normalizeClubKey(cupClubFilter);
  return rounds
    .filter((r) => !cupRoundFilter || String(r.round_no) === cupRoundFilter)
    .map((r) => {
      if (!key) return r;
      if (isTwoLegCupQuarterFinal(currentCup, r.round_no)) {
        const ties = groupCupBracketTies(r.matches, currentCup, r.round_no);
        const keep = new Set(
          ties
            .filter(
              (t) => matchInvolvesShort(t.leg1, key) || matchInvolvesShort(t.leg2, key)
            )
            .map((t) => t.match_no)
        );
        return { ...r, matches: r.matches.filter((m) => keep.has(m.match_no)) };
      }
      return { ...r, matches: r.matches.filter((m) => matchInvolvesShort(m, key)) };
    })
    .filter((r) => r.matches.length);
}

function renderCupFilters(nodes) {
  const bar = document.getElementById("cupFilterBar");
  if (!bar) return;
  const rounds = preprocessCupBracketRounds(nodes || [], currentCup);
  const clubs = clubsInBracket(nodes || []);
  if (cupRoundFilter && !rounds.some((r) => String(r.round_no) === cupRoundFilter)) {
    cupRoundFilter = "";
  }
  if (
    cupClubFilter &&
    !clubs.some((c) => normalizeClubKey(c.short) === normalizeClubKey(cupClubFilter))
  ) {
    cupClubFilter = "";
  }

  bar.replaceChildren();

  const roundLabel = document.createElement("label");
  roundLabel.className = "cup-filter";
  roundLabel.textContent = "Round";
  const roundSel = document.createElement("select");
  roundSel.id = "cupRoundFilter";
  roundSel.title = "Show one round of this cup";
  const allRounds = document.createElement("option");
  allRounds.value = "";
  allRounds.textContent = "All rounds";
  roundSel.appendChild(allRounds);
  for (const round of rounds) {
    const opt = document.createElement("option");
    opt.value = String(round.round_no);
    opt.textContent = roundFilterLabel(round);
    roundSel.appendChild(opt);
  }
  roundSel.value = cupRoundFilter;
  roundSel.onchange = () => {
    cupRoundFilter = roundSel.value;
    renderBracket(lastBracketNodes, lastBracketExtras);
  };
  roundLabel.appendChild(roundSel);

  const clubLabel = document.createElement("label");
  clubLabel.className = "cup-filter";
  clubLabel.textContent = "Club";
  const clubSel = document.createElement("select");
  clubSel.id = "cupClubFilter";
  clubSel.title = "Show ties for one club";
  const allClubs = document.createElement("option");
  allClubs.value = "";
  allClubs.textContent = "All clubs";
  clubSel.appendChild(allClubs);
  const mine = normalizeClubKey(myClubShort);
  for (const club of clubs) {
    const opt = document.createElement("option");
    opt.value = club.short;
    opt.textContent =
      mine && normalizeClubKey(club.short) === mine ? `${club.name} (my club)` : club.name;
    clubSel.appendChild(opt);
  }
  clubSel.value = cupClubFilter;
  clubSel.onchange = () => {
    cupClubFilter = clubSel.value;
    renderBracket(lastBracketNodes, lastBracketExtras);
  };
  clubLabel.appendChild(clubSel);

  bar.append(roundLabel, clubLabel);
}

function previewNodesFromSchedule() {
  const rows = (cupScheduleRows || []).filter((row) => Number(row.matches_in_round) > 0);
  if (!rows.length) return [];
  const cap = 4;
  let nextId = -1;
  const byRound = new Map();
  for (const row of rows) {
    const roundNo = Number(row.round_no);
    if (!byRound.has(roundNo)) byRound.set(roundNo, []);
    byRound.get(roundNo).push(row);
  }
  const nodes = [];
  for (const roundNo of [...byRound.keys()].sort((a, b) => a - b)) {
    const legs = byRound.get(roundNo);
    const leg1 = legs.find((row) => Number(row.cup_leg) === 1) || legs[0];
    const leg2 = legs.find((row) => Number(row.cup_leg) === 2);
    const total = Number(leg1.matches_in_round) || 1;
    const show = Math.min(total, cap);
    const isFinal =
      String(leg1.stage || "").toLowerCase() === "final" ||
      String(leg1.round_label || "").toLowerCase() === "final";
    for (let matchNo = 1; matchNo <= show; matchNo += 1) {
      const home = `Club ${matchNo * 2 - 1}`;
      const away = `Club ${matchNo * 2}`;
      const leg1Id = nextId;
      nextId -= 1;
      nodes.push({
        id: leg1Id,
        preview: true,
        preview_more: matchNo === show && total > show ? total - show : 0,
        round_no: roundNo,
        match_no: matchNo,
        cup_leg: 1,
        round_label: leg1.round_label,
        round_stage: leg1.stage,
        round_gpsl_month: leg1.gpsl_month,
        fixture_gpsl_month: leg1.gpsl_month,
        home_club_name: home,
        away_club_name: away,
        venue_name: isFinal ? "Wembley" : "Home stadium",
      });
      if (leg2) {
        nodes.push({
          id: nextId,
          preview: true,
          round_no: roundNo,
          match_no: matchNo,
          cup_leg: 2,
          leg1_node_id: leg1Id,
          round_label: leg2.round_label || leg1.round_label,
          round_stage: leg2.stage || leg1.stage,
          round_gpsl_month: leg2.gpsl_month,
          fixture_gpsl_month: leg2.gpsl_month,
          home_club_name: away,
          away_club_name: home,
          venue_name: "Home stadium",
        });
        nextId -= 1;
      }
    }
  }
  return nodes;
}

function isGroupStageCup(cup) {
  return cup === "super8" || cup === "bowl";
}

function syncCupSectionCopy() {
  const title = document.getElementById("cupSectionTitle");
  const strip = document.getElementById("cupProcess");
  const group = isGroupStageCup(currentCup) && !lastBracketNodes.length;
  if (title) title.textContent = group ? "Group stage" : "Knockout bracket";
  if (!strip) return;
  strip.innerHTML = group
    ? `
      <div class="mod"><div class="k">Groups</div><div class="v">Two groups of four</div><div class="s">Group A is 1st with 6th, 7th and 8th. Group B is 2nd with 3rd, 4th and 5th.</div></div>
      <div class="mod"><div class="k">Each tie</div><div class="v">Home and away</div><div class="s">Two matches, one tie. The aggregate sets the points. Away goals only split a level aggregate.</div></div>
      <div class="mod"><div class="k">Points</div><div class="v">3, 2, 1, 0</div><div class="s">Aggregate win 3, loss 0. Level aggregate: 2 for more away goals, 1 for fewer, 1 each if away goals are level. The top two in each group go through.</div></div>
      <div class="mod"><div class="k">Semis</div><div class="v">Cross</div><div class="s">Winner of A plays runner-up of B, and the other way around. The final is at Wembley.</div></div>
      <div class="mod"><div class="k">Each match</div><div class="v">Kick-off</div><div class="s">Check-in, Match Centre, and video ticks (H/A ✓ · report R).</div></div>`
    : `
      <div class="mod"><div class="k">Progression</div><div class="v">Left → right</div><div class="s">Early rounds on the left, the final on the right.</div></div>
      <div class="mod"><div class="k">Scores</div><div class="v">90, extra time, pens</div><div class="s">90 minutes, after extra time, and the penalty winner.</div></div>
      <div class="mod"><div class="k">Stadium</div><div class="v">Home venue</div><div class="s">Cup finals are at Wembley.</div></div>
      <div class="mod"><div class="k">Money</div><div class="v">After the result</div><div class="s">Gate receipts and prize money once the tie is confirmed.</div></div>
      <div class="mod"><div class="k">Each tie</div><div class="v">Kick-off</div><div class="s">Check-in, Match Centre, and video ticks (H/A ✓ · report R).</div></div>`;
}

function groupTieLines(pairs) {
  return pairs
    .map(
      ([home, away]) =>
        `<div class="group-tie">${escapeHtml(home)} vs ${escapeHtml(away)}<span>home and away</span></div>`
    )
    .join("");
}

function groupPreviewColumn(title, seeds, pairs) {
  return `
    <div class="bracket-round">
      <div class="round-title">${escapeHtml(title)}</div>
      <div class="bracket-match">
        <div class="group-seeds">${escapeHtml(seeds)}</div>
        ${groupTieLines(pairs)}
        <div class="cup-ops-meta"><span class="cup-ko cup-ko--open">Kick-off not set</span> <span class="cup-ci">H○ A○</span> <span class="mv-ticks">H · A · R</span></div>
      </div>
    </div>`;
}

function groupStagePreviewHtml() {
  const semis = [
    ["Winner Group A", "Runner-up Group B"],
    ["Winner Group B", "Runner-up Group A"],
  ]
    .map(
      ([home, away]) => `
      <div class="bracket-match">
        <div class="match-status">Sample tie · one match</div>
        <div class="match-teams">${escapeHtml(home)}<span class="vs">vs</span>${escapeHtml(away)}</div>
        <div class="match-venue">Home stadium</div>
        ${previewOpsSampleHtml()}
      </div>`
    )
    .join("");
  return `
    <p class="cup-preview-banner">Preview of the group draw. These are last season’s places, not real clubs. Admin has not drawn this cup yet.
      <button type="button" id="hideCupPreview" class="cup-preview-toggle">Hide preview</button></p>
    <div class="bracket-flow is-preview">
      ${groupPreviewColumn(
        "Group A",
        "1st, 6th, 7th, 8th",
        [
          ["1st", "6th"],
          ["1st", "7th"],
          ["1st", "8th"],
          ["6th", "7th"],
          ["6th", "8th"],
          ["7th", "8th"],
        ]
      )}
      ${groupPreviewColumn(
        "Group B",
        "2nd, 3rd, 4th, 5th",
        [
          ["2nd", "3rd"],
          ["2nd", "4th"],
          ["2nd", "5th"],
          ["3rd", "4th"],
          ["3rd", "5th"],
          ["4th", "5th"],
        ]
      )}
      <div class="bracket-round">
        <div class="round-title">Semi-final · November</div>
        ${semis}
      </div>
      <div class="bracket-round">
        <div class="round-title">Final · December</div>
        <div class="bracket-match">
          <div class="match-status">Sample tie · one match</div>
          <div class="match-teams">Semi winner<span class="vs">vs</span>Semi winner</div>
          <div class="match-venue">📺 Wembley</div>
          ${previewOpsSampleHtml()}
        </div>
      </div>
    </div>
    <p class="bracket-arrow-hint">← Groups · Final →</p>`;
}

function wireCupPreviewButtons() {
  document.getElementById("hideCupPreview")?.addEventListener("click", () => {
    previewHiddenCups.add(currentCup);
    renderBracket(lastBracketNodes, lastBracketExtras);
  });
  document.getElementById("showCupPreview")?.addEventListener("click", () => {
    previewHiddenCups.delete(currentCup);
    renderBracket(lastBracketNodes, lastBracketExtras);
  });
}

function renderBracket(nodes, extras) {
  const root = document.getElementById("bracketRoot");
  lastBracketNodes = nodes || [];
  lastBracketExtras = extras || null;
  const groupCup = isGroupStageCup(currentCup);
  const showingPreview = !lastBracketNodes.length && !previewHiddenCups.has(currentCup);
  syncCupSectionCopy();
  if (showingPreview && groupCup) {
    renderCupFilters([]);
    root.innerHTML = groupStagePreviewHtml();
    wireCupPreviewButtons();
    return;
  }
  const source = showingPreview ? previewNodesFromSchedule() : lastBracketNodes;
  renderCupFilters(source);
  if (!source.length) {
    const canPreview = !lastBracketNodes.length && (groupCup || cupScheduleRows.length > 0);
    const emptyText = groupCup
      ? "No draw yet. Admin draws this cup in GPSL Admin."
      : "No bracket yet. Admin draws this cup in GPSL Admin.";
    root.innerHTML = canPreview
      ? `<p class="empty">${emptyText}</p>
         <button type="button" id="showCupPreview" class="cup-preview-toggle">Show draw preview</button>`
      : `<p class="empty">${emptyText}</p>`;
    wireCupPreviewButtons();
    return;
  }

  const rounds = filterCupRounds(preprocessCupBracketRounds(source, currentCup));
  if (!rounds.length) {
    root.innerHTML = '<p class="empty">No ties match this round and club.</p>';
    return;
  }
  const flowClass =
    currentCup === "league_cup" ? "bracket-flow bracket-flow--league-cup" : "bracket-flow";
  const banner = showingPreview
    ? `<p class="cup-preview-banner">Preview of the draw. These are not real clubs or ties. Admin has not drawn this cup yet.
         <button type="button" id="hideCupPreview" class="cup-preview-toggle">Hide preview</button></p>`
    : "";
  root.innerHTML = `
    ${banner}
    <div class="${flowClass}${showingPreview ? " is-preview" : ""}">
      ${rounds.map(({ round_no, matches }) => renderBracketRoundColumn(round_no, matches, extras)).join("")}
    </div>
    <p class="bracket-arrow-hint">← Early rounds · Final →</p>
  `;
  wireCupPreviewButtons();
}

/** Compact prize for round headers, e.g. 10000000 → ₿10m */
function formatMoneyCompact(amount) {
  const n = Number(amount);
  if (!Number.isFinite(n) || n <= 0) return "";
  if (n >= 1_000_000) {
    const m = n / 1_000_000;
    const text = Number.isInteger(m) ? String(m) : String(Number(m.toFixed(2)));
    return `₿${text}m`;
  }
  if (n >= 1_000) {
    const k = n / 1_000;
    const text = Number.isInteger(k) ? String(k) : String(Number(k.toFixed(1)));
    return `₿${text}k`;
  }
  return formatMoney(n);
}

function groupPrizeSummary() {
  if (currentCup !== "super8" && currentCup !== "bowl") return "";
  const lines = [
    ["appearance", "group appearance"],
    ["group_win", "group win"],
    ["group_draw", "group draw"],
    ["group_loss", "group loss"],
    ["sf", "semi-final"],
    ["winner", "winner"],
    ["runner_up", "runner-up"],
  ];
  const parts = [];
  for (const [stage, label] of lines) {
    const amt = Number(cupPrizeByStage.get(stage) || 0);
    if (amt > 0) parts.push(`${label} ${formatMoneyCompact(amt)}`);
  }
  if (!parts.length) return "";
  return `Prize money: ${parts.join(" · ")}.`;
}

function roundPrizeHint(round_no) {
  const stage = cupRoundStageByNo.get(Number(round_no));
  if (!stage) return "";

  if (stage === "final") {
    const win = Number(cupPrizeByStage.get("winner") || 0);
    const run = Number(cupPrizeByStage.get("runner_up") || 0);
    const parts = [];
    if (win > 0) parts.push(`Winner ${formatMoneyCompact(win)}`);
    if (run > 0) parts.push(`Runner-up ${formatMoneyCompact(run)}`);
    const appearance = Number(cupPrizeByStage.get("appearance") || 0);
    if (appearance > 0) parts.push(`${formatMoneyCompact(appearance)} appearance`);
    return parts.length ? `(${parts.join(" · ")})` : "";
  }

  const roundAmt = Number(cupPrizeByStage.get(stage) || 0);
  const appearance = Number(cupPrizeByStage.get("appearance") || 0);
  const parts = [];
  if (roundAmt > 0) {
    // Both clubs receive this when the tie is played — owners know it as appearance money.
    parts.push(`${formatMoneyCompact(roundAmt)} appearance fee`);
  } else if (appearance > 0) {
    parts.push(`${formatMoneyCompact(appearance)} appearance fee`);
  }
  return parts.length ? `(${parts.join(" · ")})` : "";
}

async function loadCupPrizeContext(seasonId, cupCode) {
  cupPrizeByStage = new Map();
  cupRoundStageByNo = new Map();
  cupScheduleRows = [];
  if (!cupCode) return;

  const prizeQuery = seasonId
    ? supabase
        .from("competition_cup_prize_config_public")
        .select("stage, amount")
        .eq("season_id", seasonId)
        .eq("cup_code", cupCode)
    : Promise.resolve({ data: [], error: null });

  const [{ data: prizes, error: prizeErr }, { data: schedule, error: schedErr }] =
    await Promise.all([
      prizeQuery,
      supabase
        .from("competition_cup_round_schedule")
        .select("round_no, stage, cup_leg, gpsl_month, round_label, matches_in_round")
        .eq("cup_code", cupCode),
    ]);

  if (prizeErr) {
    console.warn("cups prize config:", prizeErr);
  } else {
    for (const row of prizes || []) {
      const amt = Number(row.amount) || 0;
      if (amt > 0) cupPrizeByStage.set(String(row.stage), amt);
    }
  }

  if (schedErr) {
    console.warn("cups round schedule:", schedErr);
  } else {
    cupScheduleRows = schedule || [];
    for (const row of schedule || []) {
      if (row?.round_no == null || !row.stage) continue;
      // Prefer leg 1 stage if both legs exist
      if (cupRoundStageByNo.has(Number(row.round_no)) && Number(row.cup_leg) === 2) {
        continue;
      }
      cupRoundStageByNo.set(Number(row.round_no), String(row.stage));
    }
  }
}

function renderBracketRoundColumn(round_no, matches, extras) {
  const sample = matches[0] || {};
  const title = sample.round_label || cupRoundLabel(cupRoundTieCount(matches));
  const prizeHint = roundPrizeHint(round_no);
  const twoLegQf = isTwoLegCupQuarterFinal(currentCup, round_no);

  if (twoLegQf) {
    const ties = groupCupBracketTies(matches, currentCup, round_no);
    const columnTitle = `${title} · ${GPSL_MONTH_LABELS.september}/${GPSL_MONTH_LABELS.october}${
      prizeHint ? ` ${prizeHint}` : ""
    }`;
    const cards = ties.map((tie) => renderTwoLegTieCard(tie, extras)).join("");
    return `
      <div class="bracket-round bracket-round-two-leg" data-round="${round_no}">
        <div class="round-title">${escapeHtml(columnTitle)}</div>
        ${cards}
        ${previewMoreNote(matches)}
      </div>`;
  }

  const month =
    GPSL_MONTH_LABELS[sample.round_gpsl_month || sample.fixture_gpsl_month] ||
    sample.round_gpsl_month ||
    "";
  const base = month ? `${title} · ${month}` : title;
  const columnTitle = prizeHint ? `${base} ${prizeHint}` : base;
  const cards = matches.map((m) => renderMatchCard(m, extras, round_no)).join("");
  return `
    <div class="bracket-round" data-round="${round_no}">
      <div class="round-title">${escapeHtml(columnTitle)}</div>
      ${cards}
      ${previewMoreNote(matches)}
    </div>`;
}

function previewMoreNote(matches) {
  const more = Math.max(0, ...(matches || []).map((m) => Number(m.preview_more) || 0));
  if (!more) return "";
  return `<p class="preview-more">+ ${more} more tie${more === 1 ? "" : "s"} in this round</p>`;
}

async function loadCupVideosAndExtras(fixtureIds) {
  const [extras, videos, reported, cleared] = await Promise.all([
    loadCupMatchExtras(supabase, fixtureIds),
    loadFixtureMatchVideos(supabase, fixtureIds),
    loadMatchVideoReportedSides(supabase, fixtureIds),
    videoAdmin
      ? loadMatchVideoAdminClearedSides(supabase, fixtureIds)
      : Promise.resolve(new Set()),
  ]);
  matchVideoMap = videos;
  matchVideoReportedSides = reported;
  matchVideoAdminCleared = cleared;
  lastCupFixturesById = extras.fixturesById || new Map();
  return extras;
}

async function renderCup() {
  ensureMatchVideoStyles();
  ensureMatchVideoReportsWired();
  const archiveSeason = seasonFromUrl();
  const pageMeta = document.getElementById("pageMeta");

  if (archiveSeason) {
    if (pageMeta) {
      pageMeta.innerHTML = `${CUP_LABELS[currentCup] || currentCup} · <b>${escapeHtml(archiveSeason)}</b> final bracket (archived) · <a class="gpsl-link" href="cups.html?cup=${encodeURIComponent(currentCup)}">Current season</a>`;
    }
    const nodes = await loadCupBracketForSeason(
      supabase,
      currentCup,
      archiveSeason,
      fullClubName
    );
    document.getElementById("qualifiedList").innerHTML = nodes.length
      ? `<span class="empty">Archived ${escapeHtml(archiveSeason)} — ${nodes.length} bracket node${nodes.length === 1 ? "" : "s"}.</span>`
      : `<span class="empty">No archived bracket for ${escapeHtml(archiveSeason)} ${escapeHtml(CUP_LABELS[currentCup] || currentCup)}.</span>`;
    const fixtureIds = nodes.map((n) => n.fixture_id).filter(Boolean);
    const extras = await loadCupVideosAndExtras(fixtureIds);
    await ensureCupDrawContext(nodes[0]?.season_id);
    renderBracket(nodes, extras);
    renderGroupPrizeLine();
    return;
  }

  if (pageMeta) {
    pageMeta.textContent =
      "Prestige cups (table places) and League Cup (60-club knockout) — kick-off, check-in, Match Day and video ticks on each tie";
  }

  const qualified = await loadCupQualified(supabase, currentCup);
  renderQualified(qualified);

  const nodes = await loadCupBracket(supabase, currentCup);
  const fixtureIds = nodes.map((n) => n.fixture_id).filter(Boolean);
  const extras = await loadCupVideosAndExtras(fixtureIds);
  await ensureCupDrawContext(nodes[0]?.season_id);
  renderBracket(nodes, extras);
  renderGroupPrizeLine();
}

async function ensureCupDrawContext(seasonId) {
  let id = seasonId || null;
  if (!id) {
    id = (await loadCurrentSeason(supabase))?.id || null;
  }
  if (id) await loadTvFixtureIds(supabase, id);
  await loadCupPrizeContext(id, currentCup);
}

function renderGroupPrizeLine() {
  const el = document.getElementById("cupGroupPrizes");
  if (!el) return;
  const text = groupPrizeSummary();
  el.hidden = !text;
  el.textContent = text;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();
  calendarStatus = await loadCalendarStatus(supabase);
  try {
    setSeasonCalendarMonths(await loadSeasonCalendarMonths(supabase));
  } catch (err) {
    console.warn("cups: season calendar months", err);
  }
  holidayContext = await loadHolidayPlayContext();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();

  myClubShort = club?.ShortName ?? null;
  videoAdmin = isGpslAdminUser(user);

  const urlCup = cupFromUrl();
  if (urlCup) currentCup = urlCup;

  applyCupPageTheme(currentCup);
  const hero = document.getElementById("cupHero");
  if (hero) {
    hero.innerHTML = renderCupHero(currentCup, CUP_LABELS[currentCup]);
  }

  renderToolbar();
  syncCupDrawReplayLink();
  await renderCup();
});

function syncCupDrawReplayLink() {
  const link = document.getElementById("cupDrawReplayLink");
  if (link) {
    link.href = `cup_draw.html?cup=${encodeURIComponent(currentCup)}&replay=1`;
  }
}
