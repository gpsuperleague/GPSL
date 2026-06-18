import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  parsePesdbCsvToStagingRows,
  chunkRows,
  enrichRowsWithEconomics,
  dedupeRowsByKonamiId,
} from "./gpdb_pesdb_import.js";

primeAdminPageChrome();

const CONFIRM_TEXT = "SYNC GPDB";
const SCRAPE_FUNCTION = "gpdb-pesdb-scrape";
const SCRAPE_PACE = "chunked";
const PROGRESS_KEY = "gpdb_pesdb_scrape_progress";
const LAST_APPLY_KEY = "gpdb_pesdb_last_apply";
let scrapeAbort = false;
let scrapeRunning = false;
let liveTimerId = null;
let lastAuditRows = [];
let lastPreviewResult = null;

const PREVIEW_ACTION_ORDER = {
  mark_unavailable: 1,
  already_unavailable: 2,
  restore_and_update: 3,
  update_stats: 4,
  update_mv: 5,
  insert_free_agent: 6,
  unchanged: 99,
};

const PREVIEW_TABLE_LIMIT = 500;
const APPLY_BATCH_SIZE = 800;

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function setPlayerLabel(text) {
  const el = document.getElementById("scrapePlayerLabel");
  if (el) el.textContent = text || "";
}

function stopLiveTimer() {
  if (liveTimerId != null) {
    clearInterval(liveTimerId);
    liveTimerId = null;
  }
}

/** Tick status every second while an async call runs (edge cold start can take 30–60s). */
async function withLiveProgress(statusId, messageFn, work) {
  const started = Date.now();
  const tick = () => {
    const sec = Math.floor((Date.now() - started) / 1000);
    const msg = messageFn(sec);
    setStatus(statusId, msg, true);
    setPlayerLabel(msg);
  };
  tick();
  liveTimerId = setInterval(tick, 1000);
  try {
    return await work();
  } finally {
    stopLiveTimer();
  }
}

async function sleepWithCountdown(statusId, label, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end && !scrapeAbort) {
    const left = Math.ceil((end - Date.now()) / 1000);
    setPlayerLabel(`${label} ${left}s…`);
    await sleep(500);
  }
  setPlayerLabel("");
}

function isRateLimitError(message) {
  return /429|rate limit/i.test(String(message || ""));
}

function readProgress() {
  try {
    return JSON.parse(localStorage.getItem(PROGRESS_KEY) || "null");
  } catch {
    return null;
  }
}

const OVERALL_SCRAPE_START_PAGE = 1;

function saveProgress(lastPage, endPage, stagingTotal, extra = {}) {
  localStorage.setItem(
    PROGRESS_KEY,
    JSON.stringify({
      lastPage,
      endPage,
      stagingTotal,
      rangeStartPage: OVERALL_SCRAPE_START_PAGE,
      inProgressPage: null,
      playersCompletedOnPage: 0,
      pagePlayerTotal: null,
      savedAt: new Date().toISOString(),
      ...extra,
      rangeStartPage: OVERALL_SCRAPE_START_PAGE,
    })
  );
}

function saveProgressPartial(page, endPage, stagingTotal, playersCompleted, pageTotal) {
  saveProgress(Math.max(0, page - 1), endPage, stagingTotal, {
    inProgressPage: page,
    playersCompletedOnPage: playersCompleted,
    pagePlayerTotal: pageTotal,
  });
}

function saveProgressPageComplete(page, endPage, stagingTotal) {
  saveProgress(page, endPage, stagingTotal, {
    inProgressPage: null,
    playersCompletedOnPage: 0,
    pagePlayerTotal: null,
  });
}

function midPageState(job) {
  const prog = readProgress();
  const page = prog?.inProgressPage || job?.in_progress_page || 0;
  const done = prog?.playersCompletedOnPage ?? job?.players_completed_on_page ?? 0;
  const total = prog?.pagePlayerTotal ?? job?.page_player_total ?? null;
  if (page > 0 && done > 0 && (total == null || done < total)) {
    return { page, done, total };
  }
  return null;
}

function clearProgress() {
  localStorage.removeItem(PROGRESS_KEY);
}

function formatWhen(iso) {
  if (!iso) return "—";
  try {
    return new Date(iso).toLocaleString();
  } catch {
    return iso;
  }
}

function readLastApply() {
  try {
    return JSON.parse(localStorage.getItem(LAST_APPLY_KEY) || "null");
  } catch {
    return null;
  }
}

function saveLastApply(result) {
  localStorage.setItem(
    LAST_APPLY_KEY,
    JSON.stringify({
      at: new Date().toISOString(),
      staging_rows: result?.staging_rows,
      updated: result?.updated ?? result?.would_update,
      inserted: result?.inserted_free_agents ?? result?.would_insert_free_agents,
      legacy: result?.marked_unavailable ?? result?.would_mark_unavailable,
    })
  );
}

async function fetchStagingStats() {
  const { data, error } = await supabase.rpc("gpdb_pesdb_staging_stats");
  if (error) throw error;
  return data || { staging_count: 0 };
}

async function fetchScrapeJob() {
  const { data, error } = await supabase.rpc("gpdb_pesdb_scrape_job_get");
  if (error) throw error;
  return data?.ok ? data : null;
}

async function saveScrapeJob(patch) {
  const { data, error } = await supabase.rpc("gpdb_pesdb_scrape_job_save", {
    p_patch: patch,
  });
  if (error) {
    console.warn("scrape job save:", error);
    return null;
  }
  return data;
}

async function clearScrapeJob() {
  const { error } = await supabase.rpc("gpdb_pesdb_scrape_job_clear");
  if (error) throw error;
}

function resolveEndPage(job) {
  const prog = readProgress();
  const formEnd = Number(document.getElementById("scrapeEndPage")?.value) || 0;
  return Math.max(
    Number(job?.end_page ?? 0),
    Number(prog?.endPage ?? 0),
    formEnd,
    1
  );
}

/** Original scrape size — always page 1 through target end (never “pages left”). */
function resolveOverallEndPage(job) {
  return resolveEndPage(job);
}

function resolveCompletedPages(job, prog) {
  const p = prog ?? readProgress();
  const lastDone = Math.max(
    Number(job?.last_completed_page ?? 0),
    Number(p?.lastPage ?? 0)
  );
  const mid = midPageState(job);
  if (mid?.page > 0 && mid.done > 0) {
    const fullPagesBefore = Math.max(0, mid.page - 1);
    const frac = mid.total > 0 ? mid.done / mid.total : 0;
    return fullPagesBefore + frac;
  }
  if (lastDone > 0) return lastDone;
  const next = resolveResumePage(job);
  if (next > OVERALL_SCRAPE_START_PAGE) return next - 1;
  return 0;
}

