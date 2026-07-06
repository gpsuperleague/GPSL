import { supabase, initGlobal } from "./global.js";
import {
  loadCurrentSeason,
  loadPlayerSeasonStats,
  loadPlayerCupStats,
  loadInternationalPlayerStats,
  CUP_LABELS,
} from "./competition.js";
import { loadClubsMap } from "./clubs_lookup.js";
import {
  playerNameLinkHtml,
  playerThumbLinkHtml,
  clubNameLinkHtml,
} from "./player_links.js";
import { renderFormationPitchHtml } from "./pitch_display.js";

const DIVISION_TITLES = {
  superleague: "SuperLeague",
  championship_a: "Championship A",
  championship_b: "Championship B",
};

const LEADERBOARD_TOP_COUNT = 10;

const LEADERBOARD_COLGROUP = `
  <colgroup>
    <col class="lb-col-rank">
    <col class="lb-col-thumb">
    <col class="lb-col-player">
    <col class="lb-col-club">
    <col class="lb-col-extra">
    <col class="lb-col-val">
    <col class="lb-col-apps">
  </colgroup>`;

let myClubShort = null;
let myNation = null;
let leagueRows = [];
let cupRows = [];
let internationalRows = [];
let activeTab = "league";

function aggregateCupRows(rows) {
  const map = new Map();
  for (const row of rows) {
    const key = row.player_id;
    const existing = map.get(key);
    if (!existing) {
      map.set(key, {
        ...row,
        cup_code: null,
        appearances: row.appearances || 0,
        starts: row.starts || 0,
        subs: row.subs || 0,
        goals: row.goals || 0,
        assists: row.assists || 0,
        potm_awards: row.potm_awards || 0,
        clean_sheets: row.clean_sheets || 0,
        _ratingWeight: (row.avg_rating != null ? Number(row.avg_rating) : 0) * (row.appearances || 0),
        _ratedApps: row.avg_rating != null ? row.appearances || 0 : 0,
      });
      continue;
    }
    existing.appearances += row.appearances || 0;
    existing.starts += row.starts || 0;
    existing.subs += row.subs || 0;
    existing.goals += row.goals || 0;
    existing.assists += row.assists || 0;
    existing.potm_awards += row.potm_awards || 0;
    existing.clean_sheets += row.clean_sheets || 0;
    if (row.avg_rating != null) {
      existing._ratingWeight += Number(row.avg_rating) * (row.appearances || 0);
      existing._ratedApps += row.appearances || 0;
    }
  }
  return [...map.values()].map((row) => ({
    ...row,
    avg_rating:
      row._ratedApps > 0
        ? Math.round((row._ratingWeight / row._ratedApps) * 100) / 100
        : null,
  }));
}

function renderLeaderboard(containerId, rows, options) {
  const {
    valueKey,
    formatValue,
    extraColumnKey = "Div",
    extraColumnValue = (r) =>
      r.division ? DIVISION_TITLES[r.division] || r.division : "—",
    appsKey = "Apps",
    appsValue = (r) => r.appearances ?? 0,
    highlightRow = (r) =>
      myClubShort &&
      (r.club_short_name || "").toUpperCase() === myClubShort.toUpperCase(),
  } = options;

  const el = document.getElementById(containerId);
  if (!el) return;

  if (!rows.length) {
    el.innerHTML = '<p class="empty">No stats yet for this filter.</p>';
    return;
  }

  const body = rows
    .map((r, i) => {
      const mine = highlightRow(r);
      return `
        <tr class="${mine ? "highlight" : ""}">
          <td class="num lb-rank">${i + 1}</td>
          <td class="lb-thumb">${playerThumbLinkHtml(r.player_id, {
            className: "lb-player-thumb",
            linkClass: "lb-thumb-link",
            alt: r.player_name || "",
          })}</td>
          <td class="lb-player-name">${playerNameLinkHtml(r.player_id, r.player_name)}</td>
          <td class="lb-club-name">${clubNameLinkHtml(r.club_short_name, r.club_name || r.club_short_name)}</td>
          <td class="lb-extra-col">${extraColumnValue(r)}</td>
          <td class="num lb-val-col">${formatValue(r)}</td>
          <td class="num lb-apps-col">${appsValue(r)}</td>
        </tr>
      `;
    })
    .join("");

  const hasMore = rows.length > LEADERBOARD_TOP_COUNT;
  const collapsedClass = hasMore ? " lb-collapsed" : "";

  el.innerHTML = `
    <table class="lb${collapsedClass}" data-lb-table>
      ${LEADERBOARD_COLGROUP}
      <thead>
        <tr>
          <th class="lb-rank">#</th>
          <th class="lb-thumb" aria-label="Card"></th>
          <th>Player</th>
          <th>Club</th>
          <th class="lb-extra-col">${extraColumnKey}</th>
          <th class="num lb-val-col">${valueKey}</th>
          <th class="num lb-apps-col">${appsKey}</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>
    ${
      hasMore
        ? `<button type="button" class="lb-show-all" data-lb-toggle>Show all (${rows.length})</button>`
        : ""
    }
  `;

  const table = el.querySelector("[data-lb-table]");
  const toggle = el.querySelector("[data-lb-toggle]");
  if (!table || !toggle) return;

  toggle.addEventListener("click", () => {
    const collapsed = table.classList.toggle("lb-collapsed");
    toggle.textContent = collapsed
      ? `Show all (${rows.length})`
      : "Show top 10";
  });
}

