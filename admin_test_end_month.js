import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { loadCalendarStatus, formatUkDateTime } from "./competition_calendar.js";

primeAdminPageChrome();

function selectedSeasonId() {
  return Number(document.getElementById("seasonSelect")?.value) || null;
}

function endMonthOpenNextChecked() {
  return Boolean(document.getElementById("openNextCheck")?.checked);
}

function endMonthConfirmPhrase(openNext) {
  return openNext ? "END MONTH OPEN NEXT" : "END GPSL MONTH";
}

function updateEndMonthPhraseHint() {
  const input = document.getElementById("endMonthPhrase");
  if (!input) return;
  input.placeholder = `Type: ${endMonthConfirmPhrase(endMonthOpenNextChecked())}`;
}

function calendarGapReasonMessage(reason) {
  if (reason === "between_months") {
    return "Between GPSL months — open the next month below.";
  }
  if (reason === "no_active_season") {
    return "No active competition season found (status must be active).";
  }
  if (reason === "no_active_month") {
    return "No live GPSL month.";
  }
  return reason || "Calendar unavailable.";
}

async function loadSeasons() {
  const sel = document.getElementById("seasonSelect");
  const { data, error } = await supabase
    .from("competition_seasons")
    .select("id, label, status, is_current")
    .order("id", { ascending: false });

  if (error) {
    setStatus("endMonthStatus", "❌ " + error.message, false);
    return;
  }

  const rows = data || [];
  sel.innerHTML = rows
    .map((s) => {
      const mark = s.is_current ? " (current)" : "";
      return `<option value="${s.id}">${s.label || `Season ${s.id}`} — ${s.status}${mark}</option>`;
    })
    .join("");

  const current = rows.find((s) => s.is_current) || rows.find((s) => s.status === "active");
  if (current) sel.value = String(current.id);
}

