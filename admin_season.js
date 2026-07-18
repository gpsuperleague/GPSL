import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  renderSeasonAdminNavHtml,
  renderSeasonMgmtAdminNavHtml,
  isSeasonAdminNavItemActive,
} from "./admin_season_nav.js";

primeAdminPageChrome();
import {
  SETUP_DIVISION_OPTIONS,
  loadSetupSeasons,
  loadSeasonRegistrations,
  countSetupDivisions,
  canDrawChampionshipAb,
  canActivateSeason,
  loadCurrentSeason,
  DIVISION_LABELS,
} from "./competition.js";
import {
  loadSeasonCalendarMonths,
  loadCalendarStatus,
  formatUkDateTime,
} from "./competition_calendar.js";

let compRegistrations = [];
let compSelectedSeasonId = null;

const SEASON_PANEL_IDS = new Set([
  "wf-overview",
  "wf-calendar",
  "wf-divisions",
  "wf-kickoff",
  "wf-close-season",
]);

function renderSeasonSidebar() {
  const root = document.getElementById("adminSeasonNav");
  if (!root) return;
  const pathname = window.location.pathname;
  const search = window.location.search || "";
  root.innerHTML =
    renderSeasonAdminNavHtml(pathname, search) +
    renderSeasonMgmtAdminNavHtml(pathname, search);
}

function showSeasonPanel(panelId) {
  const id = SEASON_PANEL_IDS.has(panelId) ? panelId : "wf-overview";
  document.querySelectorAll(".admin-season-panel").forEach((panel) => {
    panel.hidden = panel.dataset.panel !== id;
  });

  document.querySelectorAll("#adminSeasonNav a.nav-link-sub").forEach((link) => {
    link.classList.remove("active");
    const href = link.getAttribute("href") || "";
    const hash = href.includes("#") ? href.split("#")[1] : "";
    if (href.includes("admin_season.html") && hash && hash === id) {
      link.classList.add("active");
    }
  });
}

function wireSeasonSidebar() {
  const root = document.getElementById("adminSeasonNav");
  if (!root) return;

  root.querySelectorAll("[data-nav-subgroup]").forEach((subgroup) => {
    const btn = subgroup.querySelector(".nav-subgroup-summary");
    if (!btn) return;
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const willOpen = !subgroup.classList.contains("open");
      subgroup.classList.toggle("open", willOpen);
      btn.setAttribute("aria-expanded", willOpen ? "true" : "false");
    });
  });

  root.querySelectorAll('a.nav-link-sub[href*="admin_season.html#"]').forEach((link) => {
    link.addEventListener("click", (e) => {
      const hash = (link.getAttribute("href") || "").split("#")[1] || "";
      if (!SEASON_PANEL_IDS.has(hash)) return;
      e.preventDefault();
      const url = `${window.location.pathname}${window.location.search}#${hash}`;
      history.pushState(null, "", url);
      showSeasonPanel(hash);
    });
  });

  const onHash = () => {
    const hash = (window.location.hash || "").replace("#", "");
    showSeasonPanel(hash || "wf-overview");
  };
  window.addEventListener("hashchange", onHash);
  onHash();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  renderSeasonSidebar();
  wireSeasonSidebar();

  document.getElementById("compCreateNextBtn").onclick = createNextSeason;
  document.getElementById("compEndSeasonBtn").onclick = endCurrentSeason;
  document.getElementById("compArchiveSeasonBtn").onclick = archiveSeasonStats;
  document.getElementById("compManagerSeasonEndBtn").onclick = processManagerSeasonEnd;
  document.getElementById("compSetupSeasonSelect").onchange = onCompSeasonSelected;
  document.getElementById("compSeedMovementsBtn").onclick = seedDivisionsFromMovements;
  document.getElementById("compSaveAssignBtn").onclick = saveCompetitionAssignments;
  document.getElementById("compAssignBody").addEventListener("change", (e) => {
    if (e.target.classList.contains("comp-div-select")) {
      updateCompSetupCounts();
    }
  });
  document.getElementById("compDrawBtn").onclick = drawCompetitionAb;
  document.getElementById("compResetDrawBtn").onclick = resetCompetitionDraw;
  document.getElementById("compStartSeasonBtn").onclick = startCompetitionSeason;
  document.getElementById("compCalendarSetBtn").onclick = setCompCalendar;
  document.getElementById("compCalendarBreakBtn").onclick = insertCompCalendarBreak;
  document.getElementById("compCalendarClearBtn").onclick = clearCompCalendar;
  document.getElementById("compInboxMonthBtn").onclick = sendMonthPreviewInbox;
  document.getElementById("compCalendarAnchor").addEventListener("input", updateCalendarPreview);
  document.getElementById("compCalendarSuggestFriBtn").onclick = () =>
    fillCalendarAnchor(nextFriday1900Uk(0));
  document.getElementById("compCalendarSuggest2wBtn").onclick = () =>
    fillCalendarAnchor(nextFriday1900Uk(14));
  updateCalendarPreview();
  // Sport rebuild lives on admin_gpsl_sport.html
  const sportRebuildBtn = document.getElementById("compSportRebuildBtn");
  if (sportRebuildBtn) sportRebuildBtn.onclick = rebuildGpslSportEdition;

  await refreshCompetitionAdmin();
  await refreshCompCalendarAdmin();
});

