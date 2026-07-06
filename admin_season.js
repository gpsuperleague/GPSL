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
  document.getElementById("compSetupSeasonSelect").onchange = onCompSeasonSelected;
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
  document.getElementById("compEndMonthPreviewBtn").onclick = previewEndGpslMonth;
  document.getElementById("compEndMonthBtn").onclick = endGpslMonthEarly;
  document.getElementById("compEndMonthOpenNext")?.addEventListener("change", updateEndMonthPhraseHint);

  await refreshCompetitionAdmin();
  await refreshCompCalendarAdmin();
  updateEndMonthPhraseHint();
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

  const active = await loadCurrentSeason(supabase);
  if (active) {
    const { error: rollErr } = await supabase.rpc("rollover_season");
    if (rollErr) {
      setStatus("compCreateStatus", "❌ Rollover failed: " + rollErr.message, false);
      return;
    }
    const { error: tickErr } = await supabase.rpc("contract_tick_season_rollover");
    if (tickErr) {
      const msg = String(tickErr.message || "");
      setStatus(
        "compCreateStatus",
        msg.includes("contract_tick_season_rollover")
          ? "✅ Rollover done. Run player_contracts_phase2.sql, then create the season again for contract tick."
          : "✅ Rollover done but contract tick failed: " + msg,
        false
      );
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
  setStatus("compCreateStatus", `✅ Pre-season created (id ${data}). Assign divisions below.`);
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
      error.message.includes("competition_end_season")
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
    select.innerHTML = `<option value="">No pre-season years</option>`;
    compSelectedSeasonId = null;
    compRegistrations = [];
    renderCompAssignTable();
    updateCompSetupCounts();
    startBtn.style.display = "none";
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
  await loadCompSeasonData(compSelectedSeasonId);
  await refreshCompCalendarForSeason(compSelectedSeasonId);
}

async function onCompSeasonSelected() {
  const val = document.getElementById("compSetupSeasonSelect").value;
  compSelectedSeasonId = val ? Number(val) : null;
  if (compSelectedSeasonId) {
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

  if (active) {
    await refreshCompCalendarForSeason(active.id);
    const months = await loadSeasonCalendarMonths(supabase);
    const activeRow = months.find((m) => m.is_active);
    note.textContent = activeRow
      ? `Live: GPSL ${activeRow.gpsl_month_label} until ${formatUkDateTime(activeRow.lock_at)} UK.`
      : "Active season — configure or extend calendar below.";
    return;
  }

  if (compSelectedSeasonId) {
    note.textContent = "Pre-season — set calendar before Start season.";
    await refreshCompCalendarForSeason(compSelectedSeasonId);
    return;
  }

  note.textContent = "Create a pre-season year or activate a season to manage the calendar.";
  document.getElementById("compCalendarBody").innerHTML =
    `<tr><td colspan="4" style="padding:8px;color:#888;">—</td></tr>`;
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
      let st = "upcoming";
      if (m.is_active) st = "LIVE";
      else if (m.is_locked) st = "locked";
      return `<tr>
            <td style="padding:8px;border:1px solid #333;">${m.gpsl_month_label}</td>
            <td style="padding:8px;border:1px solid #333;">${formatUkDateTime(m.unlock_at)}</td>
            <td style="padding:8px;border:1px solid #333;">${formatUkDateTime(m.lock_at)}</td>
            <td style="padding:8px;border:1px solid #333;">${st}</td>
          </tr>`;
    })
    .join("");
}

