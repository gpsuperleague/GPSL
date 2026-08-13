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

function renderClubSelect() {
  const sel = document.getElementById("archiveClubSelect");
  if (!sel) return;
  const cur = sel.value;
  sel.innerHTML =
    `<option value="">Select club…</option>` +
    clubs
      .map((c) => {
        const arch = c.is_archived ? " (archived)" : "";
        return `<option value="${escapeHtml(c.short_name)}">${escapeHtml(
          c.club_name
        )} [${escapeHtml(c.short_name)}]${arch}</option>`;
      })
      .join("");
  if (cur && [...sel.options].some((o) => o.value === cur)) sel.value = cur;
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
  await loadClubs();
});