function setCompStatus(msg, ok = true) {
  setStatus("compSeasonStatus", msg, ok);
}

async function createNextSeason() {
  const label = document.getElementById("compSeasonLabel").value.trim();
  if (!label) {
    setStatus("compCreateStatus", "Enter a season label.", false);
    return;
  }

  if (
    !confirm(
      `Create competition season “${label}” in pre-season?\n\nIf the legacy league year is still open, this runs season rollover and contract tick first (replaces the old Start New Season button).`
    )
  ) {
    return;
  }

  setStatus("compCreateStatus", "Working…");

  // Legacy player/transfer year rollover only while a competition season is still live.
  // Contract tick runs inside competition_create_season whenever a prior season exists
  // (including Summer Break) — see patches/contract_tick_on_create_season.sql.
  const active = await loadCurrentSeason(supabase);
  if (active) {
    const { error: rollErr } = await supabase.rpc("rollover_season");
    if (rollErr) {
      setStatus("compCreateStatus", "❌ Rollover failed: " + rollErr.message, false);
      return;
    }
  }

  const { data, error } = await supabase.rpc("competition_create_season", {
    p_label: label,
  });

  if (error) {
    setStatus("compCreateStatus", "❌ " + error.message, false);
    return;
  }

  document.getElementById("compSeasonLabel").value = "";
  setStatus(
    "compCreateStatus",
    `✅ Pre-season created (id ${data}). Contracts ticked if a prior season existed. Assign divisions below.`
  );
  await refreshCompetitionAdmin();
  if (data) {
    document.getElementById("compSetupSeasonSelect").value = String(data);
    compSelectedSeasonId = data;
    await loadCompSeasonData(data);
    await refreshCompCalendarForSeason(data);
  }
}

async function archiveSeasonStats() {
  if (
    !confirm(
      "Archive current season stats?\n\nWrites league positions, cup winners, player season stats, Ballon d'Or & club records. Safe to re-run."
    )
  ) {
    return;
  }

  setStatus("compArchiveStatus", "Archiving…");
  let { data, error } = await supabase.rpc("competition_admin_archive_season_with_inbox", {
    p_season_id: null,
  });

  if (error?.message?.includes("competition_admin_archive_season_with_inbox")) {
    ({ data, error } = await supabase.rpc("competition_admin_archive_season", {
      p_season_id: null,
    }));
  }

  if (error) {
    setStatus(
      "compArchiveStatus",
      error.message.includes("competition_admin_archive_season")
        ? "❌ Run supabase/sql/competition_history.sql and patches/owner_inbox_notifications.sql in Supabase, then retry."
        : "❌ " + error.message,
      false
    );
    return;
  }

  const seasonId = data?.season_id;
  let rankNote = "";
  if (seasonId != null) {
    const { error: rankErr } = await supabase.rpc(
      "competition_owner_ranking_recompute_season",
      { p_season_id: seasonId }
    );
    rankNote = rankErr
      ? ` Owner ranking not updated (${rankErr.message}). Run competition_owner_ranking.sql.`
      : " Owner ranking updated.";

    const { error: clubRankErr } = await supabase.rpc(
      "competition_club_ranking_recompute_season",
      { p_season_id: seasonId }
    );
    rankNote += clubRankErr
      ? ` Club ranking not updated (${clubRankErr.message}). Run competition_club_stadium_attendance.sql.`
      : " Club ranking updated.";
  }

  setStatus(
    "compArchiveStatus",
    `✅ Archived ${data?.season_label || "season"} — ${data?.clubs_archived ?? 0} clubs, ${data?.players_archived ?? 0} players, ${data?.cups_archived ?? 0} cups.${rankNote}`,
    !rankNote.includes("not updated")
  );
}

