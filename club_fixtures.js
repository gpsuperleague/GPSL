import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, clubWithOwnerHtml } from "./clubs_lookup.js";
import {
  loadCurrentSeason,
  formatFixtureScore,
  GPSL_MONTH_LABELS,
  GPSL_MONTH_ORDER,
  CUP_LABELS,
  DIVISION_LABELS,
  canSubmitResult,
  needsInboxConfirm,
  fixtureInvolvesClub,
} from "./competition.js";
import {
  formatWeatherLabel,
  formatPitchLabel,
  formatFixtureContinent,
  fixtureStadiumLabel,
} from "./competition_conditions.js";
import {
  loadCalendarStatus,
} from "./competition_calendar.js";
import { loadHolidayPlayContext } from "./owner_holidays.js";
import { scheduleActionLabel } from "./match_scheduling.js";
import { loadTvFixtureIds, tvFixtureBadgeHtml } from "./tv_fixtures.js";

let myClub = { short: null, name: null };
let calendarStatus = null;
let holidayContext = null;

function showError(msg) {
  const el = document.getElementById("clubFixturesError");
  if (!el) return;
  el.textContent = msg;
  el.style.display = msg ? "block" : "none";
}

function ordinal(n) {
  const x = Number(n);
  if (!Number.isFinite(x)) return "—";
  const mod100 = x % 100;
  const mod10 = x % 10;
  if (mod100 >= 11 && mod100 <= 13) return `${x}th`;
  if (mod10 === 1) return `${x}st`;
  if (mod10 === 2) return `${x}nd`;
  if (mod10 === 3) return `${x}rd`;
  return `${x}th`;
}

function formatAttendance(n) {
  if (n == null || !Number.isFinite(Number(n))) return "—";
  return Number(n).toLocaleString("en-GB");
}

function competitionLabel(f) {
  if (f.competition_type === "cup") {
    const cup = CUP_LABELS[f.cup_code] || f.cup_code || "Cup";
    const round = f.cup_round ? ` · R${f.cup_round}` : "";
    const match = f.cup_match ? ` M${f.cup_match}` : "";
    return `${cup}${round}${match}`;
  }
  return DIVISION_LABELS[f.division] || f.division || "League";
}

function formatContributions(contributions) {
  const rows = Array.isArray(contributions) ? contributions : [];
  const scorers = rows.filter((r) => (r.goals || 0) > 0);
  const assisters = rows.filter((r) => (r.assists || 0) > 0);
  const potm = rows.find((r) => r.is_player_of_match);

  const fmtList = (list, field) =>
    list
      .map((r) => {
        const n = r[field] || 0;
        const name = r.player_name || r.player_id || "—";
        return n > 1 ? `${name} (${n})` : name;
      })
      .join(", ") || "—";

  return {
    scorers: fmtList(scorers, "goals"),
    assists: fmtList(assisters, "assists"),
    potm: potm ? (potm.player_name || potm.player_id) : "—",
  };
}

function matchLineHtml(f) {
  const homeCls =
    (f.home_club_short_name || "").toUpperCase() === (myClub.short || "").toUpperCase()
      ? "mine"
      : "";
  const awayCls =
    (f.away_club_short_name || "").toUpperCase() === (myClub.short || "").toUpperCase()
      ? "mine"
      : "";
  return `
    <span class="${homeCls}">${clubWithOwnerHtml(f.home_club_name, f.home_club_short_name, "inline")}</span>
    <span style="color:#666;margin:0 4px;">vs</span>
    <span class="${awayCls}">${clubWithOwnerHtml(f.away_club_name, f.away_club_short_name, "inline")}</span>
  `;
}

function actionHtml(f) {
  if (!myClub.short || !fixtureInvolvesClub(f, myClub)) return "";

  const url = `matchday.html?fixture=${encodeURIComponent(String(f.id))}`;

  if (canSubmitResult(f, myClub, calendarStatus, holidayContext)) {
    return `<a href="${url}" class="btn-link">Enter result</a>`;
  }
  if (needsInboxConfirm(f, myClub)) {
    return `<a href="${url}" class="btn-link secondary">Confirm result</a>`;
  }
  const sched = scheduleActionLabel(f, myClub.short);
  if (sched && f.status !== "played") {
    const cls = sched.muted ? "btn-link secondary" : "btn-link";
    return `<a href="${sched.href}" class="${cls}">${sched.label}</a>`;
  }
  if (f.status === "played") {
    return `<a href="${url}" class="btn-link secondary">Match details</a>`;
  }
  return "";
}