function scrapeProgressMetrics({ job, prog } = {}) {
  const totalPages = resolveOverallEndPage(job);
  let completed = resolveCompletedPages(job, prog);
  completed = Math.min(totalPages, Math.max(0, completed));
  const pct = totalPages > 0 ? (completed / totalPages) * 100 : 0;
  return {
    completed,
    totalPages,
    pct,
    rangeStart: OVERALL_SCRAPE_START_PAGE,
    rangeEnd: totalPages,
    mid: midPageState(job),
  };
}

function syncScrapeProgressBar(job, stagingTotal) {
  const domCount = Number(document.getElementById("progStagingCount")?.textContent);
  const count =
    stagingTotal ??
    (Number.isFinite(domCount) ? domCount : null) ??
    job?.staging_count ??
    readProgress()?.stagingTotal ??
    0;
  updateScrapeProgressBar(
    scrapeProgressMetrics({ job, prog: readProgress() }),
    Number(count) || 0
  );
}

function resolveResumePage(job) {
  const mid = midPageState(job);
  if (mid) return mid.page;

  const prog = readProgress();
  const fromJobNext = Number(job?.next_page) || 0;
  const fromJobLast = (Number(job?.last_completed_page) || 0) + 1;
  const fromLocal = prog?.lastPage ? prog.lastPage + 1 : 0;
  return Math.max(fromJobNext, fromJobLast, fromLocal, 1);
}

function resolvePlayersStartIndex(page, job) {
  const mid = midPageState(job);
  if (mid && mid.page === page) return mid.done;
  return 0;
}

function shouldAutoResumeScrape(job) {
  if (document.getElementById("scrapeAutoResume")?.checked === false) return false;

  if (midPageState(job)) return true;

  const prog = readProgress();
  const endPage = resolveEndPage(job);
  const resumePage = resolveResumePage(job);

  if (resumePage > endPage) return false;
  if (job?.status === "complete") return false;
  if (job?.status === "running") return true;
  if (prog?.lastPage && prog.lastPage < endPage) return true;
  if (job?.status === "stopped" || job?.status === "error") return resumePage <= endPage;

  return false;
}

function applyResumeToForm(job) {
  const resumePage = resolveResumePage(job);
  const endPage = resolveEndPage(job);
  const set = (id, val) => {
    const el = document.getElementById(id);
    if (el && val != null) el.value = String(val);
  };
  set("scrapeStartPage", resumePage);
  if (endPage) set("scrapeEndPage", endPage);
  if (job) {
    set("scrapePagesPerBatch", job.pages_per_batch);
    set("scrapeBatchCooldown", job.batch_cooldown_sec);
    set("scrapePlayerDelay", job.player_delay_sec);
  }
}

function readScrapeParams() {
  const { pagesPerBatch, batchCooldownMs, playerDelayMs } = scrapeSettings();
  const startPage = Math.max(1, Number(document.getElementById("scrapeStartPage")?.value) || 1);
  const endPage = Math.max(startPage, Number(document.getElementById("scrapeEndPage")?.value) || startPage);
  return {
    startPage,
    endPage,
    pagesPerBatch,
    batchCooldownMs,
    playerDelayMs,
    batchCooldownSec: batchCooldownMs / 1000,
    playerDelaySec: playerDelayMs / 1000,
  };
}

const RATE_LIMIT_RETRY_MS = 60000;
const EMPTY_PAGE_RETRY_MS = 45000;
const EMPTY_PAGE_MAX_RETRIES = 6;

class PesdbScrapePauseError extends Error {
  constructor(message) {
    super(message);
    this.name = "PesdbScrapePauseError";
  }
}

/** PESDB has no more player pages (detect often overestimates vs real catalog end). */
class PesdbCatalogEndError extends Error {
  constructor(lastPage, message) {
    super(message);
    this.name = "PesdbCatalogEndError";
    this.lastPage = lastPage;
  }
}

function isEmptyPesdbListResponse(listData) {
  return !listData?.players?.length;
}

async function fetchPesdbPageList(page, endPage, lastCompletedPage = 0) {
  for (let attempt = 1; attempt <= EMPTY_PAGE_MAX_RETRIES; attempt++) {
    if (scrapeAbort) return null;

    const listData = await withLiveProgress(
      "scrapeStatus",
      (sec) => `Page ${page}/${endPage} — loading player list from PESDB… ${sec}s`,
      () =>
        invokePesdbScrape({
          action: "scrape_page",
          page,
        })
    );

    if (!isEmptyPesdbListResponse(listData)) {
      return listData;
    }

    // Page after the last successful one is empty → real end of catalog (not rate limit).
    if (lastCompletedPage > 0 && page > lastCompletedPage) {
      throw new PesdbCatalogEndError(
        lastCompletedPage,
        `End of PESDB catalog at page ${lastCompletedPage} (page ${page} has no players). Detect may overestimate; ${lastCompletedPage} is the last page with data.`
      );
    }

    if (attempt < EMPTY_PAGE_MAX_RETRIES) {
      const waitMs = EMPTY_PAGE_RETRY_MS * attempt;
      const msg = listData?.warning || `PESDB returned no players on page ${page}`;
      setStatus(
        "scrapeStatus",
        `${msg} — waiting ${Math.round(waitMs / 1000)}s before retry (${attempt}/${EMPTY_PAGE_MAX_RETRIES - 1})…`,
        true
      );
      setPlayerLabel(`2-page limit cooldown — retry ${attempt} in ${Math.round(waitMs / 1000)}s`);
      await sleep(waitMs);
      continue;
    }

    const hint =
      listData?.warning ||
      `No players on page ${page} — PESDB 2-page limit. Wait 30–60 min, then refresh to resume from page ${page}.`;
    throw new PesdbScrapePauseError(hint);
  }
  return null;
}

async function finalizeScrapeComplete(actualEndPage, stagingTotal) {
  const endPage = Math.max(1, actualEndPage);
  saveProgressPageComplete(endPage, endPage, stagingTotal);
  const endInput = document.getElementById("scrapeEndPage");
  if (endInput) {
    endInput.value = String(endPage);
    endInput.dataset.userEdited = "1";
  }
  await saveScrapeJob({
    status: "complete",
    start_page: OVERALL_SCRAPE_START_PAGE,
    end_page: endPage,
    last_completed_page: endPage,
    next_page: endPage + 1,
    in_progress_page: 0,
    players_completed_on_page: 0,
    page_player_total: 0,
    staging_count: stagingTotal,
    last_error: null,
  });
  setStatus(
    "scrapeStatus",
    `Scrape complete at page ${endPage} — ${stagingTotal} players in staging. Run preview next.`,
    true
  );
  renderProgressPanel(
    { staging_count: stagingTotal, last_loaded_at: new Date().toISOString() },
    {
      status: "complete",
      last_completed_page: endPage,
      end_page: endPage,
      next_page: endPage + 1,
      staging_count: stagingTotal,
    }
  );
  updateScrapeProgressBar(
    scrapeProgressMetrics({
      job: { end_page: endPage, last_completed_page: endPage },
    }),
    stagingTotal
  );
}