async function processManagerSeasonEnd() {
  if (
    !confirm(
      "Process manager contracts for season end?\n\nTicks mid-deal seasons; at deal end offers owner renewal if they hit ≥1 target, or releases for MV with a 2-season rehire ban if they missed both."
    )
  ) {
    return;
  }

  setStatus("compManagerSeasonEndStatus", "Processing managers…");
  let { data, error } = await supabase.rpc("manager_process_season_end_with_inbox");
  if (error?.message?.includes("manager_process_season_end_with_inbox")) {
    ({ data, error } = await supabase.rpc("manager_process_season_end"));
  }

  if (error) {
    setStatus(
      "compManagerSeasonEndStatus",
      error.message.includes("manager_process_season_end")
        ? "❌ Run manager_two_season_deal_eval.sql (and owner_inbox_notifications.sql) in Supabase, then retry."
        : "❌ " + error.message,
      false
    );
    return;
  }

  const results = Array.isArray(data?.results) ? data.results : [];
  const counts = results.reduce((acc, row) => {
    const action = row?.action || "other";
    acc[action] = (acc[action] || 0) + 1;
    return acc;
  }, {});
  const summary = Object.keys(counts).length
    ? Object.entries(counts)
        .map(([k, n]) => `${n}× ${k}`)
        .join(", ")
    : "no contracted managers processed";

  setStatus(
    "compManagerSeasonEndStatus",
    `✅ Manager season-end done — ${summary}.`,
    true
  );
}

async function endCurrentSeason() {
  if (
    !confirm(
      "End the current active GPSL season?\n\nOwners will see Summer Break in the nav until a new season is started."
    )
  ) {
    return;
  }

  setStatus("compEndStatus", "Ending season…");
  const { data, error } = await supabase.rpc("competition_end_season");

  if (error) {
    setStatus(
      "compEndStatus",
      error.message.includes("No active current season")
        ? "❌ No active competition season found. Check competition_seasons has status = active. If you ended a month early without opening the next, use Open next GPSL month on the Calendar page first — the season is still live."
        : error.message.includes("competition_end_season")
          ? "❌ Run supabase/sql/admin_season_lifecycle.sql in Supabase, then retry."
          : "❌ " + error.message,
      false
    );
    return;
  }

  setStatus(
    "compEndStatus",
    `✅ ${data?.label || "Season"} ended — league phase: Summer Break.`
  );
  await refreshCompetitionAdmin();
  await refreshCompCalendarAdmin();
}

async function loadSeedFromSeasonOptions(targetSeasonId) {
  const select = document.getElementById("compSeedFromSeasonSelect");
  if (!select) return;

  const prevValue = select.value;
  select.innerHTML = `<option value="">Auto (first with movements / finished playoffs)</option>`;

  const { data: seasons, error } = await supabase
    .from("competition_seasons")
    .select("id, label, status")
    .order("id", { ascending: true });

  if (error || !seasons?.length) return;

  const { data: moveRows } = await supabase
    .from("competition_season_movements")
    .select("season_id");
  const withMoves = new Set((moveRows || []).map((r) => r.season_id));

  let preferred = "";
  for (const s of seasons) {
    if (targetSeasonId && s.id === targetSeasonId) continue;
    const opt = document.createElement("option");
    opt.value = String(s.id);
    const tag = withMoves.has(s.id) ? " · has movements" : "";
    opt.textContent = `${s.label} (id ${s.id}, ${s.status})${tag}`;
    select.appendChild(opt);
    if (!preferred && withMoves.has(s.id)) preferred = String(s.id);
    // Prefer explicitly labelled Season 1 when present and no movements elsewhere yet
    if (
      !preferred &&
      /^season\s*1$/i.test(String(s.label || "").trim())
    ) {
      preferred = String(s.id);
    }
  }

  if (prevValue && [...select.options].some((o) => o.value === prevValue)) {
    select.value = prevValue;
  } else if (preferred) {
    select.value = preferred;
  }
}

