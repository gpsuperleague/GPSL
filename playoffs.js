import { supabase, initGlobal, getAuthUserFast, isGpslAdminUser } from "./global.js";
import { loadCalendarStatus, formatUkDateTime } from "./competition_calendar.js";
import { DIVISION_LABELS } from "./competition.js";

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function clubLabel(tie, side) {
  const short = side === "home" ? tie.home_club_short_name : tie.away_club_short_name;
  const name = side === "home" ? tie.home_club_name : tie.away_club_name;
  if (!short) return `<span class="tbd">TBD</span>`;
  const won = tie.winner_club_short_name === short;
  return `<span class="club${won ? " winner" : ""}">${escapeHtml(name || short)}</span>`;
}

function scoreHtml(tie) {
  if (tie.status === "played" || tie.fixture_status === "played") {
    const h = tie.home_goals ?? "–";
    const a = tie.away_goals ?? "–";
    let s = `${h}–${a}`;
    if (tie.cup_pen_winner_club_short_name) s += " (p)";
    return s;
  }
  if (tie.fixture_id) return "vs";
  return "—";
}

function statusLine(tie) {
  if (tie.status === "played") {
    return `Winner: ${escapeHtml(tie.winner_club_short_name || "—")}`;
  }
  if (tie.fixture_id) {
    return `<a href="matchday.html?fixture=${encodeURIComponent(tie.fixture_id)}">Open matchday</a>`;
  }
  if (tie.status === "pending") return "Waiting for earlier round";
  return escapeHtml(tie.status || "");
}

const BRACKET_SECTIONS = [
  {
    key: "sl_1617",
    title: "SuperLeague — relegation playoff",
    filter: (t) => t.bracket === "sl_1617",
  },
  {
    key: "ch_sb",
    title: "Championship — Shield / Bowl playoffs (16th vs 17th)",
    filter: (t) => t.bracket === "ch_sb_a" || t.bracket === "ch_sb_b",
  },
  {
    key: "ch_promo_a",
    title: "Championship A — promotion playoffs",
    filter: (t) => t.bracket === "ch_promo_a",
  },
  {
    key: "ch_promo_b",
    title: "Championship B — promotion playoffs",
    filter: (t) => t.bracket === "ch_promo_b",
  },
  {
    key: "finals",
    title: "Finals",
    filter: (t) => t.bracket === "ch_final" || t.bracket === "sl_final",
  },
];

function renderTie(tie, myClub) {
  const mine =
    myClub &&
    (tie.home_club_short_name === myClub || tie.away_club_short_name === myClub);
  return `
    <div class="tie${mine ? " mine" : ""}">
      <div class="label">${escapeHtml(tie.label)}</div>
      <div>${clubLabel(tie, "home")}</div>
      <div class="score">${escapeHtml(scoreHtml(tie))}</div>
      <div style="text-align:right">${clubLabel(tie, "away")}</div>
      <div class="status">${statusLine(tie)}</div>
    </div>`;
}

function renderMovements(rows) {
  if (!rows?.length) return "";
  return `
    <div class="section">
      <h2>End-of-season movements</h2>
      <table class="movements">
        <thead><tr><th>Club</th><th>From</th><th>To</th><th>Reason</th></tr></thead>
        <tbody>
          ${rows
            .map(
              (m) => `<tr>
              <td>${escapeHtml(m.club_short_name)}</td>
              <td>${escapeHtml(DIVISION_LABELS[m.from_division] || m.from_division)}</td>
              <td>${escapeHtml(DIVISION_LABELS[m.to_division] || m.to_division)}</td>
              <td>${escapeHtml(m.reason)}</td>
            </tr>`
            )
            .join("")}
        </tbody>
      </table>
    </div>`;
}

async function loadOwnerClub() {
  const user = await getAuthUserFast();
  if (!user) return null;
  const { data } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();
  return data?.ShortName || null;
}

async function isAdmin() {
  try {
    const user = await getAuthUserFast();
    return isGpslAdminUser(user);
  } catch {
    return false;
  }
}

function setStatus(msg, ok = true) {
  const el = document.getElementById("statusLine");
  if (!el) return;
  el.textContent = msg;
  el.className = ok ? "" : "err";
}

async function loadPlayoffs() {
  const { data, error } = await supabase.rpc("competition_playoffs_public", {
    p_season_id: null,
  });
  if (error) throw error;
  return data;
}

