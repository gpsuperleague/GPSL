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

function severityRank(severity) {
  const b = severityBucket(severity);
  if (b === "long") return 3;
  if (b === "medium") return 2;
  return 1;
}

function divisionLabel(division) {
  return DIVISION_LABELS[division] || division || "—";
}

function clubHref(shortName) {
  return `club.html?club=${encodeURIComponent(String(shortName || "").trim())}`;
}

function clubLinkHtml(shortName, displayName) {
  const short = String(shortName || "").trim();
  const label = displayName || short || "—";
  if (!short) return escapeHtml(label);
  return `<a class="gpsl-link" href="${clubHref(short)}">${escapeHtml(label)}</a>`;
}

function matchWord(n) {
  const v = Math.max(0, Number(n) || 0);
  return v === 1 ? "1 match" : `${v} matches`;
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

function emptyClubRow(key, clubName, division) {
  return {
    clubShortName: key,
    clubName: clubName || key,
    division: division || "",
    seasonTotal: 0,
    currentInjuries: 0,
    lowTerm: 0,
    mediumTerm: 0,
    longTerm: 0,
    longest: null,
  };
}

function considerLongest(club, inj, playerName) {
  const outLeft = Number(inj.matches_out_remaining) || 0;
  if (outLeft <= 0) return;
  const next = {
    playerId: String(inj.player_id || ""),
    playerName: playerName || String(inj.player_id || "Unknown"),
    label: inj.label || "Injury",
    severity: inj.severity || "",
    matchesOut: outLeft,
  };
  const cur = club.longest;
  if (!cur) {
    club.longest = next;
    return;
  }
  if (
    next.matchesOut > cur.matchesOut ||
    (next.matchesOut === cur.matchesOut &&
      severityRank(next.severity) > severityRank(cur.severity))
  ) {
    club.longest = next;
  }
}

function longestCellHtml(longest) {
  if (!longest) return `<span class="muted">—</span>`;
  const title = `${longest.playerName} — ${longest.label} — ${matchWord(longest.matchesOut)} out`;
  return `<span title="${escapeHtml(title)}"><b>${escapeHtml(longest.playerName)}</b><br><span class="muted">${escapeHtml(matchWord(longest.matchesOut))} · ${escapeHtml(longest.label)}</span></span>`;
}

function renderSummary(rows, seasonLabel) {
  const wrap = document.getElementById("injurySummary");
  if (!wrap) return;
  const seasonTotal = rows.reduce((sum, row) => sum + (row.seasonTotal || 0), 0);
  const currentTotal = rows.reduce((sum, row) => sum + (row.currentInjuries || 0), 0);
  const longTermTotal = rows.reduce((sum, row) => sum + (row.longTerm || 0), 0);
  const worst = rows[0];
  const worstLabel = worst
    ? `${clubLinkHtml(worst.clubShortName, worst.clubName)} <span class="muted">(${worst.currentInjuries} current)</span>`
    : "—";

  let longestLeague = null;
  for (const row of rows) {
    if (!row.longest) continue;
    if (
      !longestLeague ||
      row.longest.matchesOut > longestLeague.matchesOut ||
      (row.longest.matchesOut === longestLeague.matchesOut &&
        severityRank(row.longest.severity) > severityRank(longestLeague.severity))
    ) {
      longestLeague = { ...row.longest, clubShortName: row.clubShortName, clubName: row.clubName };
    }
  }
  const longestLabel = longestLeague
    ? `${escapeHtml(longestLeague.playerName)} <span class="muted">(${clubLinkHtml(longestLeague.clubShortName, longestLeague.clubName)} · ${escapeHtml(matchWord(longestLeague.matchesOut))})</span>`
    : "—";

  wrap.innerHTML = `
    <div class="card"><div class="metric-label">Season</div><div class="metric-value" style="font-size:20px">${escapeHtml(seasonLabel || "Current")}</div></div>
    <div class="card"><div class="metric-label">Season Total</div><div class="metric-value">${seasonTotal}</div></div>
    <div class="card"><div class="metric-label">Current Injuries</div><div class="metric-value">${currentTotal}</div></div>
    <div class="card"><div class="metric-label">Long Term</div><div class="metric-value">${longTermTotal}</div></div>
    <div class="card"><div class="metric-label">Worst Hit Club</div><div class="metric-value" style="font-size:16px;line-height:1.35">${worstLabel}</div></div>
    <div class="card"><div class="metric-label">Longest Out</div><div class="metric-value" style="font-size:16px;line-height:1.35">${longestLabel}</div></div>
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
          <th>Longest out</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (row, index) => `
              <tr class="${row.currentInjuries ? "highlight" : ""}">
                <td class="num">${index + 1}</td>
                <td>${clubLinkHtml(row.clubShortName, row.clubName)}</td>
                <td>${escapeHtml(divisionLabel(row.division))}</td>
                <td class="num">${row.seasonTotal}</td>
                <td class="num">${row.currentInjuries}</td>
                <td class="num">${row.lowTerm}</td>
                <td class="num">${row.mediumTerm}</td>
                <td class="num">${row.longTerm}</td>
                <td>${longestCellHtml(row.longest)}</td>
              </tr>
            `
          )
          .join("")}
      </tbody>
    </table>
  `;
}

async function loadPlayerNameMap(playerIds) {
  const ids = [...new Set((playerIds || []).map(String).filter(Boolean))];
  const map = new Map();
  if (!ids.length) return map;

  const chunkSize = 200;
  for (let i = 0; i < ids.length; i += chunkSize) {
    const chunk = ids.slice(i, i + chunkSize);
    const { data, error } = await supabase
      .from("Players")
      .select("Konami_ID, Name")
      .in("Konami_ID", chunk);
    if (error) {
      console.warn("league injuries player names:", error.message);
      continue;
    }
    for (const p of data || []) {
      map.set(String(p.Konami_ID), p.Name || String(p.Konami_ID));
    }
  }
  return map;
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
        .select(
          "club_short_name, severity, status, matches_out_remaining, player_id, label, season_id"
        )
        .eq("season_id", season.id),
    ]);

    if (injuryRes.error) throw injuryRes.error;

    const byClub = new Map();
    for (const club of clubs || []) {
      const key = String(club.club_short_name || "");
      byClub.set(key, emptyClubRow(key, club.club_name || key, club.division || ""));
    }

    const activeRows = [];
    for (const row of injuryRes.data || []) {
      const key = String(row.club_short_name || "");
      if (!key) continue;
      if (!byClub.has(key)) {
        byClub.set(key, emptyClubRow(key, key, ""));
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
      activeRows.push(row);
    }

    const nameMap = await loadPlayerNameMap(activeRows.map((r) => r.player_id));
    for (const row of activeRows) {
      const club = byClub.get(String(row.club_short_name || ""));
      if (!club) continue;
      const name = nameMap.get(String(row.player_id || "")) || String(row.player_id || "Unknown");
      considerLongest(club, row, name);
    }

    const rows = sortRows([...byClub.values()]);
    renderSummary(rows, season.name || season.label || "Current season");
    renderTable(rows);
    status.innerHTML = `<span class="muted">Sorted by current injuries, then long / medium / low-term counts, then season total. Club names open the club page. Longest out = active injury with most matches still remaining.</span>`;
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
