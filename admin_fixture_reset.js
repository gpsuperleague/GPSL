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
/** @type {Record<string, unknown>|null} */
let preview = null;

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
  const typed = document.getElementById("fixtureIdInput")?.value?.trim();
  if (typed) {
    const n = Number(typed);
    if (Number.isFinite(n) && n > 0) return n;
  }
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
  preview = null;
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
        ? "❌ Run admin_testing_deploy_one_fixture.sql (club list helper) in Supabase."
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
          )} (${c.fixture_count ?? 0})</option>`
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
  preview = null;
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
        const label = `#${f.fixture_id} · ${f.competition_label}${
          f.matchday != null ? ` MD${f.matchday}` : ""
        } · ${venue} vs ${f.opponent_name} · ${f.status}${score}`;
        return `<option value="${f.fixture_id}">${escapeHtml(label)}</option>`;
      })
      .join("");

  setStatus("pickStatus", `${fixtures.length} fixture(s) loaded.`);
}

function countLine(p) {
  if (!p) return "";
  return `<div class="counts">
    <span>Subs <b>${p.submissions ?? 0}</b></span>
    <span>Stats <b>${p.stats ?? 0}</b></span>
    <span>Videos <b>${p.videos ?? 0}</b></span>
    <span>Pending <b>${p.pending_videos ?? 0}</b></span>
    <span>Ledger <b>${p.ledger_rows ?? 0}</b></span>
    <span>Check-ins <b>${p.checkins ?? 0}</b></span>
  </div>`;
}

async function loadPreview(fixtureId) {
  const detail = document.getElementById("fixtureDetail");
  if (!detail) return;
  preview = null;

  if (!fixtureId) {
    detail.hidden = true;
    detail.innerHTML = "";
    return;
  }

  detail.hidden = false;
  detail.innerHTML = `<div>Loading fixture #${fixtureId}…</div>`;

  const { data, error } = await supabase.rpc("admin_fixture_reset_preview", {
    p_fixture_id: fixtureId,
  });

  if (error) {
    detail.innerHTML = `<div class="warn">❌ ${escapeHtml(error.message)}${
      /admin_fixture_reset_preview|schema cache|Could not find/i.test(error.message || "")
        ? " — run admin_fixture_reset_for_replay_20261027.sql"
        : ""
    }</div>`;
    return;
  }

  if (!data?.ok) {
    detail.innerHTML = `<div class="warn">⚠ ${escapeHtml(
      data?.reason || "Fixture not found"
    )}</div>`;
    return;
  }

  preview = data;
  const idInput = document.getElementById("fixtureIdInput");
  if (idInput) idInput.value = String(data.fixture_id);

  const score =
    data.home_goals != null
      ? `${data.home_goals}–${data.away_goals}`
      : "—";
  const sched = data.schedule_status || "no schedule row";
  detail.innerHTML = `
    <div><b>${escapeHtml(data.home_club_short_name)}</b> vs <b>${escapeHtml(
      data.away_club_short_name
    )}</b> · #${data.fixture_id}</div>
    <div>${escapeHtml(data.division || data.competition_type || "")}${
      data.matchday != null ? ` · MD${data.matchday}` : ""
    } · ${escapeHtml(data.gpsl_month || "")}</div>
    <div>Status: <code>${escapeHtml(data.status)}</code> · score <b>${escapeHtml(
      score
    )}</b>${data.is_forfeit ? " · forfeit" : ""}</div>
    <div>Schedule: <code>${escapeHtml(sched)}</code>${
      data.agreed_kickoff_at
        ? ` · KO ${escapeHtml(String(data.agreed_kickoff_at))}`
        : ""
    }</div>
    ${countLine(data)}
    <div class="${
      data.status === "played" || (data.stats || 0) > 0 || (data.videos || 0) > 0
        ? "warn"
        : "ok"
    }" style="margin-top:8px;">
      Reset will clear the above and leave the fixture <code>scheduled</code> /
      schedule <code>unscheduled</code>.
    </div>
  `;
}

async function onFixturePicked() {
  const id = document.getElementById("fixtureSelect")?.value;
  const n = id ? Number(id) : null;
  if (n) {
    const input = document.getElementById("fixtureIdInput");
    if (input) input.value = String(n);
  }
  await loadPreview(n);
}

async function onLoadId() {
  const id = selectedFixtureId();
  if (!id) {
    setStatus("pickStatus", "Enter a fixture id.", false);
    return;
  }
  await loadPreview(id);
  setStatus("pickStatus", `Loaded fixture #${id}.`);
}

