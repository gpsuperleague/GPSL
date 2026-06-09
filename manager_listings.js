import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";

let currentClub = null;
let selectedListing = null;

function parseMoney(value) {
  return Number(String(value || "").replace(/,/g, "")) || 0;
}

function formatEndTime(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-GB", { timeZone: "Europe/London" });
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
      const seller = l.seller_club_id ? fullClubName(l.seller_club_id) : "—";
      const canBid = currentClub && l.seller_club_id !== currentClub;
      return `<tr>
        <td>${mgr.name || "—"}</td>
        <td>${mgr.rating ?? "—"}</td>
        <td>${seller}</td>
        <td>${formatMoney(l.market_value ?? mgr.market_value)}</td>
        <td>${l.current_highest_bid ? formatMoney(l.current_highest_bid) : "—"}</td>
        <td>${formatEndTime(l.end_time)}</td>
        <td>${canBid ? `<button class="button bid-btn" data-id="${l.id}">Bid</button>` : ""}</td>
      </tr>`;
    })
    .join("");

  body.querySelectorAll(".bid-btn").forEach((btn) => {
    btn.addEventListener("click", () => openBidModal(listings.find((x) => x.id === Number(btn.dataset.id))));
  });
}

function openBidModal(listing) {
  selectedListing = listing;
  const mgr = listing?.Managers || {};
  document.getElementById("bidManagerName").textContent = mgr.name || "Manager";
  const high = Number(listing.current_highest_bid) || 0;
  const mv = Number(listing.market_value) || Number(mgr.market_value) || 0;
  const min = high ? Math.max(mv, high + 500000) : mv;
  document.getElementById("bidHint").textContent = `Minimum bid: ${formatMoney(min)}`;
  document.getElementById("bidAmount").value = String(min);
  document.getElementById("bidError").textContent = "";
  document.getElementById("bidModal").classList.add("open");
}

async function submitBid() {
  if (!selectedListing) return;
  const amount = parseMoney(document.getElementById("bidAmount").value);
  const errEl = document.getElementById("bidError");
  const { error } = await supabase.rpc("manager_place_bid", {
    p_listing_id: selectedListing.id,
    p_amount: amount,
  });
  if (error) {
    errEl.textContent = error.message;
    return;
  }
  document.getElementById("bidModal").classList.remove("open");
  await loadListings();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();
  currentClub = club?.ShortName || null;

  document.getElementById("bidCancel")?.addEventListener("click", () => {
    document.getElementById("bidModal").classList.remove("open");
  });
  document.getElementById("bidSubmit")?.addEventListener("click", submitBid);

  await loadListings();
  setInterval(loadListings, 30000);
});
