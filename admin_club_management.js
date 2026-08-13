import {
  initAdminPage,
  primeAdminPageChrome,
  setStatus,
  supabase,
} from "./admin_common.js";

primeAdminPageChrome();

let clubs = [];

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function loadClubs() {
  const { data, error } = await supabase.rpc("admin_clubs_list", {
    p_include_archived: true,
  });
  if (error) {
    setStatus(
      "archiveClubStatus",
      "❌ " +
        (error.message.includes("admin_clubs_list")
          ? "Run supabase/sql/patches/club_management_archive_owners_20260813.sql"
          : error.message),
      false
    );
    clubs = [];
    return;
  }
  clubs = Array.isArray(data) ? data : [];
  renderClubSelect();
  renderClubList();
}

function clubOptionsHtml(selected = "") {
  return (
    `<option value="">Select club…</option>` +
    clubs
      .map((c) => {
        const arch = c.is_archived ? " (archived)" : "";
        return `<option value="${escapeHtml(c.short_name)}">${escapeHtml(
          c.club_name
        )} [${escapeHtml(c.short_name)}]${arch}</option>`;
      })
      .join("")
  );
}

function fillClubSelect(selId) {
  const sel = document.getElementById(selId);
  if (!sel) return;
  const cur = sel.value;
  sel.innerHTML = clubOptionsHtml(cur);
  if (cur && [...sel.options].some((o) => o.value === cur)) sel.value = cur;
}

function renderClubSelect() {
  fillClubSelect("archiveClubSelect");
  fillClubSelect("badgeClubSelect");
}

function badgePath(short) {
  return `images/club_badges/${short}.png`;
}

function refreshBadgePreview() {
  const short = document.getElementById("badgeClubSelect")?.value || "";
  const img = document.getElementById("badgePreview");
  const file = document.getElementById("badgeFileInput")?.files?.[0];
  if (!img) return;

  if (file) {
    img.hidden = false;
    img.src = URL.createObjectURL(file);
    return;
  }

  if (!short) {
    img.hidden = true;
    img.removeAttribute("src");
    return;
  }

  img.hidden = false;
  img.onerror = () => {
    img.hidden = true;
  };
  img.src = `${badgePath(short)}?t=${Date.now()}`;
}

function readFileAsBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const result = String(reader.result || "");
      const b64 = result.includes(",") ? result.split(",")[1] : result;
      resolve(b64);
    };
    reader.onerror = () => reject(new Error("Could not read file"));
    reader.readAsDataURL(file);
  });
}

/** Wiki SVGs → PNG for images/club_badges/{SHORT}.png */
async function fileToPngBase64(file) {
  const isSvg =
    /svg/i.test(file.type) || /\.svg$/i.test(file.name || "");
  if (!isSvg && /^image\/png$/i.test(file.type)) {
    return readFileAsBase64(file);
  }
  if (!isSvg && !/^image\//i.test(file.type)) {
    throw new Error("Use a PNG or SVG badge file from Wikipedia.");
  }

  const url = URL.createObjectURL(file);
  try {
    const image = await new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = () =>
        reject(new Error("Could not load image (try exporting PNG from Wikipedia)."));
      img.src = url;
    });
    const size = Math.max(128, Math.min(512, image.naturalWidth || 256));
    const canvas = document.createElement("canvas");
    canvas.width = size;
    canvas.height = size;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("Canvas not available");
    const scale = Math.min(
      size / (image.naturalWidth || size),
      size / (image.naturalHeight || size)
    );
    const w = (image.naturalWidth || size) * scale;
    const h = (image.naturalHeight || size) * scale;
    ctx.clearRect(0, 0, size, size);
    ctx.drawImage(image, (size - w) / 2, (size - h) / 2, w, h);
    const dataUrl = canvas.toDataURL("image/png");
    return dataUrl.split(",")[1] || "";
  } finally {
    URL.revokeObjectURL(url);
  }
}

async function uploadClubBadge() {
  const short = document.getElementById("badgeClubSelect")?.value || "";
  const file = document.getElementById("badgeFileInput")?.files?.[0];
  if (!short) {
    setStatus("badgeUploadStatus", "Select a club.", false);
    return;
  }
  if (!file) {
    setStatus("badgeUploadStatus", "Choose a PNG or SVG file first.", false);
    return;
  }

  const path = badgePath(short);
  if (!confirm(`Upload ${file.name} as ${path} on GitHub for ${short}?`)) {
    return;
  }

  const btn = document.getElementById("uploadBadgeBtn");
  if (btn) btn.disabled = true;
  setStatus("badgeUploadStatus", "Uploading badge…");

  try {
    const image_base64 = await fileToPngBase64(file);
    const { data, error } = await supabase.functions.invoke(
      "club-stadiums-sync",
      {
        body: {
          action: "upload_club_badge",
          club_short_name: short,
          image_base64,
        },
      }
    );

    if (error) {
      const msg = String(error.message || error);
      throw new Error(
        /Failed to send a request to the Edge Function|BOOT_ERROR/i.test(msg)
          ? `${msg} — redeploy club-stadiums-sync (paste updated index.ts), JWT off. Check function logs if BOOT_ERROR.`
          : msg
      );
    }
    if (data?.error) throw new Error(data.error);

    setStatus(
      "badgeUploadStatus",
      `✅ Uploaded ${data?.path || path}` +
        (data?.github?.commit_sha
          ? ` (commit ${String(data.github.commit_sha).slice(0, 7)})`
          : "") +
        ". Live after GitHub Pages updates.",
      true
    );
    const input = document.getElementById("badgeFileInput");
    if (input) input.value = "";
    refreshBadgePreview();
  } catch (err) {
    setStatus("badgeUploadStatus", "❌ " + (err?.message || err), false);
  } finally {
    if (btn) btn.disabled = false;
  }
}

