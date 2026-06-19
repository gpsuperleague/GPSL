import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  KIT_KINDS,
  defaultKitImagePath,
  resolveKitImageSrc,
} from "./club_kits_common.js";
import { currentKitSeasonStartYear } from "./club_kits_cof.js";

primeAdminPageChrome();

const COF_SYNC_FUNCTION = "club-kits-cof-sync";

/** @type {Array<Record<string, unknown>>} */
let allRows = [];
let cofSyncRunning = false;

const FIELD_IDS = {
  home: "homeUrl",
  away: "awayUrl",
  third: "thirdUrl",
};

const PREVIEW_IDS = {
  home: "homePreview",
  away: "awayPreview",
  third: "thirdPreview",
};

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("refreshBtn").onclick = () => loadTable();
  document.getElementById("saveKitsBtn").onclick = saveKits;
  document.getElementById("clubSelect").onchange = onClubSelect;
  document.getElementById("downloadLatestKitsBtn").onclick = () =>
    downloadLatestKits({ download: true, github: true });
  document.getElementById("cofLinksOnlyBtn").onclick = () =>
    downloadLatestKits({ download: false, github: false });
  document.getElementById("cofPreviewBtn").onclick = () => previewCofForSelected();

  for (const kind of KIT_KINDS) {
    const input = document.getElementById(FIELD_IDS[kind]);
    if (input) input.addEventListener("input", () => updatePreviews());
  }

  await loadTable();
});

async function loadTable() {
  setStatus("statusLine", "Loading clubs…", true);

  const { data, error } = await supabase.rpc("admin_club_kits_list");

  if (error) {
    setStatus(
      "statusLine",
      error.message.includes("Admin only")
        ? "Admin access required."
        : `Could not load kits (${error.message}). Run supabase/sql/patches/club_kits.sql first.`,
      false
    );
    return;
  }

  allRows = data || [];
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
    opt.value = row.club_short_name;
    opt.textContent = `${row.club_name} (${row.club_short_name})`;
    sel.appendChild(opt);
  }
  if (current) sel.value = current;
}

function rowForClub(short) {
  return allRows.find((r) => r.club_short_name === short) || null;
}

function onClubSelect() {
  const short = document.getElementById("clubSelect")?.value || "";
  const editor = document.getElementById("kitsEditor");
  const saveBtn = document.getElementById("saveKitsBtn");

  if (!short) {
    if (editor) editor.hidden = true;
    if (saveBtn) saveBtn.disabled = true;
    const previewBtn = document.getElementById("cofPreviewBtn");
    if (previewBtn) previewBtn.disabled = true;
    return;
  }

  const row = rowForClub(short);
  if (editor) editor.hidden = false;
  if (saveBtn) saveBtn.disabled = false;

  const previewBtn = document.getElementById("cofPreviewBtn");
  if (previewBtn) previewBtn.disabled = false;

  document.getElementById("defaultHome").textContent = defaultKitImagePath(short, "home");
  document.getElementById("defaultAway").textContent = defaultKitImagePath(short, "away");
  document.getElementById("defaultThird").textContent = defaultKitImagePath(short, "third");

  document.getElementById("homeUrl").value = row?.home_image_url || "";
  document.getElementById("awayUrl").value = row?.away_image_url || "";
  document.getElementById("thirdUrl").value = row?.third_image_url || "";

  updatePreviews();
}

function updatePreviews() {
  const short = document.getElementById("clubSelect")?.value || "";
  if (!short) return;

  for (const kind of KIT_KINDS) {
    const input = document.getElementById(FIELD_IDS[kind]);
    const img = document.getElementById(PREVIEW_IDS[kind]);
    if (!img) continue;
    const src = resolveKitImageSrc(input?.value || "", short, kind);
    img.src = src;
    img.onerror = () => {
      img.style.opacity = "0.35";
    };
    img.onload = () => {
      img.style.opacity = "1";
    };
  }
}

