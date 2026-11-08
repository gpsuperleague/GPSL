/**
 * Club page: recent form beside the header, and the Analysis tab
 * (Match Day formation, lineup, injuries, head-to-head, last score).
 */
import { formatFixtureCompetition, GPSL_MONTH_LABELS, gpslMonthSortIndex } from "./competition.js";
import {
  formationDisplayName,
  getFormation,
  PITCH_SLOT_IDS,
  resolvePitchLayout,
} from "./matchday_formations.js";
import { loadClubActiveInjuries } from "./player_discipline.js?v=20261026-club-squad-lwf";
import { playerNameLinkHtml } from "./player_links.js";
import { renderFormationPitchHtml } from "./pitch_display.js";

const FORM_LIMIT = 5;

/** Same GK → CF order as Match Day squad and stats tables. */
const POSITION_ORDER = [
  "GK",
  "LB",
  "CB",
  "RB",
  "LWB",
  "RWB",
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

function esc(v) {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function clubKey(v) {
  return String(v ?? "").trim().toUpperCase();
}

function played(f) {
  return f.home_goals != null && f.away_goals != null && f.home_goals !== "" && f.away_goals !== "";
}

function sortKey(f) {
  return [
    gpslMonthSortIndex(f.gpsl_month) ?? 99,
    Number(f.matchday) || 0,
    Number(f.week_in_month) || 0,
    f.agreed_kickoff_at ? new Date(f.agreed_kickoff_at).getTime() : 0,
    Number(f.id) || 0,
  ];
}

function byRecent(a, b) {
  const ka = sortKey(a);
  const kb = sortKey(b);
  for (let i = 0; i < ka.length; i++) {
    if (ka[i] !== kb[i]) return ka[i] - kb[i];
  }
  return 0;
}

function isHome(club, f) {
  return clubKey(f.home_club_short_name) === clubKey(club);
}

function outcome(club, f) {
  if (!played(f)) return null;
  const gf = Number(isHome(club, f) ? f.home_goals : f.away_goals);
  const ga = Number(isHome(club, f) ? f.away_goals : f.home_goals);
  if (gf > ga) return "W";
  if (gf < ga) return "L";
  return "D";
}

function opponentOf(club, f) {
  return isHome(club, f)
    ? { short: f.away_club_short_name, name: f.away_club_name }
    : { short: f.home_club_short_name, name: f.home_club_name };
}

function compLabel(f) {
  return formatFixtureCompetition(f) || "Match";
}

function monthLabel(f) {
  const key = String(f.gpsl_month || "").toLowerCase();
  return GPSL_MONTH_LABELS[key] || f.gpsl_month || "";
}

function clubNameOn(f, side) {
  return side === "home" ? f.home_club_name || "Home" : f.away_club_name || "Away";
}

function positionIndex(player) {
  const role = String(player?.role_label || player?.player_position || "")
    .trim()
    .toUpperCase();
  const i = POSITION_ORDER.indexOf(role);
  return i >= 0 ? i : POSITION_ORDER.length;
}

function byPosition(a, b) {
  const d = positionIndex(a) - positionIndex(b);
  if (d) return d;
  return String(a.player_name || "").localeCompare(String(b.player_name || ""));
}

function whenLabel(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString("en-GB", {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

async function loadFixtures(supabase, club) {
  const code = clubKey(club);
  if (!/^[A-Z0-9]{2,8}$/.test(code)) return [];
  const { data, error } = await supabase
    .from("competition_fixtures_public")
    .select(
      "id, competition_type, cup_code, division, gpsl_month, matchday, week_in_month, home_club_short_name, home_club_name, away_club_short_name, away_club_name, home_goals, away_goals, status, is_forfeit, agreed_kickoff_at"
    )
    .or(`home_club_short_name.eq.${code},away_club_short_name.eq.${code}`)
    .limit(200);
  if (error) {
    console.warn("club fixtures:", error.message);
    return [];
  }
  return (data || []).slice().sort(byRecent);
}

function renderForm(host, club, fixtures) {
  if (!host) return;
  const recent = fixtures.filter((f) => played(f)).slice(-FORM_LIMIT);
  const pills = recent.length
    ? recent
        .map((f) => {
          const mark = outcome(club, f);
          const opp = opponentOf(club, f);
          const tip = `${f.home_club_name || "Home"} ${f.home_goals}–${f.away_goals} ${f.away_club_name || "Away"} · ${monthLabel(f)} · ${formatFixtureCompetition(f)}${f.is_forfeit ? " · forfeit" : ""}`;
          return `<a class="club-form-pill is-${mark.toLowerCase()}" href="match_report.html?fixture=${encodeURIComponent(f.id)}" title="${esc(tip)}">${mark}</a>`;
        })
        .join("")
    : `<span class="club-form-empty">No results yet</span>`;
  host.innerHTML = `
    <div class="club-form-label">Recent form</div>
    <div class="club-form-row">${pills}</div>
  `;
}

function renderLineup(preview) {
  const xi = (Array.isArray(preview?.xi) ? preview.xi : []).slice().sort(byPosition);
  const bench = (Array.isArray(preview?.bench) ? preview.bench : []).slice().sort(byPosition);
  if (!xi.length && !bench.length) {
    return `<p class="club-an-empty">No Match Day lineup saved.</p>`;
  }
  const row = (p) => `
      <li>
        <span class="club-an-role">${esc(p.role_label || p.player_position || "")}</span>
        ${playerNameLinkHtml(p.player_id, p.player_name)}
      </li>`;
  const subs = bench.map(row).join("");
  return `
    <ol class="club-an-xi">${xi.map(row).join("")}</ol>
    ${subs ? `<p class="club-an-bench"><span>Bench</span></p><ol class="club-an-xi">${subs}</ol>` : ""}
  `;
}

function renderInjuries(injuries, names) {
  if (!injuries.length) return `<p class="club-an-empty">No current injuries.</p>`;
  return `<ul class="club-an-list">${injuries
    .map((inj) => {
      const id = String(inj.player_id || "");
      const out = Number(inj.matches_out_remaining) || 0;
      const rec = Number(inj.recovery_remaining) || 0;
      const phase = out > 0 ? `Out · ${out} match${out === 1 ? "" : "es"}` : `Recovery · ${rec} match${rec === 1 ? "" : "es"}`;
      const label = names.get(id) || "Player";
      return `<li>${playerNameLinkHtml(id, label)} <span class="club-an-meta">${esc(inj.label || "Injury")} · ${esc(phase)}</span></li>`;
    })
    .join("")}</ul>`;
}

function h2hFigures(club, fixtures, opponent) {
  const rows = fixtures.filter((f) => clubKey(opponentOf(club, f).short) === clubKey(opponent) && played(f));
  let w = 0;
  let d = 0;
  let l = 0;
  for (const f of rows) {
    const mark = outcome(club, f);
    if (mark === "W") w += 1;
    else if (mark === "L") l += 1;
    else d += 1;
  }
  const last = rows.length ? rows[rows.length - 1] : null;
  return { w, d, l, played: rows.length, last };
}

function meetingsBetween(viewer, page, fixtures) {
  const a = clubKey(viewer);
  const b = clubKey(page);
  return fixtures.filter((f) => {
    const sides = [clubKey(f.home_club_short_name), clubKey(f.away_club_short_name)];
    return sides.includes(a) && sides.includes(b);
  });
}

function renderMatchup(viewer, page, fixtures, viewerName, pageName) {
  if (!viewer) {
    return {
      h2h: `<p class="club-an-empty">Head to head appears when you are logged in with a club.</p>`,
      last: `<p class="club-an-empty">No meeting to show.</p>`,
    };
  }
  if (clubKey(viewer) === clubKey(page)) {
    return {
      h2h: `<p class="club-an-empty">Open another club to see your head to head.</p>`,
      last: `<p class="club-an-empty">Open another club to see your last meeting.</p>`,
    };
  }
  const rows = meetingsBetween(viewer, page, fixtures).filter(played);
  const fig = h2hFigures(viewer, rows.length ? rows : [], page);
  const yours = viewerName || "Your club";
  const theirs = pageName || "This club";
  const h2h = fig.played
    ? `<p class="club-an-versus">${esc(yours)} <span>vs</span> ${esc(theirs)}</p>
       <div class="club-an-record">
         <div class="is-w"><b>${fig.w}</b><span>Wins</span></div>
         <div class="is-d"><b>${fig.d}</b><span>Draws</span></div>
         <div class="is-l"><b>${fig.l}</b><span>Losses</span></div>
       </div>
       <p class="club-an-meta">Your record · ${fig.played} played</p>`
    : `<p class="club-an-versus">${esc(yours)} <span>vs</span> ${esc(theirs)}</p>
       <p class="club-an-empty">No result between you yet this season.</p>`;
  let last;
  if (!fig.last) {
    last = `<p class="club-an-empty">No score between ${esc(yours)} and ${esc(theirs)} yet.</p>`;
  } else {
    const bits = [monthLabel(fig.last), compLabel(fig.last), fig.last.is_forfeit ? "Forfeit" : ""]
      .filter(Boolean)
      .join(" · ");
    last = `
      <a class="club-an-scoreboard" href="match_report.html?fixture=${encodeURIComponent(fig.last.id)}">
        <span class="side">${esc(clubNameOn(fig.last, "home"))}</span>
        <span class="nums">${esc(fig.last.home_goals)}–${esc(fig.last.away_goals)}</span>
        <span class="side away">${esc(clubNameOn(fig.last, "away"))}</span>
      </a>
      <p class="club-an-meta">${esc(bits)}</p>
    `;
  }
  return { h2h, last };
}

function pitchSlotsFromLayout(raw, formationId) {
  const resolved = resolvePitchLayout(raw, formationId || undefined);
  return PITCH_SLOT_IDS.map((id) => {
    const pos = resolved.positions?.[id];
    if (!pos) return null;
    return { id, x: pos.x, y: pos.y, label: resolved.labels?.[id] || id };
  }).filter(Boolean);
}

function renderFormation(preview, pitchLayout) {
  const xi = Array.isArray(preview?.xi) ? preview.xi : [];
  const id = String(preview?.formation_id || "").trim();
  const known = id && getFormation(id)?.id === id ? formationDisplayName(getFormation(id)) : "";
  const named = String(preview?.formation_name || "").trim();
  const title = named && named !== id ? named : known;
  if (!title && !xi.length) {
    return `<p class="club-an-empty">Not set on Match Day.</p>`;
  }
  const members = xi.map((p) => ({
    pitch_slot: p.pitch_slot,
    slot_label: p.role_label || p.player_position || "",
    player_id: p.player_id,
    player_name: p.player_name,
  }));
  return renderFormationPitchHtml({
    formationId: known ? id : undefined,
    title: title || "Match Day shape",
    members,
    slots: pitchSlotsFromLayout(pitchLayout, known ? id : undefined),
    showStats: false,
    showClub: false,
  });
}

async function loadInjuryNames(supabase, injuries) {
  const ids = [...new Set(injuries.map((i) => String(i.player_id || "")).filter(Boolean))];
  const names = new Map();
  if (!ids.length) return names;
  const { data, error } = await supabase
    .from("Players")
    .select("Konami_ID, Name")
    .in("Konami_ID", ids);
  if (error) {
    console.warn("injury names:", error.message);
    return names;
  }
  for (const row of data || []) names.set(String(row.Konami_ID), row.Name);
  return names;
}

function bindTabs() {
  const tabs = document.getElementById("clubTabs");
  const squad = document.getElementById("clubSquadPane");
  const analysis = document.getElementById("clubAnalysisPane");
  if (!tabs || !squad || !analysis) return;
  tabs.hidden = false;

  const show = (name) => {
    const onAnalysis = name === "analysis";
    squad.hidden = onAnalysis;
    analysis.hidden = !onAnalysis;
    tabs.querySelectorAll("[data-club-tab]").forEach((btn) => {
      const on = btn.dataset.clubTab === name;
      btn.classList.toggle("is-on", on);
      btn.setAttribute("aria-selected", on ? "true" : "false");
    });
  };

  tabs.addEventListener("click", (ev) => {
    const btn = ev.target.closest("[data-club-tab]");
    if (!btn) return;
    const name = btn.dataset.clubTab;
    show(name);
    const url = new URL(window.location.href);
    if (name === "analysis") url.hash = "analysis";
    else url.hash = "";
    history.replaceState(null, "", url);
  });

  show(window.location.hash === "#analysis" ? "analysis" : "squad");
}

export async function startClubInsights({ supabase, clubShort, viewerClub }) {
  if (!clubShort) return;
  bindTabs();
  const formHost = document.getElementById("clubForm");
  const analysisHost = document.getElementById("clubAnalysisPane");
  if (formHost) formHost.innerHTML = `<div class="club-form-label">Recent form</div><div class="club-form-empty">Loading…</div>`;
  if (analysisHost) analysisHost.innerHTML = `<p class="club-an-empty">Loading…</p>`;

  const nameCodes = [...new Set([clubKey(clubShort), clubKey(viewerClub)].filter(Boolean))];
  const [fixtures, previewRes, injuries, layoutRes, nameRes] = await Promise.all([
    loadFixtures(supabase, clubShort),
    supabase.rpc("competition_match_club_preview", { p_club: clubShort }),
    loadClubActiveInjuries(supabase, clubShort),
    supabase
      .from("club_matchday_squad")
      .select("pitch_layout")
      .eq("club_short_name", clubKey(clubShort))
      .maybeSingle(),
    nameCodes.length
      ? supabase.from("Clubs").select("ShortName, Club").in("ShortName", nameCodes)
      : Promise.resolve({ data: [] }),
  ]);

  renderForm(formHost, clubShort, fixtures);

  const preview = previewRes.error ? null : previewRes.data;
  if (previewRes.error) console.warn("matchday preview:", previewRes.error.message);
  if (layoutRes.error) console.warn("matchday shape:", layoutRes.error.message);
  const names = await loadInjuryNames(supabase, injuries);
  injuries.sort((a, b) =>
    String(names.get(String(a.player_id)) || "").localeCompare(String(names.get(String(b.player_id)) || ""))
  );
  const updated = whenLabel(preview?.squad_updated_at);
  const clubNames = new Map(
    (nameRes.data || []).map((row) => [clubKey(row.ShortName), row.Club])
  );
  const pageName = clubNames.get(clubKey(clubShort)) || "";
  const viewerName = clubNames.get(clubKey(viewerClub)) || "";
  const matchup = renderMatchup(viewerClub, clubShort, fixtures, viewerName, pageName);

  if (!analysisHost) return;
  analysisHost.innerHTML = `
    <div class="club-an-grid">
      <section class="club-an-card club-an-card--wide">
        <h2>Formation</h2>
        ${renderFormation(preview, layoutRes.data?.pitch_layout)}
        <p class="club-an-meta">${updated ? `Saved ${esc(updated)}` : "Match Day setup"}</p>
      </section>
      <section class="club-an-card">
        <h2>Lineup</h2>
        ${renderLineup(preview)}
      </section>
      <section class="club-an-card">
        <h2>Current injuries</h2>
        ${renderInjuries(injuries, names)}
      </section>
      <section class="club-an-card">
        <h2>Head to head</h2>
        ${matchup.h2h}
      </section>
      <section class="club-an-card">
        <h2>Last score</h2>
        ${matchup.last}
      </section>
    </div>
  `;
}
