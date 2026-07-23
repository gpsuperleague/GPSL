/**
 * Dashboard mid-header: live matchday synopsis for fixtures in the
 * kick-off −30m → +30m window. Check-in / Match Day actions.
 */

import { supabase } from "./global.js";
import { fullClubName } from "./clubs_lookup.js";

const REFRESH_MS = 20_000;

let refreshTimer = null;
let clubShort = null;

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatKickoffLocal(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString(undefined, {
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function formatKickoffUk(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-GB", {
    timeZone: "Europe/London",
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function competitionLabel(fx) {
  const t = String(fx.competition_type || "").toLowerCase();
  if (t === "cup" || fx.cup_code) {
    return fx.cup_code ? String(fx.cup_code).toUpperCase() : "Cup";
  }
  if (fx.matchday != null) return `MD${fx.matchday}`;
  return "League";
}

function minutesUntil(iso) {
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return null;
  return Math.round((t - Date.now()) / 60000);
}

function statusLine(fx) {
  if (fx.can_enter_result) {
    return "Both checked in — enter the result";
  }
  if (fx.can_check_in) {
    return "Check-in open now (10 min window)";
  }
  if (fx.before_kickoff) {
    const m = minutesUntil(fx.agreed_kickoff_at);
    if (m != null && m > 0) {
      return `Kick-off in ${m} min — check-in opens at kick-off`;
    }
    return "Check-in opens at kick-off";
  }
  if (fx.my_checked_in && !(fx.home_checked_in && fx.away_checked_in)) {
    return "You are checked in — waiting for opponent";
  }
  if (!fx.my_checked_in) {
    return "Check-in window closed — see Schedule";
  }
  return "Match window open";
}

function renderFixtureCard(fx) {
  const home = fullClubName(fx.home_club_short_name) || fx.home_club_name;
  const away = fullClubName(fx.away_club_short_name) || fx.away_club_name;
  const vs = `${escapeHtml(home)} vs ${escapeHtml(away)}`;
  const kickLocal = formatKickoffLocal(fx.agreed_kickoff_at);
  const kickUk = formatKickoffUk(fx.agreed_kickoff_at);
  const fid = Number(fx.fixture_id);
  const scheduleHref = `fixture_schedule.html?fixture=${fid}`;
  const matchdayHref = `matchday.html?fixture=${fid}`;

  const checks = `
    <span class="dash-md-check ${fx.home_checked_in ? "is-in" : ""}" title="Home check-in">H${fx.home_checked_in ? "✓" : "·"}</span>
    <span class="dash-md-check ${fx.away_checked_in ? "is-in" : ""}" title="Away check-in">A${fx.away_checked_in ? "✓" : "·"}</span>
  `;

  let actions = "";
  if (fx.can_check_in) {
    actions += `<button type="button" class="dash-md-btn dash-md-checkin" data-fixture-id="${fid}">Check in</button>`;
  }
  if (fx.can_enter_result) {
    actions += `<a class="dash-md-btn dash-md-result" href="${matchdayHref}">Enter result</a>`;
  } else if (!fx.can_check_in) {
    actions += `<a class="dash-md-btn dash-md-link" href="${scheduleHref}">Schedule</a>`;
  }
  if (fx.can_check_in || fx.before_kickoff) {
    actions += `<a class="dash-md-btn dash-md-link" href="${matchdayHref}">Match Day</a>`;
  }

  return `
    <div class="dash-md-card" data-fixture-id="${fid}">
      <div class="dash-md-meta">
        <span class="dash-md-comp">${escapeHtml(competitionLabel(fx))}</span>
        <span class="dash-md-checks">${checks}</span>
      </div>
      <div class="dash-md-vs">${vs}</div>
      <div class="dash-md-time" title="UK: ${escapeHtml(kickUk)}">${escapeHtml(kickLocal)}</div>
      <div class="dash-md-status">${escapeHtml(statusLine(fx))}</div>
      <div class="dash-md-actions">${actions}</div>
    </div>
  `;
}

function setPanelVisible(visible) {
  const panel = document.getElementById("dashboardMatchdayPanel");
  if (!panel) return;
  panel.hidden = !visible;
  panel.setAttribute("aria-hidden", visible ? "false" : "true");
}

function renderSynopsis(data) {
  const body = document.getElementById("dashboardMatchdayBody");
  if (!body) return;

  const fixtures = Array.isArray(data?.fixtures) ? data.fixtures : [];
  if (!fixtures.length) {
    setPanelVisible(false);
    body.innerHTML = "";
    return;
  }

  setPanelVisible(true);
  body.innerHTML = fixtures.map(renderFixtureCard).join("");

  body.querySelectorAll(".dash-md-checkin").forEach((btn) => {
    btn.addEventListener("click", () => onCheckIn(Number(btn.dataset.fixtureId), btn));
  });
}

async function onCheckIn(fixtureId, btn) {
  if (!fixtureId) return;
  if (btn) {
    btn.disabled = true;
    btn.textContent = "Checking in…";
  }
  const { error } = await supabase.rpc("fixture_check_in", {
    p_fixture_id: fixtureId,
  });
  if (error) {
    alert(error.message || "Could not check in.");
    if (btn) {
      btn.disabled = false;
      btn.textContent = "Check in";
    }
    return;
  }
  await refreshDashboardMatchday();
}

export async function refreshDashboardMatchday() {
  const body = document.getElementById("dashboardMatchdayBody");
  if (!body || !clubShort) {
    setPanelVisible(false);
    return;
  }

  const { data, error } = await supabase.rpc("dashboard_my_matchday_synopsis");
  if (error) {
    console.warn("dashboard_my_matchday_synopsis:", error.message);
    setPanelVisible(false);
    return;
  }
  renderSynopsis(data);
}

export function startDashboardMatchday(clubShortName) {
  clubShort = clubShortName || null;
  const panel = document.getElementById("dashboardMatchdayPanel");
  if (!panel || !clubShort) {
    setPanelVisible(false);
    return;
  }

  refreshDashboardMatchday();
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = setInterval(refreshDashboardMatchday, REFRESH_MS);

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") refreshDashboardMatchday();
  });
}