async function refreshCompetitionAdmin() {
  const active = await loadCurrentSeason(supabase);
  const summary = document.getElementById("compActiveSummary");
  summary.textContent = active
    ? `Live season: ${active.label} (${active.status})`
    : "No live competition season (pre-season setup or Summer Break).";

  const setupSeasons = await loadSetupSeasons(supabase);
  const select = document.getElementById("compSetupSeasonSelect");
  select.innerHTML = "";

  const startBtn = document.getElementById("compStartSeasonBtn");

  if (!setupSeasons.length) {
    select.innerHTML = active
      ? `<option value="">None — ${active.label} is live</option>`
      : `<option value="">No pre-season years</option>`;
    compSelectedSeasonId = null;
    compRegistrations = [];
    renderCompAssignTable();
    updateCompSetupCounts();
    startBtn.style.display = "none";
    const startStatus = document.getElementById("compStartStatus");
    if (active && startStatus && !startStatus.textContent?.trim()) {
      setStatus(
        "compStartStatus",
        `✅ ${active.label} is the live season. Pre-season dropdowns clear after Start — that is expected.`
      );
    }
    await loadSeedFromSeasonOptions(null);
    return;
  }

  for (const s of setupSeasons) {
    const opt = document.createElement("option");
    opt.value = s.id;
    opt.textContent = `${s.label} (${s.status})`;
    select.appendChild(opt);
  }

  compSelectedSeasonId = setupSeasons[0].id;
  select.value = String(compSelectedSeasonId);
  await loadSeedFromSeasonOptions(compSelectedSeasonId);
  await loadCompSeasonData(compSelectedSeasonId);
  await refreshCompCalendarForSeason(compSelectedSeasonId);
}

async function onCompSeasonSelected() {
  const val = document.getElementById("compSetupSeasonSelect").value;
  compSelectedSeasonId = val ? Number(val) : null;
  if (compSelectedSeasonId) {
    await loadSeedFromSeasonOptions(compSelectedSeasonId);
    await loadCompSeasonData(compSelectedSeasonId);
    await refreshCompCalendarForSeason(compSelectedSeasonId);
  }
}

async function loadCompSeasonData(seasonId) {
  compRegistrations = await loadSeasonRegistrations(supabase, seasonId);
  renderCompAssignTable();
  updateCompSetupCounts();
}

function renderCompAssignTable() {
  const tbody = document.getElementById("compAssignBody");
  tbody.innerHTML = "";

  for (const row of compRegistrations) {
    const tr = document.createElement("tr");
    const drawn =
      row.division === "championship_a" || row.division === "championship_b";

    let divisionCell;
    if (drawn) {
      divisionCell = `<td style="padding:8px;border:1px solid #333;">${
        DIVISION_LABELS[row.division] || row.division
      }</td>`;
    } else {
      const options = SETUP_DIVISION_OPTIONS.map(
        (o) =>
          `<option value="${o.value}"${
            o.value === row.division ? " selected" : ""
          }>${o.label}</option>`
      ).join("");
      divisionCell = `<td style="padding:8px;border:1px solid #333;">
            <select data-club="${row.club_short_name}" class="comp-div-select" style="width:100%;padding:6px;background:#222;border:1px solid #444;color:#ddd;">
              ${options}
            </select>
          </td>`;
    }

    tr.innerHTML = `
          <td style="padding:8px;border:1px solid #333;">${row.club_name}</td>
          ${divisionCell}
        `;
    tbody.appendChild(tr);
  }
}

function getCompSetupCountsFromUi() {
  const byClub = new Map(
    [...document.querySelectorAll(".comp-div-select")].map((sel) => [
      sel.dataset.club,
      sel.value,
    ])
  );
  const merged = compRegistrations.map((row) =>
    byClub.has(row.club_short_name)
      ? { ...row, division: byClub.get(row.club_short_name) }
      : row
  );
  return countSetupDivisions(merged);
}

function formatDivisionCount(label, current, target) {
  let color = "#ffcc00";
  if (current === target) color = "#66cc66";
  else if (current > target) color = "#ff6666";
  return `<span style="color:${color};">${label} ${current}/${target}</span>`;
}

function formatUnassignedCount(count) {
  const color = count === 0 ? "#66cc66" : "#ff6666";
  return `<span style="color:${color};">Unassigned ${count}</span>`;
}

