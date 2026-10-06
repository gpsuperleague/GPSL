import { setStatus, supabase } from "./admin_common.js";

/** @type {Array<Record<string, any>>} */
let mgrRows = [];

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatBid(amount) {
  const n = Number(amount);
  if (!Number.isFinite(n) || n <= 0) return "";
  return `₿${(n / 1e6).toLocaleString("en-GB", { maximumFractionDigits: 2 })}m`;
}

function rowState(row) {
  if (row.manager_name) return "has_manager";
  if (row.leading.length > 1) return "multi_lead";
  if (row.leading.length === 1) return "leading";
  if (row.bid_count > 0) return "outbid";
  return "not_bid";
}

function filteredRows() {
  const vacantOnly = document.getElementById("mgrFilterVacant")?.checked;
  const notBid = document.getElementById("mgrFilterNotBid")?.checked;
  const leadingOnly = document.getElementById("mgrFilterLeading")?.checked;
  return mgrRows.filter((row) => {
    const st = rowState(row);
    if (vacantOnly && st === "has_manager") return false;
    if (notBid && st !== "not_bid") return false;
    if (leadingOnly && st !== "leading" && st !== "multi_lead") return false;
    return true;
  });
}

function renderSummary() {
  const el = document.getElementById("mgrSummary");
  if (!el) return;
  const counts = { has_manager: 0, leading: 0, multi_lead: 0, outbid: 0, not_bid: 0 };
  for (const r of mgrRows) counts[rowState(r)] += 1;
  const vacant = mgrRows.length - counts.has_manager;
  el.innerHTML = `
    <span><b>${mgrRows.length}</b> owned clubs</span>
    <span>${counts.has_manager} have a manager · <b>${vacant}</b> without</span>
    <span>${counts.leading + counts.multi_lead} leading · ${counts.outbid} outbid · ${counts.not_bid} not bid yet</span>
    ${counts.multi_lead ? `<span style="color:#ffb0b0"><b>${counts.multi_lead}</b> leading 2+ auctions (rule breach)</span>` : ""}
  `;
}

function biddingCell(row) {
  const st = rowState(row);
  if (st === "has_manager") return `<td class="chk-sub">—</td>`;
  if (st === "leading" || st === "multi_lead") {
    const list = row.leading
      .map((l) => `${escapeHtml(l.manager_name)} <span class="muted">${formatBid(l.amount)}</span>`)
      .join("<br>");
    const cls = st === "multi_lead" ? "chk-cell-warn" : "chk-cell-ok";
    const tag =
      st === "multi_lead"
        ? `<span class="chk-tag-ok" style="background:#5a2020;color:#ffb0b0;">Leading ${row.leading.length}</span>`
        : `<span class="chk-tag-ok">Leading</span>`;
    return `<td class="${cls}"${st === "multi_lead" ? ' title="Owners may only lead one manager auction at a time"' : ""}>${tag}<br>${list}<div class="chk-sub">Bid on ${row.bid_count} manager${row.bid_count === 1 ? "" : "s"}</div></td>`;
  }
  if (st === "outbid") {
    return `<td class="chk-cell-warn" title="Has bid but is not currently the highest bidder on any manager">Outbid<div class="chk-sub">Bid on ${row.bid_count} manager${row.bid_count === 1 ? "" : "s"}</div></td>`;
  }
  return `<td class="chk-cell-bad" title="No bids in the current manager draft auction">Not bid yet</td>`;
}

function renderTable() {
  const wrap = document.getElementById("mgrTableWrap");
  if (!wrap) return;
  renderSummary();
  const rows = filteredRows();
  if (!mgrRows.length) {
    wrap.innerHTML = '<p class="note">No owned clubs found.</p>';
    return;
  }
  if (!rows.length) {
    wrap.innerHTML = '<p class="note">No clubs match this filter.</p>';
    return;
  }
  const body = rows
    .map((row) => {
      const st = rowState(row);
      const mgrCell = row.manager_name
        ? `<td class="chk-cell-ok">✔ ${escapeHtml(row.manager_name)}</td>`
        : `<td class="chk-cell-bad">✘ Vacant</td>`;
      return `<tr class="${st === "not_bid" || st === "multi_lead" ? "chk-row-flagged" : ""}">
        <td class="club-cell"><div class="club-name">${escapeHtml(row.club_name)}</div><div class="club-short">${escapeHtml(row.club_short)}</div></td>
        <td>${row.owner ? escapeHtml(row.owner) : '<span class="muted">—</span>'}</td>
        ${mgrCell}
        ${biddingCell(row)}
      </tr>`;
    })
    .join("");
  wrap.innerHTML = `
    <table class="chk-table">
      <thead><tr><th>Club</th><th>Owner</th><th>Manager</th><th>Manager auction</th></tr></thead>
      <tbody>${body}</tbody>
    </table>`;
}