async function loadCalendarTable() {
  const seasonId = selectedSeasonId();
  const tbody = document.getElementById("calendarBody");
  const note = document.getElementById("calendarNote");

  if (!seasonId) {
    tbody.innerHTML = `<tr><td colspan="4" style="color:#888;">No season selected</td></tr>`;
    note.textContent = "Select a season.";
    return;
  }

  const { data: months, error } = await supabase
    .from("competition_season_calendar_public")
    .select("*")
    .eq("season_id", seasonId)
    .order("sort_order", { ascending: true });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="4" style="color:#c88;">${error.message}</td></tr>`;
    return;
  }

  if (!months?.length) {
    tbody.innerHTML = `<tr><td colspan="4" style="color:#888;">Calendar not configured</td></tr>`;
    note.textContent = "No calendar months for this season.";
    return;
  }

  tbody.innerHTML = months
    .map((m) => {
      let st = "upcoming";
      let cls = "";
      if (m.is_active) {
        st = "LIVE";
        cls = "live-cell";
      } else if (m.is_locked) {
        st = "locked";
        cls = "locked-cell";
      }
      return `<tr>
        <td>${m.gpsl_month_label}</td>
        <td>${formatUkDateTime(m.unlock_at)}</td>
        <td>${formatUkDateTime(m.lock_at)}</td>
        <td class="${cls}">${st}</td>
      </tr>`;
    })
    .join("");

  const calStatus = await loadCalendarStatus(supabase);
  const active = months.find((m) => m.is_active);
  if (active) {
    note.textContent = `Live: GPSL ${active.gpsl_month_label} until ${formatUkDateTime(active.lock_at)} UK.`;
  } else if (calStatus?.calendar_phase === "between_months") {
    const nextLabel =
      calStatus.next_gpsl_month_label || calStatus.next_gpsl_month || "next month";
    note.textContent = `Between months — no live GPSL month. ${nextLabel} was scheduled for ${formatUkDateTime(calStatus.next_unlock_at)} UK.`;
  } else {
    note.textContent = "No live GPSL month right now.";
  }

  await refreshBetweenMonthsPanel(seasonId);
}

async function refreshBetweenMonthsPanel(seasonId) {
  const card = document.getElementById("betweenMonthsCard");
  if (!card) return;

  const { data, error } = await supabase.rpc("competition_admin_open_next_gpsl_month_preview", {
    p_season_id: seasonId || null,
  });

  if (error) {
    card.hidden = true;
    return;
  }

  const show = data?.ok && data?.reason === "between_months";
  card.hidden = !show;
  if (show) renderOpenNextPreview(data);
}

function renderOpenNextPreview(data) {
  const el = document.getElementById("openNextPreview");
  if (!el) return;

  if (!data?.ok) {
    el.hidden = false;
    el.innerHTML = `⚠ ${calendarGapReasonMessage(data?.reason)}`;
    return;
  }

  el.hidden = false;
  el.innerHTML = `
    <b>${data.last_locked_month_label || data.last_locked_month}</b> is locked.
    Open <b>${data.next_gpsl_month_label || data.next_gpsl_month}</b> now
    (was scheduled ${formatUkDateTime(data.next_scheduled_unlock_at)} UK;
    pulls ${data.calendar_months_shifted ?? 0} month(s) forward).
    <br>Phrase: <code>${data.confirm_phrase || "OPEN GPSL MONTH"}</code>
  `;
}

function renderEndMonthPreview(data) {
  const el = document.getElementById("endMonthPreview");
  if (!el) return;

  if (!data?.ok) {
    el.hidden = false;
    if (data?.reason === "between_months") {
      el.innerHTML = `
        ⚠ Between GPSL months — <b>${data.last_locked_month_label || data.last_locked_month}</b> is locked and
        <b>${data.next_gpsl_month_label || data.next_gpsl_month}</b> is not open yet
        (scheduled ${formatUkDateTime(data.next_scheduled_unlock_at)} UK).
        Use <b>Open next GPSL month</b> below instead of ending a month again.
      `;
      return;
    }
    el.innerHTML = `⚠ ${calendarGapReasonMessage(data?.reason)}`;
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
  const seasonId = selectedSeasonId();
  const openNext = endMonthOpenNextChecked();
  setStatus("endMonthStatus", "Loading end-month preview…");

  const { data, error } = await supabase.rpc("competition_admin_end_gpsl_month_preview", {
    p_gpsl_month: null,
    p_season_id: seasonId || null,
    p_unlock_next_month: openNext,
  });

  if (error) {
    const missing = /competition_admin_end_gpsl_month/i.test(error.message || "");
    setStatus(
      "endMonthStatus",
      missing
        ? "❌ Run supabase/sql/patches/competition_admin_end_gpsl_month.sql in Supabase, then retry."
        : "❌ " + error.message,
      false
    );
    return;
  }

  renderEndMonthPreview(data);

  if (!data?.ok) {
    setStatus("endMonthStatus", "⚠ " + calendarGapReasonMessage(data.reason), false);
    return;
  }

  const nextBit =
    openNext && data.next_gpsl_month_label ? ` → open ${data.next_gpsl_month_label} now` : "";
  setStatus(
    "endMonthStatus",
    `Preview: end ${data.gpsl_month_label}${nextBit} (${data.unplayed_league ?? 0} unplayed league, ${data.unplayed_cup ?? 0} cup).`
  );
}

async function endGpslMonthEarly() {
  const seasonId = selectedSeasonId();
  const openNext = endMonthOpenNextChecked();
  const requiredPhrase = endMonthConfirmPhrase(openNext);
  const phrase = document.getElementById("endMonthPhrase")?.value?.trim() || "";

  const { data: preview, error: previewErr } = await supabase.rpc(
    "competition_admin_end_gpsl_month_preview",
    { p_gpsl_month: null, p_season_id: seasonId || null, p_unlock_next_month: openNext }
  );

  if (previewErr) {
    setStatus("endMonthStatus", "❌ " + previewErr.message, false);
    return;
  }

  if (!preview?.ok) {
    renderEndMonthPreview(preview);
    setStatus("endMonthStatus", "⚠ " + calendarGapReasonMessage(preview?.reason), false);
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
    setStatus("endMonthStatus", `Type exactly: ${requiredPhrase}`, false);
    return;
  }

  setStatus(
    "endMonthStatus",
    openNext
      ? "Ending month, running lock jobs, opening next month…"
      : "Ending month and running lock jobs…"
  );

  const { data, error } = await supabase.rpc("competition_admin_end_gpsl_month_early", {
    p_confirm_phrase: phrase,
    p_gpsl_month: null,
    p_season_id: seasonId || null,
    p_unlock_next_month: openNext,
  });

  if (error) {
    setStatus("endMonthStatus", "❌ " + error.message, false);
    return;
  }

  if (!data?.ended) {
    renderEndMonthPreview(data);
    setStatus("endMonthStatus", "⚠ " + (data?.reason || "Month was not ended"), false);
    return;
  }

  document.getElementById("endMonthPhrase").value = "";
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

  setStatus("endMonthStatus", statusMsg);
  await loadCalendarTable();
}

async function previewOpenNextGpslMonth() {
  const seasonId = selectedSeasonId();
  setStatus("openNextStatus", "Loading open-next preview…");

  const { data, error } = await supabase.rpc("competition_admin_open_next_gpsl_month_preview", {
    p_season_id: seasonId || null,
  });

  if (error) {
    const missing = error.message.includes("competition_admin_open_next_gpsl_month_preview");
    setStatus(
      "openNextStatus",
      missing
        ? "❌ Run supabase/sql/patches/competition_admin_calendar_gap_recovery.sql in Supabase, then retry."
        : "❌ " + error.message,
      false
    );
    return;
  }

  renderOpenNextPreview(data);

  if (!data?.ok) {
    setStatus("openNextStatus", "⚠ " + calendarGapReasonMessage(data?.reason), false);
    return;
  }

  setStatus(
    "openNextStatus",
    `Preview: open ${data.next_gpsl_month_label} now (after ${data.last_locked_month_label}).`
  );
}

async function openNextGpslMonth() {
  const seasonId = selectedSeasonId();
  const phrase = document.getElementById("openNextPhrase")?.value?.trim() || "";

  const { data: preview, error: previewErr } = await supabase.rpc(
    "competition_admin_open_next_gpsl_month_preview",
    { p_season_id: seasonId || null }
  );

  if (previewErr) {
    setStatus("openNextStatus", "❌ " + previewErr.message, false);
    return;
  }

  if (!preview?.ok) {
    renderOpenNextPreview(preview);
    setStatus("openNextStatus", "⚠ " + calendarGapReasonMessage(preview?.reason), false);
    return;
  }

  const msg = [
    `Open GPSL ${preview.next_gpsl_month_label} now?`,
    "",
    `After locking ${preview.last_locked_month_label}, the league is between months.`,
    `Scheduled unlock was ${formatUkDateTime(preview.next_scheduled_unlock_at)} UK.`,
    `This pulls ${preview.calendar_months_shifted ?? 0} future month(s) forward.`,
  ].join("\n");

  if (!confirm(msg)) return;

  if (phrase !== "OPEN GPSL MONTH") {
    setStatus("openNextStatus", "Type exactly: OPEN GPSL MONTH", false);
    return;
  }

  setStatus("openNextStatus", "Opening next GPSL month…");

  const { data, error } = await supabase.rpc("competition_admin_open_next_gpsl_month", {
    p_confirm_phrase: phrase,
    p_season_id: seasonId || null,
  });

  if (error) {
    setStatus("openNextStatus", "❌ " + error.message, false);
    return;
  }

  if (!data?.opened) {
    renderOpenNextPreview(data);
    setStatus("openNextStatus", "⚠ " + calendarGapReasonMessage(data?.reason), false);
    return;
  }

  document.getElementById("openNextPhrase").value = "";
  renderOpenNextPreview(data);
  const activeAfter = data.active_gpsl_month_after;
  setStatus(
    "openNextStatus",
    `✅ Opened ${preview.next_gpsl_month_label}.${activeAfter ? ` Active month: ${activeAfter}.` : ""}`
  );
  await loadCalendarTable();
}

async function refreshAll() {
  await loadCalendarTable();
  setStatus("endMonthStatus", "Calendar refreshed.");
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("refreshBtn").onclick = refreshAll;
  document.getElementById("seasonSelect").onchange = loadCalendarTable;
  document.getElementById("openNextCheck")?.addEventListener("change", updateEndMonthPhraseHint);
  document.getElementById("previewEndBtn").onclick = previewEndGpslMonth;
  document.getElementById("endMonthBtn").onclick = endGpslMonthEarly;
  document.getElementById("previewOpenNextBtn").onclick = previewOpenNextGpslMonth;
  document.getElementById("openNextBtn").onclick = openNextGpslMonth;

  updateEndMonthPhraseHint();
  await loadSeasons();
  await loadCalendarTable();
});
