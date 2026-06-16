import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  parsePesdbCsvToStagingRows,
  chunkRows,
  enrichRowsWithEconomics,
} from "./gpdb_pesdb_import.js";

primeAdminPageChrome();

const CONFIRM_TEXT = "SYNC GPDB";
const SCRAPE_FUNCTION = "gpdb-pesdb-scrape";
const SCRAPE_PACE = "chunked";
const PROGRESS_KEY = "gpdb_pesdb_scrape_progress";
const RATE_LIMIT_RETRY_MS = 60000;
let scrapeAbort = false;
let liveTimerId = null;

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

function saveProgress(lastPage, endPage, stagingTotal) {
  localStorage.setItem(
    PROGRESS_KEY,
    JSON.stringify({
      lastPage,
      endPage,
      stagingTotal,
      savedAt: new Date().toISOString(),
    })
  );
}

function clearProgress() {
  localStorage.removeItem(PROGRESS_KEY);
}

function applyResumeFromStorage() {
  const resume = document.getElementById("scrapeResume")?.checked !== false;
  if (!resume) return;
  const prog = readProgress();
  if (!prog?.lastPage) return;
  const startInput = document.getElementById("scrapeStartPage");
  const endInput = document.getElementById("scrapeEndPage");
  if (startInput && prog.lastPage >= 1) {
    startInput.value = String(prog.lastPage + 1);
  }
  if (endInput && prog.endPage && !endInput.dataset.userEdited) {
    endInput.value = String(prog.endPage);
  }
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

function renderSummary(result, prefix = "") {
  const grid = document.getElementById("previewGrid");
  if (!grid || !result) return;
  grid.hidden = false;

  const dry = result.dry_run !== false;
  grid.innerHTML = `
    <div><span>${result.staging_rows ?? "—"}</span> staging rows</div>
    <div><span>${dry ? result.would_mark_unavailable ?? result.marked_unavailable ?? 0 : result.marked_unavailable ?? 0}</span> ${prefix}legacy (off PESDB)</div>
    <div><span>${dry ? result.would_insert_free_agents ?? result.inserted_free_agents ?? 0 : result.inserted_free_agents ?? 0}</span> ${prefix}new free agents</div>
    <div><span>${dry ? result.would_update ?? result.updated ?? 0 : result.updated ?? 0}</span> ${prefix}stat updates</div>
    <div><span>${dry ? result.would_restore_from_legacy ?? result.restored_from_legacy ?? 0 : result.restored_from_legacy ?? 0}</span> ${prefix}restored from legacy</div>
    <div><span>${result.unchanged ?? 0}</span> unchanged</div>
  `;
}

function renderAuditTable(rows) {
  const wrap = document.getElementById("previewTableWrap");
  const tbody = document.getElementById("previewBody");
  if (!wrap || !tbody) return;

  if (!rows?.length) {
    wrap.hidden = true;
    tbody.innerHTML = "";
    return;
  }

  wrap.hidden = false;
  const show = rows.filter((r) => r.action !== "unchanged").slice(0, 250);
  const actionClass = {
    mark_unavailable: "tag-warn",
    already_unavailable: "tag-blocked",
    insert_free_agent: "tag-ok",
    update_stats: "tag-ok",
    restore_and_update: "tag-ok",
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
      <td><small>${escapeHtml(r.detail || "")}</small></td>
    </tr>`
    )
    .join("");

  const hidden = rows.filter((r) => r.action === "unchanged").length;
  if (hidden) {
    tbody.innerHTML += `<tr><td colspan="6" style="color:#888;padding:10px;">${hidden} unchanged row(s) hidden.</td></tr>`;
  }
  if (rows.length > show.length + hidden) {
    tbody.innerHTML += `<tr><td colspan="6" style="color:#888;padding:10px;">Showing first ${show.length} changed rows.</td></tr>`;
  }
}

async function loadAuditRows() {
  const { data, error } = await supabase.rpc("gpdb_pesdb_sync_audit");
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
  if (!rows?.length) throw new Error("No rows to upload");

  await supabase.rpc("gpdb_pesdb_staging_clear");
  const chunks = chunkRows(rows);
  let imported = 0;

  for (let i = 0; i < chunks.length; i++) {
    setStatus(statusId, `Staging batch ${i + 1} / ${chunks.length}…`, true);
    const { data, error } = await supabase.rpc("gpdb_pesdb_staging_import", {
      p_rows: chunks[i],
      p_replace: i === 0,
    });
    if (error) throw error;
    imported += data?.rows_imported ?? chunks[i].length;
  }

  return imported;
}

async function appendStagingRows(rows) {
  if (!rows?.length) return 0;
  const enriched = await enrichRowsWithEconomics(rows);
  const chunks = chunkRows(enriched);
  let imported = 0;
  for (const chunk of chunks) {
    const { error } = await supabase.rpc("gpdb_pesdb_staging_import", {
      p_rows: chunk,
      p_replace: false,
    });
    if (error) throw error;
    imported += chunk.length;
  }
  return imported;
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
async function enrichPagePlayers(listPlayers, page, endPage, playerDelayMs) {
  const out = [];
  const total = listPlayers.length;

  for (let i = 0; i < listPlayers.length; i++) {
    if (scrapeAbort) break;
    const player = listPlayers[i];
    const name = player.player_name || player.konami_id;
    const pos = player.position ? ` (${player.position})` : "";
    const isFirst = i === 0 && page === 1;

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

function updateScrapeProgress(completedPages, totalPages, stagingTotal, batchLabel = "") {
  const bar = document.getElementById("scrapeProgressBar");
  const label = document.getElementById("scrapeProgressLabel");
  if (!bar || !label) return;
  const pct = totalPages > 0 ? Math.round((completedPages / totalPages) * 100) : 0;
  bar.style.width = `${Math.min(100, pct)}%`;
  label.textContent = `${batchLabel}${completedPages} / ${totalPages} pages · ${stagingTotal} players in staging`;
}

async function scrapeSinglePage(page, endPage, playerDelayMs) {
  const listData = await withLiveProgress(
    "scrapeStatus",
    (sec) => `Page ${page}/${endPage} — loading player list from PESDB… ${sec}s`,
    () =>
      invokePesdbScrape({
        action: "scrape_page",
        page,
      })
  );

  if (listData.warning && !listData.players?.length) {
    throw new Error(listData.warning);
  }

  let players = listData.players || [];
  if (!players.length) {
    throw new Error(
      `No players on page ${page} — PESDB 2-page limit may be active. Wait 30–60 min, then resume from page ${page}.`
    );
  }

  setPlayerLabel(`List loaded — ${players.length} players on page ${page}. Starting details…`);
  players = await enrichPagePlayers(players, page, endPage, playerDelayMs);
  setPlayerLabel(`Page ${page} complete — ${players.length} players enriched.`);
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
      `~${data.total_players ?? "?"} players · ~${data.estimated_pages ?? "?"} pages. Start with pages 1–2 to test.`,
      true
    );
  } catch (err) {
    console.error("pesdb detect:", err);
    setStatus("scrapeStatus", err.message || "Detect failed.", false);
  }
}

async function runPesdbScrape() {
  const startPage = Math.max(1, Number(document.getElementById("scrapeStartPage")?.value) || 1);
  const endPage = Math.max(startPage, Number(document.getElementById("scrapeEndPage")?.value) || startPage);
  const clearStaging = document.getElementById("scrapeClearStaging")?.checked === true;
  const { pagesPerBatch, batchCooldownMs, playerDelayMs } = scrapeSettings();

  scrapeAbort = false;
  document.getElementById("scrapeBtn")?.setAttribute("disabled", "disabled");
  document.getElementById("scrapeStopBtn")?.removeAttribute("disabled");

  let stagingTotal = readProgress()?.stagingTotal ?? 0;
  let pagesDone = 0;
  const totalPages = endPage - startPage + 1;

  try {
    if (clearStaging) {
      await supabase.rpc("gpdb_pesdb_staging_clear");
      stagingTotal = 0;
      clearProgress();
    }

    setStatus(
      "scrapeStatus",
      `Chunked scrape pages ${startPage}–${endPage} · ${pagesPerBatch} pages/batch · ~${playerDelayMs / 1000}s per player…`,
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

        const players = await scrapeSinglePage(page, endPage, playerDelayMs);
        const added = await appendStagingRows(players);
        stagingTotal += added;
        pagesDone += 1;

        saveProgress(page, endPage, stagingTotal);
        updateScrapeProgress(pagesDone, totalPages, stagingTotal, `Batch ${batchStart}–${batchEnd}: `);
        setStatus(
          "scrapeStatus",
          `Page ${page}/${endPage} done — ${players.length} players (${stagingTotal} total in staging).`,
          true
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

    if (!scrapeAbort) {
      saveProgress(endPage, endPage, stagingTotal);
      setStatus(
        "scrapeStatus",
        `Scrape complete — ${stagingTotal} players in staging. Run preview next.`,
        true
      );
    } else {
      setStatus(
        "scrapeStatus",
        `Stopped. ${stagingTotal} players in staging. Resume will continue from page ${(readProgress()?.lastPage ?? startPage) + 1}.`,
        true
      );
    }
  } catch (err) {
    console.error("pesdb scrape:", err);
    setStatus(
      "scrapeStatus",
      (err.message || `Scrape failed. Deploy ${SCRAPE_FUNCTION} edge function.`) +
        " Progress saved — adjust start page and resume after cooldown.",
      false
    );
  } finally {
    document.getElementById("scrapeBtn")?.removeAttribute("disabled");
    document.getElementById("scrapeStopBtn")?.setAttribute("disabled", "disabled");
  }
}

function stopPesdbScrape() {
  scrapeAbort = true;
  stopLiveTimer();
  setStatus("scrapeStatus", "Stopping after current player…", true);
  setPlayerLabel("Stop requested — finishing current request…");
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
    const { rows, skipped } = await parsePesdbCsvToStagingRows(text);
    if (!rows.length) {
      throw new Error("No valid player rows in CSV");
    }

    const imported = await uploadStagingRows(rows, "importStatus");

    const skipNote = skipped.length ? ` (${skipped.length} rows skipped)` : "";
    setStatus(
      "importStatus",
      `Staging loaded — ${imported} players${skipNote}. Run preview next.`,
      true
    );
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
    const [auditRows, { data: result, error }] = await Promise.all([
      loadAuditRows(),
      supabase.rpc("gpdb_pesdb_sync_apply", { p_dry_run: true }),
    ]);
    if (error) throw error;
    renderSummary(result);
    renderAuditTable(auditRows);
    setStatus(
      "previewStatus",
      "Preview ready — review changes before applying.",
      true
    );
  } catch (err) {
    console.error("pesdb sync preview:", err);
    setStatus(
      "previewStatus",
      err.message || "Preview failed. Run patches/gpdb_pesdb_sync.sql first.",
      false
    );
  }
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

  setStatus("applyStatus", "Applying…", true);
  try {
    const { data: result, error } = await supabase.rpc("gpdb_pesdb_sync_apply", {
      p_dry_run: false,
    });
    if (error) throw error;
    renderSummary(result, "applied ");
    await Promise.all([loadAuditRows().then(renderAuditTable), loadUnavailableList()]);
    setStatus("applyStatus", "Sync applied.", true);
  } catch (err) {
    console.error("pesdb sync apply:", err);
    setStatus("applyStatus", err.message || "Apply failed.", false);
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

  document.getElementById("scrapeEndPage")?.addEventListener("input", (e) => {
    e.target.dataset.userEdited = "1";
  });

  document.getElementById("importBtn")?.addEventListener("click", importCsv);
  document.getElementById("detectPagesBtn")?.addEventListener("click", detectPesdbPages);
  document.getElementById("scrapeBtn")?.addEventListener("click", runPesdbScrape);
  document.getElementById("scrapeStopBtn")?.addEventListener("click", stopPesdbScrape);
  document.getElementById("previewBtn")?.addEventListener("click", runPreview);
  document.getElementById("applyBtn")?.addEventListener("click", runApply);
  document.getElementById("refreshLegacyBtn")?.addEventListener("click", loadUnavailableList);

  document.getElementById("legacyBody")?.addEventListener("click", (e) => {
    const btn = e.target.closest(".restore-btn");
    if (!btn) return;
    restorePlayer(btn.dataset.id);
  });

  loadUnavailableList().catch(() => {});
});
