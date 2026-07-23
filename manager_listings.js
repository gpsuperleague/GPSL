import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";
import {
  parseMoneyInput,
  setMoneyInputValue,
  wireMoneyBidInput,
} from "./money_input.js";

let currentClub = null;
/** True when this club already has a signed manager (cannot bid on market). */
let clubHasManager = false;
let selectedListing = null;
let currentMinBid = 0;
let bidAmountControl = null;

function getBidInput() {
  return document.getElementById("bidAmount");
}

function formatEndTime(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-GB", { timeZone: "Europe/London" });
}

function updateHasManagerBanner() {
  const el = document.getElementById("hasManagerBanner");
  if (!el) return;
  if (!currentClub) {
    el.hidden = true;
    return;
  }
  if (clubHasManager) {
    el.hidden = false;
    el.textContent =
      "Your club already has a manager — bidding is locked. Sack or transfer them before hiring another.";
  } else {
    el.hidden = true;
    el.textContent = "";
  }
}

async function refreshClubManagerState() {
  if (!currentClub) {
    clubHasManager = false;
    updateHasManagerBanner();
    return;
  }

  const [{ data: club }, { data: contracted }] = await Promise.all([
    supabase
      .from("Clubs")
      .select("manager_id")
      .eq("ShortName", currentClub)
      .maybeSingle(),
    supabase
      .from("Managers")
      .select("id")
      .eq("contracted_club", currentClub)
      .limit(1)
      .maybeSingle(),
  ]);

  clubHasManager = club?.manager_id != null || contracted?.id != null;
  updateHasManagerBanner();
}

async function loadListings() {
  const nowIso = new Date().toISOString();
  const { data: listings, error } = await supabase
    .from("Manager_Transfer_Listings")
    .select("*, Managers(name, rating, market_value)")
    .eq("status", "Active")
    .neq("listing_type", "draft")
    .gt("end_time", nowIso)
    .order("end_time", { ascending: true });

  const body = document.getElementById("listingsBody");
  if (!body) return;

  if (error) {
    body.innerHTML = `<tr><td colspan="7">Error: ${error.message}</td></tr>`;
    return;
  }

  if (!listings?.length) {
    body.innerHTML = `<tr><td colspan="7">No active manager listings.</td></tr>`;
    return;
  }

  body.innerHTML = listings
    .map((l) => {
      const mgr = l.Managers || {};
      const seller = l.seller_club_id
        ? fullClubName(l.seller_club_id)
        : l.listing_type === "window_fa"
          ? "League FA"
          : "Free agent";
      const ownListing = currentClub && l.seller_club_id === currentClub;
      const canBid = currentClub && !ownListing && !clubHasManager;
      let actionHtml = "";
      if (canBid) {
        actionHtml = `<button class="button bid-btn" data-id="${l.id}">Bid</button>`;
      } else if (clubHasManager && currentClub && !ownListing) {
        actionHtml = `<span class="muted" title="Sack or transfer your current manager first">Has manager</span>`;
      }
      return `<tr>
        <td>${mgr.name || "—"}</td>
        <td>${mgr.rating ?? "—"}</td>
        <td>${seller}</td>
        <td>${formatMoney(l.market_value ?? mgr.market_value)}</td>
        <td>${l.current_highest_bid ? formatMoney(l.current_highest_bid) : "—"}</td>
        <td>${formatEndTime(l.end_time)}</td>
        <td>${actionHtml}</td>
      </tr>`;
    })
    .join("");

  body.querySelectorAll(".bid-btn").forEach((btn) => {
    btn.addEventListener("click", () =>
      openBidModal(listings.find((x) => x.id === Number(btn.dataset.id)))
    );
  });
}

function listingMinBid(listing) {
  const mgr = listing?.Managers || {};
  const high = Number(listing?.current_highest_bid) || 0;
  const mv = Number(listing?.market_value) || Number(mgr.market_value) || 0;
  return high ? Math.max(mv, high + 500000) : mv;
}

function openBidModal(listing) {
  if (clubHasManager) {
    alert(
      "Your club already has a manager — sack or transfer them before bidding on another."
    );
    return;
  }
  selectedListing = listing;
  const mgr = listing?.Managers || {};
  currentMinBid = listingMinBid(listing);

  document.getElementById("bidManagerName").textContent = mgr.name || "Manager";
  document.getElementById("bidHint").textContent =
    `Minimum bid: ${formatMoney(currentMinBid)}`;
  setMoneyInputValue(getBidInput(), currentMinBid);
  document.getElementById("bidError").textContent = "";
  document.getElementById("bidModal").classList.add("open");
}

async function submitBid() {
  if (!selectedListing) return;
  if (clubHasManager) {
    document.getElementById("bidError").textContent =
      "Your club already has a manager — sack or transfer them before bidding.";
    return;
  }
  const amount = parseMoneyInput(getBidInput()?.value);
  const errEl = document.getElementById("bidError");
  const mgr = selectedListing.Managers || {};

  if (amount < currentMinBid) {
    errEl.textContent = `Minimum bid is ${formatMoney(currentMinBid)}.`;
    return;
  }

  const { error } = await supabase.rpc("manager_place_bid", {
    p_listing_id: selectedListing.id,
    p_amount: amount,
  });
  if (error) {
    errEl.textContent = error.message;
    return;
  }

  document.getElementById("bidModal").classList.remove("open");
  selectedListing = null;
  alert(
    `Bid placed: ${formatMoney(amount)} for ${mgr.name || "manager"}.\n\nThe listing will update with your new highest bid.`
  );
  await refreshClubManagerState();
  await loadListings();
}

function wireBidModalControls() {
  const input = getBidInput();
  bidAmountControl = wireMoneyBidInput(input, {
    min: () => currentMinBid,
  });

  document.querySelectorAll("#bidModal .inc-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      bidAmountControl?.adjust(Number(btn.dataset.delta) || 0);
    });
  });

  document.querySelectorAll("#bidModal .dec-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      bidAmountControl?.adjust(Number(btn.dataset.delta) || 0);
    });
  });

  document.getElementById("bidQuickMin")?.addEventListener("click", () => {
    if (!selectedListing) return;
    currentMinBid = listingMinBid(selectedListing);
    bidAmountControl?.set(currentMinBid);
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, manager_id")
    .eq("owner_id", user.id)
    .maybeSingle();
  currentClub = club?.ShortName || null;
  clubHasManager = club?.manager_id != null;

  await refreshClubManagerState();

  wireBidModalControls();

  document.getElementById("bidCancel")?.addEventListener("click", () => {
    document.getElementById("bidModal").classList.remove("open");
    selectedListing = null;
  });
  document.getElementById("bidSubmit")?.addEventListener("click", submitBid);

  await loadListings();
  setInterval(loadListings, 30000);
});