async function render() {
  const cal = await loadCalendarStatus(supabase);
  const active = String(cal?.active_gpsl_month || "").toLowerCase();
  const isPlayoffsWeek = active === "playoffs";
  const admin = await isAdmin();
  const myClub = await loadOwnerClub();

  const meta = document.getElementById("meta");
  const banner = document.getElementById("banner");
  const root = document.getElementById("root");
  const adminBox = document.getElementById("adminBox");

  if (adminBox) adminBox.style.display = admin ? "block" : "none";

  let payload;
  try {
    payload = await loadPlayoffs();
  } catch (e) {
    meta.textContent = "Could not load playoffs.";
    banner.innerHTML = `<div class="banner warn">${escapeHtml(e.message || String(e))} — run competition_phase7_playoffs.sql if needed.</div>`;
    root.innerHTML = "";
    return;
  }

  const ties = Array.isArray(payload?.ties) ? payload.ties : [];
  const calRow = payload?.calendar;
  const unlock = calRow?.unlock_at ? formatUkDateTime(calRow.unlock_at) : "—";
  const lock = calRow?.lock_at ? formatUkDateTime(calRow.lock_at) : "—";

  meta.textContent = isPlayoffsWeek
    ? `Playoffs week is live · locks ${lock} UK`
    : `Playoffs window: ${unlock} → ${lock} UK`;

  if (!ties.length) {
    banner.innerHTML = `<div class="banner warn">
      Brackets are not generated yet.
      ${
        isPlayoffsWeek || admin
          ? " Admin can generate from this page (or they generate automatically when May locks)."
          : " This page is mainly for Playoffs week (Week 11 after May)."
      }
    </div>`;
  } else if (payload?.state?.completed_at) {
    banner.innerHTML = `<div class="banner">Playoffs complete. ${
      payload?.state?.movements_applied_at
        ? "Movements have been applied."
        : "Admin can apply end-of-season movements when ready."
    }</div>`;
  } else {
    banner.innerHTML = `<div class="banner">Single-leg knockout ties (extra time &amp; penalties if needed). Higher table position is at home.</div>`;
  }

  root.innerHTML = BRACKET_SECTIONS.map((sec) => {
    const rows = ties.filter(sec.filter);
    if (!rows.length) return "";
    return `<div class="section"><h2>${escapeHtml(sec.title)}</h2>${rows
      .map((t) => renderTie(t, myClub))
      .join("")}</div>`;
  }).join("");

  root.innerHTML += renderMovements(payload?.movements || []);
}

async function runAdmin(rpc, args, label) {
  setStatus(`${label}…`);
  const { data, error } = await supabase.rpc(rpc, args);
  if (error) {
    setStatus(error.message, false);
    return;
  }
  if (data?.ok === false) {
    setStatus(data.reason || data.error || "Failed", false);
    return;
  }
  setStatus(
    data?.already
      ? `Already generated · scheduled ${data.scheduled_now ?? 0} ready tie(s).`
      : `${label} OK.` +
          (data?.ties_created != null ? ` Ties ${data.ties_created}.` : "") +
          (data?.fixtures_scheduled != null
            ? ` Fixtures ${data.fixtures_scheduled}.`
            : "") +
          (data?.movements != null ? ` Movements ${data.movements}.` : "")
  );
  await render();
}

document.getElementById("genBtn")?.addEventListener("click", () => {
  runAdmin(
    "admin_competition_generate_playoffs",
    { p_season_id: null, p_force: false },
    "Generate"
  ).catch((e) => setStatus(e.message || String(e), false));
});

document.getElementById("forceBtn")?.addEventListener("click", () => {
  if (!confirm("Delete existing playoff ties/fixtures and regenerate?")) return;
  runAdmin(
    "admin_competition_generate_playoffs",
    { p_season_id: null, p_force: true },
    "Force regenerate"
  ).catch((e) => setStatus(e.message || String(e), false));
});

document.getElementById("applyBtn")?.addEventListener("click", () => {
  runAdmin(
    "admin_competition_apply_playoff_movements",
    { p_season_id: null },
    "Apply movements"
  ).catch((e) => setStatus(e.message || String(e), false));
});

initGlobal()
  .then(() => render())
  .catch((e) => {
    document.getElementById("meta").textContent = e.message || String(e);
  });
