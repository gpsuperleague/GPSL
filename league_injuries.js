import { supabase, initGlobal } from "./global.js";
import { loadCurrentSeason, loadActiveSeasonRegistrations, DIVISION_LABELS } from "./competition.js";

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function severityBucket(severity) {
  const s = String(severity || "").trim().toLowerCase();
  if (s === "major") return "long";
  if (s === "moderate") return "medium";
  return "low";
}

function divisionLabel(division) {
  return DIVISION_LABELS[division] || division || "—";
}

function sortRows(rows) {
  return [...rows].sort((a, b) => {
    return (
      (b.currentInjuries || 0) - (a.currentInjuries || 0) ||
      (b.longTerm || 0) - (a.longTerm || 0) ||
      (b.mediumTerm || 0) - (a.mediumTerm || 0) ||
      (b.lowTerm || 0) - (a.lowTerm || 0) ||
      (b.seasonTotal || 0) - (a.seasonTotal || 0) ||
      String(a.division || "").localeCompare(String(b.division || "")) ||
      String(a.clubName || "").localeCompare(String(b.clubName || ""))
    );
  });
}

function renderSummary(rows, seasonLabel) {
  const wrap = document.getElementById("injurySummary");
  if (!wrap) return;
  const seasonTotal = rows.reduce((sum, row) => sum + (row.seasonTotal || 0), 0);
  const currentTotal = rows.reduce((sum, row) => sum + (row.currentInjuries || 0), 0);
  const longTermTotal = rows.reduce((sum, row) => sum + (row.longTerm || 0), 0);
  const worst = rows[0];
  const worstLabel = worst
    ? `${worst.clubName} (${worst.currentInjuries} current)`
    : "—";

  wrap.innerHTML = `
    <div class="card"><div class="metric-label">Season</div><div class="metric-value" style="font-size:20px">${escapeHtml(seasonLabel || "Current")}</div></div>
    <div class="card"><div class="metric-label">Season Total</div><div class="metric-value">${seasonTotal}</div></div>
    <div class="card"><div class="metric-label">Current Injuries</div><div class="metric-value">${currentTotal}</div></div>
    <div class="card"><div class="metric-label">Long Term</div><div class="metric-value">${longTermTotal}</div></div>
    <div class="card"><div class="metric-label">Worst Hit Club</div><div class="metric-value" style="font-size:18px">${escapeHtml(worstLabel)}</div></div>
  `;
}

function renderTable(rows) {
  const wrap = document.getElementById("leagueInjuriesTableWrap");
  if (!wrap) return;

  if (!rows.length) {
    wrap.innerHTML = `<div class="empty">No clubs or injury data found for the current season.</div>`;
    return;
  }

  wrap.innerHTML = `
    <table>
      <thead>
        <tr>
          <th class="num">#</th>
          <th>Club</th>
          <th>Division</th>
          <th class="num">Season total</th>
          <th class="num">Current injuries</th>
          <th class="num">Low term</th>
          <th class="num">Medium term</th>
          <th class="num">Long term</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (row, index) => `
              <tr class="${row.currentInjuries ? "highlight" : ""}">
                <td class="num">${index + 1}</td>
                <td>${escapeHtml(row.clubName)}</td>
                <td>${escapeHtml(divisionLabel(row.division))}</td>
                <td class="num">${row.seasonTotal}</td>
                <td class="num">${row.currentInjuries}</td>
                <td class="num">${row.lowTerm}</td>
                <td class="num">${row.mediumTerm}</td>
                <td class="num">${row.longTerm}</td>
              </tr>
            `
          )
          .join("")}
      </tbody>
    </table>
  `;
}

async function loadLeagueInjuries() {
  const status = document.getElementById("leagueInjuriesStatus");
  const tableWrap = document.getElementById("leagueInjuriesTableWrap");
  try {
    status.textContent = "Loading injuries…";
    tableWrap.innerHTML = "";

    const season = await loadCurrentSeason(supabase);
    if (!season?.id) {
      throw new Error("No current season found.");
    }

    const [clubs, injuryRes] = await Promise.all([
      loadActiveSeasonRegistrations(supabase),
      supabase
        .from("competition_player_injuries")
        .select("club_short_name, severity, status, matches_out_remaining, season_id")
        .eq("season_id", season.id),
    ]);

    if (injuryRes.error) throw injuryRes.error;

    const byClub = new Map();
    for (const club of clubs || []) {
      const key = String(club.club_short_name || "");
      byClub.set(key, {
        clubShortName: key,
        clubName: club.club_name || key,
        division: club.division || "",
        seasonTotal: 0,
        currentInjuries: 0,
        lowTerm: 0,
        mediumTerm: 0,
        longTerm: 0,
      });
    }

    for (const row of injuryRes.data || []) {
      const key = String(row.club_short_name || "");
      if (!key) continue;
      if (!byClub.has(key)) {
        byClub.set(key, {
          clubShortName: key,
          clubName: key,
          division: "",
          seasonTotal: 0,
          currentInjuries: 0,
          lowTerm: 0,
          mediumTerm: 0,
          longTerm: 0,
        });
      }
      const club = byClub.get(key);
      club.seasonTotal += 1;

      const isCurrent =
        String(row.status || "").toLowerCase() === "active" &&
        Number(row.matches_out_remaining || 0) > 0;
      if (!isCurrent) continue;

      club.currentInjuries += 1;
      const bucket = severityBucket(row.severity);
      if (bucket === "long") club.longTerm += 1;
      else if (bucket === "medium") club.mediumTerm += 1;
      else club.lowTerm += 1;
    }

    const rows = sortRows([...byClub.values()]);
    renderSummary(rows, season.name || season.label || "Current season");
    renderTable(rows);
    status.innerHTML = `<span class="muted">Sorted by current injuries, then long / medium / low-term counts, then season total.</span>`;
  } catch (err) {
    console.error("loadLeagueInjuries failed:", err);
    status.textContent = "";
    tableWrap.innerHTML = `<div class="error">Could not load league injuries: ${escapeHtml(err.message || err)}</div>`;
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadLeagueInjuries();
});
