import { supabase, initGlobal } from "./global.js";
import {
  loadCurrentSeason,
  loadPlayerSeasonStats,
  loadPlayerCupStats,
  loadInternationalPlayerStats,
  CUP_LABELS,
} from "./competition.js";
import { playerNameLinkHtml } from "./player_links.js";

const DIVISION_TITLES = {
  superleague: "SuperLeague",
  championship_a: "Championship A",
  championship_b: "Championship B",
};

const LEADERBOARD_TOP_COUNT = 10;

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
          <td class="num">${i + 1}</td>
          <td>${r.player_name || r.player_id}</td>
          <td>${r.club_name || r.club_short_name || "—"}</td>
          <td>${extraColumnValue(r)}</td>
          <td class="num">${formatValue(r)}</td>
          <td class="num">${appsValue(r)}</td>
        </tr>
      `;
    })
    .join("");

  const hasMore = rows.length > LEADERBOARD_TOP_COUNT;
  const collapsedClass = hasMore ? " lb-collapsed" : "";

  el.innerHTML = `
    <table class="lb${collapsedClass}" data-lb-table>
      <thead>
        <tr>
          <th>#</th>
          <th>Player</th>
          <th>Club</th>
          <th>${extraColumnKey}</th>
          <th>${valueKey}</th>
          <th>${appsKey}</th>
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

  renderLeaderboard(`${prefix}ScorersTable`, byGoals, {
    ...common,
    valueKey: "Goals",
    formatValue: (r) => r.goals,
  });
  renderLeaderboard(`${prefix}AssistsTable`, byAssists, {
    ...common,
    valueKey: "Assists",
    formatValue: (r) => r.assists,
  });
  renderLeaderboard(`${prefix}RatingsTable`, byRating, {
    ...common,
    valueKey: "Avg",
    formatValue: (r) => Number(r.avg_rating).toFixed(2),
  });
  renderLeaderboard(`${prefix}PotmTable`, byPotm, {
    ...common,
    valueKey: "POTM",
    formatValue: (r) => r.potm_awards,
  });
  renderLeaderboard(`${prefix}CleanSheetsTable`, byCleanSheets, {
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

  el.innerHTML = `
    <p class="meta" style="margin:0 0 10px;">
      <b>${formatGpslMonthLabel(team.gpsl_month)}</b> · ${team.season_label} · ${team.formation_id}
    </p>
    <table class="lb">
      <thead>
        <tr>
          <th>Pos</th>
          <th>Player</th>
          <th>Club</th>
          <th class="num">Apps</th>
          <th class="num">G</th>
          <th class="num">A</th>
          <th class="num">Avg</th>
          <th class="num">CS</th>
        </tr>
      </thead>
      <tbody>
        ${sorted
          .map(
            (r) => `
          <tr${myClubShort && r.club_short_name === myClubShort ? ' class="highlight"' : ""}>
            <td>${r.slot_label || r.pitch_slot}</td>
            <td>${playerNameLinkHtml(r.player_id, r.player_name)}</td>
            <td>${r.club_name || r.club_short_name}</td>
            <td class="num">${r.appearances ?? 0}</td>
            <td class="num">${r.goals ?? 0}</td>
            <td class="num">${r.assists ?? 0}</td>
            <td class="num">${r.avg_rating != null ? Number(r.avg_rating).toFixed(2) : "—"}</td>
            <td class="num">${r.clean_sheets ?? 0}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
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