async function saveKits() {
  const short = document.getElementById("clubSelect")?.value || "";
  if (!short) return;

  const saveBtn = document.getElementById("saveKitsBtn");
  if (saveBtn) saveBtn.disabled = true;

  const { data, error } = await supabase.rpc("admin_club_kits_upsert", {
    p_club_short_name: short,
    p_home_image_url: document.getElementById("homeUrl")?.value || null,
    p_away_image_url: document.getElementById("awayUrl")?.value || null,
    p_third_image_url: document.getElementById("thirdUrl")?.value || null,
  });

  if (saveBtn) saveBtn.disabled = false;

  if (error) {
    setStatus("statusLine", error.message, false);
    return;
  }

  const idx = allRows.findIndex((r) => r.club_short_name === short);
  const updated = {
    club_short_name: short,
    club_name: rowForClub(short)?.club_name || short,
    home_image_url: data?.home_image_url ?? null,
    away_image_url: data?.away_image_url ?? null,
    third_image_url: data?.third_image_url ?? null,
    updated_at: new Date().toISOString(),
  };
  if (idx >= 0) allRows[idx] = { ...allRows[idx], ...updated };
  else allRows.push(updated);

  renderTable();
  setStatus("statusLine", `Saved kits for ${short}.`, true);
}

function kitStatusPill(url) {
  if (url) {
    return '<span class="kits-pill kits-pill--set">custom</span>';
  }
  return '<span class="kits-pill kits-pill--default">default</span>';
}

