import { setStatus, supabase } from "./admin_common.js";

/** @type {Array<Record<string, any>>} */
let readinessRows = [];

const ITEMS = [
  ["has_tag", "Owner tag"],
  ["has_timezone", "Timezone"],
  ["has_availability", "Availability"],
  ["has_interest", "Primary club"],
  ["has_backup", "Backup club"],
];

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function statusLabel(row) {
  if (row.invited_to_auction) return "Invited to auction";
  if (row.status === "on_absence") return "Waiting list (absence)";
  return "Waiting list";
}

function checkCell(done, text, missingTip) {
  if (done) return `<td class="chk-cell-ok">✔ ${text}</td>`;
  return `<td class="chk-cell-bad" title="${escapeHtml(missingTip)}">✘ Missing</td>`;
}

function filteredReadinessRows() {
  const notReady = document.getElementById("readyFilterNotReady")?.checked;
  const invitedOnly = document.getElementById("readyFilterInvited")?.checked;
  return readinessRows.filter((row) => {
    if (notReady && row.ready) return false;
    if (invitedOnly && !row.invited_to_auction) return false;
    return true;
  });
}

function renderReadinessSummary() {
  const el = document.getElementById("readySummary");
  if (!el) return;
  const total = readinessRows.length;
  const ready = readinessRows.filter((r) => r.ready).length;
  const invited = readinessRows.filter((r) => r.invited_to_auction);
  const invitedNotReady = invited.filter((r) => !r.ready).length;
  const missing = ITEMS.map(([key, label]) => {
    const n = readinessRows.filter((r) => !r[key]).length;
    return n ? `<span>${n} missing ${label.toLowerCase()}</span>` : "";
  }).join("");
  el.innerHTML = `
    <span><b>${total}</b> owners without a club</span>
    <span>${ready} ready · ${total - ready} not ready</span>
    <span>${invited.length} invited${invitedNotReady ? ` (<b style="color:#ffb0b0">${invitedNotReady} not ready</b>)` : ""}</span>
    ${missing}
  `;
}

function renderReadinessTable() {
  const wrap = document.getElementById("readyTableWrap");
  if (!wrap) return;
  renderReadinessSummary();

  const rows = filteredReadinessRows();
  if (!readinessRows.length) {
    wrap.innerHTML = '<p class="note">No owners are waiting for a club.</p>';
    return;
  }
  if (!rows.length) {
    wrap.innerHTML = '<p class="note">No owners match this filter.</p>';
    return;
  }

  const body = rows
    .map((row) => {
      const who = row.owner_tag
        ? `<div class="club-name">${escapeHtml(row.owner_tag)}</div>`
        : `<div class="club-name muted">No tag</div>`;
      const email = row.email ? `<div class="club-short">${escapeHtml(row.email)}</div>` : "";
      const pos = row.waiting_list_position != null ? ` · #${row.waiting_list_position}` : "";
      const season = row.confirmed_live_season
        ? ""
        : `<div class="chk-sub">Season invite not accepted</div>`;
      const tz = row.owner_timezone ? escapeHtml(String(row.owner_timezone).replace(/_/g, " ")) : "";
      const slots = Number(row.availability_slot_count || 0);
      const interest = escapeHtml(row.interest_club_name || row.interest_club_short || "");
      const backup = escapeHtml(row.backup_club_name || row.backup_club_short || "");
      const readyCell = row.ready
        ? `<td class="chk-cell-ok"><span class="chk-tag-ok">Ready</span></td>`
        : `<td class="chk-cell-bad">${ITEMS.filter(([k]) => !row[k]).length} to do</td>`;
      return `<tr class="${row.ready ? "" : "chk-row-flagged"}">
        <td class="club-cell">${who}${email}</td>
        <td>${escapeHtml(statusLabel(row))}${pos}${season}</td>
        ${readyCell}
        ${checkCell(row.has_tag, escapeHtml(row.owner_tag || ""), "Owner sets their tag on the Awaiting club page")}
        ${checkCell(row.has_timezone, tz, "Owner picks a timezone on the Awaiting club page")}
        ${checkCell(row.has_availability, `${slots} block${slots === 1 ? "" : "s"}`, "Owner saves weekly match availability")}
        ${checkCell(row.has_interest, interest, "Owner marks 1 club as interest in the Club Database")}
        ${checkCell(row.has_backup, backup, "Owner marks 1 different club as backup in the Club Database")}
      </tr>`;
    })
    .join("");

  wrap.innerHTML = `
    <table class="chk-table">
      <thead>
        <tr>
          <th>Owner</th>
          <th>Status</th>
          <th>Ready</th>
          ${ITEMS.map(([, label]) => `<th>${label}</th>`).join("")}
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>`;
}

export async function loadAuctionReadiness() {
  const wrap = document.getElementById("readyTableWrap");
  if (!wrap) return;
  wrap.innerHTML = '<p class="note">Loading…</p>';
  const { data, error } = await supabase.rpc("admin_club_auction_owner_readiness");
  if (error) {
    const msg = [error.message, error.hint].filter(Boolean).join(" — ");
    setStatus(
      "readyStatus",
      `❌ ${msg}. Run supabase/sql/patches/admin_club_auction_owner_readiness_20261002.sql in Supabase.`,
      false
    );
    wrap.innerHTML = "";
    return;
  }
  readinessRows = Array.isArray(data) ? data : [];
  setStatus("readyStatus", "");
  renderReadinessTable();
}

export function wireAuctionReadiness() {
  document.getElementById("readyFilterNotReady")?.addEventListener("change", renderReadinessTable);
  document.getElementById("readyFilterInvited")?.addEventListener("change", renderReadinessTable);
  document.getElementById("readyReloadBtn")?.addEventListener("click", () => loadAuctionReadiness());
}