async function markScrapeComplete() {
  const job = await fetchScrapeJob().catch(() => null);
  const prog = readProgress();
  const stagingTotal = (await fetchStagingStats().catch(() => null))?.staging_count ?? 0;
  const lastPage = Math.max(
    Number(job?.last_completed_page ?? 0),
    Number(prog?.lastPage ?? 0)
  );
  if (!lastPage) {
    setStatus("progressStatus", "No completed pages yet — cannot mark complete.", false);
    return;
  }
  if (
    !confirm(
      `Mark scrape complete at page ${lastPage}? (${stagingTotal} players in staging). Use when PESDB has no more pages (detect overestimated).`
    )
  ) {
    return;
  }
  await finalizeScrapeComplete(lastPage, stagingTotal);
  setStatus(
    "progressStatus",
    `Marked complete at page ${lastPage}. You can run preview / apply.`,
    true
  );
}

function renderProgressPanel(stagingStats = null, scrapeJob = null) {
  const prog = readProgress();
  const lastApply = readLastApply();
  const job = scrapeJob || null;
  const stagingCount =
    stagingStats?.staging_count ?? job?.staging_count ?? prog?.stagingTotal ?? "—";
  const lastPage = job?.last_completed_page || prog?.lastPage;
  const endPage = resolveEndPage(job);
  const nextPage = resolveResumePage(job);
  const mid = midPageState(job);

  const set = (id, text) => {
    const el = document.getElementById(id);
    if (el) el.textContent = text ?? "—";
  };

  const statusLabel = job?.status
    ? `${job.status}${
        mid
          ? ` (page ${mid.page} · ${mid.done}/${mid.total ?? "?"} players)`
          : job.status === "running"
            ? " (page " + nextPage + ")"
            : ""
      }`
    : mid
      ? `in progress (page ${mid.page} · ${mid.done}/${mid.total ?? "?"} players)`
      : "—";
  set("progJobStatus", statusLabel);
  set("progStagingCount", String(stagingCount));
  set(
    "progLastPage",
    mid ? `${mid.page} · ${mid.done}/${mid.total ?? "?"} players` : lastPage ? String(lastPage) : "—"
  );
  set("progTargetEnd", endPage ? String(endPage) : "—");
  set(
    "progNextPage",
    mid ? `Page ${mid.page} · player ${mid.done + 1}${mid.total ? ` of ${mid.total}` : ""}` : String(nextPage)
  );
  set("progLastSaved", formatWhen(job?.updated_at || prog?.savedAt));
  set(
    "progLastApply",
    lastApply?.at
      ? `${formatWhen(lastApply.at)} (${lastApply.updated ?? 0} updated, ${lastApply.inserted ?? 0} new)`
      : "Never"
  );

  if (stagingStats?.last_loaded_at) {
    const label = document.querySelector("#syncProgressCard .note");
    if (label) {
      label.textContent =
        `Staging: ${stagingCount} unique players. Job saved in database — refresh safe; reopen page to continue.`;
    }
  }

  syncScrapeProgressBar(job, Number(stagingCount) || 0);
}

async function refreshProgressPanel(statusId = "progressStatus") {
  try {
    const [stats, job] = await Promise.all([
      fetchStagingStats(),
      fetchScrapeJob().catch(() => null),
    ]);
    if (job || readProgress()?.lastPage) {
      applyResumeToForm(job);
    }
    renderProgressPanel(stats, job);
    if (statusId) setStatus(statusId, "Progress refreshed.", true);
    return { stats, job };
  } catch (err) {
    console.error("staging stats:", err);
    renderProgressPanel(null, null);
    if (statusId) setStatus(statusId, err.message || "Could not load staging stats.", false);
    return null;
  }
}

async function clearStagingAndProgress() {
  if (
    !window.confirm(
      "Clear all rows in gpdb_pesdb_staging and reset scrape progress? This does not change live Players until you apply."
    )
  ) {
    return;
  }
  setStatus("progressStatus", "Clearing staging…", true);
  await supabase.rpc("gpdb_pesdb_staging_clear");
  await clearScrapeJob();
  clearProgress();
  const startInput = document.getElementById("scrapeStartPage");
  if (startInput) startInput.value = "1";
  document.getElementById("scrapeClearStaging") &&
    (document.getElementById("scrapeClearStaging").checked = false);
  await refreshProgressPanel("progressStatus");
  setStatus("progressStatus", "Staging cleared. Set end page (Detect pages) and start fresh scrape.", true);
}

function applyResumeFromStorage() {
  const resume = document.getElementById("scrapeResume")?.checked !== false;
  if (!resume) return;
  if (!readProgress()?.lastPage) return;
  applyResumeToForm(null);
}

const fileInput = () => document.getElementById("csvFile");
const importBtn = () => document.getElementById("importBtn");

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function scrapeSettings() {
  const pagesPerBatch = Math.min(
    2,
    Math.max(1, Number(document.getElementById("scrapePagesPerBatch")?.value) || 2)
  );
  const batchCooldownSec = Math.max(
    5,
    Number(document.getElementById("scrapeBatchCooldown")?.value) || 20
  );
  const playerDelaySec = Math.min(
    30,
    Math.max(2, Number(document.getElementById("scrapePlayerDelay")?.value) || 3.5)
  );
  return {
    pagesPerBatch,
    batchCooldownMs: batchCooldownSec * 1000,
    playerDelayMs: playerDelaySec * 1000,
  };
}

function previewFilterActions(filter) {
  if (filter === "legacy") {
    return ["mark_unavailable", "already_unavailable"];
  }
  if (filter === "new") {
    return ["insert_free_agent"];
  }
  if (filter === "all") {
    return [
      "mark_unavailable",
      "already_unavailable",
      "restore_and_update",
      "update_stats",
      "update_mv",
      "insert_free_agent",
    ];
  }
  return ["update_stats", "update_mv", "restore_and_update"];
}

