import { supabase, initGlobal } from "./global.js";
import { stadiumImageUrl } from "./stadium_images.js";
import {
  CUP_LABELS,
  DIVISION_LABELS,
  GPSL_MONTH_LABELS,
  formatFixtureScore,
} from "./competition.js";
import { formatKickoff, UK_TZ } from "./match_scheduling.js";
import {
  getFormation,
  formationDisplayName,
  DEFAULT_FORMATION_ID,
} from "./matchday_formations.js";
import {
  loadFixtureUnavailable,
  formatFixtureUnavailableHtml,
  unavailableStatusByPlayerId,
} from "./player_discipline.js";
import { prematchConsoleChecklistHtml } from "./matchday_console_rules.js?v=20260924-stadium";

function unavailableLabel(status) {
  if (status === "injured") return "Injured";
  if (status === "recovery") return "Gaining match fitness";
  if (status === "suspended") return "Suspended";
  return "Unavailable";
}

function unavailableBadge(status) {
  if (!status) return "";
  const cls =
    status === "injured"
      ? "mr-unavail injured"
      : status === "recovery"
        ? "mr-unavail recovery"
        : "mr-unavail suspended";
  return `<span class="${cls}" title="${esc(unavailableLabel(status))}">${esc(
    unavailableLabel(status)
  )}</span>`;
}

/** Players in XI/bench who are suspended / injured / recovery for this fixture. */
function squadUnavailableConflicts(preview, statusById) {
  if (!preview?.has_squad || !statusById?.size) return [];
  const out = [];
  const seen = new Set();
  for (const group of [
    ...(preview.xi || []).map((p) => ({ ...p, slot: "XI" })),
    ...(preview.bench || []).map((p) => ({ ...p, slot: "Bench" })),
  ]) {
    const id = String(group.player_id || "");
    if (!id || seen.has(id)) continue;
    const status = statusById.get(id);
    if (!status) continue;
    seen.add(id);
    out.push({
      player_id: id,
      player_name: group.player_name || id,
      slot: group.slot,
      status,
    });
  }
  return out;
}

function squadConflictHtml(clubName, conflicts) {
  if (!conflicts?.length) return "";
  return `<div class="mr-squad-conflict">
    <div class="mr-squad-conflict-title">${esc(clubName)} — unavailable in selected squad</div>
    <ul class="mr-squad-conflict-list">${conflicts
      .map(
        (c) =>
          `<li><span class="mr-name">${esc(c.player_name)}</span>` +
          `<span class="mr-slot">${esc(c.slot)}</span>` +
          unavailableBadge(c.status) +
          `</li>`
      )
      .join("")}</ul>
  </div>`;
}

function qsFixtureId() {
  const raw = new URLSearchParams(window.location.search).get("fixture");
  if (!raw) return null;
  const n = Number(raw);
  return Number.isFinite(n) ? n : null;
}

function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function competitionLabel(fx) {
  if (!fx) return "Match";
  if (String(fx.competition_type || "").toLowerCase() === "cup") {
    const cup = CUP_LABELS[fx.cup_code] || fx.cup_code || "Cup";
    const round = fx.cup_round != null ? ` · R${fx.cup_round}` : "";
    return `${cup}${round}`;
  }
  const div = DIVISION_LABELS[fx.division] || fx.division || "League";
  const md = fx.matchday != null ? ` · MD ${fx.matchday}` : "";
  return `${div}${md}`;
}

function playerTags(p) {
  const tags = [];
  if (p.is_player_of_match) tags.push(`<span class="mr-tag potm">POTM</span>`);
  if ((p.goals || 0) > 0) {
    tags.push(
      `<span class="mr-tag goal">${p.goals > 1 ? `${p.goals}G` : "G"}</span>`
    );
  }
  if ((p.assists || 0) > 0) {
    tags.push(
      `<span class="mr-tag assist">${
        p.assists > 1 ? `${p.assists}A` : "A"
      }</span>`
    );
  }
  if ((p.own_goals || 0) > 0) {
    tags.push(
      `<span class="mr-tag og">OG−${p.own_goals > 1 ? `×${p.own_goals}` : ""}</span>`
    );
  }
  if (p.yellow_card) tags.push(`<span class="mr-tag yellow">YC</span>`);
  if (p.red_card) tags.push(`<span class="mr-tag red">RC</span>`);
  if (p.rating != null && p.rating !== "") {
    const r = Number(p.rating);
    if (Number.isFinite(r)) {
      tags.push(`<span class="mr-tag rating">${r.toFixed(1)}</span>`);
    }
  }
  return tags.join("");
}

