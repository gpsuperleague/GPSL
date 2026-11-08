/**
 * Club page: recent form beside the header, and the Analysis tab
 * (Match Day formation, lineup, injuries, head-to-head, last score).
 */
import { GPSL_MONTH_LABELS, gpslMonthSortIndex } from "./competition.js";
import { formationDisplayName, getFormation } from "./matchday_formations.js";
import { loadClubActiveInjuries } from "./player_discipline.js?v=20261026-club-squad-lwf";
import { playerNameLinkHtml } from "./player_links.js";

const FORM_LIMIT = 5;

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
  if (f.competition_type === "cup") return f.cup_code || "Cup";
  if (f.competition_type === "league") return "League";
  return f.competition_type || "Match";
}

function monthLabel(f) {
  const key = String(f.gpsl_month || "").toLowerCase();
  return GPSL_MONTH_LABELS[key] || f.gpsl_month || "";
}

function scoreLine(f) {
  return `${esc(f.home_club_short_name)} ${esc(f.home_goals)}–${esc(f.away_goals)} ${esc(f.away_club_short_name)}`;
}

function formationText(preview) {
  const id = String(preview?.formation_id || "").trim();
  const named = String(preview?.formation_name || "").trim();
  const known = id && getFormation(id)?.id === id ? formationDisplayName(getFormation(id)) : "";
  if (named && named !== id && named !== known) {
    return known ? `${named} · ${known}` : named;
  }
  return known || named || "";
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
      "id, competition_type, cup_code, gpsl_month, matchday, week_in_month, home_club_short_name, home_club_name, away_club_short_name, away_club_name, home_goals, away_goals, status, is_forfeit, agreed_kickoff_at"
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
          const tip = `${opp.name || opp.short} · ${f.home_goals}–${f.away_goals}${f.is_forfeit ? " · forfeit" : ""} · ${monthLabel(f)}`;
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
  const xi = Array.isArray(preview?.xi) ? preview.xi : [];
  const bench = Array.isArray(preview?.bench) ? preview.bench : [];
  if (!xi.length && !bench.length) {
    return `<p class="club-an-empty">No Match Day lineup saved.</p>`;
  }
  const rows = xi
    .map(
      (p) => `
      <li>
        <span class="club-an-role">${esc(p.role_label || p.player_position || "")}</span>
        ${playerNameLinkHtml(p.player_id, p.player_name)}
      </li>`
    )
    .join("");
  const subs = bench
    .map((p) => playerNameLinkHtml(p.player_id, p.player_name))
    .join(", ");
  return `
    <ol class="club-an-xi">${rows}</ol>
    ${subs ? `<p class="club-an-bench"><span>Bench</span> ${subs}</p>` : ""}
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
      return `<li>${playerNameLinkHtml(id, names.get(id) || id)} <span class="club-an-meta">${esc(inj.label || "Injury")} · ${esc(phase)}</span></li>`;
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

function opponentOptions(club, fixtures, viewerClub) {
  const map = new Map();
  for (const f of fixtures) {
    const opp = opponentOf(club, f);
    const key = clubKey(opp.short);
    if (!key || key === clubKey(club)) continue;
    if (!map.has(key)) map.set(key, opp.name || key);
  }
  const list = [...map.entries()].sort((a, b) => a[1].localeCompare(b[1]));
  const viewer = clubKey(viewerClub);
  const playedRows = fixtures.filter((f) => played(f));
  const latestOpp = playedRows.length ? clubKey(opponentOf(club, playedRows[playedRows.length - 1]).short) : "";
  let selected = "";
  if (viewer && viewer !== clubKey(club) && map.has(viewer)) selected = viewer;
  else if (latestOpp && map.has(latestOpp)) selected = latestOpp;
  else if (list.length) selected = list[0][0];
  return { list, selected };
}

function renderOpponentBlocks(club, fixtures, opponent, name) {
  if (!opponent) {
    return {
      h2h: `<p class="club-an-empty">No opponents this season.</p>`,
      last: `<p class="club-an-empty">No score yet.</p>`,
    };
  }
  const fig = h2hFigures(club, fixtures, opponent);
  const h2h = fig.played
    ? `<p class="club-an-h2h"><b>${fig.w}</b> wins · <b>${fig.d}</b> draws · <b>${fig.l}</b> losses</p><p class="club-an-meta">${fig.played} played against ${esc(name || opponent)}</p>`
    : `<p class="club-an-empty">No result against ${esc(name || opponent)} yet.</p>`;
  let last;
  if (!fig.last) {
    last = `<p class="club-an-empty">No score against ${esc(name || opponent)} yet.</p>`;
  } else {
    const mark = outcome(club, fig.last);
    const word = mark === "W" ? "Win" : mark === "L" ? "Loss" : "Draw";
    const bits = [monthLabel(fig.last), compLabel(fig.last), word, fig.last.is_forfeit ? "Forfeit" : ""]
      .filter(Boolean)
      .join(" · ");
    last = `
      <a class="club-an-score" href="match_report.html?fixture=${encodeURIComponent(fig.last.id)}">${scoreLine(fig.last)}</a>
      <p class="club-an-meta">${esc(bits)}</p>
    `;
  }
  return { h2h, last };
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

  const [fixtures, previewRes, injuries] = await Promise.all([
    loadFixtures(supabase, clubShort),
    supabase.rpc("competition_match_club_preview", { p_club: clubShort }),
    loadClubActiveInjuries(supabase, clubShort),
  ]);

  renderForm(formHost, clubShort, fixtures);

  const preview = previewRes.error ? null : previewRes.data;
  if (previewRes.error) console.warn("matchday preview:", previewRes.error.message);
  const names = await loadInjuryNames(supabase, injuries);
  const formation = formationText(preview);
  const updated = whenLabel(preview?.squad_updated_at);
  const { list, selected } = opponentOptions(clubShort, fixtures, viewerClub);

  const paintOpponent = (code) => {
    const name = list.find(([short]) => short === code)?.[1] || code;
    const blocks = renderOpponentBlocks(clubShort, fixtures, code, name);
    const h2h = document.getElementById("clubH2hBody");
    const last = document.getElementById("clubLastScoreBody");
    if (h2h) h2h.innerHTML = blocks.h2h;
    if (last) last.innerHTML = blocks.last;
  };

  if (!analysisHost) return;
  const options = list
    .map(
      ([short, name]) =>
        `<option value="${esc(short)}"${short === selected ? " selected" : ""}>${esc(name)} (${esc(short)})</option>`
    )
    .join("");
  const picker = list.length
    ? `<label class="club-an-pick">Against
        <select id="clubOpponentPick">${options}</select>
      </label>`
    : "";

  analysisHost.innerHTML = `
    <div class="club-an-grid">
      <section class="club-an-card">
        <h2>Formation</h2>
        <p class="club-an-lead">${formation ? esc(formation) : "Not set on Match Day"}</p>
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
        ${picker}
        <div id="clubH2hBody"></div>
      </section>
      <section class="club-an-card">
        <h2>Last score vs opponent</h2>
        <div id="clubLastScoreBody"></div>
      </section>
    </div>
  `;
  paintOpponent(selected);
  document.getElementById("clubOpponentPick")?.addEventListener("change", (ev) => {
    paintOpponent(ev.target.value);
  });
}
