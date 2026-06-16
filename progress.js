import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, clubWithOwnerHtml } from "./clubs_lookup.js";
import {
  loadCurrentSeason,
  loadStandingsWithPrizes,
  loadArchivedSeasonStandings,
  loadLeagueFixtures,
  loadShieldSpoonPlayoffQualifiers,
  groupStandingsByDivision,
  buildVenueStandings,
  rankVenueStandings,
  LEAGUE_DIVISIONS,
  statusForStanding,
  prestigeBarKeyForStanding,
  leagueTintKey,
  leagueBoundaryKey,
  PRESTIGE_CUP_BAR_COLORS,
  LEAGUE_TINT_LEGEND_COLORS,
  formatFormHtml,
  formatMoney,
  normalizeClubKey,
} from "./competition.js";

function seasonFromUrl() {
  return new URLSearchParams(window.location.search).get("season")?.trim() || "";
}

function divisionFromUrl() {
  const div = new URLSearchParams(window.location.search).get("division")?.trim() || "";
  return LEAGUE_DIVISIONS.includes(div) ? div : "";
}

function applyDivisionFilterFromUrl() {
  const div = divisionFromUrl();
  if (!div) return;
  document.querySelectorAll(".filter-div").forEach((el) => {
    el.checked = el.dataset.division === div;
  });
  syncFilterAllCheckbox();
}

function scrollToDivisionFromUrl() {
  const div = divisionFromUrl();
  if (!div) return;
  requestAnimationFrame(() => {
    document
      .querySelector(`.division-panel[data-division="${div}"]`)
      ?.scrollIntoView({ behavior: "smooth", block: "start" });
  });
}

function setArchiveModeUi(seasonLabel) {
  const meta = document.getElementById("seasonMeta");
  if (meta) {
    meta.innerHTML = `Final tables — <b>${seasonLabel}</b> (archived) · <a class="gpsl-link" href="progress.html">Current season</a>`;
  }
  document.getElementById("homeAwaySection")?.setAttribute("hidden", "");
  const venueFilter = document.getElementById("venueFilter");
  if (venueFilter) venueFilter.hidden = true;
  document.querySelector(".home-away-note")?.remove();
}

const DIVISION_TITLES = {
  superleague: "SuperLeague",
  championship_a: "Championship A",
  championship_b: "Championship B",
};

/** Shared column widths so all three division tables line up. */
const STANDINGS_COLGROUP = `
  <colgroup>
    <col class="col-pos" />
    <col class="col-club" />
    <col class="col-status" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-stat" />
    <col class="col-prize" />
    <col class="col-form" />
  </colgroup>`;

function renderLegend() {
  const el = document.getElementById("zoneLegend");
  const prestige = [
    { color: PRESTIGE_CUP_BAR_COLORS.super8, label: "Bar · Super8" },
    { color: PRESTIGE_CUP_BAR_COLORS.plate, label: "Bar · Plate" },
    { color: PRESTIGE_CUP_BAR_COLORS.shield, label: "Bar · Shield" },
    { color: PRESTIGE_CUP_BAR_COLORS.bowl, label: "Bar · Bowl" },
  ];
  const league = [
    { color: LEAGUE_TINT_LEGEND_COLORS.champion, label: "Tint · Champion" },
    { color: LEAGUE_TINT_LEGEND_COLORS.runner_up, label: "Tint · Runner-up" },
    { color: LEAGUE_TINT_LEGEND_COLORS.promotion, label: "Tint · Promotion" },
    { color: LEAGUE_TINT_LEGEND_COLORS.playoffs, label: "Tint · Playoffs" },
    { color: LEAGUE_TINT_LEGEND_COLORS.playoff, label: "Tint · 16v17 playoff" },
    { color: LEAGUE_TINT_LEGEND_COLORS.relegation, label: "Tint · Relegation / Spoon" },
  ];
  const lines = [
    { color: LEAGUE_TINT_LEGEND_COLORS.playoff, label: "Line · Playoff zone", dashed: true },
    { color: LEAGUE_TINT_LEGEND_COLORS.relegation, label: "Line · Relegation / Spoon", dashed: false },
  ];
  const chip = (i) =>
    `<span><i style="display:inline-block;width:12px;height:12px;border-radius:2px;background:${i.color};"></i> ${i.label}</span>`;
  const lineChip = (i) =>
    `<span><i class="legend-line${i.dashed ? " legend-line-dashed" : ""}" style="--line-color:${i.color};"></i> ${i.label}</span>`;
  el.innerHTML = `
    <span class="legend-group"><b>Left bar</b> (prestige cup) ${prestige.map(chip).join(" ")}</span>
    <span class="legend-group"><b>Row tint</b> (league) ${league.map(chip).join(" ")}</span>
    <span class="legend-group"><b>Zone lines</b> ${lines.map(lineChip).join(" ")}</span>
  `;
}

