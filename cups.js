import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName, clubWithOwnerHtml } from "./clubs_lookup.js";
import {
  CUP_CODES,
  CUP_LABELS,
  GPSL_MONTH_LABELS,
  loadCupBracket,
  loadCupBracketForSeason,
  loadCupQualified,
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
import { applyCupPageTheme, renderCupHero } from "./trophy_assets.js";
import { loadTvFixtureIds, tvFixtureBadgeHtml } from "./tv_fixtures.js";
import {
  scheduleActionLabel,
  formatKickoff,
  UK_TZ,
  isCatchUpFixture,
  fixtureNewOwnerArrangeGrace,
  newOwnerGraceKickoffNoteHtml,
  setSeasonCalendarMonths,
} from "./match_scheduling.js?v=20261028-new-owner-grace";
import { matchCentreButtonHtml } from "./match_centre_link.js";
import {
  loadFixtureMatchVideos,
  loadMatchVideoReportedSides,
  matchVideoTicksHtml,
  MATCH_VIDEO_TICK_CSS,
  wireMatchVideoReportButtons,
} from "./match_videos_ui.js?v=20261026-pending-hint";
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
let calendarStatus = null;
let holidayContext = null;
/** @type {Map<string, { home_url?: string|null, away_url?: string|null }>} */
let matchVideoMap = new Map();
/** @type {Set<string>} */
let matchVideoReportedSides = new Set();
/** @type {Map<number, object>} last fixturesById for report wiring */
let lastCupFixturesById = new Map();
let matchVideoReportsWired = false;

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
    return `<span class="cup-ko cup-ko--pending">${catchUpPrefix}Proposal pending</span>`;
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
    allowReport: Boolean(myClubShort),
    reportedSides: matchVideoReportedSides,
  });
}

function cupOpsHtml(leg, extras) {
  const f = cupFixtureView(leg, extras);
  if (!f) return "";

  const myClub = { short: myClubShort };
  const involvesMe = isMyMatch(leg);
  const parts = [];

  const ko = cupKickoffHtml(f);
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
  if (!leg?.fixture_id) return { playable: false, reason: "Awaiting draw / teams" };
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
      ${renderFinanceHtml(finance)}
    </div>`;
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

  let status = "Awaiting draw / teams";
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
      ${winnerHtml}
      ${renderFinanceHtml(finance)}
    </div>`;
}

function renderBracket(nodes, extras) {
  const root = document.getElementById("bracketRoot");
  if (!nodes.length) {
    root.innerHTML =
      '<p class="empty">No bracket yet. Admin draws this cup in GPSL Admin.</p>';
    return;
  }

  const rounds = preprocessCupBracketRounds(nodes, currentCup);
  const flowClass =
    currentCup === "league_cup" ? "bracket-flow bracket-flow--league-cup" : "bracket-flow";
  root.innerHTML = `
    <div class="${flowClass}">
      ${rounds.map(({ round_no, matches }) => renderBracketRoundColumn(round_no, matches, extras)).join("")}
    </div>
    <p class="bracket-arrow-hint">← Early rounds · Final →</p>
  `;
}

function renderBracketRoundColumn(round_no, matches, extras) {
  const sample = matches[0] || {};
  const title = sample.round_label || cupRoundLabel(cupRoundTieCount(matches));
  const twoLegQf = isTwoLegCupQuarterFinal(currentCup, round_no);

  if (twoLegQf) {
    const ties = groupCupBracketTies(matches, currentCup, round_no);
    const columnTitle = `${title} · ${GPSL_MONTH_LABELS.september}/${GPSL_MONTH_LABELS.october}`;
    const cards = ties.map((tie) => renderTwoLegTieCard(tie, extras)).join("");
    return `
      <div class="bracket-round bracket-round-two-leg" data-round="${round_no}">
        <div class="round-title">${escapeHtml(columnTitle)}</div>
        ${cards}
      </div>`;
  }

  const month =
    GPSL_MONTH_LABELS[sample.round_gpsl_month || sample.fixture_gpsl_month] ||
    sample.round_gpsl_month ||
    "";
  const columnTitle = month ? `${title} · ${month}` : title;
  const cards = matches.map((m) => renderMatchCard(m, extras, round_no)).join("");
  return `
    <div class="bracket-round" data-round="${round_no}">
      <div class="round-title">${escapeHtml(columnTitle)}</div>
      ${cards}
    </div>`;
}

async function loadCupVideosAndExtras(fixtureIds) {
  const [extras, videos, reported] = await Promise.all([
    loadCupMatchExtras(supabase, fixtureIds),
    loadFixtureMatchVideos(supabase, fixtureIds),
    loadMatchVideoReportedSides(supabase, fixtureIds),
  ]);
  matchVideoMap = videos;
  matchVideoReportedSides = reported;
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
    const seasonId = nodes[0]?.season_id;
    if (seasonId) await loadTvFixtureIds(supabase, seasonId);
    renderBracket(nodes, extras);
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
  const seasonId = nodes[0]?.season_id;
  if (seasonId) await loadTvFixtureIds(supabase, seasonId);
  renderBracket(nodes, extras);
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