function renderSummary(result, prefix = "") {
  const grid = document.getElementById("previewGrid");
  if (!grid || !result) return;
  grid.hidden = false;

  const dry = result.dry_run !== false;
  const mvOnly = result.would_update_mv_only ?? 0;
  const statUpdates = dry
    ? Math.max(0, (result.would_update ?? 0) - mvOnly)
    : result.updated ?? 0;

  grid.innerHTML = `
    <div><span>${result.staging_rows ?? "—"}</span> staging rows</div>
    <div><span>${dry ? result.would_mark_unavailable ?? result.marked_unavailable ?? 0 : result.marked_unavailable ?? 0}</span> ${prefix}legacy (off PESDB)</div>
    <div><span>${dry ? result.would_insert_free_agents ?? result.inserted_free_agents ?? 0 : result.inserted_free_agents ?? 0}</span> ${prefix}new free agents</div>
    <div><span>${statUpdates}</span> ${prefix}stat updates</div>
    ${mvOnly ? `<div><span>${mvOnly}</span> ${prefix}MV-only updates</div>` : ""}
    <div><span>${dry ? result.would_restore_from_legacy ?? result.restored_from_legacy ?? 0 : result.restored_from_legacy ?? 0}</span> ${prefix}restored from legacy</div>
    <div><span>${result.unchanged ?? 0}</span> unchanged (matched)</div>
  `;
}

function sortAuditRows(rows) {
  return [...(rows || [])].sort((a, b) => {
    const ao = PREVIEW_ACTION_ORDER[a.action] ?? 50;
    const bo = PREVIEW_ACTION_ORDER[b.action] ?? 50;
    if (ao !== bo) return ao - bo;
    return String(a.konami_id).localeCompare(String(b.konami_id));
  });
}

function renderAuditTable(rows) {
  const wrap = document.getElementById("previewTableWrap");
  const tbody = document.getElementById("previewBody");
  const filterRow = document.getElementById("previewFilterRow");
  const filterNote = document.getElementById("previewFilterNote");
  if (!wrap || !tbody) return;

  const unchangedCount = lastPreviewResult?.unchanged ?? 0;

  if (!rows?.length) {
    wrap.hidden = false;
    if (filterRow) filterRow.hidden = false;
    tbody.innerHTML = `<tr><td colspan="7" style="color:#888;padding:10px;">No rows in this filter. Try another filter or check the summary counts above.</td></tr>`;
    if (filterNote) {
      filterNote.textContent = `${unchangedCount.toLocaleString()} unchanged (matched) in summary above.`;
    }
    return;
  }

  const sorted = sortAuditRows(rows);
  const show = sorted.slice(0, PREVIEW_TABLE_LIMIT);

  if (filterRow) filterRow.hidden = false;
  if (filterNote) {
    const shown = show.length;
    const suffix = unchangedCount
      ? ` (${unchangedCount.toLocaleString()} unchanged in summary above)`
      : "";
    filterNote.textContent =
      sorted.length >= PREVIEW_TABLE_LIMIT
        ? `Showing first ${shown} rows in this filter${suffix}.`
        : `${sorted.length.toLocaleString()} row(s) in this filter${suffix}.`;
  }

  wrap.hidden = false;
  const actionClass = {
    mark_unavailable: "tag-warn",
    already_unavailable: "tag-blocked",
    insert_free_agent: "tag-ok",
    update_stats: "tag-ok",
    update_mv: "tag-ok",
    restore_and_update: "tag-ok",
  };

  const fmtMv = (v) => {
    if (v == null || v === "") return "—";
    const n = Number(v);
    return Number.isFinite(n) ? `₿ ${n.toLocaleString("en-GB")}` : "—";
  };

  tbody.innerHTML = show
    .map(
      (r) => `
    <tr>
      <td><span class="${actionClass[r.action] || ""}">${escapeHtml(r.action)}</span></td>
      <td>${escapeHtml(r.konami_id)}</td>
      <td>${escapeHtml(r.player_name || "—")}</td>
      <td>${escapeHtml(r.club || "—")}</td>
      <td>${escapeHtml(r.old_rating || "—")} → ${escapeHtml(r.new_rating || "—")}</td>
      <td>${fmtMv(r.old_mv)} → ${fmtMv(r.new_mv)}</td>
      <td><small>${escapeHtml(r.detail || "")}</small></td>
    </tr>`
    )
    .join("");

  if (sorted.length > show.length) {
    tbody.innerHTML += `<tr><td colspan="7" style="color:#888;padding:10px;">… ${sorted.length - show.length} more in this filter (export via SQL audit for full list).</td></tr>`;
  }
}

async function loadAuditRows(filter = "updates") {
  const { data, error } = await supabase.rpc("gpdb_pesdb_sync_audit", {
    p_actions: previewFilterActions(filter),
    p_limit: PREVIEW_TABLE_LIMIT,
    p_offset: 0,
  });
  if (error) throw error;
  return data || [];
}

async function loadUnavailableList() {
  const { data, error } = await supabase.rpc("gpdb_pesdb_unavailable_list");
  if (error) throw error;
  renderUnavailableTable(data || []);
}

function renderUnavailableTable(rows) {
  const tbody = document.getElementById("legacyBody");
  const wrap = document.getElementById("legacyTableWrap");
  if (!tbody || !wrap) return;

  if (!rows.length) {
    wrap.hidden = true;
    tbody.innerHTML = "";
    return;
  }

  wrap.hidden = false;
  tbody.innerHTML = rows
    .map(
      (r) => `
    <tr>
      <td>${escapeHtml(r.konami_id)}</td>
      <td>${escapeHtml(r.player_name)}</td>
      <td>${escapeHtml(r.club || "Free agent")}</td>
      <td>${escapeHtml(r.rating || "—")}</td>
      <td>${r.unavailable_since ? new Date(r.unavailable_since).toLocaleString() : "—"}</td>
      <td><button type="button" class="button restore-btn" data-id="${escapeHtml(r.konami_id)}" style="font-size:11px;padding:4px 8px;">Restore</button></td>
    </tr>`
    )
    .join("");
}

async function uploadStagingRows(rows, statusId = "importStatus") {
  const unique = dedupeRowsByKonamiId(rows);
  if (!unique?.length) throw new Error("No rows to upload");

  await supabase.rpc("gpdb_pesdb_staging_clear");
  const chunks = chunkRows(unique);
  let stagingCount = 0;

  for (let i = 0; i < chunks.length; i++) {
    setStatus(statusId, `Staging batch ${i + 1} / ${chunks.length}…`, true);
    const { data, error } = await supabase.rpc("gpdb_pesdb_staging_import", {
      p_rows: chunks[i],
      p_replace: i === 0,
    });
    if (error) throw error;
    stagingCount = data?.staging_count ?? stagingCount;
  }

  return stagingCount;
}

async function appendStagingRows(rows) {
  if (!rows?.length) return { stagingCount: 0, rowsNew: 0, rowsUpdated: 0 };
  const enriched = dedupeRowsByKonamiId(await enrichRowsWithEconomics(rows));
  const chunks = chunkRows(enriched);
  let stagingCount = 0;
  let rowsNew = 0;
  let rowsUpdated = 0;
  for (const chunk of chunks) {
    const { data, error } = await supabase.rpc("gpdb_pesdb_staging_import", {
      p_rows: chunk,
      p_replace: false,
    });
    if (error) throw error;
    stagingCount = data?.staging_count ?? stagingCount;
    rowsNew += data?.rows_new ?? 0;
    rowsUpdated += data?.rows_updated ?? 0;
  }
  return { stagingCount, rowsNew, rowsUpdated };
}

