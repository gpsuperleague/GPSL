import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js?v=20260807-archive-inbox-types";
import {
  renderAdminSidebarHtml,
  wireAdminSidebarNav,
} from "./admin_main_nav.js?v=20260807-prizes-in-create";
import { renderAdminSeasonCreateRules } from "./admin_season_create_rules.js?v=20260807-create-season-rules";

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

/** Sidebar mirrors live Admin mega sections for season workflow. */
const SEASON_SIDEBAR_SECTIONS = [
  "create_season",
  "pre_season",
  "season_management",
  "season_checklist",
  "close_season",
  "end_of_season",
];

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
  root.innerHTML = renderAdminSidebarHtml(SEASON_SIDEBAR_SECTIONS, pathname, search);
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

  wireAdminSidebarNav(root);

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
  renderAdminSeasonCreateRules();

  document.getElementById("compCreateNextBtn").onclick = createNextSeason;
  document.getElementById("compTickContractsBtn").onclick = tickContractsOnly;
  document.getElementById("compEndSeasonBtn").onclick = endCurrentSeason;
  document.getElementById("compArchiveSeasonBtn").onclick = archiveSeasonStats;
  document.getElementById("compManagerSeasonEndBtn").onclick = processManagerSeasonEnd;
  const renewDeadlineBtn = document.getElementById("compManagerRenewalDeadlineBtn");
  if (renewDeadlineBtn) {
    renewDeadlineBtn.onclick = processManagerRenewalDeadline;
  }
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
  document.getElementById("compCalendarSuggestTonightBtn").onclick = () =>
    fillCalendarAnchor(tonight1900Uk());
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

async function tickContractsOnly() {
  if (
    !confirm(
      "Tick all PLAYER contracts now?\n\nDecrements multi-year deals, resolves expiry wage bids, and releases players with 0 seasons left (MV to holding club).\n\nManagers are separate: Close season → Process manager contracts (or SQL catch-up)."
    )
  ) {
    return;
  }

  setStatus("compCreateStatus", "Ticking player contracts…");
  // Prefer catch-up wrapper (logs tick) when deployed; fall back to raw tick.
  let { data, error } = await supabase.rpc("admin_catchup_player_contract_tick", {
    p_force: false,
  });
  if (error?.message?.includes("admin_catchup_player_contract_tick")) {
    ({ data, error } = await supabase.rpc("contract_tick_season_rollover"));
  }

  if (error) {
    setStatus(
      "compCreateStatus",
      `❌ ${error.message}${
        /timeout|canceling statement/i.test(error.message || "")
          ? " — run in SQL Editor: SELECT public.admin_catchup_player_contract_tick(); (after season_contract_tick_catchup.sql)"
          : ""
      }`,
      false
    );
    return;
  }

  if (data?.ok === false && data?.reason === "already_ticked") {
    setStatus(
      "compCreateStatus",
      `⚠ Player tick already logged for ${data.for_season_label || "this season"}. Check SELECT public.admin_season_contract_tick_status(); before forcing.`,
      false
    );
    return;
  }

  const tick = data?.tick || data;
  setStatus(
    "compCreateStatus",
    `✅ Player contracts ticked — ${tick?.players_decremented ?? "—"} decremented, ${
      tick?.players_released_zero_years ?? "—"
    } released, ${tick?.players_final_year ?? "—"} now final-year (expiring market).`,
    true
  );
}

