import {
  initGlobal,
  getManagerDraftEnabled,
  getDraftAuctionStartTime,
  getUKNow,
  refreshDraftBiddingOpen,
  getDraftPhaseOptions,
} from "./global.js";
import {
  supabase,
  getManagerDraftEffectivePhase,
  managerDraftPhaseLabel,
  isManagerDraftAuctionEnded,
  fetchManagerDraftBidsGrouped,
  highestManagerDraftBid,
  getManagerDraftBidEligibility,
  getClubLeadingManagerDraftId,
} from "./manager_draft_engine.js";
import { loadClubsMap, fullClubName, ownerTagForClub } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";
import { managerListCellHtml, loadManagerPortraitManifest } from "./manager_images.js";

let buyerShortName = null;
let managerDraftEnabled = false;
let draftAuctionStartTime = null;
let pollTimer = null;

async function loadBuyerClub(userId) {
  const { data } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", userId)
    .maybeSingle();
  buyerShortName = data?.ShortName || null;
}

async function updateLeadPanel() {
  const el = document.getElementById("leadPanel");
  if (!el || !buyerShortName || !managerDraftEnabled || !draftAuctionStartTime) {
    if (el) el.textContent = "";
    return;
  }

  const leadingId = await getClubLeadingManagerDraftId(
    buyerShortName,
    draftAuctionStartTime
  );
  if (!leadingId) {
    el.innerHTML =
      '<span style="font-size:11px;color:#aaa;">You are not leading any manager draft auction.</span>';
    return;
  }

  const { data: mgr } = await supabase
    .from("Managers")
    .select("name")
    .eq("id", leadingId)
    .maybeSingle();

  el.innerHTML = `
    <b>Your leading bid:</b> ${mgr?.name || `Manager #${leadingId}`}
    <span style="font-size:11px;color:#aaa;"> — you may only lead one auction at a time</span>
  `;
}

async function loadManagerDraftListings() {
  const tbody = document.getElementById("draftTableBody");
  const statusEl = document.getElementById("draftStatus");
  if (!tbody) return;

  const nowUK = getUKNow();

  if (managerDraftEnabled && draftAuctionStartTime) {
    await refreshDraftBiddingOpen();
  }

  if (!managerDraftEnabled || !draftAuctionStartTime) {
    if (statusEl) statusEl.textContent = "";
    tbody.innerHTML = `<tr><td colspan="9">Manager draft auction is not active.</td></tr>`;
    return;
  }

  const phaseOpts = getDraftPhaseOptions();
  const phase = getManagerDraftEffectivePhase(
    nowUK,
    draftAuctionStartTime,
    phaseOpts
  );
  if (statusEl) statusEl.textContent = managerDraftPhaseLabel(phase);

  if (nowUK < draftAuctionStartTime) {
    tbody.innerHTML = `<tr><td colspan="9">Manager draft has not started yet.</td></tr>`;
    return;
  }

  const { data: listings } = await supabase
    .from("Manager_Transfer_Listings")
    .select("id, manager_id, status, current_highest_bid, current_highest_bidder")
    .eq("listing_type", "draft")
    .eq("status", "Active");

  if (!listings?.length) {
    tbody.innerHTML = `<tr><td colspan="9">No active manager draft auctions. Open a free agent in <a href="MGDB.html" style="color:#ff9900;">MGDB</a>.</td></tr>`;
    return;
  }

  const managerIds = listings.map((l) => Number(l.manager_id));
  const { data: managers } = await supabase
    .from("Managers")
    .select("id, slug, name, nation, rating, market_value, contracted_club")
    .in("id", managerIds);

  const managerMap = new Map((managers || []).map((m) => [Number(m.id), m]));
  const bidsByManager = await fetchManagerDraftBidsGrouped(managerIds, draftAuctionStartTime);

  await loadClubsMap();
  const auctionEnded = isManagerDraftAuctionEnded(
    nowUK,
    draftAuctionStartTime,
    phaseOpts
  );

  if (statusEl && auctionEnded) {
    statusEl.textContent =
      "Bidding closed (random finish reached). Winning bids assign managers and debit balance via the transfer engine — usually within a minute. Refresh Club Details if not updated yet.";
  }

  tbody.innerHTML = "";

  await loadManagerPortraitManifest();

  for (const listing of listings) {
    const mgr = managerMap.get(Number(listing.manager_id));
    if (!mgr) continue;

    const bids = bidsByManager.get(Number(listing.manager_id)) || [];
    const top = highestManagerDraftBid(bids);
    const high = top?.bid_amount ?? listing.current_highest_bid;
    const leader = top?.bidder_club_id ?? listing.current_highest_bidder;
    const leaderClub = leader ? fullClubName(leader) || leader : "—";
    const leaderOwner = leader ? ownerTagForClub(leader) || "—" : "—";
    const eligibility = await getManagerDraftBidEligibility({
      managerId: mgr.id,
      buyerShortName,
      managerDraftEnabled,
      draftAuctionStartTime,
    });
    const canBid = eligibility.allowed;

    const btnClass = auctionEnded ? "view-only" : canBid ? "enabled" : "disabled";
    const btnLabel = auctionEnded ? "View" : canBid ? "Bid" : "Locked";
    const lockTitle = !auctionEnded && !canBid ? eligibility.reason : "";

    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${managerListCellHtml(mgr)}</td>
      <td>${mgr.nation || "—"}</td>
      <td>${mgr.rating}</td>
      <td>${formatMoney(mgr.market_value)}</td>
      <td>${high != null ? formatMoney(high) : "—"}</td>
      <td>${leaderClub}</td>
      <td><span class="club-owner-tag">${leaderOwner}</span></td>
      <td>
        <button class="bid-btn ${btnClass}" data-manager-id="${mgr.id}" title="${lockTitle.replace(/"/g, "&quot;")}" ${auctionEnded || canBid ? "" : "disabled"}>
          ${btnLabel}
        </button>
      </td>
    `;
    tbody.appendChild(tr);
  }

  await updateLeadPanel();

  if (!pollTimer) {
    pollTimer = setInterval(() => loadManagerDraftListings(), auctionEnded ? 10000 : 5000);
  }
}

function wireTable() {
  document.getElementById("draftTableBody")?.addEventListener("click", (e) => {
    const btn = e.target.closest(".bid-btn.enabled, .bid-btn.view-only");
    if (!btn) return;
    const id = btn.getAttribute("data-manager-id");
    if (id) window.location = `manager_draftauction_manager.html?manager=${id}`;
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  await initGlobal();
  managerDraftEnabled = getManagerDraftEnabled();
  draftAuctionStartTime = getDraftAuctionStartTime();
  await loadBuyerClub(user.id);
  wireTable();
  await updateLeadPanel();
  await loadManagerDraftListings();
});