function updateCompSetupCounts() {
  const counts = getCompSetupCountsFromUi();
  const el = document.getElementById("compSetupCounts");
  const hasPending = document.querySelectorAll(".comp-div-select").length > 0;
  el.innerHTML =
    `${formatDivisionCount("SL", counts.superleague, 20)} · ` +
    `${formatDivisionCount("Pool", counts.championship_pool, 40)} · ` +
    `${formatDivisionCount("CH A", counts.championship_a, 20)} · ` +
    `${formatDivisionCount("CH B", counts.championship_b, 20)} · ` +
    formatUnassignedCount(counts.unassigned);
  el.title = hasPending
    ? "Live counts — includes unsaved dropdown picks (save to apply)"
    : "";
  document.getElementById("compDrawBtn").disabled = !canDrawChampionshipAb(counts);
  const ready = canActivateSeason(counts);
  const startBtn = document.getElementById("compStartSeasonBtn");
  startBtn.style.display = compSelectedSeasonId && ready ? "inline-block" : "none";
  startBtn.disabled = !ready;
  document.getElementById("compResetDrawBtn").disabled =
    counts.championship_a === 0 && counts.championship_b === 0;
}

async function seedDivisionsFromMovements() {
  if (!compSelectedSeasonId) {
    setCompStatus("Select a pre-season year.", false);
    return;
  }

  const fromSelect = document.getElementById("compSeedFromSeasonSelect");
  const fromVal = fromSelect?.value ? Number(fromSelect.value) : null;
  const fromLabel = fromVal
    ? fromSelect.options[fromSelect.selectedIndex]?.textContent || `id ${fromVal}`
    : "auto-detected prior season";

  if (
    !confirm(
      `Seed SuperLeague (20) and Championship pool (40) from ${fromLabel}?\n\nUses that season’s promotions, relegations and playoff results (applies movements if needed). Overwrites current SL / pool / A–B on this pre-season.`
    )
  ) {
    return;
  }

  setCompStatus("Seeding from source season movements…");
  const args = { p_season_id: compSelectedSeasonId };
  if (fromVal) args.p_from_season_id = fromVal;

  const { data, error } = await supabase.rpc(
    "admin_competition_seed_divisions_from_movements",
    args
  );

  if (error) {
    setCompStatus("❌ " + error.message, false);
    return;
  }

  const prev = data?.previous_season_label || data?.previous_season_id || "?";
  const appliedNote = data?.movements_applied_now
    ? " (movements applied from playoffs)"
    : "";
  setCompStatus(
    `✅ Seeded from ${prev}${appliedNote} — SL ${data?.superleague ?? 20}, pool ${data?.championship_pool ?? 40}. Draw A/B next.`
  );
  await loadSeedFromSeasonOptions(compSelectedSeasonId);
  await loadCompSeasonData(compSelectedSeasonId);
}

async function saveCompetitionAssignments() {
  if (!compSelectedSeasonId) {
    setCompStatus("Select a pre-season year.", false);
    return;
  }

  const selects = document.querySelectorAll(".comp-div-select");
  const assignments = [...selects].map((sel) => ({
    club: sel.dataset.club,
    division: sel.value,
  }));

  setCompStatus("Saving…");
  const { error } = await supabase.rpc("competition_bulk_set_divisions", {
    p_season_id: compSelectedSeasonId,
    p_assignments: assignments,
  });

  if (error) {
    setCompStatus("❌ " + error.message, false);
    return;
  }

  setCompStatus("✅ Assignments saved.");
  await loadCompSeasonData(compSelectedSeasonId);
}

async function drawCompetitionAb() {
  if (!compSelectedSeasonId) return;
  if (!confirm("Randomly split 40 pool clubs into Championship A and B?")) return;

  setCompStatus("Drawing…");
  const { data, error } = await supabase.rpc("competition_draw_championship_ab", {
    p_season_id: compSelectedSeasonId,
  });

  if (error) {
    setCompStatus("❌ " + error.message, false);
    return;
  }

  setCompStatus(`✅ Draw complete — A: ${data.championship_a}, B: ${data.championship_b}.`);
  await loadCompSeasonData(compSelectedSeasonId);
}

async function resetCompetitionDraw() {
  if (!compSelectedSeasonId) return;
  if (!confirm("Move A/B clubs back to the championship pool?")) return;

  setCompStatus("Resetting draw…");
  const { error } = await supabase.rpc("competition_reset_championship_draw", {
    p_season_id: compSelectedSeasonId,
  });

  if (error) {
    setCompStatus("❌ " + error.message, false);
    return;
  }

  setCompStatus("✅ Draw reset — clubs returned to pool.");
  await loadCompSeasonData(compSelectedSeasonId);
}