async function createNextSeason() {
  const label = document.getElementById("compSeasonLabel").value.trim();
  if (!label) {
    setStatus("compCreateStatus", "Enter a season label.", false);
    return;
  }

  if (
    !confirm(
      `Create competition season “${label}” in pre-season?\n\nThis will automatically:\n• create the pre-season\n• tick PLAYER contracts (decrement / expiry market)\n• catch up MANAGER season-end if that was skipped when ending the prior season`
    )
  ) {
    return;
  }

  setStatus("compCreateStatus", "Creating pre-season + ticking contracts…");

  const active = await loadCurrentSeason(supabase);
  if (active) {
    const { error: rollErr } = await supabase.rpc("rollover_season");
    if (rollErr) {
      setStatus("compCreateStatus", "❌ Rollover failed: " + rollErr.message, false);
      return;
    }
  }

  // Preferred: one RPC (create + player tick + manager safety-net)
  let { data, error } = await supabase.rpc("competition_create_season_full", {
    p_label: label,
  });

  // Fallback if full RPC not deployed yet
  if (error?.message?.includes("competition_create_season_full")) {
    const created = await supabase.rpc("competition_create_season", {
      p_label: label,
    });
    if (created.error) {
      setStatus(
        "compCreateStatus",
        `❌ ${created.error.message} — run patches/season_rollover_auto_contracts.sql`,
        false
      );
      return;
    }
    const tick = await supabase.rpc("admin_catchup_player_contract_tick", {
      p_force: false,
    });
    const tickFallback =
      tick.error?.message?.includes("admin_catchup_player_contract_tick")
        ? await supabase.rpc("contract_tick_season_rollover")
        : tick;
    if (tickFallback.error) {
      setStatus(
        "compCreateStatus",
        `✅ Season created (id ${created.data}) but PLAYER tick failed: ${tickFallback.error.message}. Run Tick contracts / SQL catch-up before go-live.`,
        false
      );
      await refreshCompetitionAdmin();
      return;
    }
    data = {
      ok: true,
      season_id: created.data,
      player_tick: tickFallback.data?.tick || tickFallback.data,
      manager_catchup: null,
    };
    error = null;
  }

  if (error) {
    setStatus(
      "compCreateStatus",
      `❌ ${error.message}${
        /timeout|canceling statement/i.test(error.message || "")
          ? " — run in SQL Editor: SELECT public.competition_create_season_full('…'); after season_rollover_auto_contracts.sql"
          : error.message?.includes("player_assign_to_club")
            ? " — run patches/player_assign_to_club_overload_fix.sql, then retry (or Tick contracts catch-up if season row exists)"
            : /foreign contract lock|paid-up overflow lock/i.test(error.message || "")
              ? " — run patches/foreign_lock_preseason_fallback.sql, then retry (or Tick contracts catch-up if season row exists)"
              : /DELETE requires a WHERE clause/i.test(error.message || "")
                ? " — run patches/contract_release_delete_where_fix.sql, then retry (or Tick contracts catch-up if season row exists)"
                : " — run patches/contract_tick_fa_before_contested.sql (+ foreign_lock / assign overload / delete-where fixes if needed), then retry"
      }`,
      false
    );
    return;
  }

  const seasonId = data?.season_id ?? data;
  const tick = data?.player_tick || {};
  const mgr = data?.manager_catchup;
  const mgrNote =
    mgr == null
      ? ""
      : mgr.skipped || mgr.reason === "already_processed"
        ? " Managers already processed for prior season."
        : mgr.ok === false
          ? ` Manager catch-up: ${mgr.reason || "failed"} — run admin_catchup_manager_season_end(NULL).`
          : ` Managers caught up for prior season.`;

  document.getElementById("compSeasonLabel").value = "";
  setStatus(
    "compCreateStatus",
    `✅ Pre-season created (id ${seasonId}). Players: ${
      tick?.players_decremented ?? "—"
    } decremented, ${tick?.players_final_year ?? "—"} final-year, ${
      tick?.players_released_zero_years ?? "—"
    } released.${mgrNote}`,
    !(mgr && mgr.ok === false)
  );

  await refreshCompetitionAdmin();
  if (seasonId) {
    document.getElementById("compSetupSeasonSelect").value = String(seasonId);
    compSelectedSeasonId = seasonId;
    await loadCompSeasonData(seasonId);
    await refreshCompCalendarForSeason(seasonId);
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

  // Archive stats/awards first (own timeout). Inbox + underperformance run as a
  // second RPC so a slow follow-up cannot roll back a successful archive.
  setStatus("compArchiveStatus", "Archiving season stats & awards…");
  let { data, error } = await supabase.rpc("competition_admin_archive_season", {
    p_season_id: null,
  });

  if (error) {
    setStatus(
      "compArchiveStatus",
      error.message.includes("statement timeout")
        ? "❌ Timed out. Run supabase/sql/patches/archive_season_statement_timeout_fix.sql in Supabase SQL Editor, then retry."
        : error.message.includes("competition_admin_archive_season")
          ? "❌ Run supabase/sql/patches/archive_season_statement_timeout_fix.sql (or competition_history.sql) in Supabase, then retry."
          : "❌ " + error.message,
      false
    );
    return;
  }

  const seasonId = data?.season_id;
  let followNote = "";
  let followWarn = false;
  if (seasonId != null) {
    setStatus("compArchiveStatus", "Archive saved — running inbox & underperformance…");
    const { data: followData, error: followErr } = await supabase.rpc(
      "competition_admin_archive_season_followup",
      { p_season_id: seasonId }
    );
    if (followErr?.message?.includes("competition_admin_archive_season_followup")) {
      followWarn = true;
      followNote =
        " ⚠ Inbox/underperformance skipped — re-run archive_season_statement_timeout_fix.sql.";
    } else if (followErr) {
      followWarn = true;
      followNote = followErr.message.includes("message_type_check")
        ? " ⚠ Inbox blocked (message_type check) — re-run archive_season_statement_timeout_fix.sql (or archive_season_inbox_message_types_fix.sql), then Archive again (safe)."
        : ` ⚠ Inbox/underperformance: ${followErr.message}`;
    } else if (followData?.inbox_error || followData?.underperformance_error) {
      followWarn = true;
      const bits = [];
      if (followData.inbox_error) {
        bits.push(
          followData.inbox_error.includes("message_type_check")
            ? "inbox types — re-run archive_season_statement_timeout_fix.sql then Archive again"
            : `inbox: ${followData.inbox_error}`
        );
      }
      if (followData.underperformance_error) {
        bits.push(`underperformance: ${followData.underperformance_error}`);
      }
      followNote = ` ⚠ ${bits.join("; ")}.`;
    } else {
      const triggered = followData?.underperformance?.triggered_count;
      followNote =
        triggered != null
          ? ` Inbox notified. Underperformance triggers: ${triggered}.`
          : " Inbox/underperformance done.";
    }
  }

  let rankNote = "";
  let rankWarn = false;
  if (seasonId != null) {
    const { error: rankErr } = await supabase.rpc(
      "competition_owner_ranking_recompute_season",
      { p_season_id: seasonId }
    );
    if (rankErr) {
      rankWarn = true;
      rankNote = ` ⚠ Owner ranking not updated (${rankErr.message}).`;
    } else {
      rankNote = " Owner ranking updated.";
    }

    const { error: clubRankErr } = await supabase.rpc(
      "competition_club_ranking_recompute_season",
      { p_season_id: seasonId }
    );
    if (clubRankErr) {
      rankWarn = true;
      rankNote += ` ⚠ Club ranking not updated (${clubRankErr.message}).`;
    } else {
      rankNote += " Club ranking updated.";
    }
  }

  // Archive itself succeeded — never paint full red for a follow-up-only issue
  setStatus(
    "compArchiveStatus",
    `✅ Archived ${data?.season_label || "season"} — ${data?.clubs_archived ?? 0} clubs, ${data?.players_archived ?? 0} players, ${data?.cups_archived ?? 0} cups.${followNote}${rankNote}`,
    followWarn || rankWarn ? "warn" : true
  );
}

async function processManagerRenewalDeadline() {
  if (
    !confirm(
      "Process manager renewal deadline?\n\nReleases managers still awaiting owner renewal once July has ended / August has started (club receives market value). Safe to re-run."
    )
  ) {
    return;
  }

  setStatus("compManagerRenewalDeadlineStatus", "Processing renewal deadline…");
  const { data, error } = await supabase.rpc(
    "manager_process_pending_renewal_deadline"
  );

  if (error) {
    setStatus(
      "compManagerRenewalDeadlineStatus",
      error.message.includes("manager_process_pending_renewal_deadline")
        ? "❌ Run manager_renewal_august_deadline.sql in Supabase, then retry."
        : "❌ " + error.message,
      false
    );
    return;
  }

  if (data?.skipped) {
    setStatus(
      "compManagerRenewalDeadlineStatus",
      `⏭ Skipped — renewal window still open (${data.active_gpsl_month || data.locked_gpsl_month || "month unknown"}). Deadline fires at end of July / start of August.`,
      true
    );
    return;
  }

  const released = Number(data?.released || 0);
  setStatus(
    "compManagerRenewalDeadlineStatus",
    `✅ Renewal deadline done — ${released} manager(s) released for MV.`,
    true
  );
}

async function processManagerSeasonEnd() {
  if (
    !confirm(
      "Process manager contracts for season end?\n\nTicks mid-deal seasons; at deal end offers owner renewal if they hit ≥1 target, or releases for MV with a 2-season rehire ban if they missed both. Unrenewed pending renewals from the start of August are also released for MV."
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
    `✅ ${data?.label || "Season"} ended — league phase: Summer Break.${
      data?.next_season_id
        ? " Admin checklist now follows the next preseason/setup season (blank ticks)."
        : " Create Pre-Season next — checklist will start blank for that season."
    }`
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
  const startStatus = document.getElementById("compStartStatus");
  if (!compSelectedSeasonId) {
    startBtn.style.display = "none";
    startBtn.disabled = true;
  } else {
    startBtn.style.display = "inline-block";
    startBtn.disabled = !ready;
    if (!ready && startStatus && !/Starting season|✅|❌/.test(startStatus.textContent || "")) {
      setStatus(
        "compStartStatus",
        `Not ready yet — need SL 20, CH A 20, CH B 20 (now SL ${counts.superleague}, A ${counts.championship_a}, B ${counts.championship_b}). Draw A/B after seeding the pool, set the calendar, then Start.`,
        false
      );
    } else if (ready && startStatus && /Not ready yet/.test(startStatus.textContent || "")) {
      setStatus(
        "compStartStatus",
        "Divisions look ready (20+20+20). Set the GPSL calendar if needed, then Start season (go live).",
        true
      );
    }
  }
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
    const detail = [error.message, error.details, error.hint].filter(Boolean).join(" — ");
    setCompStatus(
      `❌ ${detail}${
        /auto_rel|auto_pro|incomplete_table|invalid counts|standings/i.test(detail)
          ? " — re-run patches/seed_divisions_standings_any_season_fix.sql then retry."
          : ""
      }`,
      false
    );
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

/** Tonight 19:00 UK wall clock (for testing mid-week starts). */
function tonight1900Uk() {
  const now = new Date();
  const uk = new Date(now.toLocaleString("en-US", { timeZone: "Europe/London" }));
  const pad = (n) => String(n).padStart(2, "0");
  return `${uk.getFullYear()}-${pad(uk.getMonth() + 1)}-${pad(uk.getDate())}T19:00`;
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
  const allowAny = !!document.getElementById("compCalendarAllowAnyWeekday")?.checked;
  if (!seasonId || !june) {
    setStatus(
      "compCalendarStatus",
      "Pick season and season start 19:00 UK (that moment = June week 1).",
      false
    );
    return;
  }

  if (!allowAny) {
    const dt = new Date(Date.UTC(june.y, june.mo - 1, june.d, 12, 0, 0));
    const weekday = dt.getUTCDay(); // 5 = Friday
    if (weekday !== 5) {
      setStatus(
        "compCalendarStatus",
        "Not a Friday — tick “Allow any weekday (testing)” or use Next Friday 19:00.",
        false
      );
      return;
    }
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
        (allowAny
          ? `TESTING: any-weekday override is on.\n\n`
          : "") +
        `Each GPSL month = one real week.`
    )
  ) {
    return;
  }

  setStatus("compCalendarStatus", "Saving…");
  const { data, error } = await supabase.rpc("competition_admin_set_season_calendar", {
    p_season_id: seasonId,
    p_anchor_local: juneLocal.length >= 19 ? juneLocal.slice(0, 19) : juneLocal,
    p_allow_any_weekday: allowAny,
  });
  if (error) {
    const detail = [error.message, error.details, error.hint].filter(Boolean).join(" — ");
    setStatus(
      "compCalendarStatus",
      `❌ ${detail}${
        /Friday|weekday/i.test(detail)
          ? " — tick “Allow any weekday (testing)” or run patches/calendar_allow_any_weekday_testing.sql."
          : /check constraint|gpsl_month|sort_order|Could not find/i.test(detail)
            ? " — run patches/calendar_allow_any_weekday_testing.sql then retry."
            : ""
      }`,
      false
    );
    return;
  }
  setStatus(
    "compCalendarStatus",
    `✅ Calendar set${data?.allow_any_weekday ? " (testing weekday override)" : ""}. ` +
      `June ${data.june_uk || data.anchor_uk}; ` +
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