function playerListHtml(players, mode) {
  const rows = (players || []).filter((p) => {
    if (mode === "xi") return p.started;
    if (mode === "subs") return p.subbed_on && !p.started;
    return true;
  });
  if (!rows.length) {
    return `<p class="mr-empty">${
      mode === "xi" ? "No starters recorded." : "No introduced subs."
    }</p>`;
  }
  return `<ul class="mr-list">${rows
    .map(
      (p) => `<li>
        <span class="mr-name">${esc(p.player_name || p.player_id)}</span>
        <span class="mr-tags">${playerTags(p)}</span>
      </li>`
    )
    .join("")}</ul>`;
}

function eventLines(players, field, label) {
  const hits = (players || []).filter((p) => (p[field] || 0) > 0);
  if (!hits.length) return `<p class="mr-empty">—</p>`;
  return `<ul class="mr-list">${hits
    .map((p) => {
      const n = p[field];
      const name = esc(p.player_name || p.player_id);
      return `<li><span class="mr-name">${name}${
        n > 1 ? ` (${n})` : ""
      }</span><span class="mr-tag">${label}</span></li>`;
    })
    .join("")}</ul>`;
}

function cardLines(players) {
  const y = (players || []).filter((p) => p.yellow_card);
  const r = (players || []).filter((p) => p.red_card);
  if (!y.length && !r.length) return `<p class="mr-empty">—</p>`;
  const items = [
    ...y.map(
      (p) =>
        `<li><span class="mr-name">${esc(
          p.player_name || p.player_id
        )}</span><span class="mr-tag yellow">YC</span></li>`
    ),
    ...r.map(
      (p) =>
        `<li><span class="mr-name">${esc(
          p.player_name || p.player_id
        )}</span><span class="mr-tag red">RC</span></li>`
    ),
  ];
  return `<ul class="mr-list">${items.join("")}</ul>`;
}

function injuryLines(injuries, clubShort) {
  const rows = (injuries || []).filter(
    (i) =>
      String(i.club_short_name || "").toUpperCase() ===
      String(clubShort || "").toUpperCase()
  );
  if (!rows.length) return `<p class="mr-empty">—</p>`;
  return `<ul class="mr-list">${rows
    .map((i) => {
      const sev = i.severity ? ` · ${esc(i.severity)}` : "";
      return `<li><span class="mr-name">${esc(
        i.player_name || i.player_id
      )}</span><span class="mr-tag">${esc(i.label || "Injury")}${sev}</span></li>`;
    })
    .join("")}</ul>`;
}

function formatAttendance(att, cap) {
  if (att == null || !Number.isFinite(Number(att))) return "—";
  const a = Math.round(Number(att)).toLocaleString("en-GB");
  if (cap != null && Number.isFinite(Number(cap))) {
    return `${a} / ${Math.round(Number(cap)).toLocaleString("en-GB")}`;
  }
  return a;
}

function setStadiumBg(homeShort) {
  const el = document.getElementById("mrBg");
  if (!el) return;
  const url = stadiumImageUrl(homeShort);
  if (url) el.style.backgroundImage = `url("${url}")`;
  else {
    el.style.backgroundImage =
      "linear-gradient(135deg, #1a1208 0%, #0d1520 50%, #101010 100%)";
  }
}