export async function loadManagerAuctionReadiness() {
  const wrap = document.getElementById("mgrTableWrap");
  if (!wrap) return;
  wrap.innerHTML = '<p class="note">Loading…</p>';

  const [clubsRes, listingsRes] = await Promise.all([
    supabase.from("Clubs").select("ShortName, Club, owner, owner_id, manager_id").not("owner_id", "is", null),
    supabase
      .from("Manager_Transfer_Listings")
      .select("id, manager_id, current_highest_bidder, current_highest_bid")
      .eq("listing_type", "draft")
      .eq("status", "Active"),
  ]);
  if (clubsRes.error || listingsRes.error) {
    setStatus("mgrStatus", `❌ ${(clubsRes.error || listingsRes.error).message}`, false);
    wrap.innerHTML = "";
    return;
  }
  const clubs = clubsRes.data || [];
  const listings = listingsRes.data || [];
  const clubShorts = clubs.map((c) => c.ShortName);

  const listingIds = listings.map((l) => l.id);
  const listedMgrIds = listings.map((l) => l.manager_id).filter((id) => id != null);
  const assignedMgrIds = clubs.map((c) => c.manager_id).filter((id) => id != null);

  const [contractedRes, namesRes, bidsRes] = await Promise.all([
    clubShorts.length
      ? supabase.from("Managers").select("id, name, contracted_club").in("contracted_club", clubShorts)
      : Promise.resolve({ data: [] }),
    listedMgrIds.length || assignedMgrIds.length
      ? supabase.from("Managers").select("id, name").in("id", [...new Set([...listedMgrIds, ...assignedMgrIds])])
      : Promise.resolve({ data: [] }),
    listingIds.length
      ? supabase.from("Manager_Transfer_Bids").select("listing_id, bidder_club_id").in("listing_id", listingIds)
      : Promise.resolve({ data: [] }),
  ]);
  if (bidsRes.error) console.warn("Manager draft bids:", bidsRes.error.message);

  const nameById = new Map((namesRes.data || []).map((m) => [Number(m.id), m.name]));
  const contractedByClub = new Map((contractedRes.data || []).map((m) => [m.contracted_club, m.name]));
  const listingById = new Map(listings.map((l) => [l.id, l]));

  const bidListingsByClub = new Map();
  for (const b of bidsRes.data || []) {
    const club = String(b.bidder_club_id || "").trim();
    if (!club) continue;
    if (!bidListingsByClub.has(club)) bidListingsByClub.set(club, new Set());
    bidListingsByClub.get(club).add(b.listing_id);
  }

  mgrRows = clubs
    .map((c) => {
      const leading = listings
        .filter((l) => l.current_highest_bidder === c.ShortName)
        .map((l) => ({
          manager_name: nameById.get(Number(l.manager_id)) || `Manager ${l.manager_id}`,
          amount: l.current_highest_bid,
        }));
      const bidSet = bidListingsByClub.get(c.ShortName) || new Set();
      return {
        club_short: c.ShortName,
        club_name: c.Club || c.ShortName,
        owner: c.owner || "",
        manager_name:
          contractedByClub.get(c.ShortName) ||
          (c.manager_id != null ? nameById.get(Number(c.manager_id)) || `Manager ${c.manager_id}` : null),
        leading,
        bid_count: [...bidSet].filter((id) => listingById.has(id)).length,
      };
    })
    .sort((a, b) => {
      const order = { multi_lead: 0, not_bid: 1, outbid: 2, leading: 3, has_manager: 4 };
      return order[rowState(a)] - order[rowState(b)] || a.club_name.localeCompare(b.club_name);
    });

  setStatus("mgrStatus", listings.length ? "" : "No manager draft auctions are active right now.", "warn");
  renderTable();
}

export function wireManagerAuctionReadiness() {
  for (const id of ["mgrFilterVacant", "mgrFilterNotBid", "mgrFilterLeading"]) {
    document.getElementById(id)?.addEventListener("change", renderTable);
  }
  document.getElementById("mgrReloadBtn")?.addEventListener("click", () => loadManagerAuctionReadiness());
}