async function invokePesdbScrape(body, attempt = 1) {
  const { data, error } = await supabase.functions.invoke(SCRAPE_FUNCTION, {
    body: { ...body, pace: SCRAPE_PACE },
  });
  if (error) {
    let detail = error.message || "Scrape request failed";
    try {
      const ctx = error.context;
      if (ctx && typeof ctx.json === "function") {
        const payload = await ctx.json();
        if (payload?.error) detail = String(payload.error);
      }
    } catch (_) {
      /* ignore parse errors */
    }
    if (data?.error) detail = String(data.error);

    if (isRateLimitError(detail) && attempt < 8 && !scrapeAbort) {
      const waitMs = RATE_LIMIT_RETRY_MS * attempt;
      setStatus(
        "scrapeStatus",
        `PESDB rate limit — waiting ${Math.round(waitMs / 1000)}s before retry (${attempt}/7)…`,
        true
      );
      await sleep(waitMs);
      return invokePesdbScrape(body, attempt + 1);
    }

    const hint = detail.includes("Failed to send")
      ? ` — deploy edge function ${SCRAPE_FUNCTION} in Supabase`
      : "";
    throw new Error(detail + hint);
  }
  if (data?.error) {
    if (isRateLimitError(data.error) && attempt < 8 && !scrapeAbort) {
      const waitMs = RATE_LIMIT_RETRY_MS * attempt;
      setStatus(
        "scrapeStatus",
        `PESDB rate limit — waiting ${Math.round(waitMs / 1000)}s before retry (${attempt}/7)…`,
        true
      );
      await sleep(waitMs);
      return invokePesdbScrape(body, attempt + 1);
    }
    throw new Error(String(data.error));
  }
  return data;
}

/** Per-player detail fetch — mirrors local script: list row then max_level page. */
async function enrichPagePlayers(listPlayers, page, endPage, playerDelayMs, startIndex = 0, onPlayerDone) {
  const out = [];
  const total = listPlayers.length;

  if (startIndex > 0) {
    setStatus(
      "scrapeStatus",
      `Resuming page ${page}/${endPage} from player ${startIndex + 1}/${total}…`,
      true
    );
  }

  for (let i = startIndex; i < listPlayers.length; i++) {
    if (scrapeAbort) break;
    const player = listPlayers[i];
    const name = player.player_name || player.konami_id;
    const pos = player.position ? ` (${player.position})` : "";
    const isFirst = i === 0 && page === 1 && startIndex === 0;

    const data = await withLiveProgress(
      "scrapeStatus",
      (sec) => {
        const cold = isFirst && sec >= 8
          ? " — first request can take up to 60s (edge cold start)"
          : "";
        return `Page ${page}/${endPage} · ${i + 1}/${total}: ${name}${pos} — fetching max rating + style… ${sec}s${cold}`;
      },
      () =>
        invokePesdbScrape({
          action: "enrich_players",
          players: [player],
        })
    );

    const row = (data.players || [])[0];
    if (row) {
      out.push(row);
      const ovr = row.max_level_rating ?? row.rating ?? "?";
      const style = row.playing_style || "None";
      setPlayerLabel(
        `✓ ${name}${pos} — max OVR ${ovr}, ${style} (${i + 1}/${total} on page ${page})`
      );
      setStatus(
        "scrapeStatus",
        `Page ${page}/${endPage} — ${i + 1}/${total} done: ${name} → OVR ${ovr}, ${style}`,
        true
      );
      if (onPlayerDone) {
        await onPlayerDone(row, i + 1, total);
      }
    } else {
      setPlayerLabel(`✗ ${name} — no detail returned (${i + 1}/${total})`);
    }

    if (i < listPlayers.length - 1 && !scrapeAbort) {
      await sleepWithCountdown(
        "scrapeStatus",
        `Pause before next player on page ${page}:`,
        playerDelayMs
      );
    }
  }

  return out;
}

function updateScrapeProgressBar(metrics, stagingTotal = 0, extraLabel = "") {
  const bar = document.getElementById("scrapeProgressBar");
  const label = document.getElementById("scrapeProgressLabel");
  if (!bar || !label || !metrics) return;
  bar.style.width = `${Math.min(100, Math.max(0, metrics.pct))}%`;
  const pctLabel = Math.round(metrics.pct * 10) / 10;
  const pageNote = metrics.mid
    ? ` · page ${metrics.mid.page}${
        metrics.mid.total ? ` (${metrics.mid.done}/${metrics.mid.total} players)` : ""
      }`
    : "";
  label.textContent =
    `${extraLabel}${pctLabel}% · ${metrics.completed.toFixed(1)} of ${metrics.totalPages} pages overall` +
    ` · ${stagingTotal} in staging${pageNote}`;
}

async function scrapeSinglePage(
  page,
  endPage,
  playerDelayMs,
  startPlayerIndex = 0,
  onPlayerDone,
  lastCompletedPage = 0
) {
  const listData = await fetchPesdbPageList(page, endPage, lastCompletedPage);
  if (!listData) return [];

  let players = listData.players || [];
  const resumeAt = Math.min(startPlayerIndex, players.length);
  if (resumeAt > 0) {
    setPlayerLabel(
      `List loaded — resuming page ${page} at player ${resumeAt + 1}/${players.length}.`
    );
  } else {
    setPlayerLabel(`List loaded — ${players.length} players on page ${page}. Starting details…`);
  }

  players = await enrichPagePlayers(
    players,
    page,
    endPage,
    playerDelayMs,
    resumeAt,
    onPlayerDone
  );
  setPlayerLabel(`Page ${page} complete — ${resumeAt + players.length}/${listData.players.length} players enriched this run.`);
  return players;
}

async function detectPesdbPages() {
  setStatus("scrapeStatus", "Detecting PESDB page count…", true);
  try {
    const data = await invokePesdbScrape({ action: "detect" });
    const endInput = document.getElementById("scrapeEndPage");
    if (endInput && data.estimated_pages) {
      endInput.value = String(data.estimated_pages);
      endInput.dataset.userEdited = "1";
    }
    setStatus(
      "scrapeStatus",
      `~${data.total_players ?? "?"} players · detect estimates ~${data.estimated_pages ?? "?"} pages` +
        (data.max_page_link ? ` (pagination shows ${data.max_page_link})` : "") +
        `. PESDB often has trailing empty pages — scrape stops at the first empty page after the last one with players.`,
      true
    );
  } catch (err) {
    console.error("pesdb detect:", err);
    setStatus("scrapeStatus", err.message || "Detect failed.", false);
  }
}