function clubPanel(title, players, injuries, clubShort, ogFor = 0) {
  const ogForN = Math.max(0, Number(ogFor) || 0);
  const ogForHtml =
    ogForN > 0
      ? `<ul class="mr-list"><li><span class="mr-name">Opponent own goal${
          ogForN > 1 ? `s (${ogForN})` : ""
        }</span><span class="mr-tag og-for">OG+</span></li></ul>`
      : `<p class="mr-empty">—</p>`;
  return `
    <section class="mr-panel">
      <h2>${esc(title)}</h2>
      <h3>Starting XI</h3>
      ${playerListHtml(players, "xi")}
      <h3>Introduced subs</h3>
      ${playerListHtml(players, "subs")}
      <h3>Goals</h3>
      ${eventLines(players, "goals", "G")}
      <h3>Opponent OGs for (OG+)</h3>
      ${ogForHtml}
      <h3>Own goals against (OG−)</h3>
      ${eventLines(players, "own_goals", "OG−")}
      <h3>Assists</h3>
      ${eventLines(players, "assists", "A")}
      <h3>Cards</h3>
      ${cardLines(players)}
      <h3>Injuries</h3>
      ${injuryLines(injuries, clubShort)}
    </section>
  `;
}


function formationLabel(preview) {
  if (!preview) return null;
  const id = preview.formation_id || null;
  const named = preview.formation_name || null;
  if (named && id && named !== id) return named;
  if (named && !id) return named;
  if (!id) return null;
  try {
    const f = getFormation(id);
    if (f && f.id === id) return formationDisplayName(f);
  } catch {
    /* ignore */
  }
  return named || id;
}

function playerPreviewLines(players, statusById = null) {
  const rows = players || [];
  if (!rows.length) return `<p class="mr-empty">—</p>`;
  return `<ul class="mr-list">${rows
    .map((p) => {
      const role = p.role_label || p.player_position || "";
      const status = statusById?.get(String(p.player_id || "")) || null;
      const rowCls = status ? ` class="mr-unavail-row"` : "";
      return `<li${rowCls}><span class="mr-name">${esc(p.player_name || p.player_id)}${
        role ? ` <span class="mr-role">${esc(role)}</span>` : ""
      }</span>${unavailableBadge(status)}</li>`;
    })
    .join("")}</ul>`;
}

function clubPreviewPanel(title, preview, statusById = null) {
  const p = preview || {};
  const style = p.strongest_playstyle;
  const styleText = style
    ? `${style.label || style.key}${
        style.value != null ? ` (${style.value})` : ""
      }`
    : null;
  const form = formationLabel(p);
  const manager = p.manager_name
    ? `${p.manager_name}${
        p.manager_rating != null ? ` · ${p.manager_rating}` : ""
      }`
    : null;

  const metaBits = [
    manager
      ? `<div class="mr-preview-meta"><span class="mr-preview-k">Manager</span><span class="mr-preview-v">${esc(
          manager
        )}</span></div>`
      : `<div class="mr-preview-meta"><span class="mr-preview-k">Manager</span><span class="mr-preview-v mr-muted">Not signed</span></div>`,
    styleText
      ? `<div class="mr-preview-meta"><span class="mr-preview-k">Strongest playstyle</span><span class="mr-preview-v">${esc(
          styleText
        )}</span></div>`
      : "",
    form
      ? `<div class="mr-preview-meta"><span class="mr-preview-k">Tactic / formation</span><span class="mr-preview-v">${esc(
          form
        )}</span></div>`
      : `<div class="mr-preview-meta"><span class="mr-preview-k">Tactic / formation</span><span class="mr-preview-v mr-muted">Not set</span></div>`,
  ]
    .filter(Boolean)
    .join("");

  const conflicts = squadUnavailableConflicts(p, statusById);
  const body = p.has_squad
    ? `${squadConflictHtml(title, conflicts)}
      <h3>Starting XI</h3>
      ${playerPreviewLines(p.xi, statusById)}
      <h3>Bench</h3>
      ${playerPreviewLines(p.bench, statusById)}`
    : `<p class="mr-empty">No Match Day squad saved yet.</p>`;

  return `
    <section class="mr-panel mr-preview-panel">
      <h2>${esc(title)}</h2>
      <div class="mr-preview-head">${metaBits}</div>
      ${body}
    </section>
  `;
}