async function startCompetitionSeason() {
  if (!compSelectedSeasonId) {
    setStatus("compStartStatus", "No pre-season year selected — open Assign Divisions first.", false);
    return;
  }
  if (
    !confirm(
      "Start this season?\n\nRequires divisions (20+20+20) and the GPSL season calendar. It becomes the current live season for all owners."
    )
  ) {
    return;
  }

  setStatus("compStartStatus", "Starting season…");
  const { error } = await supabase.rpc("competition_activate_season", {
    p_season_id: compSelectedSeasonId,
  });

  if (error) {
    setStatus("compStartStatus", "❌ " + error.message, false);
    return;
  }

  setStatus("compStartStatus", "✅ Season is live.");
  setStatus("compCreateStatus", "");
  await refreshCompetitionAdmin();
  await refreshCompCalendarAdmin();
}

function anchorLocalForRpc(datetimeLocalValue) {
  if (!datetimeLocalValue) return null;
  const v =
    datetimeLocalValue.length === 16 ? `${datetimeLocalValue}:00` : datetimeLocalValue;
  return v.replace("T", " ");
}

/** Parse datetime-local as a London wall-clock instant (no TZ in string). */
function parseLocalDateTime(value) {
  if (!value) return null;
  const v = value.length === 16 ? `${value}:00` : value;
  const m = v.match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?$/);
  if (!m) return null;
  return {
    y: Number(m[1]),
    mo: Number(m[2]),
    d: Number(m[3]),
    h: Number(m[4]),
    mi: Number(m[5]),
    s: Number(m[6] || 0),
  };
}

function addDaysYmd(parts, days) {
  const dt = new Date(Date.UTC(parts.y, parts.mo - 1, parts.d + days, parts.h, parts.mi, parts.s));
  return {
    y: dt.getUTCFullYear(),
    mo: dt.getUTCMonth() + 1,
    d: dt.getUTCDate(),
    h: parts.h,
    mi: parts.mi,
    s: parts.s,
  };
}

