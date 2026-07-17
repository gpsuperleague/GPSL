import { supabase, initGlobal } from "./global.js";
import { loadCurrentGpslSeasonLabel } from "./player_season_transfer.js";
import {
  loadClubsMap,
  displayClubName,
  displayTransferBuyer,
  formatSeasonSaleDestination,
  clubPageHref,
  isForeignBuyerClub,
} from "./clubs_lookup.js";
import { playerNameLinkHtml } from "./player_links.js";

let allRows = [];
let listingTypeById = new Map();
let playerNameById = new Map();
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

function classifyDeal(row) {
  const note = String(row.transfer_sale_note || "").trim();
  const listingType = row.listing_id
    ? listingTypeById.get(String(row.listing_id))
    : null;

  if (note === "special_auction" || note.startsWith("special_auction:")) {
    return "special";
  }
  if (listingType === "draft") return "draft";
  if (note === "squad_overflow") return "release";
  if (isForeignBuyerClub(row.buyer_club_id)) return "foreign";
  if (!row.seller_club_id && row.buyer_club_id && !isForeignBuyerClub(row.buyer_club_id)) {
    return "draft";
  }
  if (row.seller_club_id && row.buyer_club_id && !isForeignBuyerClub(row.buyer_club_id)) {
    return "transfer";
  }
  return "foreign";
}

function dealTypeLabel(kind) {
  switch (kind) {
    case "draft":
      return "Draft signing";
    case "transfer":
      return "Club transfer";
    case "foreign":
      return "Foreign sale";
    case "release":
      return "Squad release";
    case "special":
      return "Special auction";
    default:
      return "Deal";
  }
}

function sellerCell(row) {
  if (!row.seller_club_id) return "Free agent";
  const href = clubPageHref(row.seller_club_id);
  const label = displayClubName(row.seller_club_id);
  return href
    ? `<a class="gpsl-link" href="${href}">${escapeHtml(label)}</a>`
    : escapeHtml(label);
}

function buyerCell(row) {
  const label = displayTransferBuyer(row);
  if (isForeignBuyerClub(row.buyer_club_id)) {
    return escapeHtml(label);
  }
  const href = clubPageHref(row.buyer_club_id);
  return href
    ? `<a class="gpsl-link" href="${href}">${escapeHtml(label)}</a>`
    : escapeHtml(label);
}

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function filteredRows() {
  if (activeFilter === "all") return allRows;
  if (activeFilter === "foreign") {
    return allRows.filter((r) => {
      const k = classifyDeal(r);
      return k === "foreign" || k === "release";
    });
  }
  return allRows.filter((r) => classifyDeal(r) === activeFilter);
}

function renderTable() {
  const host = document.getElementById("tableHost");
  const rows = filteredRows();

  if (!rows.length) {
    host.innerHTML = "<p class=\"empty\">No completed deals for this filter yet.</p>";
    return;
  }

  const body = rows
    .map((row) => {
      const pid = String(row.player_id);
      const name = playerNameById.get(pid) || "Unknown";
      const kind = classifyDeal(row);
      const detail =
        kind === "release" || kind === "foreign"
          ? formatSeasonSaleDestination(row)
          : "";

      return `
        <tr>
          <td>${formatWhen(row.transfer_time)}</td>
          <td>${playerNameLinkHtml(pid, name)}</td>
          <td>${sellerCell(row)}</td>
          <td>${buyerCell(row)}</td>
          <td>${formatMoney(row.fee)}</td>
          <td>
            <span class="type-pill ${kind}">${escapeHtml(dealTypeLabel(kind))}</span>
            ${detail ? `<br><span style="font-size:11px;color:#aaa;">${escapeHtml(detail)}</span>` : ""}
          </td>
        </tr>
      `;
    })
    .join("");

  host.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Date</th>
          <th>Player</th>
          <th>From</th>
          <th>To</th>
          <th>Fee</th>
          <th>Type</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>
  `;
}

async function loadSeasonStart() {
  const { data, error } = await supabase
    .from("competition_season_public")
    .select("label, started_at")
    .eq("is_current", true)
    .maybeSingle();

  if (error) {
    console.error("competition_season_public:", error);
    return { label: await loadCurrentGpslSeasonLabel(supabase), startedAt: null };
  }

  return {
    label: data?.label || (await loadCurrentGpslSeasonLabel(supabase)) || "Current season",
    startedAt: data?.started_at || null,
  };
}

async function loadTransfers(seasonStartedAt) {
  let q = supabase
    .from("Transfer_History")
    .select(
      "player_id, seller_club_id, buyer_club_id, fee, agent_fee, transfer_time, listing_id, foreign_buyer_name, transfer_sale_note"
    )
    .order("transfer_time", { ascending: false });

  if (seasonStartedAt) {
    q = q.gte("transfer_time", seasonStartedAt);
  }

  const { data, error } = await q.limit(500);
  if (error) throw error;
  return data || [];
}

async function hydratePlayers(playerIds) {
  if (!playerIds.length) return;
  const { data, error } = await supabase
    .from("Players")
    .select("Konami_ID, Name")
    .in("Konami_ID", playerIds);

  if (error) {
    console.error("Players:", error);
    return;
  }

  playerNameById.clear();
  for (const p of data || []) {
    playerNameById.set(String(p.Konami_ID), p.Name);
  }
}

async function hydrateListingTypes(listingIds) {
  listingTypeById.clear();
  if (!listingIds.length) return;

  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("id, listing_type")
    .in("id", listingIds);

  if (error) {
    console.error("Listings:", error);
    return;
  }

  for (const l of data || []) {
    listingTypeById.set(String(l.id), l.listing_type);
  }
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

  await loadClubsMap();
  wireFilters();

  try {
    const { label, startedAt } = await loadSeasonStart();
    const labelEl = document.getElementById("seasonLabel");
    if (labelEl) {
      labelEl.textContent = startedAt
        ? ` — ${label} (since ${new Date(startedAt).toLocaleDateString("en-GB")})`
        : ` — ${label}`;
    }

    allRows = await loadTransfers(startedAt);

    const playerIds = [...new Set(allRows.map((r) => String(r.player_id)))];
    const listingIds = [
      ...new Set(allRows.map((r) => r.listing_id).filter((id) => id != null)),
    ];

    await Promise.all([
      hydratePlayers(playerIds),
      hydrateListingTypes(listingIds),
    ]);

    renderTable();
  } catch (err) {
    console.error(err);
    document.getElementById("tableHost").innerHTML =
      `<p class="empty">Could not load transfers: ${escapeHtml(err.message || "error")}</p>`;
  }
});