function gdDisplay(gd) {
  if (gd > 0) return `+${gd}`;
  return String(gd);
}

function renderStandingsTable(division, rows, myClub, opts = {}) {
  const {
    rankField = "table_position",
    showPrize = true,
    zoneBoundaries = true,
    panelTitle = DIVISION_TITLES[division],
    rankHeader = "#",
    tableClass = "standings-table",
    playoffQualifiers = shieldSpoonPlayoffQualifiers,
  } = opts;

  const panel = document.createElement("div");
  panel.className = "division-panel";
  panel.dataset.division = division;

  if (!rows.length) {
    panel.innerHTML = `
      <h2>${panelTitle}</h2>
      <p class="empty-msg">No standings for this division.</p>
    `;
    return panel;
  }

  const sortedRows = [...rows].sort((a, b) => {
    const ra = a[rankField] ?? 999;
    const rb = b[rankField] ?? 999;
    return ra - rb;
  });

  let prevPrestigeKey = null;
  let prevLeagueKey = null;
  const tbody = sortedRows
    .map((row) => {
      const displayRank = row[rankField];
      const leaguePos = row.table_position;
      const prestigeKey = prestigeBarKeyForStanding(
        division,
        leaguePos,
        row.club_short_name,
        playoffQualifiers
      );
      const tintKey = leagueTintKey(division, leaguePos);
      const leagueKey = leagueBoundaryKey(division, leaguePos);
      const prestigeBoundary =
        zoneBoundaries &&
        prevPrestigeKey !== null &&
        prevPrestigeKey !== prestigeKey;
      const playoffBoundary =
        zoneBoundaries &&
        prevLeagueKey !== null &&
        (((leagueKey === "playoff" || leagueKey === "playoffs") &&
          prevLeagueKey !== "playoff" &&
          prevLeagueKey !== "playoffs") ||
          (division !== "superleague" &&
            leagueKey === "mid" &&
            prevLeagueKey === "playoffs"));
      const relegationBoundary =
        zoneBoundaries &&
        leagueKey === "relegation" &&
        prevLeagueKey !== null &&
        prevLeagueKey !== "relegation";
      const bowlBoundary =
        zoneBoundaries &&
        leagueKey === "bowl" &&
        prevLeagueKey !== null &&
        prevLeagueKey !== "bowl";
      if (zoneBoundaries) {
        prevPrestigeKey = prestigeKey;
        prevLeagueKey = leagueKey;
      }
      const statusText = statusForStanding(
        division,
        leaguePos,
        row.club_short_name,
        playoffQualifiers
      ).join(" · ");
      const mine =
        myClub?.short &&
        normalizeClubKey(row.club_short_name) === normalizeClubKey(myClub.short)
          ? " my-club"
          : "";

      const prizeCell = showPrize
        ? (() => {
            const prizeAmt = Number(row.league_prize_amount || 0);
            const prizeTitle = row.league_prize_paid
              ? "Paid at end of league season"
              : "Projected if season ended now";
            return prizeAmt > 0
              ? `<td class="num prize-col" title="${prizeTitle}">${formatMoney(prizeAmt)}</td>`
              : `<td class="num prize-col">—</td>`;
          })()
        : `<td class="num prize-col muted-col" title="Overall league only">—</td>`;

      const leader = displayRank === 1 ? " row-leader" : "";

      return `
        <tr class="prestige-${prestigeKey} league-${tintKey}${prestigeBoundary ? " zone-boundary" : ""}${playoffBoundary ? " zone-boundary-playoff" : ""}${relegationBoundary || bowlBoundary ? " zone-boundary zone-boundary-relegation" : ""}${leader}${mine}">
          <td class="num">${displayRank}</td>
          <td class="club-col">${clubWithOwnerHtml(row.club_name, row.club_short_name)}</td>
          <td class="status-col">${statusText}</td>
          <td class="num">${row.mp}</td>
          <td class="num">${row.w}</td>
          <td class="num">${row.d}</td>
          <td class="num">${row.l}</td>
          <td class="num">${row.gf}</td>
          <td class="num">${row.ga}</td>
          <td class="num">${gdDisplay(row.gd)}</td>
          <td class="num"><b>${row.pts}</b></td>
          ${prizeCell}
          <td class="form-cell">${formatFormHtml(row.form_last10)}</td>
        </tr>
      `;
    })
    .join("");

  panel.innerHTML = `
    <h2>${panelTitle}</h2>
    <table class="${tableClass}">
      ${STANDINGS_COLGROUP}
      <thead>
        <tr>
          <th>${rankHeader}</th>
          <th class="club-col">Club</th>
          <th class="status-col">Status</th>
          <th>MP</th>
          <th>W</th>
          <th>D</th>
          <th>L</th>
          <th>GF</th>
          <th>GA</th>
          <th>GD</th>
          <th>Pts</th>
          <th>Prize</th>
          <th>Form</th>
        </tr>
      </thead>
      <tbody>${tbody}</tbody>
    </table>
  `;

  panel.dataset.division = division;
  return panel;
}