function fixtureCardHtml(f) {
  const isLeague = f.competition_type === "league";
  const badgeCls = isLeague ? "league" : "cup";
  const ha = f.is_home ? "Home" : "Away";
  const score = formatFixtureScore(f, myClub);
  const weather = formatWeatherLabel(f.weather);
  const pitch = formatPitchLabel(f.pitch_condition);
  const continent = formatFixtureContinent(f);
  const stadium = fixtureStadiumLabel(f, myClub.short, null);

  let playedBlock = "";
  if (f.status === "played") {
    const { scorers, assists, potm } = formatContributions(f.match_contributions);
    const leaguePos =
      isLeague && f.league_position != null
        ? `${ordinal(f.league_position)} in ${DIVISION_LABELS[f.division] || f.division}`
        : null;

    playedBlock = `
      <div class="played-details">
        <div>
          <div class="label">Attendance</div>
          <div class="value">${formatAttendance(f.attendance)}</div>
        </div>
        ${
          leaguePos
            ? `<div>
          <div class="label">League position</div>
          <div class="value">${leaguePos}</div>
        </div>`
            : ""
        }
        <div>
          <div class="label">Scorers</div>
          <div class="value">${scorers}</div>
        </div>
        <div>
          <div class="label">Assists</div>
          <div class="value">${assists}</div>
        </div>
        <div>
          <div class="label">Player of the match</div>
          <div class="value potm">${potm === "—" ? potm : `⭐ ${potm}`}</div>
        </div>
      </div>
    `;
  }

  const mdLabel =
    f.competition_type === "league"
      ? `MD ${f.matchday}`
      : competitionLabel(f);

  return `
    <div class="fixture-card">
      <div class="fixture-top">
        <span class="fixture-badge ${badgeCls}">${competitionLabel(f)}</span>
        ${tvFixtureBadgeHtml(f.id)}
        <span class="fixture-match">${matchLineHtml(f)}</span>
        <span class="fixture-score">${score}</span>
      </div>
      <div class="fixture-meta">
        <span><b>${mdLabel}</b></span>
        <span><b>${ha}</b></span>
        <span>${stadium}</span>
        <span>${continent}</span>
      </div>
      <div class="conditions-row">
        <span class="weather">Weather: ${weather}</span>
        <span style="color:#555;margin:0 6px;">·</span>
        <span class="pitch">Pitch: ${pitch}</span>
      </div>
      ${playedBlock}
      <div class="fixture-actions">${actionHtml(f)}</div>
    </div>
  `;
}

function mergeFixtureActions(rpcRows, publicRows) {
  const byId = new Map((publicRows || []).map((f) => [f.id, f]));
  const actionFields = [
    "submission_id",
    "submission_status",
    "submitted_by_club",
    "proposed_home_goals",
    "proposed_away_goals",
    "proposed_et_home_goals",
    "proposed_et_away_goals",
    "proposed_pen_winner_club",
    "schedule_status",
    "agreed_kickoff_at",
    "schedule_pending_proposal_id",
    "schedule_home_proposal_count",
    "schedule_away_proposal_count",
    "schedule_discord_hint",
    "home_checked_in",
    "away_checked_in",
  ];

  return (rpcRows || []).map((f) => {
    const pub = byId.get(f.id);
    if (!pub) return f;
    const merged = { ...f };
    for (const key of actionFields) {
      if (pub[key] !== undefined) merged[key] = pub[key];
    }
    return merged;
  });
}

async function loadPublicFixturesForClub() {
  const { data, error } = await supabase.from("competition_fixtures_public").select("*");
  if (error) {
    console.warn("competition_fixtures_public:", error);
    return [];
  }
  const key = (myClub.short || "").trim().toUpperCase();
  return (data || []).filter(
    (f) =>
      (f.home_club_short_name || "").trim().toUpperCase() === key ||
      (f.away_club_short_name || "").trim().toUpperCase() === key
  );
}

