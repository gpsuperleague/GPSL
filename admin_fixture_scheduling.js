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
/** @type {Array<Record<string, unknown>>} */
let timelineItems = [];

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

function fmtUk(iso) {
  if (!iso) return "—";
  try {
    return new Intl.DateTimeFormat("en-GB", {
      timeZone: "Europe/London",
      weekday: "short",
      day: "numeric",
      month: "short",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    }).format(new Date(iso));
  } catch {
    return String(iso);
  }
}

function ts(iso) {
  if (!iso) return 0;
  const n = Date.parse(iso);
  return Number.isFinite(n) ? n : 0;
}

async function loadClubs() {
  const month = selectedMonth();
  const clubSel = document.getElementById("clubSelect");
  const fixSel = document.getElementById("fixtureSelect");
  if (!clubSel || !fixSel) return;

  fixtureMap = new Map();
  fixSel.innerHTML = `<option value="">Select club first…</option>`;

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
    setStatus("pickStatus", "❌ " + error.message, false);
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
  if (!fixSel) return;

  fixtureMap = new Map();

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

function buildTimeline(payload) {
  /** @type {Array<Record<string, unknown>>} */
  const items = [];

  for (const p of payload.proposals || []) {
    items.push({
      kind: "proposal",
      at: p.created_at,
      sort: ts(p.created_at),
      status: p.status,
      who: p.proposed_by_club_short_name,
      title: `Proposed kick-off ${fmtUk(p.kickoff_at)}`,
      body: `Proposal #${p.id} · status ${p.status}`,
    });
  }

  for (const i of payload.inbox || []) {
    items.push({
      kind: "inbox",
      at: i.created_at,
      sort: ts(i.created_at),
      status: i.message_type,
      who: i.recipient_club_short_name,
      title: i.title || i.message_type,
      body: i.body || "",
    });
  }

  for (const o of payload.mutual_overrides || []) {
    items.push({
      kind: "override",
      at: o.created_at,
      sort: ts(o.created_at),
      status: o.status,
      who: o.requested_by_club,
      title: `Discord lock · ${o.kind} · ${fmtUk(o.proposed_kickoff_at)}`,
      body: `Status ${o.status}${o.applied_at ? ` · applied ${fmtUk(o.applied_at)}` : ""}`,
    });
  }

  for (const c of payload.checkins || []) {
    items.push({
      kind: "checkin",
      at: c.checked_in_at,
      sort: ts(c.checked_in_at),
      status: "checkin",
      who: c.club_short_name,
      title: "Checked in",
      body: "",
    });
  }

  for (const n of payload.no_show_events || []) {
    items.push({
      kind: "noshow",
      at: n.created_at,
      sort: ts(n.created_at),
      status: n.action,
      who: n.club_short_name,
      title: `No-show · attempt ${n.play_attempt_no} · ${n.action}`,
      body: `Kick-off was ${fmtUk(n.kickoff_at)}${n.both_miss ? " · both missed" : ""}`,
    });
  }

  items.sort((a, b) => a.sort - b.sort || String(a.kind).localeCompare(String(b.kind)));
  return items;
}

function renderSummary(payload) {
  const f = payload.fixture || {};
  const s = payload.schedule || null;
  const score =
    f.home_goals != null ? `${f.home_goals}–${f.away_goals}` : "—";
  const el = document.getElementById("fixtureSummary");
  if (!el) return;

  el.innerHTML = `
    <div><b>${escapeHtml(f.home_club_short_name)} vs ${escapeHtml(
      f.away_club_short_name
    )}</b>
      · fixture <code>#${f.fixture_id}</code>
      · ${escapeHtml(f.competition_type || "")}${
        f.matchday != null ? ` MD${f.matchday}` : ""
      }
      · GPSL ${escapeHtml(f.gpsl_month || "—")}
      · fixture status <b>${escapeHtml(f.status)}</b>
      · score ${escapeHtml(score)}
    </div>
    <div class="meta-row">
      <span>Schedule <b>${escapeHtml(s?.status || "none")}</b></span>
      <span>Agreed KO <b>${escapeHtml(fmtUk(s?.agreed_kickoff_at))}</b></span>
      <span>Home props <b>${s?.home_proposal_count ?? 0}</b></span>
      <span>Away props <b>${s?.away_proposal_count ?? 0}</b></span>
      <span>Response due <b>${
        s?.response_due_at
          ? `${escapeHtml(fmtUk(s.response_due_at))} (${escapeHtml(
              s.response_required_club_short_name || "?"
            )})`
          : "—"
      }</b></span>
      <span>Play attempts <b>${s?.play_attempt_count ?? 0}</b></span>
      <span>Proposals <b>${(payload.proposals || []).length}</b></span>
      <span>Inbox <b>${(payload.inbox || []).length}</b></span>
    </div>
  `;

  const ownerLink = document.getElementById("ownerScheduleLink");
  if (ownerLink) {
    ownerLink.href = `fixture_schedule.html?fixture=${f.fixture_id}`;
  }
  const resetLink = document.getElementById("resetLink");
  if (resetLink) {
    resetLink.href = `admin_fixture_reset.html?fixture=${f.fixture_id}`;
  }
}

function enabledKinds() {
  const out = new Set();
  document.querySelectorAll("#timelineFilters input[data-kind]").forEach((cb) => {
    if (cb.checked) out.add(cb.getAttribute("data-kind"));
  });
  return out;
}

function renderTimeline() {
  const ul = document.getElementById("timeline");
  const empty = document.getElementById("timelineEmpty");
  if (!ul) return;

  const kinds = enabledKinds();
  const visible = timelineItems.filter((it) => kinds.has(it.kind));

  if (!visible.length) {
    ul.innerHTML = "";
    if (empty) empty.hidden = false;
    return;
  }
  if (empty) empty.hidden = true;

  ul.innerHTML = visible
    .map((it) => {
      const tagClass = escapeHtml(String(it.status || "").toLowerCase());
      return `<li class="kind-${escapeHtml(it.kind)}">
        <div class="when">${escapeHtml(fmtUk(it.at))}</div>
        <div>
          <span class="tag ${tagClass}">${escapeHtml(it.kind)}</span>
          <span class="who">${escapeHtml(it.who || "—")}</span>
          · ${escapeHtml(it.title || "")}
        </div>
        ${
          it.body
            ? `<div class="body">${escapeHtml(it.body)}</div>`
            : ""
        }
      </li>`;
    })
    .join("");
}

async function loadHistory(fixtureId) {
  const card = document.getElementById("historyCard");
  if (!card) return;

  if (!fixtureId) {
    card.hidden = true;
    timelineItems = [];
    return;
  }

  card.hidden = false;
  const summary = document.getElementById("fixtureSummary");
  if (summary) summary.innerHTML = `<div>Loading fixture #${fixtureId}…</div>`;
  const ul = document.getElementById("timeline");
  if (ul) ul.innerHTML = "";
  setStatus("pickStatus", `Loading history for #${fixtureId}…`);

  const { data, error } = await supabase.rpc("admin_fixture_scheduling_history", {
    p_fixture_id: fixtureId,
  });

  if (error) {
    if (summary) {
      summary.innerHTML = `<div class="warn">❌ ${escapeHtml(error.message)}${
        /admin_fixture_scheduling_history|schema cache|Could not find/i.test(
          error.message || ""
        )
          ? " — run admin_fixture_scheduling_history_20261104.sql"
          : ""
      }</div>`;
    }
    setStatus("pickStatus", "❌ " + error.message, false);
    timelineItems = [];
    renderTimeline();
    return;
  }

  if (!data?.ok) {
    if (summary) {
      summary.innerHTML = `<div class="warn">⚠ ${escapeHtml(
        data?.reason || "Fixture not found"
      )}</div>`;
    }
    setStatus("pickStatus", "⚠ " + (data?.reason || "not found"), false);
    timelineItems = [];
    renderTimeline();
    return;
  }

  const idInput = document.getElementById("fixtureIdInput");
  if (idInput) idInput.value = String(data.fixture?.fixture_id || fixtureId);

  renderSummary(data);
  timelineItems = buildTimeline(data);
  renderTimeline();

  const n = timelineItems.length;
  setStatus(
    "pickStatus",
    `Loaded #${data.fixture.fixture_id}: ${n} event(s) · schedule ${
      data.schedule?.status || "none"
    }.`
  );

  // Keep URL shareable
  try {
    const url = new URL(window.location.href);
    url.searchParams.set("fixture", String(data.fixture.fixture_id));
    window.history.replaceState({}, "", url);
  } catch {
    /* ignore */
  }
}

whenDomReady(async () => {
  const user = await initAdminPage();
  if (!user) return;

  populateMonthSelect();

  document.getElementById("monthSelect")?.addEventListener("change", async () => {
    await loadClubs();
  });
  document.getElementById("clubSelect")?.addEventListener("change", async () => {
    await loadFixtures();
  });
  document.getElementById("fixtureSelect")?.addEventListener("change", async () => {
    const id = selectedFixtureId();
    const idInput = document.getElementById("fixtureIdInput");
    if (idInput && id) idInput.value = String(id);
    await loadHistory(id);
  });
  document.getElementById("loadIdBtn")?.addEventListener("click", async () => {
    await loadHistory(selectedFixtureId());
  });
  document.getElementById("fixtureIdInput")?.addEventListener("keydown", async (ev) => {
    if (ev.key === "Enter") {
      ev.preventDefault();
      await loadHistory(selectedFixtureId());
    }
  });
  document.getElementById("timelineFilters")?.addEventListener("change", () => {
    renderTimeline();
  });

  // Deep link ?fixture=8966
  const params = new URLSearchParams(window.location.search);
  const deep = Number(params.get("fixture") || "");
  if (Number.isFinite(deep) && deep > 0) {
    const idInput = document.getElementById("fixtureIdInput");
    if (idInput) idInput.value = String(deep);
    await loadHistory(deep);
  } else {
    await loadClubs();
  }
});