function renderTable() {
  const wrap = document.getElementById("tableWrap");
  if (!wrap) return;

  if (!allRows.length) {
    wrap.innerHTML = '<p style="padding:12px;color:#888;">No clubs found.</p>';
    return;
  }

  const rowsHtml = allRows
    .map((row) => {
      const short = row.club_short_name;
      return `
        <tr data-club="${escapeAttr(short)}">
          <td>
            <div>${escapeHtml(row.club_name || short)}</div>
            <div class="club-short">${escapeHtml(short)}</div>
          </td>
          <td>${kitStatusPill(row.home_image_url)}</td>
          <td>${kitStatusPill(row.away_image_url)}</td>
          <td>${kitStatusPill(row.third_image_url)}</td>
          <td>
            <button type="button" class="button secondary kits-edit-btn" data-club="${escapeAttr(short)}">Edit</button>
          </td>
        </tr>`;
    })
    .join("");

  wrap.innerHTML = `
    <table class="kits-table">
      <thead>
        <tr>
          <th>Club</th>
          <th>Home</th>
          <th>Away</th>
          <th>3rd</th>
          <th></th>
        </tr>
      </thead>
      <tbody>${rowsHtml}</tbody>
    </table>`;

  wrap.querySelectorAll(".kits-edit-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const short = btn.getAttribute("data-club");
      const sel = document.getElementById("clubSelect");
      if (sel && short) {
        sel.value = short;
        onClubSelect();
        document.getElementById("kitsEditor")?.scrollIntoView({ behavior: "smooth", block: "start" });
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

function appendCofLog(line) {
  const el = document.getElementById("cofSyncLog");
  if (!el) return;
  el.textContent += `${line}\n`;
  el.scrollTop = el.scrollHeight;
}

function clearCofLog() {
  const el = document.getElementById("cofSyncLog");
  if (el) el.textContent = "";
}

async function invokeCofSync(body, { retries = 4 } = {}) {
  let lastError = null;

  for (let attempt = 0; attempt < retries; attempt += 1) {
    const { data, error } = await supabase.functions.invoke(COF_SYNC_FUNCTION, {
      body,
    });

    if (!error) {
      if (data?.error) throw new Error(String(data.error));
      return data;
    }

    let detail = error.message || "COF sync request failed";
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
          " — edge function unreachable (520). Wait a minute, redeploy club-kits-cof-sync, then retry.";
      }
      if (detail.includes("504") || detail.includes("Gateway Timeout")) {
        detail +=
          " — edge function timed out (~60s). Use Save COF links only (uncheck Storage).";
      }
      throw new Error(detail);
    }

    lastError = new Error(detail);
    const waitMs = 3000 * (attempt + 1);
    appendCofLog(`Retry ${attempt + 2}/${retries} in ${waitMs / 1000}s… (${detail})`);
    await new Promise((r) => setTimeout(r, waitMs));
  }

  throw lastError || new Error("COF sync request failed");
}

async function previewCofForSelected() {
  const short = document.getElementById("clubSelect")?.value || "";
  if (!short) return;

  clearCofLog();
  setStatus("statusLine", `Looking up ${short} on Colours of Football…`, true);
  try {
    const data = await invokeCofSync({
      action: "preview_club",
      club_short_name: short,
    });
    const kits = data?.result?.kits || {};
    const season = data?.result?.seasonLabel || data?.result?.latestSeasonCode || "?";
    appendCofLog(
      `${short} (${season}): ${data?.result?.cofClubName || data?.result?.slug || "?"}\n` +
        `  home: ${kits.home || "—"}\n` +
        `  away: ${kits.away || "—"}\n` +
        `  third: ${kits.third || "—"}`
    );
    setStatus("statusLine", `COF preview for ${short} ready.`, true);
  } catch (err) {
    setStatus("statusLine", err.message, false);
    appendCofLog(err.message);
  }
}

async function runSyncPass({
  downloadToGithub,
  seasonStartYear = null,
  clubShortNames = null,
  skipIfNewerSaved = false,
  passLabel = "",
}) {
  let offset = 0;
  const failed = new Set();
  let ok = 0;
  let fail = 0;

  while (true) {
    setStatus(
      "statusLine",
      passLabel
        ? `${passLabel} — club ${offset + 1}${clubShortNames ? ` / ${clubShortNames.length}` : "+"}…`
        : `Downloading latest kits — club ${offset + 1}+…`,
      true
    );

    const body = {
      action: "sync_batch",
      offset,
      limit: 1,
      download: !!downloadToGithub,
      github: !!downloadToGithub,
      strict_season: true,
    };
    if (seasonStartYear != null) body.season_start_year = seasonStartYear;
    if (clubShortNames?.length) body.club_short_names = clubShortNames;
    if (skipIfNewerSaved) body.skip_if_newer_saved = true;

    const data = await invokeCofSync(body);

    for (const row of data?.results || []) {
      const short = row.club_short_name;
      if (row.ok && row.skipped) {
        appendCofLog(`SKIP ${short}: ${row.reason || "newer kits already saved"}`);
      } else if (row.ok) {
        ok += 1;
        const season = row.cof?.season_label || "?";
        const gh =
          row.github?.committed?.length > 0
            ? ` → GitHub (${row.github.committed.length} file(s))`
            : "";
        appendCofLog(`OK ${short} (${season})${gh}`);
      } else {
        fail += 1;
        if (short) failed.add(short);
        appendCofLog(`FAIL ${short}: ${row.error || "failed"}`);
      }
    }

    if (data?.done || data?.next_offset == null) break;
    offset = data.next_offset;
    await new Promise((r) => setTimeout(r, 1200));
  }

  return { failed, ok, fail };
}

async function downloadLatestKits({ download, github } = { download: true, github: true }) {
  if (cofSyncRunning) return;

  const downloadToGithub = download && github !== false;

  const msg = downloadToGithub
    ? "Download latest kits from COF, commit PNGs to GitHub (images/clubs_kits/), and update club_kits?\n\nRequires GITHUB_TOKEN in Supabase Edge Function secrets."
    : "Save COF image URLs to club_kits only (no GitHub files)?\n\nRuns latest season first, then older seasons for clubs still missing kits.";

  if (!confirm(msg)) return;

  cofSyncRunning = true;
  const mainBtn = document.getElementById("downloadLatestKitsBtn");
  const linksBtn = document.getElementById("cofLinksOnlyBtn");
  if (mainBtn) mainBtn.disabled = true;
  if (linksBtn) linksBtn.disabled = true;
  clearCofLog();

  const seasonStart = currentKitSeasonStartYear();
  const maxFallbackPasses = 4;
  let pending = null;
  let totalOk = 0;
  let totalFail = 0;

  try {
    for (let pass = 0; pass < maxFallbackPasses; pass += 1) {
      if (pending && pending.size === 0) break;

      const targetYear = pass === 0 ? null : seasonStart - pass;
      const label =
        pass === 0
          ? "Pass 1: latest season on COF"
          : `Pass ${pass + 1}: ${targetYear}-${String(targetYear + 1).slice(-2)}`;

      appendCofLog(`\n=== ${label} ===`);

      const { failed, ok, fail } = await runSyncPass({
        downloadToGithub,
        seasonStartYear: targetYear,
        clubShortNames: pending ? [...pending] : null,
        skipIfNewerSaved: pass > 0,
        passLabel: label,
      });

      totalOk += ok;
      totalFail = fail;
      pending = failed;
    }

    await loadTable();
    const remaining = pending?.size || 0;
    setStatus(
      "statusLine",
      remaining
        ? `Latest kits — ${totalOk} updated, ${remaining} still missing after fallback passes.`
        : `Latest kits — ${totalOk} updated, all clubs matched.`,
      remaining === 0
    );
  } catch (err) {
    setStatus("statusLine", err.message, false);
    appendCofLog(err.message);
  } finally {
    cofSyncRunning = false;
    if (mainBtn) mainBtn.disabled = false;
    if (linksBtn) linksBtn.disabled = false;
  }
}