function statTableId(prefix, stem) {
  const suffix = stem.charAt(0).toUpperCase() + stem.slice(1) + "Table";
  return prefix ? `${prefix}${suffix}` : `${stem}Table`;
}

function renderClubLeaderboards(prefix, rows, extraColumnKey, extraColumnValue) {
  const common = {
    extraColumnKey,
    extraColumnValue,
    appsKey: "Apps",
    appsValue: (r) => r.appearances ?? 0,
  };

  const byGoals = [...rows]
    .filter((r) => (r.goals || 0) > 0)
    .sort((a, b) => b.goals - a.goals || b.assists - a.assists);
  const byAssists = [...rows]
    .filter((r) => (r.assists || 0) > 0)
    .sort((a, b) => b.assists - a.assists || b.goals - a.goals);
  const byRating = [...rows]
    .filter((r) => r.avg_rating != null && (r.appearances || 0) >= 3)
    .sort((a, b) => Number(b.avg_rating) - Number(a.avg_rating));
  const byPotm = [...rows]
    .filter((r) => (r.potm_awards || 0) > 0)
    .sort((a, b) => b.potm_awards - a.potm_awards);
  const byCleanSheets = [...rows]
    .filter(
      (r) => r.stat_role === "goalkeeper" && (r.clean_sheets || 0) > 0
    )
    .sort(
      (a, b) =>
        b.clean_sheets - a.clean_sheets ||
        (b.starts || 0) - (a.starts || 0) ||
        Number(b.avg_rating || 0) - Number(a.avg_rating || 0)
    );

  renderLeaderboard(statTableId(prefix, "scorers"), byGoals, {
    ...common,
    valueKey: "Goals",
    formatValue: (r) => r.goals,
  });
  renderLeaderboard(statTableId(prefix, "assists"), byAssists, {
    ...common,
    valueKey: "Assists",
    formatValue: (r) => r.assists,
  });
  renderLeaderboard(statTableId(prefix, "ratings"), byRating, {
    ...common,
    valueKey: "Avg",
    formatValue: (r) => Number(r.avg_rating).toFixed(2),
  });
  renderLeaderboard(statTableId(prefix, "potm"), byPotm, {
    ...common,
    valueKey: "POTM",
    formatValue: (r) => r.potm_awards,
  });
  renderLeaderboard(statTableId(prefix, "cleanSheets"), byCleanSheets, {
    ...common,
    valueKey: "CS",
    formatValue: (r) => r.clean_sheets,
  });
}

function renderLeague() {
  const division = document.getElementById("divisionFilter")?.value || "";
  const rows = division
    ? leagueRows.filter((r) => r.division === division)
    : [...leagueRows];

  renderClubLeaderboards("", rows, "Div", (r) =>
    r.division ? DIVISION_TITLES[r.division] || r.division : "—"
  );
}

