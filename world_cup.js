import { supabase, initGlobal } from "./global.js";
import {
  loadWcCycles,
  loadQualStandings,
  loadFinalsStandings,
  loadInternationalFixtures,
  loadMyNation,
  groupStandingsTable,
  WC_QUAL_GROUPS,
  WC_FINALS_GROUPS,
} from "./international.js";
import { renderNationFlag } from "./international_flags.js";

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

function renderGroupGrid(containerId, letters, rows) {
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
        ${groupStandingsTable(rows, g)}
      </div>`
    )
    .join("");
}

function nationCell(code, name, flag) {
  if (!code) return '<span class="empty">TBD</span>';
  return `${renderNationFlag({ code, name, flag_emoji: flag }, "sm")} ${escapeHtml(name || code)}`;
}

function monthLabel(m) {
  if (!m) return "";
  return String(m).charAt(0).toUpperCase() + String(m).slice(1);
}

function renderFixtures(containerId, fixtures, emptyMsg) {
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
  el.innerHTML = keys
    .map((md) => {
      const rows = byMatch.get(md) || [];
      const sample = rows[0];
      const when = [monthLabel(sample?.gpsl_month), sample?.week_in_month != null ? `W${sample.week_in_month}` : ""]
        .filter(Boolean)
        .join(" · ");
      const seasonHint = sample?.season_id != null ? ` · season id ${sample.season_id}` : "";
      const lines = rows
        .slice()
        .sort((a, b) => String(a.group_code || "").localeCompare(String(b.group_code || "")))
        .map((f) => {
          const score = f.played
            ? `<b>${f.home_goals}–${f.away_goals}</b>`
            : `<span class="empty">vs</span>`;
          const href = `international_matchday.html?fixture=${f.id}`;
          return `<div class="intl-fix-row">
            <span class="intl-fix-group">Grp ${escapeHtml(f.group_code || "?")}</span>
            <span class="intl-fix-sides">
              ${renderNationFlag({ code: f.home_nation, name: f.home_nation_name, flag_emoji: f.home_flag }, "sm")}
              ${escapeHtml(f.home_nation_name || f.home_nation)}
              ${score}
              ${renderNationFlag({ code: f.away_nation, name: f.away_nation_name, flag_emoji: f.away_flag }, "sm")}
              ${escapeHtml(f.away_nation_name || f.away_nation)}
            </span>
            <a class="intl-fix-link" href="${href}">Open</a>
          </div>`;
        })
        .join("");

      return `<div class="intl-fix-md">
        <h3>Window ${md}${when ? ` — ${escapeHtml(when)}` : ""}${escapeHtml(seasonHint)}</h3>
        ${lines}
      </div>`;
    })
    .join("");
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
  const cycleNo = cycles[0]?.cycle_no ?? null;

  const [qual, finals, qualFix, finalsFix] = await Promise.all([
    loadQualStandings(cycleNo, supabase),
    loadFinalsStandings(cycleNo, supabase),
    loadInternationalFixtures(cycleNo, "qualifying", supabase),
    loadInternationalFixtures(cycleNo, "finals_group", supabase),
  ]);

  renderGroupGrid("qualGroups", QUAL_LETTERS.slice(0, WC_QUAL_GROUPS), qual);
  renderFixtures(
    "qualFixtures",
    qualFix,
    "No qualifying fixtures yet — admin: World Cup cycle → Generate qual fixtures."
  );

  renderGroupGrid("finalsGroups", FINALS_LETTERS.slice(0, WC_FINALS_GROUPS), finals);
  renderFixtures(
    "finalsFixtures",
    finalsFix,
    "No finals fixtures yet — generated after finals groups are drawn."
  );

  let koQuery = supabase
    .from("international_knockout_public")
    .select("*")
    .order("match_no", { ascending: true });
  if (cycleNo != null) koQuery = koQuery.eq("cycle_no", cycleNo);
  const { data: koNodes } = await koQuery;
  renderKnockout(koNodes || []);
});
