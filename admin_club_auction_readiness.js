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
  const notBid = document.getElementById("readyFilterNotBid")?.checked;
  return readinessRows.filter((row) => {
    if (notReady && row.ready) return false;
    if (notBid && row.bid_club_count > 0) return false;
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
  const leading = readinessRows.filter((r) => r.leading_club).length;
  const outbid = readinessRows.filter((r) => !r.leading_club && r.bid_club_count > 0).length;
  const notBid = readinessRows.filter((r) => !r.bid_club_count).length;
  const missing = ITEMS.map(([key, label]) => {
    const n = readinessRows.filter((r) => !r[key]).length;
    return n ? `<span>${n} missing ${label.toLowerCase()}</span>` : "";
  }).join("");
  el.innerHTML = `
    <span><b>${total}</b> owners without a club</span>
    <span>${ready} ready · ${total - ready} not ready</span>
    <span>${invited.length} invited${invitedNotReady ? ` (<b style="color:#ffb0b0">${invitedNotReady} not ready</b>)` : ""}</span>
    <span>${leading} leading a club · ${outbid} outbid · ${notBid} not bid yet</span>
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
      const inviteCell = row.invited_to_auction
        ? `<td class="chk-sub">Invited</td>`
        : `<td><button type="button" class="ready-invite-btn" data-owner-id="${escapeHtml(row.owner_id)}" data-owner-label="${escapeHtml(row.owner_tag || row.email || "owner")}"${
            row.ready ? "" : ' title="Not ready yet — they can be invited, but cannot bid until all items are done"'
          }>Invite to auction</button></td>`;
      return `<tr class="${row.ready ? "" : "chk-row-flagged"}">
        <td class="club-cell">${who}${email}</td>
        <td>${escapeHtml(statusLabel(row))}${pos}${season}</td>
        ${readyCell}
        ${biddingCell(row)}
        ${checkCell(row.has_tag, escapeHtml(row.owner_tag || ""), "Owner sets their tag on the Awaiting club page")}
        ${checkCell(row.has_timezone, tz, "Owner picks a timezone on the Awaiting club page")}
        ${checkCell(row.has_availability, `${slots} block${slots === 1 ? "" : "s"}`, "Owner saves weekly match availability")}
        ${checkCell(row.has_interest, interest, "Owner marks 1 club as interest in the Club Database")}
        ${checkCell(row.has_backup, backup, "Owner marks 1 different club as backup in the Club Database")}
        ${inviteCell}
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
          <th>Bidding</th>
          ${ITEMS.map(([, label]) => `<th>${label}</th>`).join("")}
          <th>Auction</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>`;
}

/** Attach bid activity on currently active club auction listings to each readiness row. */
async function attachBidActivity(rows) {
  const { data: listings, error: listErr } = await supabase
    .from("club_auction_listings_public")
    .select("id, club_short_name, club_name, current_highest_bidder, current_highest_bid");
  if (listErr) {
    console.warn("Club auction listings:", listErr.message);
    return;
  }
  const listingById = new Map((listings || []).map((l) => [l.id, l]));
  const bidClubsByOwner = new Map();
  if (listingById.size) {
    const { data: bids, error: bidErr } = await supabase
      .from("Club_Auction_Bids")
      .select("listing_id, bidder_owner_id")
      .in("listing_id", [...listingById.keys()]);
    if (bidErr) console.warn("Club auction bids:", bidErr.message);
    for (const b of bids || []) {
      if (!b.bidder_owner_id) continue;
      if (!bidClubsByOwner.has(b.bidder_owner_id)) bidClubsByOwner.set(b.bidder_owner_id, new Set());
      bidClubsByOwner.get(b.bidder_owner_id).add(b.listing_id);
    }
  }
  for (const row of rows) {
    const lead = (listings || []).find((l) => l.current_highest_bidder && l.current_highest_bidder === row.owner_id);
    row.leading_club = lead ? lead.club_name || lead.club_short_name : null;
    row.leading_bid = lead ? lead.current_highest_bid : null;
    row.bid_club_count = bidClubsByOwner.get(row.owner_id)?.size || 0;
  }
}

function formatBid(amount) {
  const n = Number(amount);
  if (!Number.isFinite(n) || n <= 0) return "";
  return `₿${(n / 1e6).toLocaleString("en-GB", { maximumFractionDigits: 2 })}m`;
}

function biddingCell(row) {
  if (row.leading_club) {
    return `<td class="chk-cell-ok"><span class="chk-tag-ok">Leading</span> ${escapeHtml(row.leading_club)}${
      row.leading_bid ? ` <span class="muted">${formatBid(row.leading_bid)}</span>` : ""
    }<div class="chk-sub">Bid on ${row.bid_club_count} club${row.bid_club_count === 1 ? "" : "s"}</div></td>`;
  }
  if (row.bid_club_count > 0) {
    return `<td class="chk-cell-warn" title="Has bid but is not currently the highest bidder anywhere">Outbid<div class="chk-sub">Bid on ${row.bid_club_count} club${row.bid_club_count === 1 ? "" : "s"}</div></td>`;
  }
  return `<td class="chk-cell-bad" title="No bids placed in the current club auction">Not bid yet</td>`;
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
  await attachBidActivity(readinessRows);
  setStatus("readyStatus", "");
  renderReadinessTable();
}

async function inviteOwnerToAuction(btn) {
  const ownerId = btn.dataset.ownerId;
  const label = btn.dataset.ownerLabel || "this owner";
  if (!ownerId) return;
  if (!window.confirm(`Invite ${label} to the club auction now? They get the default starting budget and can bid once all items are ready.`)) {
    return;
  }
  btn.disabled = true;
  btn.textContent = "Inviting…";
  const { error } = await supabase.rpc("admin_waiting_list_set_auction_invite", {
    p_owner_id: ownerId,
    p_invited: true,
  });
  if (error) {
    setStatus("readyStatus", `❌ Invite failed for ${label}: ${error.message}`, false);
    btn.disabled = false;
    btn.textContent = "Invite to auction";
    return;
  }
  setStatus("readyStatus", `✅ ${label} invited to the club auction.`, true);
  await loadAuctionReadiness();
}

export function wireAuctionReadiness() {
  document.getElementById("readyTableWrap")?.addEventListener("click", (e) => {
    const btn = e.target.closest?.(".ready-invite-btn");
    if (btn) void inviteOwnerToAuction(btn);
  });
  document.getElementById("readyFilterNotReady")?.addEventListener("change", renderReadinessTable);
  document.getElementById("readyFilterInvited")?.addEventListener("change", renderReadinessTable);
  document.getElementById("readyFilterNotBid")?.addEventListener("change", renderReadinessTable);
  document.getElementById("readyReloadBtn")?.addEventListener("click", () => loadAuctionReadiness());
}