function renderNotPlayed(fx, myShort, data = {}) {
  const involves =
    !!myShort &&
    [fx.home_club_short_name, fx.away_club_short_name]
      .map((s) => String(s || "").toUpperCase())
      .includes(String(myShort).toUpperCase());

  const ctas = [];
  if (involves) {
    ctas.push(
      `<a href="matchday.html?fixture=${encodeURIComponent(fx.id)}">Open Match Day</a>`
    );
    ctas.push(
      `<a href="fixture_schedule.html?fixture=${encodeURIComponent(
        fx.id
      )}">Schedule / check-in</a>`
    );
  }

  const homePrev = data.home_preview || null;
  const awayPrev = data.away_preview || null;
  const unavailable = data.unavailable || null;
  const homeUnavail = unavailableStatusByPlayerId(
    unavailable,
    fx.home_club_short_name
  );
  const awayUnavail = unavailableStatusByPlayerId(
    unavailable,
    fx.away_club_short_name
  );
  const anyPreview =
    (homePrev &&
      (homePrev.has_squad || homePrev.manager_name || homePrev.formation_id)) ||
    (awayPrev &&
      (awayPrev.has_squad || awayPrev.manager_name || awayPrev.formation_id));

  const homeConflicts = squadUnavailableConflicts(homePrev, homeUnavail);
  const awayConflicts = squadUnavailableConflicts(awayPrev, awayUnavail);
  const prematchCheck =
    homeConflicts.length || awayConflicts.length
      ? `<div class="mr-prematch-check is-warn">
          <div class="mr-prematch-check-title">Prematch squad check — unavailable players selected</div>
          <p class="mr-prematch-check-note">One or both clubs still have suspended / injured players in their saved Match Day squad. Replace them before kick-off.</p>
          ${squadConflictHtml(
            fx.home_club_name || fx.home_club_short_name || "Home",
            homeConflicts
          )}
          ${squadConflictHtml(
            fx.away_club_name || fx.away_club_short_name || "Away",
            awayConflicts
          )}
        </div>`
      : anyPreview && unavailable
        ? `<div class="mr-prematch-check is-ok">
            <div class="mr-prematch-check-title">Prematch squad check</div>
            <p class="mr-prematch-check-note">No suspended or injured players in the saved Match Day squads.</p>
          </div>`
        : "";
  const consoleCheck = prematchConsoleChecklistHtml();

  return `
    <div class="mr-scoreboard">
      <div class="mr-comp">${esc(competitionLabel(fx))}</div>
      <div class="mr-teams">
        <div class="mr-club home">${esc(
          fx.home_club_name || fx.home_club_short_name
        )}</div>
        <div class="mr-score">vs</div>
        <div class="mr-club away">${esc(
          fx.away_club_name || fx.away_club_short_name
        )}</div>
      </div>
      <div class="mr-submeta">
        <span>Not played yet</span>
        ${fx.home_stadium ? `<span>${esc(fx.home_stadium)}</span>` : ""}
        ${
          fx.agreed_kickoff_at
            ? `<span>${esc(formatKickoff(fx.agreed_kickoff_at, UK_TZ))} UK</span>`
            : ""
        }
      </div>
    </div>
    ${data.unavailableHtml || ""}
    ${prematchCheck}
    ${consoleCheck}
    ${
      anyPreview
        ? `<p class="mr-preview-note">Saved Match Day squads, tactics and managers (scouting preview).</p>
          <div class="mr-grid">
            ${clubPreviewPanel(
              fx.home_club_name || fx.home_club_short_name || "Home",
              homePrev,
              homeUnavail
            )}
            ${clubPreviewPanel(
              fx.away_club_name || fx.away_club_short_name || "Away",
              awayPrev,
              awayUnavail
            )}
          </div>`
        : `<p class="mr-empty">Line-ups, scorers, cards and injuries appear here once the match is played and squad stats are recorded. Clubs can save a Match Day squad beforehand to show it here.</p>`
    }
    ${ctas.length ? `<div class="mr-cta">${ctas.join("")}</div>` : ""}
  `;
}