function groupByMonth(fixtures) {
  const monthSort = Object.fromEntries(GPSL_MONTH_ORDER.map((m, i) => [m, i]));
  const groups = new Map();

  for (const f of fixtures) {
    const key = f.gpsl_month || "unknown";
    if (!groups.has(key)) {
      groups.set(key, {
        gpsl_month: key,
        sort: f.gpsl_month_sort ?? monthSort[key] ?? 99,
        fixtures: [],
      });
    }
    groups.get(key).fixtures.push(f);
  }

  return [...groups.values()]
    .sort((a, b) => a.sort - b.sort)
    .map((g) => {
      g.fixtures.sort((a, b) => (a.matchday || 0) - (b.matchday || 0) || a.id - b.id);
      return g;
    });
}

function requestedClubFixturesMonth() {
  const params = new URLSearchParams(window.location.search);
  const raw = (params.get("month") || "").trim().toLowerCase();
  return raw || null;
}

function renderFixtures(fixtures) {
  const root = document.getElementById("clubFixturesRoot");
  if (!fixtures.length) {
    root.innerHTML =
      '<p class="empty">No fixtures for your club this season yet.</p>';
    return;
  }

  const groups = groupByMonth(fixtures);
  const focusMonth = requestedClubFixturesMonth();
  root.innerHTML = groups
    .map((g) => {
      const label = GPSL_MONTH_LABELS[g.gpsl_month] || g.gpsl_month || "—";
      const cards = g.fixtures.map(fixtureCardHtml).join("");
      const monthKey = String(g.gpsl_month || "").toLowerCase();
      return `
        <div class="month-block" id="month-${monthKey}" data-gpsl-month="${monthKey}">
          <div class="month-head">${label}</div>
          ${cards}
        </div>
      `;
    })
    .join("");

  if (focusMonth) {
    const target = root.querySelector(
      `.month-block[data-gpsl-month="${CSS.escape(focusMonth)}"]`
    );
    if (target) {
      requestAnimationFrame(() => {
        target.scrollIntoView({ behavior: "smooth", block: "start" });
      });
    }
  }
}

async function loadMyClub(user) {
  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  myClub = { short: club?.ShortName || null, name: club?.Club || null };

  if (myClub.short) {
    const { data: reg } = await supabase
      .from("competition_club_season_public")
      .select("club_short_name, club_name")
      .eq("club_short_name", myClub.short)
      .maybeSingle();
    if (reg) {
      myClub.short = reg.club_short_name;
      myClub.name = reg.club_name || myClub.name;
    }
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  const root = document.getElementById("clubFixturesRoot");
  try {
    await initGlobal();
    await loadClubsMap();

    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) {
      window.location = "login.html";
      return;
    }

    await loadMyClub(user);
    if (!myClub.short) {
      root.innerHTML =
        '<p class="empty">Assign a club to your account to see your fixtures here.</p>';
      return;
    }

    const title = document.getElementById("clubFixturesTitle");
    const meta = document.getElementById("clubFixturesMeta");
    if (title) title.textContent = `${myClub.name || myClub.short} — Fixtures`;
    if (meta) {
      meta.textContent =
        "Your club’s matches this season, grouped by month. Played games show attendance, score, contributors, league position, weather and pitch.";
    }

    const season = await loadCurrentSeason(supabase);
    if (!season) {
      root.innerHTML =
        '<p class="empty">Fixtures appear once the league admin activates a season.</p>';
      return;
    }

    await loadTvFixtureIds(supabase, season.id);

    calendarStatus = await loadCalendarStatus(supabase);
    holidayContext = await loadHolidayPlayContext(supabase, myClub.short);

    const { data, error } = await supabase.rpc("club_fixtures_my_club");
    if (error) {
      console.error("club_fixtures_my_club:", error);
      showError(
        "Could not load club fixtures. Run supabase/sql/patches/club_fixtures_my_club.sql in Supabase, then refresh."
      );
      root.innerHTML = '<p class="empty">Fixtures unavailable.</p>';
      return;
    }

    const publicFixtures = await loadPublicFixturesForClub();
    const fixtures = mergeFixtureActions(
      Array.isArray(data) ? data : [],
      publicFixtures
    );
    renderFixtures(fixtures);
  } catch (err) {
    console.error(err);
    showError(err.message || "Failed to load fixtures.");
    if (root) root.innerHTML = '<p class="empty">Something went wrong.</p>';
  }
});