async function executePesdbScrapeLoop(params) {
  const {
    startPage,
    endPage,
    pagesPerBatch,
    batchCooldownMs,
    playerDelayMs,
    batchCooldownSec,
    playerDelaySec,
  } = params;

  scrapeAbort = false;
  scrapeRunning = true;
  document.getElementById("scrapeBtn")?.setAttribute("disabled", "disabled");
  document.getElementById("scrapeStopBtn")?.removeAttribute("disabled");

  const existingJob = await fetchScrapeJob().catch(() => null);

  let stagingTotal = (await fetchStagingStats().catch(() => null))?.staging_count ?? 0;

  try {
    await saveScrapeJob({
      status: "running",
      start_page: OVERALL_SCRAPE_START_PAGE,
      end_page: endPage,
      next_page: startPage,
      pages_per_batch: pagesPerBatch,
      batch_cooldown_sec: batchCooldownSec,
      player_delay_sec: playerDelaySec,
      staging_count: stagingTotal,
      last_error: null,
      started_at: existingJob?.started_at || new Date().toISOString(),
    });
    saveProgress(Math.max(0, startPage - 1), endPage, stagingTotal);
    syncScrapeProgressBar(
      {
        ...existingJob,
        start_page: OVERALL_SCRAPE_START_PAGE,
        end_page: endPage,
        last_completed_page: Math.max(
          Number(existingJob?.last_completed_page ?? 0),
          Number(readProgress()?.lastPage ?? 0),
          startPage > 1 ? startPage - 1 : 0
        ),
        staging_count: stagingTotal,
      },
      stagingTotal
    );

    setStatus(
      "scrapeStatus",
      `Chunked scrape pages ${startPage}–${endPage} (overall 1–${endPage}) · ${pagesPerBatch} pages/batch · ~${playerDelaySec}s per player…`,
      true
    );

    for (let batchStart = startPage; batchStart <= endPage; batchStart += pagesPerBatch) {
      if (scrapeAbort) break;

      const batchEnd = Math.min(batchStart + pagesPerBatch - 1, endPage);
      setStatus(
        "scrapeStatus",
        `Batch pages ${batchStart}–${batchEnd} (fresh PESDB session)…`,
        true
      );

      for (let page = batchStart; page <= batchEnd; page++) {
        if (scrapeAbort) break;

        const resumeJob = await fetchScrapeJob().catch(() => null);
        const startPlayerIndex = resolvePlayersStartIndex(page, resumeJob);
        const lastCompletedPage = Math.max(
          Number(resumeJob?.last_completed_page ?? 0),
          Number(readProgress()?.lastPage ?? 0)
        );

        await saveScrapeJob({
          status: "running",
          next_page: page,
          in_progress_page: startPlayerIndex > 0 ? page : 0,
          players_completed_on_page: startPlayerIndex,
          staging_count: stagingTotal,
        });

        const onPlayerDone = async (row, completedCount, totalOnPage) => {
          const importResult = await appendStagingRows([row]);
          stagingTotal = importResult.stagingCount;
          saveProgressPartial(page, endPage, stagingTotal, completedCount, totalOnPage);
          const jobPatch = {
            status: "running",
            start_page: OVERALL_SCRAPE_START_PAGE,
            end_page: endPage,
            next_page: page,
            in_progress_page: page,
            players_completed_on_page: completedCount,
            page_player_total: totalOnPage,
            staging_count: stagingTotal,
          };
          await saveScrapeJob(jobPatch);
          const liveJob = {
            ...existingJob,
            ...jobPatch,
            last_completed_page: Math.max(0, page - 1),
            updated_at: new Date().toISOString(),
          };
          renderProgressPanel(
            { staging_count: stagingTotal, last_loaded_at: new Date().toISOString() },
            liveJob
          );
          updateScrapeProgressBar(
            scrapeProgressMetrics({ job: liveJob }),
            stagingTotal
          );
        };

        let players;
        try {
          players = await scrapeSinglePage(
            page,
            endPage,
            playerDelayMs,
            startPlayerIndex,
            onPlayerDone,
            lastCompletedPage
          );
        } catch (err) {
          if (err?.name === "PesdbCatalogEndError") {
            await finalizeScrapeComplete(err.lastPage || lastCompletedPage, stagingTotal);
            return;
          }
          throw err;
        }
        if (scrapeAbort) break;

        saveProgressPageComplete(page, endPage, stagingTotal);
        await saveScrapeJob({
          status: "running",
          start_page: OVERALL_SCRAPE_START_PAGE,
          end_page: endPage,
          last_completed_page: page,
          next_page: page + 1,
          in_progress_page: 0,
          players_completed_on_page: 0,
          page_player_total: 0,
          staging_count: stagingTotal,
        });

        const pageCompleteJob = {
          status: "running",
          start_page: OVERALL_SCRAPE_START_PAGE,
          end_page: endPage,
          last_completed_page: page,
          next_page: page + 1,
          staging_count: stagingTotal,
        };
        updateScrapeProgressBar(
          scrapeProgressMetrics({ job: pageCompleteJob }),
          stagingTotal,
          `Batch ${batchStart}–${batchEnd}: `
        );
        const dupeNote =
          players.length > 0
            ? ` (${players.length} enriched this run)`
            : "";
        setStatus(
          "scrapeStatus",
          `Page ${page}/${endPage} done${dupeNote} (${stagingTotal} unique in staging).`,
          true
        );
        renderProgressPanel(
          { staging_count: stagingTotal, last_loaded_at: new Date().toISOString() },
          {
            status: "running",
            last_completed_page: page,
            next_page: page + 1,
            end_page: endPage,
            staging_count: stagingTotal,
            updated_at: new Date().toISOString(),
          }
        );
      }

      if (batchEnd < endPage && !scrapeAbort) {
        setStatus(
          "scrapeStatus",
          `Batch ${batchStart}–${batchEnd} complete. Cooldown ${batchCooldownMs / 1000}s before next batch…`,
          true
        );
        await sleep(batchCooldownMs);
      }
    }

    if (!scrapeAbort && startPage <= endPage) {
      const job = await fetchScrapeJob().catch(() => null);
      const actualEnd = Math.max(
        Number(job?.last_completed_page ?? 0),
        Number(readProgress()?.lastPage ?? 0),
        endPage
      );
      await finalizeScrapeComplete(actualEnd, stagingTotal);
    } else {
      await saveScrapeJob({
        status: "stopped",
        staging_count: stagingTotal,
        last_error: null,
      });
      const resumeJob = await fetchScrapeJob().catch(() => null);
      const resumePage = resolveResumePage(resumeJob);
      const mid = midPageState(resumeJob);
      setStatus(
        "scrapeStatus",
        mid
          ? `Stopped. ${stagingTotal} in staging. Refresh to continue page ${mid.page} from player ${mid.done + 1}${mid.total ? ` of ${mid.total}` : ""}.`
          : `Stopped. ${stagingTotal} in staging. Refresh to continue from page ${resumePage}.`,
        true
      );
    }
  } catch (err) {
    console.error("pesdb scrape:", err);
    if (err?.name === "PesdbCatalogEndError") {
      await finalizeScrapeComplete(err.lastPage || 0, stagingTotal);
      return;
    }
    const isPause =
      err?.name === "PesdbScrapePauseError" ||
      /2-page limit|No players parsed|No players on page/i.test(String(err.message || err));
    const resumeJob = await fetchScrapeJob().catch(() => null);
    const resumePage = resolveResumePage(resumeJob);
    await saveScrapeJob({
      status: isPause ? "stopped" : "error",
      last_error: String(err.message || err).slice(0, 500),
      staging_count: stagingTotal,
    });
    setStatus(
      "scrapeStatus",
      isPause
        ? `${err.message} Progress saved — ${stagingTotal} in staging. Wait 30–60 min, refresh this page (auto-resume will continue from page ${resumePage}).`
        : (err.message || `Scrape failed. Deploy ${SCRAPE_FUNCTION} edge function.`) +
            " Refresh this page to retry from the last saved page.",
      isPause
    );
  } finally {
    scrapeRunning = false;
    document.getElementById("scrapeBtn")?.removeAttribute("disabled");
    document.getElementById("scrapeStopBtn")?.setAttribute("disabled", "disabled");
    refreshProgressPanel(null).catch(() => {});
  }
}

