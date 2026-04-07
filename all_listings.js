// --- config / helpers ---
const ACTIVE_KEY = "allListingsFilterActive";
const CLOSED_KEY = "allListingsFilterClosed";

const filterActive = document.getElementById("filter-active");
const filterClosed = document.getElementById("filter-closed");
const tbody = document.getElementById("listings-body");

// Modal elements
const bidModal = document.getElementById("bid-modal");
const bidModalClose = document.getElementById("bid-modal-close");
const bidPlayerName = document.getElementById("bid-player-name");
const bidPlayerPosition = document.getElementById("bid-player-position");
const bidPlayerPlaystyle = document.getElementById("bid-player-playstyle");
const bidPlayerRating = document.getElementById("bid-player-rating");
const bidSellingClub = document.getElementById("bid-selling-club");
const bidReservePrice = document.getElementById("bid-reserve-price");
const bidMarketValue = document.getElementById("bid-market-value");
const bidStatus = document.getElementById("bid-status");
const bidTimeRemaining = document.getElementById("bid-time-remaining");
const bidHighestBid = document.getElementById("bid-highest-bid");
const bidHighestClub = document.getElementById("bid-highest-club");
const bidAmountInput = document.getElementById("bid-amount");
const placeBidBtn = document.getElementById("place-bid-btn");
const bidError = document.getElementById("bid-error");

let listings = [];
let currentListing = null;
let countdownInterval = null;

// --- init filters from localStorage ---
function initFilters() {
  const activeStored = localStorage.getItem(ACTIVE_KEY);
  const closedStored = localStorage.getItem(CLOSED_KEY);

  filterActive.checked = activeStored === null ? true : activeStored !== "false";
  filterClosed.checked = closedStored === null ? true : closedStored !== "false";

  filterActive.addEventListener("change", () => {
    localStorage.setItem(ACTIVE_KEY, filterActive.checked);
    renderListings();
  });

  filterClosed.addEventListener("change", () => {
    localStorage.setItem(CLOSED_KEY, filterClosed.checked);
    renderListings();
  });
}

// --- time helpers ---
function getStatusAndTime(listing) {
  const now = new Date();
  const end = new Date(listing.end_time);

  if (listing.status === "Seller Review") {
    return { status: "Seller Review", timeLeft: "" };
  }

  if (end > now && listing.status === "Active") {
    const diffMs = end - now;
    const diffSec = Math.floor(diffMs / 1000);
    const h = Math.floor(diffSec / 3600);
    const m = Math.floor((diffSec % 3600) / 60);
    const s = diffSec % 60;
    return {
      status: "Active",
      timeLeft: `${h}h ${m}m ${s}s`
    };
  }

  return { status: "Closed", timeLeft: "Expired" };
}

// --- fetch listings + highest bids ---
async function loadListings() {
  // Replace with your Supabase / API calls.
  // Expect: listings with joined player + club info and aggregated highest bid.
  // Example shape:
  // {
  //   listing_id, player_name, position, playstyle, rating,
  //   selling_club, reserve_price, market_value,
  //   end_time, status,
  //   highest_bid, highest_bidder_club
  // }

  // Placeholder: you plug in your real fetch here.
  const res = await fetch("/api/listings-with-bids"); // your endpoint
  listings = await res.json();
  renderListings();
}

// --- render table ---
function renderListings() {
  tbody.innerHTML = "";

  listings.forEach(listing => {
    const { status, timeLeft } = getStatusAndTime(listing);

    if (status === "Active" && !filterActive.checked) return;
    if ((status === "Closed" || status === "Seller Review") && !filterClosed.checked) return;

    const tr = document.createElement("tr");
    tr.classList.add("listing-row");
    tr.dataset.listingId = listing.listing_id;

    tr.innerHTML = `
      <td>${listing.player_name}</td>
      <td>${listing.position}</td>
      <td>${listing.playstyle}</td>
      <td>${listing.rating}</td>
      <td>${listing.selling_club}</td>
      <td>${listing.reserve_price}</td>
      <td>${listing.market_value}</td>
      <td>${status}</td>
      <td>${timeLeft}</td>
      <td>${listing.highest_bid ?? "—"}</td>
      <td>${listing.highest_bidder_club ?? "—"}</td>
    `;

    tr.addEventListener("click", () => openBidModal(listing));
    tbody.appendChild(tr);
  });
}

// --- modal open/close ---
function openBidModal(listing) {
  currentListing = listing;
  bidError.textContent = "";
  bidAmountInput.value = "";

  const { status, timeLeft } = getStatusAndTime(listing);

  bidPlayerName.textContent = listing.player_name;
  bidPlayerPosition.textContent = listing.position;
  bidPlayerPlaystyle.textContent = listing.playstyle;
  bidPlayerRating.textContent = listing.rating;
  bidSellingClub.textContent = listing.selling_club;
  bidReservePrice.textContent = listing.reserve_price;
  bidMarketValue.textContent = listing.market_value;
  bidStatus.textContent = status;
  bidHighestBid.textContent = listing.highest_bid ?? "—";
  bidHighestClub.textContent = listing.highest_bidder_club ?? "—";

  if (countdownInterval) clearInterval(countdownInterval);
  updateModalCountdown();
  countdownInterval = setInterval(updateModalCountdown, 1000);

  // Disable bidding if closed or Seller Review
  const canBid = status === "Active";
  document.getElementById("bid-input-section").style.display = canBid ? "block" : "none";

  bidModal.style.display = "block";
}

function closeBidModal() {
  bidModal.style.display = "none";
  if (countdownInterval) clearInterval(countdownInterval);
  currentListing = null;
}

bidModalClose.addEventListener("click", closeBidModal);
window.addEventListener("click", (e) => {
  if (e.target === bidModal) closeBidModal();
});

// --- modal countdown ---
function updateModalCountdown() {
  if (!currentListing) return;
  const { status, timeLeft } = getStatusAndTime(currentListing);
  bidStatus.textContent = status;
  bidTimeRemaining.textContent = timeLeft;
}

// --- place bid ---
placeBidBtn.addEventListener("click", async () => {
  if (!currentListing) return;

  const bidValue = parseFloat(bidAmountInput.value);
  if (isNaN(bidValue) || bidValue <= 0) {
    bidError.textContent = "Enter a valid bid amount.";
    return;
  }

  const marketValue = parseFloat(currentListing.market_value);
  const highestBid = currentListing.highest_bid ? parseFloat(currentListing.highest_bid) : 0;

  if (bidValue < marketValue) {
    bidError.textContent = "Bid must be at least the market value.";
    return;
  }
  if (bidValue <= highestBid) {
    bidError.textContent = "Bid must be higher than the current highest bid.";
    return;
  }

  // Call backend to place bid + handle extension logic
  const res = await fetch("/api/place-bid", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      listing_id: currentListing.listing_id,
      bid_amount: bidValue
    })
  });

  if (!res.ok) {
    bidError.textContent = "Failed to place bid.";
    return;
  }

  const updated = await res.json();
  // updated should return refreshed listing (with new end_time, highest_bid, etc.)
  currentListing = updated;
  // Update in main list
  const idx = listings.findIndex(l => l.listing_id === updated.listing_id);
  if (idx !== -1) listings[idx] = updated;

  renderListings();
  openBidModal(updated); // refresh modal view
});

// --- init ---
initFilters();
loadListings();