function renderPlayed(data) {
  const fx = data.fixture || {};
  const month = GPSL_MONTH_LABELS[fx.gpsl_month] || fx.gpsl_month || "";
  const score =
    formatFixtureScore(fx) ||
    `${fx.home_goals ?? "–"} – ${fx.away_goals ?? "–"}`;

  return `
    <div class="mr-scoreboard">
      <div class="mr-comp">${esc(competitionLabel(fx))}${
        month ? ` · ${esc(month)}` : ""
      }</div>
      <div class="mr-teams">
        <div class="mr-club home">${esc(
          fx.home_club_name || fx.home_club_short_name
        )}</div>
        <div class="mr-score">${esc(score)}</div>
        <div class="mr-club away">${esc(
          fx.away_club_name || fx.away_club_short_name
        )}</div>
      </div>
      <div class="mr-submeta">
        ${fx.home_stadium ? `<span>${esc(fx.home_stadium)}</span>` : ""}
        <span>Attendance ${esc(
          formatAttendance(data.attendance, data.capacity)
        )}</span>
        ${fx.is_forfeit ? `<span>Forfeit</span>` : ""}
        ${fx.weather ? `<span>${esc(fx.weather)}</span>` : ""}
        ${fx.pitch_condition ? `<span>${esc(fx.pitch_condition)}</span>` : ""}
      </div>
    </div>
    ${data.unavailableHtml || ""}
    ${
      data.has_stats
        ? `<div class="mr-grid">
            ${clubPanel(
              fx.home_club_name || "Home",
              data.home_players,
              data.injuries,
              fx.home_club_short_name,
              data.home_og_for
            )}
            ${clubPanel(
              fx.away_club_name || "Away",
              data.away_players,
              data.injuries,
              fx.away_club_short_name,
              data.away_og_for
            )}
          </div>`
        : `<div class="mr-panel mr-wide"><p class="mr-empty">Result is recorded, but squad stats (line-ups / scorers) were not entered for this match.</p>
            <div class="mr-cta"><a href="matchday.html?fixture=${encodeURIComponent(
              fx.id
            )}">Open Match Day</a></div>
          </div>`
    }
  `;
}

async function loadMyClubShort() {
  try {
    const { data, error } = await supabase.rpc("my_club_shortname");
    if (error) return null;
    return data || null;
  } catch {
    return null;
  }
}

async function main() {
  await initGlobal();
  const root = document.getElementById("mrRoot");
  const fixtureId = qsFixtureId();
  const back = document.getElementById("mrBack");
  const ref = document.referrer || "";
  if (back) {
    if (/club_fixtures\.html/i.test(ref)) back.href = "club_fixtures.html";
    else if (/fixtures\.html/i.test(ref)) back.href = "fixtures.html";
  }

  if (fixtureId == null) {
    root.innerHTML = `<div class="mr-error">Missing fixture id. Open Match Centre from a fixtures list.</div>`;
    return;
  }

  const { data, error } = await supabase.rpc("competition_match_report", {
    p_fixture_id: fixtureId,
  });

  if (error) {
    console.error(error);
    root.innerHTML = `<div class="mr-error">Could not load match report. Run <code>competition_match_report_prematch_20260918.sql</code> in the SQL editor (adds <code>own_goals</code> if missing and refreshes this RPC).<br>${esc(
      error.message
    )}</div>`;
    return;
  }

  const fx = data?.fixture || {};
  setStadiumBg(fx.home_club_short_name);
  document.title = `${fx.home_club_short_name || "Home"} vs ${
    fx.away_club_short_name || "Away"
  } — Match Centre`;

  const meta = document.getElementById("mrMeta");
  if (meta) meta.textContent = competitionLabel(fx);

  const unavailable = await loadFixtureUnavailable(supabase, fixtureId);
  const unavailableHtml = formatFixtureUnavailableHtml(unavailable, {
    homeName: fx.home_club_name || fx.home_club_short_name,
    awayName: fx.away_club_name || fx.away_club_short_name,
  });

  const status = String(fx.status || "").toLowerCase();
  if (status === "played") {
    root.innerHTML = renderPlayed({ ...data, unavailableHtml });
  } else {
    const myShort = await loadMyClubShort();
    root.innerHTML = renderNotPlayed(
      { ...fx, unavailableHtml },
      myShort,
      { ...data, unavailableHtml, unavailable }
    );
  }
}

main().catch((err) => {
  console.error(err);
  const root = document.getElementById("mrRoot");
  if (root) root.innerHTML = `<div class="mr-error">${esc(err.message || err)}</div>`;
});