async function runPesdbScrape() {
  if (scrapeRunning) return;

  const clearStaging = document.getElementById("scrapeClearStaging")?.checked === true;
  let params = readScrapeParams();

  try {
    if (clearStaging) {
      await supabase.rpc("gpdb_pesdb_staging_clear");
      await clearScrapeJob();
      clearProgress();
    } else {
      const job = await fetchScrapeJob().catch(() => null);
      const resume = document.getElementById("scrapeResume")?.checked !== false;
      if (resume) {
        const resumePage = resolveResumePage(job);
        const endFromJob = resolveEndPage(job);
        params = {
          ...params,
          startPage: resumePage,
          endPage: Math.max(params.endPage, endFromJob),
          pagesPerBatch: job?.pages_per_batch ?? params.pagesPerBatch,
          batchCooldownMs: (job?.batch_cooldown_sec ?? params.batchCooldownSec) * 1000,
          playerDelayMs: Number(job?.player_delay_sec ?? params.playerDelaySec) * 1000,
          batchCooldownSec: job?.batch_cooldown_sec ?? params.batchCooldownSec,
          playerDelaySec: Number(job?.player_delay_sec ?? params.playerDelaySec),
        };
        applyResumeToForm(job);
      }
    }

    await executePesdbScrapeLoop(params);
  } catch (err) {
    setStatus("scrapeStatus", err.message || "Could not start scrape.", false);
  }
}

async function maybeAutoResumeScrape() {
  if (scrapeRunning) return;

  let job = null;
  try {
    job = await fetchScrapeJob();
  } catch {
    /* use localStorage only */
  }

  if (!shouldAutoResumeScrape(job)) return;

  const resumePage = resolveResumePage(job);
  const endPage = resolveEndPage(job);
  const { pagesPerBatch, batchCooldownMs, playerDelayMs, batchCooldownSec, playerDelaySec } =
    scrapeSettings();

  applyResumeToForm(job);
  const mid = midPageState(job);
  setStatus(
    "scrapeStatus",
    mid
      ? `Auto-resuming page ${mid.page} from player ${mid.done + 1}${mid.total ? ` of ${mid.total}` : ""}…`
      : `Auto-resuming from page ${resumePage} of ${endPage} (saved progress)…`,
    true
  );

  await executePesdbScrapeLoop({
    startPage: resumePage,
    endPage,
    pagesPerBatch: job?.pages_per_batch ?? pagesPerBatch,
    batchCooldownMs: (job?.batch_cooldown_sec ?? batchCooldownSec) * 1000,
    playerDelayMs: Number(job?.player_delay_sec ?? playerDelaySec) * 1000,
    batchCooldownSec: job?.batch_cooldown_sec ?? batchCooldownSec,
    playerDelaySec: Number(job?.player_delay_sec ?? playerDelaySec),
  });
}

function stopPesdbScrape() {
  scrapeAbort = true;
  stopLiveTimer();
  setStatus("scrapeStatus", "Stopping after current player…", true);
  setPlayerLabel("Stop requested — finishing current request…");
  saveScrapeJob({ status: "stopped" }).catch(() => {});
}

async function importCsv() {
  const file = fileInput()?.files?.[0];
  if (!file) {
    setStatus("importStatus", "Choose a PESDB scrape CSV first.", false);
    return;
  }

  setStatus("importStatus", "Parsing CSV and computing economics…", true);
  importBtn()?.setAttribute("disabled", "disabled");

  try {
    const text = await file.text();
    const { rows, skipped, dupesRemoved } = await parsePesdbCsvToStagingRows(text);
    if (!rows.length) {
      throw new Error("No valid player rows in CSV");
    }

    const imported = await uploadStagingRows(rows, "importStatus");

    const skipNote = skipped.length ? ` (${skipped.length} rows skipped)` : "";
    const dupeNote = dupesRemoved ? ` (${dupesRemoved} CSV duplicates merged)` : "";
    setStatus(
      "importStatus",
      `Staging loaded — ${imported} players${skipNote}${dupeNote}. Run preview next.`,
      true
    );
    await refreshProgressPanel(null);
  } catch (err) {
    console.error("pesdb import:", err);
    setStatus("importStatus", err.message || "Import failed.", false);
  } finally {
    importBtn()?.removeAttribute("disabled");
  }
}

async function runPreview() {
  setStatus("previewStatus", "Loading…", true);
  try {
    const filter = document.getElementById("previewFilter")?.value ?? "updates";
    const [{ data: result, error }, auditRows] = await Promise.all([
      supabase.rpc("gpdb_pesdb_sync_apply", { p_dry_run: true }),
      loadAuditRows(filter),
    ]);
    if (error) throw error;

    lastPreviewResult = result;
    lastAuditRows = auditRows || [];

    renderSummary(result);
    renderAuditTable(lastAuditRows);

    const matched = (result.unchanged ?? 0) + (result.would_update ?? 0);
    const inserted = result.would_insert_free_agents ?? 0;
    const legacy = result.would_mark_unavailable ?? 0;
    let statusMsg = `Preview ready — ${matched.toLocaleString()} staging rows match existing GPDB; ${inserted.toLocaleString()} new cards; ${legacy.toLocaleString()} legacy.`;
    const stagingRows = result.staging_rows ?? 0;
    if (matched < 1000 && stagingRows > 5000) {
      statusMsg +=
        " ⚠️ Very few matches — check Konami IDs in staging vs Players (sample a known player ID in both tables).";
    }
    setStatus("previewStatus", statusMsg, true);
  } catch (err) {
    console.error("pesdb sync preview:", err);
    setStatus(
      "previewStatus",
      err.message || "Preview failed. Run patches/gpdb_pesdb_sync.sql first.",
      false
    );
  }
}