function renderClubList() {
  const host = document.getElementById("clubListHost");
  if (!host) return;
  if (!clubs.length) {
    host.innerHTML = `<p class="note">No clubs returned.</p>`;
    return;
  }
  host.innerHTML = `
    <table>
      <thead>
        <tr>
          <th>Club</th>
          <th>Short</th>
          <th>Owner</th>
          <th>Status</th>
          <th>Links</th>
        </tr>
      </thead>
      <tbody>
        ${clubs
          .map((c) => {
            const status = c.is_archived
              ? `<span class="pill-arch">Archived</span>`
              : `<span class="pill-live">Active</span>`;
            const owner = c.owner_tag
              ? escapeHtml(c.owner_tag)
              : c.owner_id
                ? "Linked"
                : "—";
            return `<tr>
              <td>${escapeHtml(c.club_name)}</td>
              <td><code>${escapeHtml(c.short_name)}</code></td>
              <td>${owner}</td>
              <td>${status}</td>
              <td>
                <a class="gpsl-link" href="club.html?club=${encodeURIComponent(
                  c.short_name
                )}">Details</a>
                ·
                <a class="gpsl-link" href="history.html?club=${encodeURIComponent(
                  c.short_name
                )}">History</a>
              </td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;
}

async function createClub() {
  setStatus("createClubStatus", "Creating…");
  const { data, error } = await supabase.rpc("admin_club_create", {
    p_short_name: document.getElementById("newShort")?.value,
    p_club_name: document.getElementById("newName")?.value,
    p_stadium: document.getElementById("newStadium")?.value || null,
    p_capacity: Number(document.getElementById("newCapacity")?.value) || 30000,
    p_nation: document.getElementById("newNation")?.value || null,
    p_continent: document.getElementById("newContinent")?.value || null,
  });
  if (error) {
    setStatus("createClubStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "createClubStatus",
    `✅ Created ${data?.club_name || ""} [${data?.short_name || ""}]. ${
      data?.hint || ""
    }`,
    true
  );
  document.getElementById("newShort").value = "";
  document.getElementById("newName").value = "";
  await loadClubs();
}

async function archiveClub() {
  const short = document.getElementById("archiveClubSelect")?.value;
  if (!short) {
    setStatus("archiveClubStatus", "Select a club.", false);
    return;
  }
  const club = clubs.find((c) => c.short_name === short);
  if (
    !confirm(
      `Archive ${club?.club_name || short}?\n\nOwner will be vacated. All history is kept.`
    )
  ) {
    return;
  }
  setStatus("archiveClubStatus", "Archiving…");
  const { data, error } = await supabase.rpc("admin_club_archive", {
    p_short_name: short,
    p_note: document.getElementById("archiveNote")?.value || null,
  });
  if (error) {
    setStatus("archiveClubStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "archiveClubStatus",
    `✅ Archived ${data?.club_name || short}${
      data?.owner_vacated ? " (owner vacated)" : ""
    }.`,
    true
  );
  await loadClubs();
}

async function unarchiveClub() {
  const short = document.getElementById("archiveClubSelect")?.value;
  if (!short) {
    setStatus("archiveClubStatus", "Select a club.", false);
    return;
  }
  setStatus("archiveClubStatus", "Restoring…");
  const { data, error } = await supabase.rpc("admin_club_unarchive", {
    p_short_name: short,
  });
  if (error) {
    setStatus("archiveClubStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "archiveClubStatus",
    `✅ Unarchived ${data?.club_name || short} (vacant — assign an owner when ready).`,
    true
  );
  await loadClubs();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("createClubBtn").onclick = createClub;
  document.getElementById("archiveClubBtn").onclick = archiveClub;
  document.getElementById("unarchiveClubBtn").onclick = unarchiveClub;
  document.getElementById("uploadBadgeBtn").onclick = uploadClubBadge;
  document.getElementById("badgeClubSelect")?.addEventListener("change", () => {
    const input = document.getElementById("badgeFileInput");
    if (input) input.value = "";
    refreshBadgePreview();
  });
  document.getElementById("badgeFileInput")?.addEventListener("change", () => {
    refreshBadgePreview();
  });
  await loadClubs();
});
