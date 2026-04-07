// ======================================================
//  GPSL GLOBAL TRANSFER MARKET — FULL AUCTION ENGINE
//  all_listings.js
// ======================================================

// -------------------------------
//  FILTER STATE
// -------------------------------
const ACTIVE_KEY = "allListingsFilterActive";
const CLOSED_KEY = "allListingsFilterClosed";

const filterActive = document.getElementById("filter-active");
const filterClosed = document.getElementById("filter-closed");
const tbody = document.getElementById("listings-body");

// -------------------------------
//  MODAL ELEMENTS
// -------------------------------
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

let currentUserClub = null; // Firestore identity mapping


// ======================================================
//  FIREBASE → FIRESTORE → CLUB NAME
// ======================================================
firebase.auth().onAuthStateChanged(async user => {
  if (!user) return;

  const db = firebase.firestore();
  const doc = await db.collection("users").doc(user.uid).get();

  if (doc.exists) {
    currentUserClub = doc.data().club;
  }

  loadListings();
});


// ======================================================
//  INIT FILTERS
// ======================================================
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


// ======================================================
//  TIME + STATUS HELPERS
// ======================================================
function computeStatus(listing) {
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


// ======================================================
//  SUPABASE — LOAD LISTINGS (JOINED QUERY)
// ======================================================
async function loadListings() {
  if (!window.supabase) return;

  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select(`
      *,
      Players (
        Name,
        Position,
        Rating,
        Playstyle,
        market_value
      ),
      Player_Transfer_Bids (
        bid_amount,
        bidder_club_id,
        bid_time
      )
    `);

  if (error) {
    console.error("Error loading listings:", error);
    return;
  }

  // Transform into clean objects
  listings = data.map(l => {
    const bids = l.Player_Transfer_Bids || [];
    const highest = bids.length
      ? bids.reduce((a, b) => (a.bid_amount > b.bid_amount ? a : b))
      : null;

    return {
      listing_id: l.Id,
      selling_club: l.seller_club_id,
      player_name: l.Players?.Name,
      position: l.Players?.Position,
      playstyle: l.Players?.Playstyle,
      rating: l.Players?.Rating,
      market_value: l.Players?.market_value,
      reserve_price: l.reserve_price,
      end_time: l.end_time,
      status: l.status,
      highest_bid: highest ? highest.bid_amount : null,
      highest_bidder_club: highest ? highest.bidder_club_id : null,
      bids: bids
    };
  });

  renderListings();
}


// ======================================================
//  RENDER TABLE
// ======================================================
function renderListings() {
  tbody.innerHTML = "";

  listings.forEach(listing => {
    const { status, timeLeft } = computeStatus(listing);

    if (status === "Active" && !filterActive.checked) return;
    if ((status === "Closed" || status === "Seller Review") && !filterClosed.checked) return;

    const tr = document.createElement("tr");
    tr.classList.add("listing-row");

    tr.innerHTML = `
      <td>${listing.selling_club}</td>
      <td>${listing.player_name}</td>
      <td>${listing.position}</td>
      <td>${listing.playstyle}</td>
      <td>${listing.rating}</td>
      <td>₿ ${Number(listing.market_value).toLocaleString()}</td>
      <td>₿ ${Number(listing.reserve_price).toLocaleString()}</td>
      <td>${status}</td>
      <td>${timeLeft}</td>
      <td>${listing.highest_bid ? "₿ " + Number(listing.highest_bid).toLocaleString() : "—"}</td>
      <td>${listing.highest_bidder_club ?? "—"}</td>
    `;

    tr.addEventListener("click", () => openBidModal(listing));
    tbody.appendChild(tr);
  });
}


// ======================================================
//  MODAL — OPEN / CLOSE
// ======================================================
function openBidModal(listing) {
  currentListing = listing;
  bidError.textContent = "";
  bidAmountInput.value = "";

  const { status, timeLeft } = computeStatus(listing);

  bidPlayerName.textContent = listing.player_name;
  bidPlayerPosition.textContent = listing.position;
  bidPlayerPlaystyle.textContent = listing.playstyle;
  bidPlayerRating.textContent = listing.rating;
  bidSellingClub.textContent = listing.selling_club;
  bidReservePrice.textContent = "₿ " + Number(listing.reserve_price).toLocaleString();
  bidMarketValue.textContent = "₿ " + Number(listing.market_value).toLocaleString();
  bidStatus.textContent = status;
  bidHighestBid.textContent = listing.highest_bid ? "₿ " + Number(listing.highest_bid).toLocaleString() : "—";
  bidHighestClub.textContent = listing.highest_bidder_club ?? "—";

  if (countdownInterval) clearInterval(countdownInterval);
  updateModalCountdown();
  countdownInterval = setInterval(updateModalCountdown, 1000);

  // Disable bidding if not active
  document.getElementById("bid-input-section").style.display =
    status === "Active" ? "block" : "none";

  bidModal.style.display = "block";
}

function closeBidModal() {
  bidModal.style.display = "none";
  if (countdownInterval) clearInterval(countdownInterval);
  currentListing = null;
}

bidModalClose.addEventListener("click", closeBidModal);
window.addEventListener("click", e => {
  if (e.target === bidModal) closeBidModal();
});


// ======================================================
//  MODAL COUNTDOWN
// ======================================================
function updateModalCountdown() {
  if (!currentListing) return;
  const { status, timeLeft } = computeStatus(currentListing);
  bidStatus.textContent = status;
  bidTimeRemaining.textContent = timeLeft;
}


// ======================================================
//  PLACE BID
// ======================================================
placeBidBtn.addEventListener("click", async () => {
  if (!currentListing) return;

  const bidValue = parseFloat(bidAmountInput.value);
  if (isNaN(bidValue) || bidValue <= 0) {
    bidError.textContent = "Enter a valid bid amount.";
    return;
  }

  if (!currentUserClub) {
    bidError.textContent = "Unable to identify your club.";
    return;
  }

  const highestBid = currentListing.highest_bid || 0;

  if (bidValue < currentListing.market_value) {
    bidError.textContent = "Bid must be at least the market value.";
    return;
  }

  if (bidValue <= highestBid) {
    bidError.textContent = "Bid must be higher than the current highest bid.";
    return;
  }

  // Insert bid
  const { error: bidErr } = await supabase
    .from("Player_Transfer_Bids")
    .insert({
      listing_id: currentListing.listing_id,
      bidder_club_id: currentUserClub,
      bid_amount: bidValue,
      bid_time: new Date().toISOString()
    });

  if (bidErr) {
    console.error(bidErr);
    bidError.textContent = "Failed to place bid.";
    return;
  }

  // Rolling extension: extend by 5 minutes if < 5 min left
  const now = new Date();
  const end = new Date(currentListing.end_time);
  const diffMin = (end - now) / 1000 / 60;

  if (diffMin < 5) {
    const newEnd = new Date(now.getTime() + 5 * 60000).toISOString();

    await supabase
      .from("Player_Transfer_Listings")
      .update({ end_time: newEnd })
      .eq("Id", currentListing.listing_id);

    currentListing.end_time = newEnd;
  }

  // Reload listings
  await loadListings();

  // Refresh modal
  const updated = listings.find(l => l.listing_id === currentListing.listing_id);
  openBidModal(updated);
});


// ======================================================
//  INIT
// ======================================================
initFilters();
