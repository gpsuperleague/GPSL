import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  CUP_CODES,
  CUP_LABELS,
  GPSL_MONTH_LABELS,
  loadCupBracket,
  loadCupQualified,
  loadCupMatchExtras,
  groupCupBracketByRound,
  cupRoundLabel,
  cupRoundTieCount,
  formatCupScoreLines,
  formatCupMatchFinance,
  formatMoney,
  normalizeClubKey,
} from "./competition.js";

function cupFromUrl() {
  const raw = new URLSearchParams(window.location.search).get("cup");
  if (raw && CUP_CODES.includes(raw)) return raw;
  return null;
}

let myClubShort = null;
let currentCup = "league_cup";

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
  if (!myClubShort) return false;
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

function renderMatchCard(m, extras) {
  const home = m.home_club_name || m.home_club_short_name || "TBD";
  const away = m.away_club_name || m.away_club_short_name || "TBD";
  const played = m.fixture_status === "played";
  const scheduled = !!m.fixture_id && !played;
  const scoreLines = played ? formatCupScoreLines(m, extras) : null;
  const finance = played ? formatCupMatchFinance(m, extras) : [];

  let status = "Awaiting draw / teams";
  if (played) status = "Played";
  else if (scheduled) status = "Scheduled";
  else if (m.winner_club_name && !m.fixture_id) status = "Bye / advanced";

  const legMonth =
    GPSL_MONTH_LABELS[m.round_gpsl_month || m.fixture_gpsl_month] ||
    m.round_gpsl_month ||
    "";
  const twoLegQf =
    (m.cup_code === "super8" || m.cup_code === "spoon") && m.round_no === 1;
  let legHint = "";
  if (twoLegQf && ((m.cup_leg || 1) === 2 || m.leg1_node_id)) {
    legHint = `2nd leg${legMonth ? ` · ${legMonth}` : ""}`;
  } else if (twoLegQf && (m.cup_leg || 1) === 1) {
    legHint = `1st leg${legMonth ? ` · ${legMonth}` : ""}`;
  }

  let winnerHtml = "";
  if (m.winner_club_name && !scoreLines?.some((l) => l.label === "Pens")) {
    winnerHtml = `<div class="match-winner">→ ${escapeHtml(m.winner_club_name)}</div>`;
  }

  const statusLine = [legHint, status].filter(Boolean).join(" · ");

  return `
    <div class="bracket-match ${isMyMatch(m) ? "my-club" : ""} ${played ? "played" : ""}">
      <div class="match-status">M${m.match_no} · ${escapeHtml(statusLine)}</div>
      <div class="match-teams">${escapeHtml(home)}<span class="vs">vs</span>${escapeHtml(away)}</div>
      ${renderScoreLinesHtml(scoreLines)}
      ${winnerHtml}
      ${renderFinanceHtml(finance)}
    </div>
  `;
}

function renderBracket(nodes, extras) {
  const root = document.getElementById("bracketRoot");
  if (!nodes.length) {
    root.innerHTML =
      '<p class="empty">No bracket yet. Admin draws this cup in GPSL Admin.</p>';
    return;
  }

  const rounds = groupCupBracketByRound(nodes);
  root.innerHTML = `
    <div class="bracket-flow">
      ${rounds.map(({ round_no, matches }) => renderBracketRoundColumn(round_no, matches, extras)).join("")}
    </div>
    <p class="bracket-arrow-hint">← Early rounds · Final →</p>
  `;
}

function renderBracketRoundColumn(round_no, matches, extras) {
  const legs = [...new Set(matches.map((m) => m.cup_leg || 1))].sort((a, b) => a - b);
  const hasTwoLegRound = legs.length > 1;
  const sample = matches[0] || {};
  const title =
    sample.round_label || cupRoundLabel(cupRoundTieCount(matches));

  if (hasTwoLegRound) {
    const legSections = legs
      .map((leg) => {
        const legMatches = matches.filter((m) => (m.cup_leg || 1) === leg);
        const legSample = legMatches[0] || {};
        const month =
          GPSL_MONTH_LABELS[
            legSample.round_gpsl_month || legSample.fixture_gpsl_month
          ] ||
          legSample.round_gpsl_month ||
          "";
        const subtitle = `${leg === 2 ? "2nd leg" : "1st leg"}${month ? ` · ${month}` : ""}`;
        const cards = legMatches.map((m) => renderMatchCard(m, extras)).join("");
        return `
          <div class="bracket-leg" data-leg="${leg}">
            <div class="round-subtitle">${escapeHtml(subtitle)}</div>
            ${cards}
          </div>`;
      })
      .join("");
    return `
      <div class="bracket-round" data-round="${round_no}">
        <div class="round-title">${escapeHtml(title)}</div>
        ${legSections}
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

  document.getElementById("pageMeta").textContent =
    "Prestige cups (table places) and League Cup (60-club knockout)";

  renderToolbar();
  await renderCup();
});