function renderCups() {
  const cupCode = document.getElementById("cupFilter")?.value || "";
  let rows = cupCode
    ? cupRows.filter((r) => r.cup_code === cupCode)
    : aggregateCupRows(cupRows);

  renderClubLeaderboards(
    "cup",
    rows,
    "Cup",
    (r) =>
      r.cup_code ? CUP_LABELS[r.cup_code] || r.cup_code : "All cups"
  );
}

function renderWorldCup() {
  const rows = [...internationalRows];
  const nationMatch = (r) =>
    myNation &&
    (r.nation || "").toUpperCase() === String(myNation).toUpperCase();

  const common = {
    extraColumnKey: "Nation",
    extraColumnValue: (r) => r.nation || "—",
    appsKey: "Caps",
    appsValue: (r) => r.caps ?? 0,
    highlightRow: nationMatch,
  };

  const byGoals = [...rows]
    .filter((r) => (r.goals || 0) > 0)
    .sort((a, b) => b.goals - a.goals || b.assists - a.assists);
  const byAssists = [...rows]
    .filter((r) => (r.assists || 0) > 0)
    .sort((a, b) => b.assists - a.assists || b.goals - a.goals);
  const byRating = [...rows]
    .filter((r) => r.avg_rating != null && (r.caps || 0) >= 3)
    .sort((a, b) => Number(b.avg_rating) - Number(a.avg_rating));
  const byPotm = [...rows]
    .filter((r) => (r.potm || 0) > 0)
    .sort((a, b) => b.potm - a.potm);
  const byCaps = [...rows]
    .filter((r) => (r.caps || 0) > 0)
    .sort((a, b) => b.caps - a.caps || b.goals - a.goals);

  renderLeaderboard("wcScorersTable", byGoals, {
    ...common,
    valueKey: "Goals",
    formatValue: (r) => r.goals,
  });
  renderLeaderboard("wcAssistsTable", byAssists, {
    ...common,
    valueKey: "Assists",
    formatValue: (r) => r.assists,
  });
  renderLeaderboard("wcRatingsTable", byRating, {
    ...common,
    valueKey: "Avg",
    formatValue: (r) => Number(r.avg_rating).toFixed(2),
  });
  renderLeaderboard("wcPotmTable", byPotm, {
    ...common,
    valueKey: "POTM",
    formatValue: (r) => r.potm,
  });
  renderLeaderboard("wcCapsTable", byCaps, {
    ...common,
    valueKey: "Caps",
    formatValue: (r) => r.caps,
  });
}

