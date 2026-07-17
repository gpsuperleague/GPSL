import {
  initAdminPage,
  primeAdminPageChrome,
  setStatus,
  supabase,
  whenDomReady,
} from "./admin_common.js";

primeAdminPageChrome();

const GPSL_MONTHS = [
  { value: "august", label: "August" },
  { value: "september", label: "September" },
  { value: "october", label: "October" },
  { value: "november", label: "November" },
  { value: "december", label: "December" },
  { value: "january", label: "January" },
  { value: "february", label: "February" },
  { value: "march", label: "March" },
  { value: "april", label: "April" },
  { value: "may", label: "May" },
];

/** @type {Map<number, Record<string, unknown>>} */
let fixtureMap = new Map();

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function selectedMonth() {
  return document.getElementById("monthSelect")?.value || "";
}

function selectedClub() {
  return document.getElementById("clubSelect")?.value || "";
}

function selectedFixtureId() {
  const v = document.getElementById("fixtureSelect")?.value;
  return v ? Number(v) : null;
}

function populateMonthSelect() {
  const sel = document.getElementById("monthSelect");
  if (!sel) return;
  sel.innerHTML = GPSL_MONTHS.map(
    (m) => `<option value="${m.value}">${m.label}</option>`
  ).join("");
}

async function loadClubs() {
  const month = selectedMonth();
  const clubSel = document.getElementById("clubSelect");
  const fixSel = document.getElementById("fixtureSelect");
  const detail = document.getElementById("fixtureDetail");
  if (!clubSel || !fixSel) return;

  fixtureMap = new Map();
  fixSel.innerHTML = `<option value="">Select club first…</option>`;
  if (detail) detail.hidden = true;

  if (!month) {
    clubSel.innerHTML = `<option value="">Select month first…</option>`;
    return;
  }

  clubSel.innerHTML = `<option value="">Loading…</option>`;
  setStatus("pickStatus", "Loading clubs…");

  const { data, error } = await supabase.rpc("admin_testing_list_month_clubs", {
    p_gpsl_month: month,
    p_season_id: null,
  });

  if (error) {
    clubSel.innerHTML = `<option value="">Error</option>`;
    setStatus(
      "pickStatus",
      error.message.includes("admin_testing_list_month_clubs")
        ? "❌ Run admin_testing_deploy_one_fixture.sql in Supabase first."
        : "❌ " + error.message,
      false
    );
    return;
  }

  if (!data?.ok) {
    clubSel.innerHTML = `<option value="">—</option>`;
    setStatus("pickStatus", "⚠ " + (data?.reason || "Could not load clubs"), false);
    return;
  }

  const clubs = data.clubs || [];
  if (!clubs.length) {
    clubSel.innerHTML = `<option value="">No clubs with fixtures this month</option>`;
    setStatus("pickStatus", "No fixtures found for that month.", false);
    return;
  }

  clubSel.innerHTML =
    `<option value="">Select club…</option>` +
    clubs
      .map(
        (c) =>
          `<option value="${escapeHtml(c.club_short_name)}">${escapeHtml(
            c.club_name
          )} (${c.scheduled_count ?? 0} scheduled / ${c.fixture_count ?? 0})</option>`
      )
      .join("");

  setStatus("pickStatus", `${clubs.length} club(s) with fixtures in ${month}.`);
}

async function loadFixtures() {
  const month = selectedMonth();
  const club = selectedClub();
  const fixSel = document.getElementById("fixtureSelect");
  const detail = document.getElementById("fixtureDetail");
  if (!fixSel) return;

  fixtureMap = new Map();
  if (detail) detail.hidden = true;

  if (!month || !club) {
    fixSel.innerHTML = `<option value="">Select club first…</option>`;
    return;
  }

  fixSel.innerHTML = `<option value="">Loading…</option>`;
  setStatus("pickStatus", "Loading fixtures…");

  const { data, error } = await supabase.rpc("admin_testing_list_club_month_fixtures", {
    p_gpsl_month: month,
    p_club_short_name: club,
    p_season_id: null,
  });

  if (error) {
    fixSel.innerHTML = `<option value="">Error</option>`;
    setStatus("pickStatus", "❌ " + error.message, false);
    return;
  }

  if (!data?.ok) {
    fixSel.innerHTML = `<option value="">—</option>`;
    setStatus("pickStatus", "⚠ " + (data?.reason || "Could not load fixtures"), false);
    return;
  }

  const fixtures = data.fixtures || [];
  if (!fixtures.length) {
    fixSel.innerHTML = `<option value="">No fixtures</option>`;
    setStatus("pickStatus", "No fixtures for that club/month.", false);
    return;
  }

  for (const f of fixtures) {
    fixtureMap.set(Number(f.fixture_id), f);
  }

  fixSel.innerHTML =
    `<option value="">Select fixture…</option>` +
    fixtures
      .map((f) => {
        const venue = f.is_home ? "H" : "A";
        const score =
          f.status === "played" && f.home_goals != null
            ? ` ${f.home_goals}–${f.away_goals}`
            : "";
        const ready =
          f.status === "scheduled"
            ? f.squads_ready
              ? " · ready"
              : " · not ready"
            : "";
        const label = `#${f.fixture_id} · ${f.competition_label}${
          f.matchday != null ? ` MD${f.matchday}` : ""
        } · ${venue} vs ${f.opponent_name} · ${f.status}${score}${ready}`;
        return `<option value="${f.fixture_id}">${escapeHtml(label)}</option>`;
      })
      .join("");

  setStatus("pickStatus", `${fixtures.length} fixture(s) loaded.`);
}

