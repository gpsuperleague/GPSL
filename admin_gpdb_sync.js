import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  parsePesdbCsvToStagingRows,
  chunkRows,
  enrichRowsWithEconomics,
} from "./gpdb_pesdb_import.js";

primeAdminPageChrome();

const CONFIRM_TEXT = "SYNC GPDB";
const SCRAPE_FUNCTION = "gpdb-pesdb-scrape";
const DETAIL_BATCH_SIZE = 1;
const PAGE_DELAY_MS = 60000;
const BATCH_DELAY_MS = 30000;
const RATE_LIMIT_RETRY_MS = 60000;
const PAGE_START_DELAY_MS = 8000;
let scrapeAbort = false;

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function isRateLimitError(message) {
  return /429|rate limit/i.test(String(message || ""));
}
const fileInput = () => document.getElementById("csvFile");
const importBtn = () => document.getElementById("importBtn");

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
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

async function invokePesdbScrape(body, attempt = 1) {
  const { data, error } = await supabase.functions.invoke(SCRAPE_FUNCTION, {
    body,
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

async function enrichPlayersWithDetails(listPlayers) {
  const out = [];
  const batches = chunkRows(listPlayers, DETAIL_BATCH_SIZE);
  for (let i = 0; i < batches.length; i++) {
    if (scrapeAbort) break;
    const batch = batches[i];
    const data = await invokePesdbScrape({
      action: "enrich_players",
      players: batch,
    });
    out.push(...(data.players || []));
    if (i < batches.length - 1) await sleep(BATCH_DELAY_MS);
  }
  return out;
}

function updateScrapeProgress(page, endPage, stagingTotal) {
  const bar = document.getElementById("scrapeProgressBar");
  const label = document.getElementById("scrapeProgressLabel");
  if (!bar || !label) return;
  const pct = endPage > 0 ? Math.round((page / endPage) * 100) : 0;
  bar.style.width = `${Math.min(100, pct)}%`;
  label.textContent = `Page ${page} / ${endPage} · ${stagingTotal} players in staging`;
}

async function detectPesdbPages() {
  setStatus("scrapeStatus", "Detecting PESDB page count…", true);
  try {
    const data = await invokePesdbScrape({ action: "detect" });
    const endInput = document.getElementById("scrapeEndPage");
    if (endInput && data.estimated_pages) {
      endInput.value = String(data.estimated_pages);
    }
    setStatus(
      "scrapeStatus",
      `~${data.total_players ?? "?"} players · ~${data.estimated_pages ?? "?"} pages. Set range and start scrape.`,
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
  const includeDetails = document.getElementById("scrapeDetails")?.checked !== false;

  scrapeAbort = false;
  document.getElementById("scrapeBtn")?.setAttribute("disabled", "disabled");
  document.getElementById("scrapeStopBtn")?.removeAttribute("disabled");

  let stagingTotal = 0;

  try {
    await supabase.rpc("gpdb_pesdb_staging_clear");

    setStatus(
      "scrapeStatus",
      `Scraping pesdb.net pages ${startPage}–${endPage}${includeDetails ? " (slow mode — max rating + style)" : ""}…`,
      true
    );

    await sleep(10000);

    for (let page = startPage; page <= endPage; page++) {
      if (scrapeAbort) {
        setStatus("scrapeStatus", `Stopped at page ${page - 1}. ${stagingTotal} players in staging.`, true);
        break;
      }

      await sleep(PAGE_START_DELAY_MS);

      updateScrapeProgress(page - startPage, endPage - startPage + 1, stagingTotal);
      setStatus(
        "scrapeStatus",
        `Page ${page}/${endPage} — fetching list…`,
        true
      );

      const listData = await invokePesdbScrape({
        action: "scrape_page",
        page,
      });

      let players = listData.players || [];

      if (includeDetails && players.length && !scrapeAbort) {
        setStatus(
          "scrapeStatus",
          `Page ${page}/${endPage} — max rating + style (${players.length} players, ~1 every 40s)…`,
          true
        );
        players = await enrichPlayersWithDetails(players);
      }

      const enriched = await enrichRowsWithEconomics(players);
      if (enriched.length) {
        const chunks = chunkRows(enriched);
        for (const chunk of chunks) {
          const { error } = await supabase.rpc("gpdb_pesdb_staging_import", {
            p_rows: chunk,
            p_replace: false,
          });
          if (error) throw error;
        }
        stagingTotal += enriched.length;
      }

      updateScrapeProgress(page - startPage + 1, endPage - startPage + 1, stagingTotal);
      setStatus(
        "scrapeStatus",
        `Page ${page}/${endPage} done — ${players.length} players (${stagingTotal} total in staging).`,
        true
      );

      if (page < endPage && !scrapeAbort) {
        setStatus(
          "scrapeStatus",
          `Pausing ${PAGE_DELAY_MS / 1000}s before next page (PESDB rate limit)…`,
          true
        );
        await sleep(PAGE_DELAY_MS);
      }
    }

    if (!scrapeAbort) {
      setStatus(
        "scrapeStatus",
        `Scrape complete — ${stagingTotal} players in staging. Run preview next.`,
        true
      );
    }
  } catch (err) {
    console.error("pesdb scrape:", err);
    setStatus(
      "scrapeStatus",
      err.message || `Scrape failed. Deploy ${SCRAPE_FUNCTION} edge function.`,
      false
    );
  } finally {
    document.getElementById("scrapeBtn")?.removeAttribute("disabled");
    document.getElementById("scrapeStopBtn")?.setAttribute("disabled", "disabled");
  }
}

function stopPesdbScrape() {
  scrapeAbort = true;
  setStatus("scrapeStatus", "Stopping after current page…", true);
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