async function setCompCalendar() {
  const seasonId = Number(document.getElementById("compCalendarSeason").value);
  const anchor = anchorLocalForRpc(document.getElementById("compCalendarAnchor").value);
  if (!seasonId || !anchor) {
    setStatus("compCalendarStatus", "Pick season and anchor (Friday 19:00 UK).", false);
    return;
  }
  if (!confirm(`Set calendar?\nFirst unlock (UK): ${anchor}`)) return;

  setStatus("compCalendarStatus", "Saving…");
  const { data, error } = await supabase.rpc("competition_admin_set_season_calendar", {
    p_season_id: seasonId,
    p_anchor_local: anchor,
  });
  if (error) {
    setStatus("compCalendarStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "compCalendarStatus",
    `✅ Calendar set. Anchor ${data.anchor_uk}; ends ${data.season_ends_uk}.`
  );
  await loadCalendarTableForSeason(seasonId);
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

function endMonthOpenNextChecked() {
  return Boolean(document.getElementById("compEndMonthOpenNext")?.checked);
}

function endMonthConfirmPhrase(openNext) {
  return openNext ? "END MONTH OPEN NEXT" : "END GPSL MONTH";
}

function updateEndMonthPhraseHint() {
  const input = document.getElementById("compEndMonthPhrase");
  if (!input) return;
  input.placeholder = `Type: ${endMonthConfirmPhrase(endMonthOpenNextChecked())}`;
}

function renderEndMonthPreview(data) {
  const el = document.getElementById("compEndMonthPreview");
  if (!el) return;

  if (!data?.ok) {
    el.hidden = false;
    el.innerHTML = `⚠ ${data?.reason || "Cannot preview end month."}`;
    return;
  }

  const openNext = Boolean(data.unlock_next_month);
  let nextLine = "";
  if (openNext && data.next_gpsl_month_label) {
    nextLine = `<br><b>+ Open ${data.next_gpsl_month_label} now</b> — pulls ${data.calendar_months_shifted ?? 0} month(s) forward (was ${formatUkDateTime(data.next_scheduled_unlock_at)} UK).`;
  }

  el.hidden = false;
  el.innerHTML = `
    <b>${data.gpsl_month_label || data.gpsl_month}</b>
    · scheduled lock ${formatUkDateTime(data.lock_at)} UK
    · unplayed league <b>${data.unplayed_league ?? 0}</b>
    · unplayed cup <b>${data.unplayed_cup ?? 0}</b>
    · pending submissions <b>${data.pending_submissions ?? 0}</b>
    ${nextLine}
    <br>Phrase: <code>${data.confirm_phrase || endMonthConfirmPhrase(openNext)}</code>
    · Jobs: TOTM, GPSL Sport, scheduling fines, check-in forfeits, loan installments.
  `;
  updateEndMonthPhraseHint();
}

async function previewEndGpslMonth() {
  const seasonId = Number(document.getElementById("compCalendarSeason").value) || null;
  const openNext = endMonthOpenNextChecked();
  setStatus("compCalendarStatus", "Loading end-month preview…");

  const { data, error } = await supabase.rpc("competition_admin_end_gpsl_month_preview", {
    p_gpsl_month: null,
    p_season_id: seasonId || null,
    p_unlock_next_month: openNext,
  });

  if (error) {
    setStatus("compCalendarStatus", "❌ " + error.message, false);
    return;
  }

  renderEndMonthPreview(data);

  if (!data?.ok) {
    setStatus("compCalendarStatus", "⚠ " + (data.reason || "No live GPSL month"), false);
    return;
  }

  const nextBit = openNext && data.next_gpsl_month_label
    ? ` → open ${data.next_gpsl_month_label} now`
    : "";
  setStatus(
    "compCalendarStatus",
    `Preview: end ${data.gpsl_month_label}${nextBit} (${data.unplayed_league ?? 0} unplayed league, ${data.unplayed_cup ?? 0} cup).`
  );
}

async function endGpslMonthEarly() {
  const seasonId = Number(document.getElementById("compCalendarSeason").value) || null;
  const openNext = endMonthOpenNextChecked();
  const requiredPhrase = endMonthConfirmPhrase(openNext);
  const phrase = document.getElementById("compEndMonthPhrase")?.value?.trim() || "";

  const { data: preview, error: previewErr } = await supabase.rpc(
    "competition_admin_end_gpsl_month_preview",
    { p_gpsl_month: null, p_season_id: seasonId || null, p_unlock_next_month: openNext }
  );

  if (previewErr) {
    setStatus("compCalendarStatus", "❌ " + previewErr.message, false);
    return;
  }

  if (!preview?.ok) {
    renderEndMonthPreview(preview);
    setStatus("compCalendarStatus", "⚠ " + (preview?.reason || "No live GPSL month"), false);
    return;
  }

  const msg = [
    `End GPSL ${preview.gpsl_month_label} now?`,
    "",
    `Scheduled lock: ${formatUkDateTime(preview.lock_at)} UK`,
    `Unplayed: ${preview.unplayed_league ?? 0} league, ${preview.unplayed_cup ?? 0} cup`,
    `Pending submissions: ${preview.pending_submissions ?? 0}`,
    "",
    openNext && preview.next_gpsl_month_label
      ? `Also open ${preview.next_gpsl_month_label} now and pull ${preview.calendar_months_shifted ?? 0} future month(s) forward.`
      : "Next month stays on its scheduled unlock date (gap until then).",
    "",
    "Runs month-lock jobs (fines, TOTM, GPSL Sport, etc.).",
  ].join("\n");

  if (!confirm(msg)) return;

  if (phrase !== requiredPhrase) {
    setStatus("compCalendarStatus", `Type exactly: ${requiredPhrase}`, false);
    return;
  }

  setStatus("compCalendarStatus", openNext
    ? "Ending month, running lock jobs, opening next month…"
    : "Ending month and running lock jobs…");

  const { data, error } = await supabase.rpc("competition_admin_end_gpsl_month_early", {
    p_confirm_phrase: phrase,
    p_gpsl_month: null,
    p_season_id: seasonId || null,
    p_unlock_next_month: openNext,
  });

  if (error) {
    setStatus("compCalendarStatus", "❌ " + error.message, false);
    return;
  }

  if (!data?.ended) {
    renderEndMonthPreview(data);
    setStatus("compCalendarStatus", "⚠ " + (data?.reason || "Month was not ended"), false);
    return;
  }

  document.getElementById("compEndMonthPhrase").value = "";
  renderEndMonthPreview(data);

  const totm = data.month_lock_jobs?.team_of_month?.processed;
  const sport = data.month_lock_jobs?.gpsl_sport?.processed;
  const totmCount = Array.isArray(totm) ? totm.length : 0;
  const sportCount = Array.isArray(sport) ? sport.length : 0;
  const activeAfter = data.active_gpsl_month_after;
  const pull = data.calendar_pull_forward;

  let statusMsg = `✅ ${data.gpsl_month_label} locked early. TOTM: ${totmCount}, GPSL Sport: ${sportCount}.`;
  if (openNext && pull?.ok) {
    statusMsg += ` ${pull.next_gpsl_month_label} is live until ${formatUkDateTime(pull.next_lock_at)} UK.`;
  } else if (activeAfter) {
    statusMsg += ` Active month: ${activeAfter}.`;
  }

  setStatus("compCalendarStatus", statusMsg);

  if (seasonId) {
    await loadCalendarTableForSeason(seasonId);
  } else {
    await refreshCompCalendarAdmin();
  }
}
