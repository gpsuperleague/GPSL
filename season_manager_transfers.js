import { supabase, initGlobal } from "./global.js";
import { loadCurrentGpslSeasonLabel } from "./player_season_transfer.js";
import {
  loadClubsMap,
  displayClubName,
  clubPageHref,
} from "./clubs_lookup.js";
import {
  loadManagerPortraitManifest,
  managerListCellHtml,
} from "./manager_images.js";

let allRows = [];
let activeFilter = "all";

function formatMoney(amount) {
  if (amount == null || Number.isNaN(Number(amount))) return "—";
  return `₿ ${Number(amount).toLocaleString("en-GB")}`;
}

function formatWhen(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-GB", {
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function clubCell(shortName) {
  if (!shortName) return "—";
  const label = displayClubName(shortName);
  const href = clubPageHref(shortName);
  return href
    ? `<a class="gpsl-link" href="${href}">${escapeHtml(label)}</a>`
    : escapeHtml(label);
}

function dealTypeLabel(kind) {
  switch (kind) {
    case "draft":
      return "Draft signing";
    case "market":
      return "Market transfer";
    case "assign":
      return "Direct / admin";
    default:
      return "Signing";
  }
}

function classifyDeal(row) {
  return row.dealKind || "assign";
}

function filteredRows() {
  if (activeFilter === "all") return allRows;
  return allRows.filter((r) => classifyDeal(r) === activeFilter);
}

function renderSummary() {
  const bar = document.getElementById("summaryBar");
  if (!bar) return;

  if (!allRows.length) {
    bar.hidden = true;
    return;
  }

  const draft = allRows.filter((r) => r.dealKind === "draft").length;
  const market = allRows.filter((r) => r.dealKind === "market").length;
  const assign = allRows.filter((r) => r.dealKind === "assign").length;
  const totalFees = allRows.reduce((sum, row) => sum + Number(row.fee || 0), 0);

  bar.hidden = false;
  bar.innerHTML = `
    <span><strong>${allRows.length}</strong> manager signing${allRows.length === 1 ? "" : "s"}</span>
    <span>Draft: <strong>${draft}</strong></span>
    <span>Market: <strong>${market}</strong></span>
    <span>Direct: <strong>${assign}</strong></span>
    <span>Total fees: <strong>${formatMoney(totalFees)}</strong></span>
  `;
}

function renderTable() {
  const host = document.getElementById("tableHost");
  const rows = filteredRows();

  if (!rows.length) {
    host.innerHTML =
      '<p class="empty">No completed manager moves for this filter yet.</p>';
    renderSummary();
    return;
  }

  const body = rows
    .map((row) => {
      const kind = classifyDeal(row);
      const mgr = {
        id: row.managerId,
        name: row.managerName,
        slug: row.managerSlug,
      };
      return `
        <tr>
          <td>${formatWhen(row.signedAt)}</td>
          <td>${managerListCellHtml(mgr)}</td>
          <td>${row.rating ?? "—"}</td>
          <td>${row.fromClub ? clubCell(row.fromClub) : "Free agent"}</td>
          <td>${clubCell(row.toClub)}</td>
          <td>${formatMoney(row.fee)}</td>
          <td><span class="type-pill ${kind}">${escapeHtml(dealTypeLabel(kind))}</span></td>
        </tr>
      `;
    })
    .join("");

  host.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Date</th>
          <th>Manager</th>
          <th>Rating</th>
          <th>From</th>
          <th>To</th>
          <th>Fee</th>
          <th>Type</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>
  `;

  renderSummary();
}

async function loadSeasonStart() {
  const { data, error } = await supabase
    .from("competition_season_public")
    .select("id, label, started_at")
    .eq("is_current", true)
    .maybeSingle();

  if (error) {
    console.error("competition_season_public:", error);
    return {
      id: null,
      label: (await loadCurrentGpslSeasonLabel(supabase)) || "Current season",
      startedAt: null,
    };
  }

  return {
    id: data?.id ?? null,
    label:
      data?.label ||
      (await loadCurrentGpslSeasonLabel(supabase)) ||
      "Current season",
    startedAt: data?.started_at || null,
  };
}

async function loadSignedManagers(seasonId, listingManagerIds) {
  const cols =
    "id, name, slug, rating, contracted_club, market_value, signed_season_id, updated_at";
  const byId = new Map();

  if (seasonId) {
    const { data, error } = await supabase
      .from("Managers")
      .select(cols)
      .eq("signed_season_id", seasonId)
      .not("contracted_club", "is", null);
    if (error) throw error;
    for (const mgr of data || []) {
      byId.set(mgr.id, mgr);
    }
  }

  const extraIds = listingManagerIds.filter((id) => !byId.has(id));
  if (extraIds.length) {
    const { data, error } = await supabase
      .from("Managers")
      .select(cols)
      .in("id", extraIds)
      .not("contracted_club", "is", null);
    if (error) throw error;
    for (const mgr of data || []) {
      byId.set(mgr.id, mgr);
    }
  }

  return [...byId.values()];
}

async function loadSeasonListings(seasonStartedAt) {
  let q = supabase
    .from("Manager_Transfer_Listings")
    .select(
      "id, manager_id, seller_club_id, listing_type, current_highest_bid, current_highest_bidder, transfer_completed, status, updated_at"
    )
    .in("status", ["Closed", "Review"])
    .not("current_highest_bidder", "is", null)
    .order("updated_at", { ascending: false });

  if (seasonStartedAt) {
    q = q.gte("updated_at", seasonStartedAt);
  }

  const { data, error } = await q.limit(500);
  if (error) throw error;
  return data || [];
}

function pickListingForManager(managerId, toClub, listings) {
  const matches = listings.filter(
    (l) => String(l.manager_id) === String(managerId)
  );
  if (!matches.length) return null;

  const buyerMatch = matches.find((l) => l.current_highest_bidder === toClub);
  if (buyerMatch) return buyerMatch;

  const completed = matches.find((l) => l.transfer_completed);
  if (completed) return completed;

  return matches.sort(
    (a, b) => new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime()
  )[0];
}

function listingDealKind(listingType) {
  if (listingType === "draft") return "draft";
  if (listingType === "standard" || listingType === "direct") return "market";
  return "market";
}

function buildRows(managers, listings) {
  const rows = [];

  for (const mgr of managers) {
    const toClub = mgr.contracted_club;
    const listing = pickListingForManager(mgr.id, toClub, listings);

    if (listing && listing.current_highest_bidder !== toClub) {
      continue;
    }

    let dealKind = "assign";
    let fee = mgr.market_value;
    let fromClub = null;
    let signedAt = mgr.updated_at;

    if (listing) {
      dealKind = listingDealKind(listing.listing_type);
      fee = listing.current_highest_bid ?? mgr.market_value;
      fromClub = listing.seller_club_id || null;
      signedAt = listing.updated_at || mgr.updated_at;
    }

    rows.push({
      managerId: mgr.id,
      managerName: mgr.name,
      managerSlug: mgr.slug,
      rating: mgr.rating,
      fromClub,
      toClub,
      fee,
      signedAt,
      dealKind,
    });
  }

  rows.sort(
    (a, b) => new Date(b.signedAt).getTime() - new Date(a.signedAt).getTime()
  );
  return rows;
}

function wireFilters() {
  document.querySelectorAll(".filter-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      activeFilter = btn.dataset.filter || "all";
      document.querySelectorAll(".filter-btn").forEach((b) => {
        b.classList.toggle("active", b === btn);
      });
      renderTable();
    });
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  await Promise.all([loadClubsMap(), loadManagerPortraitManifest()]);
  wireFilters();

  try {
    const { id: seasonId, label, startedAt } = await loadSeasonStart();
    const labelEl = document.getElementById("seasonLabel");
    if (labelEl) {
      labelEl.textContent = startedAt
        ? ` — ${label} (since ${new Date(startedAt).toLocaleDateString("en-GB")})`
        : ` — ${label}`;
    }

    const listings = await loadSeasonListings(startedAt);
    const listingManagerIds = [
      ...new Set(listings.map((l) => l.manager_id).filter(Boolean)),
    ];
    const managers = await loadSignedManagers(seasonId, listingManagerIds);

    allRows = buildRows(managers, listings);
    renderTable();
  } catch (err) {
    console.error(err);
    document.getElementById("tableHost").innerHTML =
      `<p class="empty">Could not load manager transfers: ${escapeHtml(err.message || "error")}</p>`;
  }
});