async function runReset() {
  const id = selectedFixtureId();
  const phrase = document.getElementById("confirmPhrase")?.value || "";
  const reason = document.getElementById("reasonInput")?.value?.trim() || "";

  if (!id) {
    setStatus("resetStatus", "Select or enter a fixture first.", false);
    return;
  }
  if (phrase !== "RESET FIXTURE REPLAY") {
    setStatus(
      "resetStatus",
      "Type exactly: RESET FIXTURE REPLAY",
      false
    );
    return;
  }

  const label = preview
    ? `${preview.home_club_short_name} vs ${preview.away_club_short_name} (#${id})`
    : `fixture #${id}`;
  if (
    !window.confirm(
      `Reset ${label} for replay?\n\nThis clears result, stats, videos, schedule and linked finance.\n\nCup ties: the winner is also pulled out of the next-round draw (unplayed next-round fixture removed if a feeder slot empties).`
    )
  ) {
    return;
  }

  setStatus("resetStatus", "Resetting…");
  const { data, error } = await supabase.rpc("admin_fixture_reset_for_replay", {
    p_fixture_id: id,
    p_reason: reason || null,
    p_confirm_phrase: phrase,
  });

  if (error) {
    setStatus(
      "resetStatus",
      error.message.includes("admin_fixture_reset_for_replay")
        ? "❌ Run admin_fixture_reset_for_replay_20261027.sql in Supabase first."
        : "❌ " + error.message,
      false
    );
    return;
  }

  if (!data?.ok) {
    setStatus("resetStatus", "⚠ " + (data?.reason || "Reset failed"), false);
    return;
  }

  const c = data.cleared || {};
  setStatus(
    "resetStatus",
    `✅ Reset #${data.fixture_id} (${data.home} vs ${data.away}) — stats ${c.stats ?? 0}, subs ${c.submissions ?? 0}, ledger ${c.ledger_rows ?? 0}.`,
    true
  );
  document.getElementById("confirmPhrase").value = "";
  await loadPreview(id);
}

async function runUnlockResult() {
  const id = selectedFixtureId();
  const note = String(document.getElementById("unlockNoteInput")?.value || "").trim();

  if (!id) {
    setStatus("unlockStatus", "Select or enter a fixture first.", false);
    return;
  }

  const label = preview
    ? `${preview.home_club_short_name} vs ${preview.away_club_short_name} (#${id})`
    : `fixture #${id}`;
  if (
    !window.confirm(
      `Unlock result entry for ${label}?\n\nAdds any missing check-in so Match Day submit works.\nNo-show fines and season strikes stay in place.`
    )
  ) {
    return;
  }

  setStatus("unlockStatus", "Unlocking…");
  const { data, error } = await supabase.rpc("admin_fixture_unlock_result_entry", {
    p_fixture_id: id,
    p_note: note || null,
  });

  if (error) {
    setStatus(
      "unlockStatus",
      /admin_fixture_unlock_result_entry|schema cache|Could not find/i.test(
        error.message || ""
      )
        ? "❌ Run admin_unlock_result_keep_noshow_20261031.sql in Supabase first."
        : "❌ " + error.message,
      false
    );
    return;
  }

  if (!data?.ok) {
    setStatus("unlockStatus", "⚠ " + (data?.reason || "Unlock failed"), false);
    return;
  }

  const inserted = Array.isArray(data.inserted_checkins)
    ? data.inserted_checkins.join(", ")
    : data.already_both_checked_in
      ? "(already both in)"
      : "—";
  setStatus(
    "unlockStatus",
    `✅ Unlocked #${data.fixture_id} (${data.home} vs ${data.away}) — check-ins added: ${inserted}. Kept ${data.preserved_noshow_events ?? 0} no-show event(s), ${data.preserved_noshow_fines ?? 0} fine(s) (₿${Number(data.preserved_noshow_fines_amount || 0).toLocaleString("en-GB")}).`,
    true
  );
  await loadPreview(id);
}

whenDomReady(async () => {
  await initAdminPage({ requireAdmin: true });
  populateMonthSelect();

  document.getElementById("monthSelect")?.addEventListener("change", () => {
    void loadClubs();
  });
  document.getElementById("clubSelect")?.addEventListener("change", () => {
    void loadFixtures();
  });
  document.getElementById("fixtureSelect")?.addEventListener("change", () => {
    void onFixturePicked();
  });
  document.getElementById("loadIdBtn")?.addEventListener("click", () => {
    void onLoadId();
  });
  document.getElementById("fixtureIdInput")?.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      void onLoadId();
    }
  });
  document.getElementById("unlockResultBtn")?.addEventListener("click", () => {
    void runUnlockResult();
  });
  document.getElementById("resetBtn")?.addEventListener("click", () => {
    void runReset();
  });

  await loadClubs();
});
