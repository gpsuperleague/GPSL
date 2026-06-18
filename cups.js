import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
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
} from "./competition.js";
import { loadCalendarStatus, isGpslMonthCurrentlyPlayable } from "./competition_calendar.js";
import { formatMatchConditions } from "./competition_conditions.js";
import { applyCupPageTheme, renderCupHero } from "./trophy_assets.js";

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

function renderLegPane(leg, extras, opts) {
  if (!leg) {
    return `<div class="leg-pane leg-empty"><div class="leg-label">${escapeHtml(opts.legLabel)}</div><div class="leg-teams">TBD <span class="vs">vs</span> TBD</div></div>`;
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
  const { playable, reason } = legPlayable(leg, extras, opts);

  let actionHtml = "";
  if (played) {
    actionHtml = `<div class="leg-action played-tag">Played</div>`;
  } else if (playable && leg.fixture_id) {
    actionHtml = `<a class="leg-action leg-enter" href="${matchdayUrl(leg.fixture_id)}">Enter result</a>`;
  } else {
    actionHtml = `<div class="leg-action leg-locked">${escapeHtml(reason)}</div>`;
  }

  return `
    <div class="leg-pane ${isMyMatch(leg) ? "my-club" : ""} ${played ? "played" : ""}">
      <div class="leg-label">${escapeHtml(opts.legLabel)}</div>
      <div class="leg-teams">${escapeHtml(home)}<span class="vs">vs</span>${escapeHtml(away)}</div>
      ${conditions ? `<div class="leg-conditions" style="font-size:11px;color:#888;margin:4px 0;">${escapeHtml(conditions)}</div>` : ""}
      ${renderScoreLinesHtml(scoreLines)}
      ${actionHtml}
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

function renderMatchCard(m, extras) {
  const home = m.home_club_name || m.home_club_short_name || "TBD";
  const away = m.away_club_name || m.away_club_short_name || "TBD";
  const played = m.fixture_status === "played";
  const scoreLines = played ? formatCupScoreLines(m, extras) : null;
  const finance = played ? formatCupMatchFinance(m, extras) : [];

  let status = "Awaiting draw / teams";
  if (played) status = "Played";
  else if (m.fixture_id) status = "Scheduled";
  else if (m.winner_club_name && !m.fixture_id) status = "Bye / advanced";

  let winnerHtml = "";
  if (m.winner_club_name && !scoreLines?.some((l) => l.label === "Pens")) {
    winnerHtml = `<div class="match-winner">→ ${escapeHtml(m.winner_club_name)}</div>`;
  }

  let actionHtml = "";
  const month = m.fixture_gpsl_month || m.round_gpsl_month;
  const monthOpen = isGpslMonthCurrentlyPlayable(month, calendarStatus);
  const conditions =
    m.fixture_id && (m.weather || m.pitch_condition || m.kit_season)
      ? formatMatchConditions(m)
      : "";
  if (!played && m.fixture_id && monthOpen && isMyMatch(m)) {
    actionHtml = `<a class="leg-action leg-enter" href="${matchdayUrl(m.fixture_id)}">Enter result</a>`;
  }

  return `
    <div class="bracket-match ${isMyMatch(m) ? "my-club" : ""} ${played ? "played" : ""}">
      <div class="match-status">M${m.match_no} · ${escapeHtml(status)}</div>
      <div class="match-teams">${escapeHtml(home)}<span class="vs">vs</span>${escapeHtml(away)}</div>
      ${conditions ? `<div class="match-conditions" style="font-size:11px;color:#888;margin:4px 0;">${escapeHtml(conditions)}</div>` : ""}
      ${renderScoreLinesHtml(scoreLines)}
      ${actionHtml}
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
  const flow = root.querySelector(".bracket-flow");
  if (flow) flow.scrollLeft = 0;
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
  const cards = matches.map((m) => renderMatchCard(m, extras)).join("");
  return `
    <div class="bracket-round" data-round="${round_no}">
      <div class="round-title">${escapeHtml(columnTitle)}</div>
      ${cards}
    </div>`;
}

async function renderCup() {
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
    const extras = await loadCupMatchExtras(supabase, fixtureIds);
    renderBracket(nodes, extras);
    return;
  }

  if (pageMeta) {
    pageMeta.textContent =
      "Prestige cups (table places) and League Cup (60-club knockout)";
  }

  const qualified = await loadCupQualified(supabase, currentCup);
  renderQualified(qualified);

  const nodes = await loadCupBracket(supabase, currentCup);
  const fixtureIds = nodes.map((n) => n.fixture_id).filter(Boolean);
  const extras = await loadCupMatchExtras(supabase, fixtureIds);
  renderBracket(nodes, extras);
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();
  calendarStatus = await loadCalendarStatus(supabase);

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
  await renderCup();
});