function renderFixtureDetail() {
  const id = selectedFixtureId();
  const el = document.getElementById("fixtureDetail");
  if (!el) return;

  const f = id ? fixtureMap.get(id) : null;
  if (!f) {
    el.hidden = true;
    el.innerHTML = "";
    return;
  }

  const readyClass = f.squads_ready ? "ok" : "bad";
  const scoreLine =
    f.status === "played"
      ? `<div>Score: <b>${f.home_goals}–${f.away_goals}</b></div>`
      : `<div>Status: <b>${escapeHtml(f.status)}</b> (must be <code>scheduled</code> to deploy)</div>`;

  el.hidden = false;
  el.innerHTML = `
    <div><b>${escapeHtml(f.home_club_name)}</b> vs <b>${escapeHtml(f.away_club_name)}</b></div>
    <div>${escapeHtml(f.competition_label)}${
      f.matchday != null ? ` · Matchday ${f.matchday}` : ""
    } · ${escapeHtml(f.gpsl_month)}</div>
    ${scoreLine}
    <div class="${readyClass}">
      Squads ready: ${f.squads_ready ? "yes" : "no"}
      (home ${f.home_available ?? "?"} avail · away ${f.away_available ?? "?"} avail)
    </div>
    <div>Fixture id: <code>${f.fixture_id}</code></div>
  `;
}

async function deployOne() {
  const fixtureId = selectedFixtureId();
  const phrase = document.getElementById("confirmPhrase")?.value?.trim() || "";

  if (!fixtureId) {
    setStatus("deployStatus", "Select a fixture first.", false);
    return;
  }

  const f = fixtureMap.get(fixtureId);
  if (f?.status && f.status !== "scheduled") {
    setStatus("deployStatus", `Fixture is already ${f.status}.`, false);
    return;
  }

  if (phrase !== "DEPLOY TEST FIXTURE") {
    setStatus("deployStatus", "Type exactly: DEPLOY TEST FIXTURE", false);
    return;
  }

  if (
    !confirm(
      `Auto-populate & calculate fixture #${fixtureId}?\n\n${f?.home_club_name || "Home"} vs ${
        f?.away_club_name || "Away"
      }`
    )
  ) {
    return;
  }

  setStatus("deployStatus", "Deploying…");

  const { data, error } = await supabase.rpc("admin_testing_deploy_one_fixture", {
    p_fixture_id: fixtureId,
    p_confirm_phrase: phrase,
  });

  if (error) {
    setStatus(
      "deployStatus",
      error.message.includes("admin_testing_deploy_one_fixture")
        ? "❌ Run admin_testing_deploy_one_fixture.sql in Supabase first."
        : "❌ " + error.message,
      false
    );
    return;
  }

  if (!data?.ok) {
    setStatus(
      "deployStatus",
      "⚠ " + (data?.reason || "Deploy failed") +
        (data?.status ? ` (status=${data.status})` : ""),
      false
    );
    await loadFixtures();
    return;
  }

  document.getElementById("confirmPhrase").value = "";
  const res = data.result || {};
  const score =
    res.score ||
    res.score_label ||
    (res.home_goals != null ? `${res.home_goals}–${res.away_goals}` : "played");

  setStatus(
    "deployStatus",
    `✅ Fixture #${fixtureId} deployed — ${score}. Discord results feed will pick it up if configured.`
  );
  await loadFixtures();
  const fixSel = document.getElementById("fixtureSelect");
  if (fixSel) fixSel.value = String(fixtureId);
  renderFixtureDetail();
}

whenDomReady(async () => {
  if (!(await initAdminPage())) return;

  populateMonthSelect();

  document.getElementById("monthSelect").onchange = async () => {
    await loadClubs();
  };
  document.getElementById("clubSelect").onchange = async () => {
    await loadFixtures();
  };
  document.getElementById("fixtureSelect").onchange = () => {
    renderFixtureDetail();
  };
  document.getElementById("deployBtn").onclick = () => {
    deployOne().catch((e) => setStatus("deployStatus", e.message || String(e), false));
  };

  await loadClubs();
});