function formatGpslMonthLabel(month) {
  if (!month) return "—";
  return String(month)
    .replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

function buildTotmStatsTable(rows) {
  return `
    <table class="lb lb-totm">
      <thead>
        <tr>
          <th>Pos</th>
          <th class="lb-thumb" aria-label="Card"></th>
          <th>Player</th>
          <th>Club</th>
          <th class="num lb-stat-col">Apps</th>
          <th class="num lb-stat-col">G</th>
          <th class="num lb-stat-col">A</th>
          <th class="num lb-stat-col">Avg</th>
          <th class="num lb-stat-col">CS</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (r) => `
          <tr${myClubShort && r.club_short_name === myClubShort ? ' class="highlight"' : ""}>
            <td class="lb-stat-col">${r.slot_label || r.pitch_slot}</td>
            <td class="lb-thumb">${playerThumbLinkHtml(r.player_id, {
              className: "lb-player-thumb",
              linkClass: "lb-thumb-link",
              alt: r.player_name || "",
            })}</td>
            <td class="lb-player-name">${playerNameLinkHtml(r.player_id, r.player_name)}</td>
            <td class="lb-club-name">${clubNameLinkHtml(r.club_short_name, r.club_name || r.club_short_name)}</td>
            <td class="num lb-stat-col">${r.appearances ?? 0}</td>
            <td class="num lb-stat-col">${r.goals ?? 0}</td>
            <td class="num lb-stat-col">${r.assists ?? 0}</td>
            <td class="num lb-stat-col">${r.avg_rating != null ? Number(r.avg_rating).toFixed(2) : "—"}</td>
            <td class="num lb-stat-col">${r.clean_sheets ?? 0}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

async function renderTeamOfMonthPanel(panelId, divisionScope, emptyLabel) {
  const el = document.getElementById(panelId);
  if (!el) return;

  const { data: team, error: teamErr } = await supabase
    .from("competition_period_team")
    .select("id, season_label, gpsl_month, formation_id, computed_at")
    .eq("period_kind", "month")
    .eq("division_scope", divisionScope)
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (teamErr) {
    el.innerHTML = `<p class="empty">${teamErr.message}</p>`;
    return;
  }

  if (!team) {
    el.innerHTML = `<p class="empty">${emptyLabel}</p>`;
    return;
  }

  const { data: rows, error } = await supabase
    .from("competition_period_team_public")
    .select("*")
    .eq("team_id", team.id)
    .order("pitch_slot");

  if (error) {
    el.innerHTML = `<p class="empty">${error.message}</p>`;
    return;
  }

  if (!rows?.length) {
    el.innerHTML = '<p class="empty">Team lineup unavailable.</p>';
    return;
  }

  const slotOrder = [
    "GK",
    "LB",
    "CB1",
    "CB2",
    "RB",
    "LMF",
    "CMF",
    "RMF",
    "LWF",
    "CF",
    "RWF",
  ];
  const sorted = [...rows].sort(
    (a, b) => slotOrder.indexOf(a.pitch_slot) - slotOrder.indexOf(b.pitch_slot)
  );

  const metaHtml = `
    <p class="meta" style="margin:0 0 4px;text-align:center;">
      <b>${formatGpslMonthLabel(team.gpsl_month)}</b> · ${team.season_label}
    </p>`;

  el.innerHTML = renderFormationPitchHtml({
    formationId: team.formation_id,
    members: sorted,
    metaHtml,
    highlightClub: myClubShort,
    tableHtml: buildTotmStatsTable(sorted),
  });
}

async function renderTeamOfMonth() {
  await Promise.all([
    renderTeamOfMonthPanel(
      "totmSuperPanel",
      "superleague",
      "No Super League Team of the Month yet — awarded when a GPSL month locks after confirmed league games."
    ),
    renderTeamOfMonthPanel(
      "totmChampionshipPanel",
      "championship",
      "No Championship Team of the Month yet — awarded when a GPSL month locks after confirmed league games."
    ),
  ]);
}

function setActiveTab(tab) {
  activeTab = tab;
  document.querySelectorAll(".stats-tab").forEach((btn) => {
    const on = btn.dataset.tab === tab;
    btn.classList.toggle("active", on);
    btn.setAttribute("aria-selected", on ? "true" : "false");
  });
  document.getElementById("leaguePanel").hidden = tab !== "league";
  document.getElementById("cupsPanel").hidden = tab !== "cups";
  document.getElementById("worldcupPanel").hidden = tab !== "worldcup";

  if (tab === "league") {
    renderLeague();
    renderTeamOfMonth();
  } else if (tab === "cups") renderCups();
  else renderWorldCup();
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
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (club?.ShortName) {
    myClubShort = club.ShortName;
    const { data: ownerNation } = await supabase
      .from("international_owner_nations")
      .select("nation_code")
      .eq("club_short_name", club.ShortName)
      .eq("is_active", true)
      .maybeSingle();
    if (ownerNation?.nation_code) myNation = ownerNation.nation_code;
  }

  const season = await loadCurrentSeason(supabase);
  const meta = document.getElementById("pageMeta");
  if (!season) {
    meta.textContent = "No active competition season.";
    return;
  }
  meta.textContent = `${season.label || "Season"} — league, cup, and international leaderboards`;

  [leagueRows, cupRows, internationalRows] = await Promise.all([
    loadPlayerSeasonStats(supabase),
    loadPlayerCupStats(supabase),
    loadInternationalPlayerStats(supabase),
  ]);

  document.getElementById("divisionFilter")?.addEventListener("change", renderLeague);
  document.getElementById("cupFilter")?.addEventListener("change", renderCups);
  document.querySelectorAll(".stats-tab").forEach((btn) => {
    btn.addEventListener("click", () => setActiveTab(btn.dataset.tab));
  });

  setActiveTab("league");
});
