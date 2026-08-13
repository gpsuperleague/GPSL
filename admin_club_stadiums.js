import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { stadiumImageUrl } from "./stadium_images.js";

primeAdminPageChrome();

const STADIUM_SYNC_FUNCTION = "club-stadiums-sync";

/** @type {Array<Record<string, unknown>>} */
let allRows = [];
/** @type {Set<string>} */
const missingShorts = new Set();
let syncRunning = false;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("refreshBtn").onclick = () => loadTable();
  document.getElementById("clubSelect").onchange = onClubSelect;
  document.getElementById("downloadAllBtn").onclick = () =>
    runStadiumSync({ onlyMissing: false });
  document.getElementById("downloadMissingBtn").onclick = () =>
    runStadiumSync({ onlyMissing: true });
  document.getElementById("downloadSelectedBtn").onclick = () =>
    downloadSelected();
  document.getElementById("previewBtn").onclick = () => previewSelected();

  await loadTable();
});

async function loadTable() {
  setStatus("statusLine", "Loading clubs…", true);
  missingShorts.clear();

  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club, Stadium, Nation")
    .neq("ShortName", "FOREIGN")
    .order("ShortName");

  if (error) {
    setStatus(
      "statusLine",
      error.message.includes("Admin only") || error.message.includes("permission")
        ? "Admin access required."
        : `Could not load clubs (${error.message}).`,
      false
    );
    return;
  }

  allRows = (data || []).map((r) => ({
    short_name: r.ShortName,
    club_name: r.Club,
    stadium: r.Stadium,
    nation: r.Nation,
  }));

  populateClubSelect();
  renderTable();
  setStatus("statusLine", `${allRows.length} clubs loaded.`, true);
}

function populateClubSelect() {
  const sel = document.getElementById("clubSelect");
  if (!sel) return;

  const current = sel.value;
  sel.innerHTML = '<option value="">— Select club —</option>';
  for (const row of allRows) {
    const opt = document.createElement("option");
    opt.value = row.short_name;
    opt.textContent = `${row.club_name} (${row.short_name})`;
    sel.appendChild(opt);
  }
  if (current) sel.value = current;
  onClubSelect();
}

function onClubSelect() {
  const short = document.getElementById("clubSelect")?.value || "";
  const downloadBtn = document.getElementById("downloadSelectedBtn");
  const previewBtn = document.getElementById("previewBtn");
  const wrap = document.getElementById("selectedPreview");
  const img = document.getElementById("clubPreviewImg");
  const meta = document.getElementById("clubPreviewMeta");

  if (downloadBtn) downloadBtn.disabled = !short || syncRunning;
  if (previewBtn) previewBtn.disabled = !short || syncRunning;

  if (!short) {
    if (wrap) wrap.hidden = true;
    return;
  }

  const row = allRows.find((r) => r.short_name === short);
  if (wrap) wrap.hidden = false;
  if (meta) {
    meta.innerHTML =
      `<div><b>${escapeHtml(row?.club_name || short)}</b> (${escapeHtml(short)})</div>` +
      `<div>Stadium: ${escapeHtml(row?.stadium || "—")}</div>` +
      `<div>Nation: ${escapeHtml(row?.nation || "—")}</div>` +
      `<div>Path: <code>${escapeHtml(stadiumImageUrl(short) || "")}</code></div>`;
  }
  if (img) {
    const bust = Date.now();
    img.style.opacity = "1";
    img.src = `${stadiumImageUrl(short)}?t=${bust}`;
    img.onerror = () => {
      img.style.opacity = "0.25";
    };
    img.onload = () => {
      img.style.opacity = "1";
    };
  }
}

function markPresence(short, present) {
  if (present) missingShorts.delete(short);
  else missingShorts.add(short);

  const pill = document.querySelector(`[data-presence="${CSS.escape(short)}"]`);
  if (pill) {
    pill.className = present ? "stad-pill stad-pill--set" : "stad-pill stad-pill--missing";
    pill.textContent = present ? "On site" : "Missing";
  }
}

