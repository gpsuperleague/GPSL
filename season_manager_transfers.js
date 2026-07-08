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

async function loadManagersByIds(ids) {
  const unique = [...new Set((ids || []).map((id) => Number(id)).filter(Number.isFinite))];
  if (!unique.length) return new Map();

  const { data, error } = await supabase
    .from("Managers")
    .select("id, name, slug, rating, market_value")
    .in("id", unique);
  if (error) throw error;

  const byId = new Map();
  for (const mgr of data || []) {
    byId.set(Number(mgr.id), mgr);
  }
  return byId;
}

async function loadSeasonListings(seasonStartedAt) {
  let q = supabase
    .from("Manager_Transfer_Listings")
    .select(
      "id, manager_id, seller_club_id, listing_type, current_highest_bid, current_highest_bidder, transfer_completed, status, updated_at"
    )
    .eq("transfer_completed", true)
    .not("current_highest_bidder", "is", null)
    .order("updated_at", { ascending: false });

  if (seasonStartedAt) {
    q = q.gte("updated_at", seasonStartedAt);
  }

  const { data, error } = await q.limit(500);
  if (error) throw error;
  return data || [];
}

async function loadSeasonSigningLedger(seasonId, seasonStartedAt) {
  let q = supabase
    .from("competition_finance_ledger")
    .select("id, club_short_name, amount, description, metadata, created_at, season_id")
    .eq("entry_type", "contract_signing_offer")
    .lt("amount", 0)
    .order("created_at", { ascending: false });

  if (seasonId) {
    q = q.eq("season_id", seasonId);
  } else if (seasonStartedAt) {
    q = q.gte("created_at", seasonStartedAt);
  }

  const { data, error } = await q.limit(500);
  if (error) {
    console.warn("manager signing ledger:", error.message);
    return [];
  }

  return (data || []).filter((row) => {
    const mid = Number(row.metadata?.manager_id);
    return Number.isFinite(mid);
  });
}

function listingDealKind(listingType) {
  if (listingType === "draft") return "draft";
  if (listingType === "standard" || listingType === "direct") return "market";
  return "market";
}

function buildRowsFromEvents(listings, ledgerRows, managersById) {
  const byKey = new Map();

  for (const listing of listings || []) {
    const managerId = Number(listing.manager_id);
    const toClub = String(listing.current_highest_bidder || "").trim().toUpperCase();
    if (!Number.isFinite(managerId) || !toClub) continue;

    const key = `${managerId}|${toClub}`;
    const mgr = managersById.get(managerId);
    const row = {
      managerId,
      managerName: mgr?.name || `Manager #${managerId}`,
      managerSlug: mgr?.slug || null,
      rating: mgr?.rating ?? null,
      fromClub: listing.seller_club_id || null,
      toClub,
      fee: listing.current_highest_bid ?? mgr?.market_value ?? 0,
      signedAt: listing.updated_at,
      dealKind: listingDealKind(listing.listing_type),
    };
    const prev = byKey.get(key);
    if (!prev || new Date(row.signedAt) > new Date(prev.signedAt)) {
      byKey.set(key, row);
    }
  }

  for (const ledger of ledgerRows || []) {
    const managerId = Number(ledger.metadata?.manager_id);
    const toClub = String(ledger.club_short_name || "").trim().toUpperCase();
    if (!Number.isFinite(managerId) || !toClub) continue;

    const key = `${managerId}|${toClub}`;
    const mgr = managersById.get(managerId);
    const isDraft =
      ledger.metadata?.manager_draft === true ||
      ledger.metadata?.manager_draft === "true" ||
      ledger.metadata?.manager_draft === "t" ||
      ledger.metadata?.manager_draft === "1";
    const row = {
      managerId,
      managerName: mgr?.name || `Manager #${managerId}`,
      managerSlug: mgr?.slug || null,
      rating: mgr?.rating ?? null,
      fromClub: null,
      toClub,
      fee: Math.abs(Number(ledger.amount) || 0),
      signedAt: ledger.created_at,
      dealKind: isDraft ? "draft" : "assign",
    };
    const prev = byKey.get(key);
    if (!prev) {
      byKey.set(key, row);
      continue;
    }
    // Prefer listing deal type/fee when both exist; keep newest timestamp.
    if (new Date(row.signedAt) >= new Date(prev.signedAt)) {
      byKey.set(key, {
        ...prev,
        ...row,
        dealKind: prev.dealKind === "draft" || isDraft ? "draft" : prev.dealKind,
        fee: prev.fee || row.fee,
        fromClub: prev.fromClub ?? row.fromClub,
      });
    } else if (isDraft && prev.dealKind !== "draft") {
      prev.dealKind = "draft";
    }
  }

  return [...byKey.values()].sort(
    (a, b) => new Date(b.signedAt).getTime() - new Date(a.signedAt).getTime()
  );
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

    const [listings, ledgerRows] = await Promise.all([
      loadSeasonListings(startedAt),
      loadSeasonSigningLedger(seasonId, startedAt),
    ]);

    const managerIds = [
      ...listings.map((l) => l.manager_id),
      ...ledgerRows.map((l) => l.metadata?.manager_id),
    ];
    const managersById = await loadManagersByIds(managerIds);

    allRows = buildRowsFromEvents(listings, ledgerRows, managersById);
    renderTable();
  } catch (err) {
    console.error(err);
    document.getElementById("tableHost").innerHTML =
      `<p class="empty">Could not load manager transfers: ${escapeHtml(err.message || "error")}</p>`;
  }
});
