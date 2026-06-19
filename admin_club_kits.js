import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  KIT_KINDS,
  defaultKitImagePath,
  resolveKitImageSrc,
} from "./club_kits_common.js";

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
  document.getElementById("cofSyncBtn").onclick = () => syncAllFromCof();
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