function renderTable() {
  const wrap = document.getElementById("tableWrap");
  if (!wrap) return;

  if (!allRows.length) {
    wrap.innerHTML = '<p style="padding:12px;color:#888;">No clubs found.</p>';
    return;
  }

  const bust = Date.now();
  const rowsHtml = allRows
    .map((row) => {
      const short = row.short_name;
      const path = stadiumImageUrl(short) || "";
      return `
        <tr data-club="${escapeAttr(short)}">
          <td class="club-short">${escapeHtml(short)}</td>
          <td>${escapeHtml(row.club_name || "")}</td>
          <td>${escapeHtml(row.stadium || "—")}</td>
          <td>${escapeHtml(row.nation || "—")}</td>
          <td><code style="font-size:10px;color:#888;">${escapeHtml(path)}</code></td>
          <td>
            <span class="stad-pill stad-pill--missing" data-presence="${escapeAttr(short)}">…</span>
          </td>
          <td>
            <img class="stad-thumb" alt="" src="${escapeAttr(path)}?t=${bust}"
              data-short="${escapeAttr(short)}">
          </td>
          <td>
            <button type="button" class="button secondary stad-pick-btn" data-club="${escapeAttr(short)}">Select</button>
          </td>
        </tr>`;
    })
    .join("");

  wrap.innerHTML = `
    <table class="stad-table">
      <thead>
        <tr>
          <th>Short</th>
          <th>Club</th>
          <th>Stadium</th>
          <th>Nation</th>
          <th>Path</th>
          <th>File</th>
          <th>Preview</th>
          <th></th>
        </tr>
      </thead>
      <tbody>${rowsHtml}</tbody>
    </table>`;

  wrap.querySelectorAll(".stad-thumb").forEach((img) => {
    const short = img.getAttribute("data-short");
    if (!short) return;
    img.addEventListener("load", () => markPresence(short, true));
    img.addEventListener("error", () => markPresence(short, false));
    // If already resolved (cached), fire handlers
    if (img.complete) {
      if (img.naturalWidth > 0) markPresence(short, true);
      else markPresence(short, false);
    }
  });

  wrap.querySelectorAll(".stad-pick-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const short = btn.getAttribute("data-club");
      const sel = document.getElementById("clubSelect");
      if (sel && short) {
        sel.value = short;
        onClubSelect();
      }
    });
  });
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapeAttr(text) {
  return escapeHtml(text).replace(/"/g, "&quot;");
}

function appendLog(line) {
  const el = document.getElementById("syncLog");
  if (!el) return;
  el.textContent += `${line}\n`;
  el.scrollTop = el.scrollHeight;
}

function clearLog() {
  const el = document.getElementById("syncLog");
  if (el) el.textContent = "";
}

function setButtonsBusy(busy) {
  syncRunning = busy;
  for (const id of [
    "downloadAllBtn",
    "downloadMissingBtn",
    "downloadSelectedBtn",
    "previewBtn",
    "refreshBtn",
  ]) {
    const el = document.getElementById(id);
    if (!el) continue;
    if (id === "downloadSelectedBtn" || id === "previewBtn") {
      const short = document.getElementById("clubSelect")?.value || "";
      el.disabled = busy || !short;
    } else {
      el.disabled = busy;
    }
  }
}

async function invokeStadiumSync(body, { retries = 4 } = {}) {
  let lastError = null;

  for (let attempt = 0; attempt < retries; attempt += 1) {
    const { data, error } = await supabase.functions.invoke(STADIUM_SYNC_FUNCTION, {
      body,
    });

    if (!error) {
      if (data?.error) throw new Error(String(data.error));
      return data;
    }

    let detail = error.message || "Stadium sync request failed";
    try {
      const ctx = error.context;
      if (ctx && typeof ctx.json === "function") {
        const payload = await ctx.json();
        if (payload?.error) detail = String(payload.error);
      }
    } catch (_) {
      /* ignore */
    }
    if (data?.error) detail = String(data.error);

    const retryable =
      /failed to send|cors|520|502|503|504|gateway timeout|network/i.test(
        detail
      );

    if (!retryable || attempt >= retries - 1) {
      if (detail.includes("Failed to send") || /520|502/.test(detail)) {
        detail +=
          " — edge function unreachable. Redeploy club-stadiums-sync, then retry.";
      }
      throw new Error(detail);
    }

    lastError = new Error(detail);
    const waitMs = 3000 * (attempt + 1);
    appendLog(`Retry ${attempt + 2}/${retries} in ${waitMs / 1000}s… (${detail})`);
    await new Promise((r) => setTimeout(r, waitMs));
  }

  throw lastError || new Error("Stadium sync request failed");
}

async function previewSelected() {
  const short = document.getElementById("clubSelect")?.value || "";
  if (!short) return;

  clearLog();
  setStatus("statusLine", `Looking up ${short} on StadiumDB…`, true);
  try {
    const data = await invokeStadiumSync({
      action: "preview",
      club_short_name: short,
    });
    appendLog(
      `${short}: ${data?.error ? `✗ ${data.error}` : "OK"}\n` +
        `  page: ${data?.page_url || "—"}\n` +
        `  image: ${data?.image_url || "—"}`
    );
    setStatus(
      "statusLine",
      data?.error ? data.error : `StadiumDB preview for ${short} ready.`,
      !data?.error
    );
  } catch (err) {
    setStatus("statusLine", err.message, false);
    appendLog(err.message);
  }
}

async function downloadSelected() {
  const short = document.getElementById("clubSelect")?.value || "";
  if (!short) return;

  const row = allRows.find((r) => r.short_name === short);
  if (
    !confirm(
      `Download stadium for ${row?.club_name || short} (${short}) from StadiumDB and commit to GitHub?\n\nOverwrites images/stadiums/${short}.jpg`
    )
  ) {
    return;
  }

  clearLog();
  setButtonsBusy(true);
  setStatus("statusLine", `Downloading stadium for ${short}…`, true);
  try {
    const data = await invokeStadiumSync({
      action: "sync_one",
      club_short_name: short,
    });
    const entry = data?.results?.[0];
    if (entry?.ok) {
      appendLog(
        `OK ${short}` +
          (entry.github?.path ? ` → ${entry.github.path}` : "") +
          (entry.skipped ? ` (skipped: ${entry.reason || ""})` : "")
      );
      setStatus("statusLine", `${short} stadium saved.`, true);
      onClubSelect();
      await loadTable();
    } else {
      appendLog(`FAIL ${short}: ${entry?.error || data?.error || "unknown"}`);
      setStatus("statusLine", entry?.error || "Download failed.", false);
    }
  } catch (err) {
    setStatus("statusLine", err.message, false);
    appendLog(err.message);
  } finally {
    setButtonsBusy(false);
  }
}

async function runStadiumSync({ onlyMissing }) {
  if (syncRunning) return;

  const label = onlyMissing ? "Download missing stadiums" : "Download all stadiums";
  if (
    !confirm(
      `${label} from StadiumDB and commit JPGs to GitHub (images/stadiums/)?\n\nRequires GITHUB_TOKEN on club-stadiums-sync.`
    )
  ) {
    return;
  }

  clearLog();
  setButtonsBusy(true);

  let offset = 0;
  let ok = 0;
  let fail = 0;
  let skipped = 0;

  /** Prefer client-detected missing list when available */
  const clubShortNames =
    onlyMissing && missingShorts.size > 0 ? [...missingShorts].sort() : null;

  try {
    while (true) {
      setStatus(
        "statusLine",
        `${label} — batch at offset ${offset}` +
          (clubShortNames ? ` (${clubShortNames.length} missing)` : "") +
          "…",
        true
      );

      const body = {
        action: "sync_batch",
        offset,
        limit: 2,
        only_missing: onlyMissing && !clubShortNames,
      };
      if (clubShortNames?.length) body.club_short_names = clubShortNames;

      const data = await invokeStadiumSync(body);

      for (const row of data?.results || []) {
        const short = row.short_name;
        if (row.ok && row.skipped) {
          skipped += 1;
          appendLog(`SKIP ${short}: ${row.reason || "already present"}`);
        } else if (row.ok) {
          ok += 1;
          appendLog(
            `OK ${short}` +
              (row.github?.path ? ` → ${row.github.path}` : "") +
              (row.page_url ? `\n  ${row.page_url}` : "")
          );
        } else {
          fail += 1;
          appendLog(`FAIL ${short}: ${row.error || "unknown"}`);
        }
      }

      if (data?.done || data?.next_offset == null) break;
      offset = data.next_offset;
    }

    appendLog(`\nDone: ${ok} ok, ${skipped} skipped, ${fail} failed.`);
    setStatus(
      "statusLine",
      `${label} finished: ${ok} ok, ${skipped} skipped, ${fail} failed.`,
      fail === 0
    );
    await loadTable();
  } catch (err) {
    setStatus("statusLine", err.message, false);
    appendLog(err.message);
  } finally {
    setButtonsBusy(false);
  }
}