function formatPartsLocal(parts) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${parts.y}-${pad(parts.mo)}-${pad(parts.d)}T${pad(parts.h)}:${pad(parts.mi)}`;
}

function formatPartsReadable(parts) {
  const pad = (n) => String(n).padStart(2, "0");
  const dt = new Date(Date.UTC(parts.y, parts.mo - 1, parts.d, 12, 0, 0));
  const weekday = dt.toLocaleDateString("en-GB", { weekday: "short", timeZone: "UTC" });
  return `${weekday} ${pad(parts.d)}/${pad(parts.mo)}/${parts.y} ${pad(parts.h)}:${pad(parts.mi)} UK`;
}

/** Next Friday 19:00 UK wall clock, at least `minDaysFromNow` days ahead. */
function nextFriday1900Uk(minDaysFromNow = 0) {
  const now = new Date();
  // Approximate "today" in UK for suggesting Fridays
  const uk = new Date(now.toLocaleString("en-US", { timeZone: "Europe/London" }));
  const day = uk.getDay(); // 0 Sun … 5 Fri
  let add = (5 - day + 7) % 7;
  if (add === 0 && (uk.getHours() > 19 || (uk.getHours() === 19 && uk.getMinutes() > 0))) {
    add = 7;
  }
  const target = new Date(uk);
  target.setDate(uk.getDate() + add);
  while (
    Math.floor((target - uk) / (24 * 60 * 60 * 1000)) < minDaysFromNow
  ) {
    target.setDate(target.getDate() + 7);
  }
  const pad = (n) => String(n).padStart(2, "0");
  return `${target.getFullYear()}-${pad(target.getMonth() + 1)}-${pad(target.getDate())}T19:00`;
}

function fillCalendarAnchor(value) {
  const el = document.getElementById("compCalendarAnchor");
  if (el) el.value = value;
  updateCalendarPreview();
}

function resolveSeasonStartParts() {
  return parseLocalDateTime(document.getElementById("compCalendarAnchor")?.value);
}

function updateCalendarPreview() {
  const el = document.getElementById("compCalendarPreview");
  if (!el) return;
  const june = resolveSeasonStartParts();
  if (!june) {
    el.textContent =
      "Pick season start Friday 19:00 UK = June week 1. July = +1 week. August (league) = +2 weeks. Each GPSL month is one real week.";
    return;
  }
  const july = addDaysYmd(june, 7);
  const august = addDaysYmd(june, 14);
  const ends = addDaysYmd(june, 91);
  el.innerHTML =
    `<b>Preview</b> — ` +
    `June <b>${formatPartsReadable(june)}</b> → ` +
    `July <b>${formatPartsReadable(july)}</b> → ` +
    `August <b>${formatPartsReadable(august)}</b> → … → ` +
    `ends ~${formatPartsReadable(ends)}.`;
}

async function refreshCompCalendarForSeason(seasonId) {
  const sel = document.getElementById("compCalendarSeason");
  if (!seasonId) return;
  sel.innerHTML = "";
  const { data: row } = await supabase
    .from("competition_seasons")
    .select("id, label, status")
    .eq("id", seasonId)
    .maybeSingle();
  if (row) {
    const opt = document.createElement("option");
    opt.value = String(row.id);
    opt.textContent = `${row.label} (${row.status})`;
    sel.appendChild(opt);
  }
  await loadCalendarTableForSeason(seasonId);
}

async function refreshCompCalendarAdmin() {
  const active = await loadCurrentSeason(supabase);
  const note = document.getElementById("compCalendarActiveNote");
  const calStatus = await loadCalendarStatus(supabase);

  if (active) {
    await refreshCompCalendarForSeason(active.id);
    const months = await loadSeasonCalendarMonths(supabase);
    const activeRow = months.find((m) => m.is_active);
    if (activeRow) {
      note.textContent = `Live: GPSL ${activeRow.gpsl_month_label} until ${formatUkDateTime(activeRow.lock_at)} UK.`;
    } else if (calStatus?.calendar_phase === "pre_season") {
      note.textContent =
        `Before season start — calendar begins (June) at ${formatUkDateTime(calStatus.anchor_unlock_at)} UK.`;
    } else if (calStatus?.calendar_phase === "between_months") {
      const nextLabel =
        calStatus.next_gpsl_month_label || calStatus.next_gpsl_month || "next month";
      note.textContent = `Between months — no live GPSL month. ${nextLabel} was scheduled for ${formatUkDateTime(calStatus.next_unlock_at)} UK. Use Admin → Testing → End Month Early to open the next month.`;
    } else {
      note.textContent = "Active season — configure or extend calendar below.";
    }
    updateCalendarPreview();
    return;
  }

  if (compSelectedSeasonId) {
    note.textContent =
      "Pre-season setup — set season start (June Friday 19:00 UK) before Start season.";
    await refreshCompCalendarForSeason(compSelectedSeasonId);
    updateCalendarPreview();
    return;
  }

  note.textContent = "Create a pre-season year or activate a season to manage the calendar.";
  document.getElementById("compCalendarBody").innerHTML =
    `<tr><td colspan="4" style="padding:8px;color:#888;">—</td></tr>`;
  updateCalendarPreview();
}

async function loadCalendarTableForSeason(seasonId) {
  const tbody = document.getElementById("compCalendarBody");
  const { data: months } = await supabase
    .from("competition_season_calendar_public")
    .select("*")
    .eq("season_id", seasonId)
    .order("sort_order", { ascending: true });

  if (!months?.length) {
    tbody.innerHTML = `<tr><td colspan="4" style="padding:8px;color:#888;">Not configured</td></tr>`;
    return;
  }

  tbody.innerHTML = months
    .map((m) => {
      const key = String(m.gpsl_month || "").toLowerCase();
      const pre = key === "june" || key === "july" ? " (pre-season)" : "";
      let st = "upcoming";
      if (m.is_active) st = "LIVE";
      else if (m.is_locked) st = "locked";
      return `<tr>
            <td style="padding:8px;border:1px solid #333;">${m.gpsl_month_label}${pre}</td>
            <td style="padding:8px;border:1px solid #333;">${formatUkDateTime(m.unlock_at)}</td>
            <td style="padding:8px;border:1px solid #333;">${formatUkDateTime(m.lock_at)}</td>
            <td style="padding:8px;border:1px solid #333;">${st}</td>
          </tr>`;
    })
    .join("");
}

async function setCompCalendar() {
  const seasonId = Number(document.getElementById("compCalendarSeason").value);
  const june = resolveSeasonStartParts();
  if (!seasonId || !june) {
    setStatus(
      "compCalendarStatus",
      "Pick season and season start Friday 19:00 UK (that Friday = June).",
      false
    );
    return;
  }

  const juneLocal = formatPartsLocal(june).replace("T", " ") + ":00";
  const july = addDaysYmd(june, 7);
  const august = addDaysYmd(june, 14);

  if (
    !confirm(
      `Set calendar?\n\n` +
        `Season start / June: ${formatPartsReadable(june)}\n` +
        `July: ${formatPartsReadable(july)}\n` +
        `August (league): ${formatPartsReadable(august)}\n\n` +
        `Each GPSL month = one real week.`
    )
  ) {
    return;
  }

  setStatus("compCalendarStatus", "Saving…");
  const { data, error } = await supabase.rpc("competition_admin_set_season_calendar", {
    p_season_id: seasonId,
    p_anchor_local: juneLocal.slice(0, 19),
  });
  if (error) {
    setStatus("compCalendarStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "compCalendarStatus",
    `✅ Calendar set. June ${data.june_uk || data.anchor_uk}; ` +
      `July ${data.july_uk || "?"}; August ${data.august_uk || "?"}; ends ${data.season_ends_uk}.`
  );
  await loadCalendarTableForSeason(seasonId);
  await refreshCompCalendarAdmin();
}

async function insertCompCalendarBreak() {
  const seasonId = Number(document.getElementById("compCalendarSeason").value);
  if (!seasonId) return;
  if (!confirm("Insert 1-week break? Future months shift forward by 7 days.")) return;

  setStatus("compCalendarStatus", "Inserting break…");
  const { data, error } = await supabase.rpc("competition_admin_insert_calendar_break", {
    p_season_id: seasonId,
    p_weeks: 1,
  });
  if (error) {
    setStatus("compCalendarStatus", "❌ " + error.message, false);
    return;
  }
  setStatus("compCalendarStatus", `✅ Break applied — ${data ?? 0} row(s) shifted.`);
  await loadCalendarTableForSeason(seasonId);
}

async function clearCompCalendar() {
  const seasonId = Number(document.getElementById("compCalendarSeason").value);
  if (!seasonId) return;
  if (!confirm("Clear calendar for this season?")) return;

  const { error } = await supabase.rpc("competition_admin_clear_season_calendar", {
    p_season_id: seasonId,
  });
  if (error) {
    setStatus("compCalendarStatus", "❌ " + error.message, false);
    return;
  }
  setStatus("compCalendarStatus", "✅ Calendar cleared.");
  await loadCalendarTableForSeason(seasonId);
}

async function sendMonthPreviewInbox() {
  const seasonId = Number(document.getElementById("compCalendarSeason").value) || null;
  if (!confirm("Send GPSL month fixture preview to all owners with matches this month?")) return;

  setStatus("compCalendarStatus", "Sending inbox previews…");
  const { data, error } = await supabase.rpc("owner_inbox_tick_monthly_notifications");
  if (error) {
    setStatus("compCalendarStatus", "❌ " + error.message, false);
    return;
  }
  if (data?.ok === false) {
    setStatus("compCalendarStatus", "⚠ " + (data.reason || "No active month"), false);
    return;
  }
  setStatus(
    "compCalendarStatus",
    `✅ Month ${data.gpsl_month} previews sent to ${data.notified ?? 0} club(s).`
  );
}

async function rebuildGpslSportEdition() {
  const seasonId = Number(document.getElementById("compCalendarSeason")?.value) || null;
  const gpslMonth = document.getElementById("compSportRebuildMonth")?.value?.trim() || "august";

  if (
    !confirm(
      `Rebuild GPSL Sport for ${gpslMonth}? Owners will see the edition as new again.`
    )
  ) {
    return;
  }

  setStatus("compCalendarStatus", `Rebuilding GPSL Sport (${gpslMonth})…`);

  const { data, error } = await supabase.rpc("competition_admin_regenerate_gpsl_sport", {
    p_gpsl_month: gpslMonth,
    p_season_id: seasonId || null,
  });

  if (error) {
    const hint = error.message?.includes("competition_admin_regenerate_gpsl_sport")
      ? " Run gpsl_sport_inseason_rich_edition.sql in Supabase first."
      : "";
    setStatus("compCalendarStatus", "❌ " + error.message + hint, false);
    return;
  }

  if (!data?.ok) {
    setStatus(
      "compCalendarStatus",
      "⚠ " + (data?.reason || "Sport edition was not rebuilt"),
      false
    );
    return;
  }

  setStatus(
    "compCalendarStatus",
    `✅ GPSL Sport rebuilt: ${data.edition_label || gpslMonth} (edition #${data.edition_id}). Hard-refresh the site and reopen GPSL Sport.`
  );
}
