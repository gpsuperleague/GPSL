import { supabase, initGlobal } from "./global.js";
import {
  loadWcCycles,
  loadQualStandings,
  loadFinalsStandings,
  loadInternationalFixtures,
  loadMyNation,
  groupStandingsTable,
  bestThirdPlaceRows,
  WC_QUAL_GROUPS,
  WC_FINALS_GROUPS,
} from "./international.js?v=20260710-standings-clean";
import { renderNationFlag } from "./international_flags.js?v=20260710-standings-clean";

const QUAL_LETTERS = "ABCDEFGHIJKL".split("");
const FINALS_LETTERS = "ABCDEFGH".split("");

function escapeHtml(t) {
  return String(t ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function renderCycle(cycles) {
  const el = document.getElementById("cycleInfo");
  if (!el) return;
  const c = cycles[0];
  if (!c) {
    el.innerHTML =
      '<span class="empty">No World Cup cycle configured yet — admin can set this up.</span>';
    return;
  }
  el.innerHTML = `
    <b>${escapeHtml(c.label)}</b> — status: <b>${escapeHtml(c.status)}</b><br>
    Qualifying seasons: ${escapeHtml(c.qual_season_1_label || "—")} &amp; ${escapeHtml(
      c.qual_season_2_label || "—"
    )}<br>
    Finals: pre-season of ${escapeHtml(c.finals_after_season_label || "—")} (season ${escapeHtml(
      c.finals_after_season_ordinal || "—"
    )})
  `;
}

function renderGroupGrid(containerId, letters, rows, phase) {
  const el = document.getElementById(containerId);
  if (!el) return;
  if (!rows.length) {
    el.innerHTML = letters
      .map(
        (g) =>
          `<div class="intl-group-card"><h4>Group ${g}</h4><p class="empty">Not drawn yet.</p></div>`
      )
      .join("");
    return;
  }
  el.innerHTML = letters
    .map(
      (g) => `
      <div class="intl-group-card">
        <h4>Group ${g}</h4>
        ${groupStandingsTable(rows, g, { phase })}
      </div>`
    )
    .join("");
}

function renderBestThirds(qualRows) {
  const el = document.getElementById("bestThirds");
  const note = document.getElementById("bestThirdsNote");
  if (!el) return;

  const thirds = bestThirdPlaceRows(qualRows);
  if (!thirds.length) {
    el.innerHTML = "";
    if (note) {
      note.hidden = false;
      note.textContent =
        "Third-place ranking appears once qualifying groups are drawn.";
    }
    return;
  }

  const ranked = thirds.some((r) => Number(r.third_place_rank) > 0);
  if (note) {
    note.hidden = false;
    note.textContent = ranked
      ? "Best 8 third-place nations (highlighted) join the 24 automatic qualifiers in the finals draw."
      : "Group 3rds listed by current form. Best 8 are locked in when every qualifying fixture is played.";
  }

  el.innerHTML = `
    <table class="intl-table intl-thirds-table">
      <thead>
        <tr>
          <th>#</th><th>Group</th><th>Nation</th><th>P</th><th>W</th><th>D</th><th>L</th><th>F:A</th><th>Pts</th><th></th>
        </tr>
      </thead>
      <tbody>
        ${thirds
          .map((r, i) => {
            const thr = Number(r.third_place_rank) || i + 1;
            const bestEight = r.qualified === true && Number(r.third_place_rank) > 0 && Number(r.third_place_rank) <= 8;
            const pendingBest = !ranked && i < 8;
            const rowClass = bestEight || pendingBest ? "intl-row-best-third" : "";
            const tag = bestEight
              ? `<span class="intl-badge intl-badge-3q">Finals</span>`
              : ranked
                ? `<span class="empty">—</span>`
                : pendingBest
                  ? `<span class="intl-badge intl-badge-3">Provisional</span>`
                  : "";
            return `<tr class="${rowClass}">
              <td>${thr}</td>
              <td>${escapeHtml(r.group_code)}</td>
              <td>
                <span class="intl-nation-cell">
                  ${renderNationFlag(r, "sm")}
                  ${escapeHtml(r.nation_name || r.nation_code)}
                </span>
              </td>
              <td>${r.played}</td>
              <td>${r.won}</td>
              <td>${r.drawn}</td>
              <td>${r.lost}</td>
              <td>${r.goals_for}:${r.goals_against}</td>
              <td><b>${r.points}</b></td>
              <td>${tag}</td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;
}

function nationCell(code, name, flag) {
  if (!code) return '<span class="empty">TBD</span>';
  return `${renderNationFlag({ code, name, flag_emoji: flag }, "sm")} ${escapeHtml(name || code)}`;
}

function monthLabel(m) {
  if (!m) return "";
  return String(m).charAt(0).toUpperCase() + String(m).slice(1);
}

function seasonTabLabel(sample, cycle) {
  if (sample?.season_label) return String(sample.season_label);
  if (sample?.season_ordinal != null) return `Season ${sample.season_ordinal}`;
  const mn = Number(sample?.match_no) || 0;
  if (sample?.phase === "qualifying" && cycle) {
    if (mn >= 1 && mn <= 5) return cycle.qual_season_1_label || "Season 1";
    if (mn >= 6 && mn <= 10) return cycle.qual_season_2_label || "Season 2";
  }
  if (sample?.phase === "finals_group" && cycle?.finals_after_season_label) {
    return cycle.finals_after_season_label;
  }
  return "";
}

function windowTabTitle(sample, cycle) {
  const month = monthLabel(sample?.gpsl_month);
  const season = seasonTabLabel(sample, cycle);
  if (month && season) return `${month} ${season}`;
  if (month) return month;
  if (season) return season;
  return "Fixtures";
}

function isMyFixture(f, myNationCode) {
  if (!myNationCode || !f) return false;
  const code = String(myNationCode).toUpperCase();
  return (
    String(f.home_nation || "").toUpperCase() === code ||
    String(f.away_nation || "").toUpperCase() === code
  );
}

function fixtureRowHtml(f, myNationCode) {
  const score = f.played
    ? `<b>${f.home_goals}–${f.away_goals}</b>`
    : `<span class="empty">vs</span>`;
  const href = `international_matchday.html?fixture=${f.id}`;
  const mine = isMyFixture(f, myNationCode);
  return `<div class="intl-fix-row${mine ? " intl-fix-row--mine" : ""}">
    <span class="intl-fix-group">Grp ${escapeHtml(f.group_code || "?")}</span>
    <span class="intl-fix-sides">
      ${renderNationFlag({ code: f.home_nation, name: f.home_nation_name, flag_emoji: f.home_flag }, "sm")}
      ${escapeHtml(f.home_nation_name || f.home_nation)}
      ${score}
      ${renderNationFlag({ code: f.away_nation, name: f.away_nation_name, flag_emoji: f.away_flag }, "sm")}
      ${escapeHtml(f.away_nation_name || f.away_nation)}
    </span>
    ${mine ? `<span class="intl-fix-mine-tag">Your match</span>` : ""}
    <a class="intl-fix-link" href="${href}">Open</a>
  </div>`;
}

/**
 * Tabbed fixture windows: Window N / Month Season X
 * Highlights the logged-in owner's nation fixtures.
 */
function renderFixtures(containerId, fixtures, emptyMsg, myNationCode, cycle) {
  const el = document.getElementById(containerId);
  if (!el) return;

  if (!fixtures.length) {
    el.innerHTML = `<p class="empty">${escapeHtml(emptyMsg)}</p>`;
    return;
  }

  const byMatch = new Map();
  for (const f of fixtures) {
    const key = Number(f.match_no) || 0;
    if (!byMatch.has(key)) byMatch.set(key, []);
    byMatch.get(key).push(f);
  }

  const keys = [...byMatch.keys()].sort((a, b) => a - b);

  let defaultKey = keys[0];
  const myUnplayed = keys.find((k) =>
    (byMatch.get(k) || []).some((f) => isMyFixture(f, myNationCode) && !f.played)
  );
  if (myUnplayed != null) defaultKey = myUnplayed;
  else {
    const myAny = keys.find((k) =>
      (byMatch.get(k) || []).some((f) => isMyFixture(f, myNationCode))
    );
    if (myAny != null) defaultKey = myAny;
  }

  const tabs = keys
    .map((md) => {
      const rows = byMatch.get(md) || [];
      const sample = rows[0];
      const hasMine = rows.some((f) => isMyFixture(f, myNationCode));
      const title = windowTabTitle(sample, cycle);
      const active = md === defaultKey ? " is-active" : "";
      const mineCls = hasMine ? " has-mine" : "";
      return `<button type="button" class="intl-fix-tab${active}${mineCls}" role="tab"
        data-window="${md}" aria-selected="${md === defaultKey ? "true" : "false"}">
        <span class="intl-fix-tab-win">Window ${md}</span>
        <span class="intl-fix-tab-when">${escapeHtml(title)}</span>
      </button>`;
    })
    .join("");

  const panels = keys
    .map((md) => {
      const rows = byMatch.get(md) || [];
      const sample = rows[0];
      const title = windowTabTitle(sample, cycle);
      const week =
        sample?.week_in_month != null ? ` · week ${sample.week_in_month}` : "";
      const lines = rows
        .slice()
        .sort((a, b) => {
          const mineA = isMyFixture(a, myNationCode) ? 0 : 1;
          const mineB = isMyFixture(b, myNationCode) ? 0 : 1;
          if (mineA !== mineB) return mineA - mineB;
          return String(a.group_code || "").localeCompare(String(b.group_code || ""));
        })
        .map((f) => fixtureRowHtml(f, myNationCode))
        .join("");
      const hidden = md === defaultKey ? "" : " hidden";
      return `<div class="intl-fix-panel" data-window-panel="${md}" role="tabpanel"${hidden}>
        <p class="intl-fix-panel-head">Window ${md} — ${escapeHtml(title)}${escapeHtml(week)}</p>
        ${lines}
      </div>`;
    })
    .join("");

  el.innerHTML = `
    <div class="intl-fix-tabs" role="tablist">${tabs}</div>
    <div class="intl-fix-panels">${panels}</div>`;

  el.querySelector(".intl-fix-tabs")?.addEventListener("click", (e) => {
    const btn = e.target.closest(".intl-fix-tab");
    if (!btn || !el.contains(btn)) return;
    const win = btn.getAttribute("data-window");
    el.querySelectorAll(".intl-fix-tab").forEach((t) => {
      const on = t.getAttribute("data-window") === win;
      t.classList.toggle("is-active", on);
      t.setAttribute("aria-selected", on ? "true" : "false");
    });
    el.querySelectorAll(".intl-fix-panel").forEach((p) => {
      p.hidden = p.getAttribute("data-window-panel") !== win;
    });
  });
}

function nationCellKo(code, name, flag) {
  if (!code) return '<span class="empty">TBD</span>';
  return `${escapeHtml(flag || "")} ${escapeHtml(name || code)}`;
}

function renderKnockout(nodes) {
  const root = document.getElementById("knockoutBracket");
  const note = document.getElementById("knockoutNote");
  if (!root) return;

  if (!nodes.length) {
    root.innerHTML = "";
    if (note) note.hidden = false;
    return;
  }
  if (note) note.hidden = true;

  const stages = [
    { key: "r16", label: "Round of 16" },
    { key: "qf", label: "Quarter-finals" },
    { key: "sf", label: "Semi-finals" },
    { key: "final", label: "Final" },
  ];

  root.innerHTML = stages
    .map(({ key, label }) => {
      const rows = nodes
        .filter((n) => n.stage === key)
        .sort((a, b) => Number(a.match_no) - Number(b.match_no));
      if (!rows.length) return "";
      return `
        <div class="intl-ko-stage" style="margin-bottom:16px;">
          <h3 style="color:#ffaa22;font-size:15px;margin:0 0 8px;">${label}</h3>
          <div class="intl-grid">
            ${rows
              .map((n) => {
                const score =
                  n.played && n.goals_a != null
                    ? `${n.goals_a}–${n.goals_b}`
                    : "vs";
                const winner = n.winner_nation
                  ? `<div class="note">Winner: ${escapeHtml(n.winner_nation)}</div>`
                  : "";
                return `<div class="intl-group-card">
                  <h4>Match ${n.match_no}</h4>
                  <div>${nationCellKo(n.nation_a, n.nation_a_name, n.nation_a_flag)}</div>
                  <div style="margin:4px 0;color:#888;">${score}</div>
                  <div>${nationCellKo(n.nation_b, n.nation_b_name, n.nation_b_flag)}</div>
                  ${winner}
                </div>`;
              })
              .join("")}
          </div>
        </div>`;
    })
    .join("");
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const myNation = await loadMyNation(supabase);
  const link = document.getElementById("myNationLink");
  if (link && myNation?.code) {
    link.href = `national_team.html?nation=${encodeURIComponent(myNation.code)}`;
    link.hidden = false;
  }

  const cycles = await loadWcCycles(supabase);
  renderCycle(cycles);
  const cycle = cycles[0] || null;
  const cycleNo = cycle?.cycle_no ?? null;
  const myNationCode = myNation?.code || null;

  const [qual, finals, qualFix, finalsFix] = await Promise.all([
    loadQualStandings(cycleNo, supabase),
    loadFinalsStandings(cycleNo, supabase),
    loadInternationalFixtures(cycleNo, "qualifying", supabase),
    loadInternationalFixtures(cycleNo, "finals_group", supabase),
  ]);

  renderGroupGrid("qualGroups", QUAL_LETTERS.slice(0, WC_QUAL_GROUPS), qual, "qualifying");
  renderBestThirds(qual);
  renderFixtures(
    "qualFixtures",
    qualFix,
    "No qualifying fixtures yet — admin: World Cup cycle → Generate qual fixtures.",
    myNationCode,
    cycle
  );

  renderGroupGrid("finalsGroups", FINALS_LETTERS.slice(0, WC_FINALS_GROUPS), finals, "finals");
  renderFixtures(
    "finalsFixtures",
    finalsFix,
    "No finals fixtures yet — generated after finals groups are drawn.",
    myNationCode,
    cycle
  );

  let koQuery = supabase
    .from("international_knockout_public")
    .select("*")
    .order("match_no", { ascending: true });
  if (cycleNo != null) koQuery = koQuery.eq("cycle_no", cycleNo);
  const { data: koNodes } = await koQuery;
  renderKnockout(koNodes || []);
});