let standingsGroups = {};
let venueStandingsGroups = { home: {}, away: {} };
let myClubRef = { short: null, name: null };
let shieldSpoonPlayoffQualifiers = {
  championship_a: {},
  championship_b: {},
};

function divisionFilterState() {
  const state = {};
  for (const div of LEAGUE_DIVISIONS) {
    const el = document.querySelector(`.filter-div[data-division="${div}"]`);
    state[div] = el ? el.checked : true;
  }
  return state;
}

function venueFilterValue() {
  const checked = document.querySelector('input[name="venueView"]:checked');
  const v = checked?.value || "";
  return v === "home" || v === "away" ? v : "";
}

function syncFilterAllCheckbox() {
  const allEl = document.getElementById("filterAll");
  if (!allEl) return;
  const boxes = [...document.querySelectorAll(".filter-div")];
  const checkedCount = boxes.filter((b) => b.checked).length;
  allEl.checked = checkedCount === boxes.length;
  allEl.indeterminate = checkedCount > 0 && checkedCount < boxes.length;
}

function renderTables() {
  const venue = venueFilterValue();
  const overallSection = document.getElementById("overallSection");
  const root = document.getElementById("tablesRoot");

  if (venue) {
    if (overallSection) overallSection.hidden = true;
    renderVenueTables();
    return;
  }

  if (overallSection) overallSection.hidden = false;

  const filter = divisionFilterState();
  const visible = LEAGUE_DIVISIONS.filter((div) => filter[div]);

  root.innerHTML = "";
  if (!visible.length) {
    root.innerHTML =
      '<p class="empty-msg">No divisions selected — tick at least one table above.</p>';
  } else {
    for (const div of visible) {
      root.appendChild(
        renderStandingsTable(div, standingsGroups[div] || [], myClubRef)
      );
    }
  }

  renderVenueTables();
}

