import { supabase, initGlobal } from "./global.js";
import {
  loadWcCycles,
  loadQualStandings,
  loadFinalsStandings,
  loadMyNation,
  groupStandingsTable,
  WC_QUAL_GROUPS,
  WC_FINALS_GROUPS,
} from "./international.js";

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
    Finals window: after ${escapeHtml(c.finals_after_season_label || "—")} (season ${escapeHtml(
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
                  <div>${nationCell(n.nation_a, n.nation_a_name, n.nation_a_flag)}</div>
                  <div style="margin:4px 0;color:#888;">${score}</div>
                  <div>${nationCell(n.nation_b, n.nation_b_name, n.nation_b_flag)}</div>
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

  const qual = await loadQualStandings(cycleNo, supabase);
  renderGroupGrid("qualGroups", QUAL_LETTERS.slice(0, WC_QUAL_GROUPS), qual);

  const finals = await loadFinalsStandings(cycleNo, supabase);
  renderGroupGrid("finalsGroups", FINALS_LETTERS.slice(0, WC_FINALS_GROUPS), finals);

  let koQuery = supabase
    .from("international_knockout_public")
    .select("*")
    .order("match_no", { ascending: true });
  if (cycleNo != null) koQuery = koQuery.eq("cycle_no", cycleNo);
  const { data: koNodes } = await koQuery;
  renderKnockout(koNodes || []);
});