async function runApplyPhase(phase, batchOffset = 0) {
  return supabase.rpc("gpdb_pesdb_sync_apply", {
    p_dry_run: false,
    p_phase: phase,
    p_batch_offset: batchOffset,
    p_batch_size: APPLY_BATCH_SIZE,
  });
}

async function runApplyBatchedPhase(statusId, phase, label, onBatch) {
  let offset = 0;
  let hasMore = true;
  let totalDone = 0;
  let totalExpected = null;

  while (hasMore) {
    const { data, error } = await runApplyPhase(phase, offset);
    if (error) throw error;

    const batchCount = data?.rows_this_batch ?? 0;
    totalDone += batchCount;
    if (phase === "update") totalExpected = data?.total_matched ?? totalExpected;
    if (phase === "insert") totalExpected = data?.total_new ?? totalExpected;

    const progress =
      totalExpected != null
        ? `${totalDone.toLocaleString()} / ${totalExpected.toLocaleString()}`
        : totalDone.toLocaleString();

    setStatus(statusId, `${label}… ${progress}`, true);
    if (onBatch) onBatch(data, totalDone);

    hasMore = data?.has_more === true && batchCount > 0;
    offset = data?.next_offset ?? offset + batchCount;
  }

  return { totalDone, totalExpected };
}

async function runApply() {
  const confirm = document.getElementById("confirmInput")?.value?.trim();
  if (confirm !== CONFIRM_TEXT) {
    setStatus("applyStatus", `Type ${CONFIRM_TEXT} exactly to confirm.`, false);
    return;
  }

  if (
    !window.confirm(
      "Apply PESDB sync to live Players table? Back up Players first (export_players_csv.sql)."
    )
  ) {
    return;
  }

  const applyBtn = document.getElementById("applyBtn");
  applyBtn?.setAttribute("disabled", "disabled");

  setStatus(
    "applyStatus",
    "Applying in batches (legacy → updates → new players) — keep this tab open.",
    true
  );

  try {
    const { data: legacy, error: legacyErr } = await runApplyPhase("legacy");
    if (legacyErr) throw legacyErr;

    const totals = {
      ok: true,
      dry_run: false,
      staging_rows: legacy?.staging_rows ?? 0,
      marked_unavailable: legacy?.marked_unavailable ?? 0,
      restored_from_legacy: legacy?.restored_from_legacy ?? 0,
      updated: 0,
      inserted_free_agents: 0,
    };

    setStatus(
      "applyStatus",
      `Legacy marked: ${totals.marked_unavailable.toLocaleString()} — updating matched players…`,
      true
    );

    const updateRun = await runApplyBatchedPhase(
      "applyStatus",
      "update",
      "Updating matched players"
    );
    totals.updated = updateRun.totalDone;

    setStatus("applyStatus", "Inserting new free agents…", true);
    const insertRun = await runApplyBatchedPhase(
      "applyStatus",
      "insert",
      "Inserting new free agents"
    );
    totals.inserted_free_agents = insertRun.totalDone;

    saveLastApply(totals);
    renderSummary(totals, "applied ");
    const filter = document.getElementById("previewFilter")?.value ?? "updates";
    await Promise.all([
      loadAuditRows(filter).then((rows) => {
        lastAuditRows = rows;
        renderAuditTable(rows);
      }),
      loadUnavailableList(),
    ]);
    await refreshProgressPanel(null);
    setStatus(
      "applyStatus",
      `Sync applied — ${totals.updated.toLocaleString()} updated, ${totals.inserted_free_agents.toLocaleString()} new, ${totals.marked_unavailable.toLocaleString()} legacy.`,
      true
    );
  } catch (err) {
    console.error("pesdb sync apply:", err);
    setStatus("applyStatus", err.message || "Apply failed.", false);
  } finally {
    applyBtn?.removeAttribute("disabled");
  }
}

async function restorePlayer(playerId) {
  if (!window.confirm(`Restore ${playerId} as available (clear legacy flag)?`)) return;
  try {
    const { error } = await supabase.rpc("gpdb_pesdb_restore_player", {
      p_player_id: playerId,
    });
    if (error) throw error;
    await loadUnavailableList();
    setStatus("legacyStatus", `Restored ${playerId}. Re-sync when they reappear on pesdb.net.`, true);
  } catch (err) {
    setStatus("legacyStatus", err.message || "Restore failed.", false);
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  await initAdminPage();
  applyResumeFromStorage();
  await refreshProgressPanel(null);
  await maybeAutoResumeScrape();

  document.getElementById("scrapeEndPage")?.addEventListener("input", (e) => {
    e.target.dataset.userEdited = "1";
  });

  document.getElementById("refreshProgressBtn")?.addEventListener("click", () => refreshProgressPanel("progressStatus"));
  document.getElementById("markCompleteBtn")?.addEventListener("click", () =>
    markScrapeComplete().catch((err) => setStatus("progressStatus", err.message, false))
  );
  document.getElementById("clearStagingBtn")?.addEventListener("click", () =>
    clearStagingAndProgress().catch((err) => setStatus("progressStatus", err.message, false))
  );

  document.getElementById("importBtn")?.addEventListener("click", importCsv);
  document.getElementById("detectPagesBtn")?.addEventListener("click", detectPesdbPages);
  document.getElementById("scrapeBtn")?.addEventListener("click", runPesdbScrape);
  document.getElementById("scrapeStopBtn")?.addEventListener("click", stopPesdbScrape);
  document.getElementById("previewBtn")?.addEventListener("click", runPreview);
  document.getElementById("previewFilter")?.addEventListener("change", async () => {
    const filter = document.getElementById("previewFilter")?.value ?? "updates";
    try {
      lastAuditRows = await loadAuditRows(filter);
      renderAuditTable(lastAuditRows);
    } catch (err) {
      setStatus("previewStatus", err.message || "Could not load preview filter.", false);
    }
  });
  document.getElementById("applyBtn")?.addEventListener("click", runApply);
  document.getElementById("refreshLegacyBtn")?.addEventListener("click", loadUnavailableList);

  document.getElementById("legacyBody")?.addEventListener("click", (e) => {
    const btn = e.target.closest(".restore-btn");
    if (!btn) return;
    restorePlayer(btn.dataset.id);
  });

  loadUnavailableList().catch(() => {});
});