function renderVenueTables() {
  const section = document.getElementById("homeAwaySection");
  const root = document.getElementById("homeAwayRoot");
  const title = document.getElementById("homeAwayTitle");
  const venue = venueFilterValue();

  if (!section || !root) return;

  if (!venue) {
    section.hidden = true;
    root.innerHTML = "";
    return;
  }

  const filter = divisionFilterState();
  const visible = LEAGUE_DIVISIONS.filter((div) => filter[div]);
  const venueLabel = venue === "home" ? "Home" : "Away";
  const groups = venueStandingsGroups[venue] || {};

  title.textContent = `${venueLabel} records`;
  section.hidden = false;
  root.innerHTML = "";

  if (!visible.length) {
    root.innerHTML =
      '<p class="empty-msg">No divisions selected — tick at least one table above.</p>';
    return;
  }

  for (const div of visible) {
    root.appendChild(
      renderStandingsTable(div, groups[div] || [], myClubRef, {
        rankField: "venue_rank",
        showPrize: false,
        zoneBoundaries: false,
        panelTitle: `${DIVISION_TITLES[div]} · ${venueLabel}`,
        rankHeader: venue === "home" ? "H#" : "A#",
        tableClass: "standings-table venue-standings-table",
      })
    );
  }
}

function wireDivisionFilter() {
  const allEl = document.getElementById("filterAll");
  const divBoxes = [...document.querySelectorAll(".filter-div")];

  allEl?.addEventListener("change", () => {
    const on = allEl.checked;
    for (const box of divBoxes) box.checked = on;
    allEl.indeterminate = false;
    renderTables();
  });

  for (const box of divBoxes) {
    box.addEventListener("change", () => {
      syncFilterAllCheckbox();
      renderTables();
    });
  }

  for (const radio of document.querySelectorAll('input[name="venueView"]')) {
    radio.addEventListener("change", () => renderTables());
  }
}

function buildVenueGroups(allStandings, fixtures) {
  for (const venue of ["home", "away"]) {
    const ranked = rankVenueStandings(
      buildVenueStandings(allStandings, fixtures, venue)
    );
    venueStandingsGroups[venue] = groupStandingsByDivision(ranked);
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();
  renderLegend();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();
  myClubRef = { short: club?.ShortName || null, name: club?.Club || null };

  const archiveSeason = seasonFromUrl();
  const meta = document.getElementById("seasonMeta");
  const root = document.getElementById("tablesRoot");

  if (archiveSeason) {
    setArchiveModeUi(archiveSeason);
    const archived = await loadArchivedSeasonStandings(supabase, archiveSeason);
    if (!archived.length) {
      root.innerHTML = `<p class="empty-msg">No archived tables for season “${archiveSeason}”. Check the season label matches the trophy (e.g. 2024/25).</p>`;
      return;
    }
    shieldSpoonPlayoffQualifiers = { championship_a: {}, championship_b: {} };
    standingsGroups = groupStandingsByDivision(archived);
    applyDivisionFilterFromUrl();
    wireDivisionFilter();
    renderTables();
    scrollToDivisionFromUrl();
    return;
  }

  const season = await loadCurrentSeason(supabase);

  if (!season) {
    meta.textContent = "No active competition season yet.";
    document.getElementById("divisionFilter")?.remove();
    document.getElementById("venueFilter")?.remove();
    document.getElementById("homeAwaySection")?.remove();
    root.innerHTML =
      '<p class="empty-msg">The league admin will set up the season from GPSL Admin.</p>';
    return;
  }

  meta.textContent = `${season.label} · ${season.status}${
    season.started_at
      ? ` · started ${new Date(season.started_at).toLocaleDateString()}`
      : ""
  } · 3 pts win · 1 pt draw`;

  const [standings, fixtures, playoffQualifiers] = await Promise.all([
    loadStandingsWithPrizes(supabase),
    loadLeagueFixtures(supabase),
    loadShieldSpoonPlayoffQualifiers(supabase, season.id),
  ]);
  shieldSpoonPlayoffQualifiers = playoffQualifiers;
  standingsGroups = groupStandingsByDivision(standings);
  buildVenueGroups(standings, fixtures);

  wireDivisionFilter();
  renderTables();
});
