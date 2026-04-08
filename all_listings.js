// ===============================
//  GLOBAL STATE
// ===============================
let currentUserShort = null;
let allListings = [];
let selectedListing = null;


// ===============================
//  AUTH + INITIAL LOAD
// ===============================
auth.onAuthStateChanged(async user => {
  if (!user) {
    window.location = "login.html";
    return;
  }

  await loadShortNameFromFirestore();
  await loadListings();
  wireFilterCheckboxes();
  wireModalControls();
  wirePlaceBidButton();
});


// ===============================
//  FIRESTORE → SHORTNAME
// ===============================
async function loadShortNameFromFirestore() {
  const uid = auth.currentUser.uid;
  const doc = await db.collection("users").doc(uid).get();

  if (!doc.exists) {
    console.error("Firestore user doc missing ShortName");
    return;
  }

  currentUserShort = doc.data().ShortName;
}


// ===============================
//  LOAD LISTINGS
// ===============================
async function loadListings() {
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("*");

  if (error) {
    console.error("Listings error", error);
    return;
  }

  allListings = data || [];
  renderListings();
}


// ===============================
//  FILTER CHECKBOXES
// ===============================
function wireFilterCheckboxes() {
  document.getElementById("filter-active").addEventListener("change", renderListings);
  document.getElementById("filter-closed").addEventListener("change", renderListings);
}


// ===============================
//  RENDER LISTINGS TABLE
// ===============================
function renderListings() {
  const tbody = document.getElementById("listings-body");
  tbody.innerHTML = "";

  const showActive = document.getElementById("filter-active").checked;
  const showClosed = document.getElementById("filter-closed").checked;

  const filtered = allListings.filter(l => {
    if (l.status === "Active") return showActive;
    if (l.status === "Review" || l.status === "Closed") return showClosed;
    return false;
  });

  filtered.forEach(async listing => {
    const player = await fetchPlayerByID(listing.player_id);

    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${listing.seller_club_id}</td>
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>${player?.Playstyle || "-"}</td>
      <td>${player?.Rating || "-"}</td>
      <td>₿ ${listing.market_value}</td>
      <td>₿ ${listing.reserve_price}</td>
      <td>${listing.status}</td>
      <td>${formatTimeRemaining(listing.end_time)}</td>
      <td>${listing.current_highest_bid || "-"}</td>
      <td>${listing.current_highest_bidder || "-"}</td>
    `;

    tr.onclick = () => openBidModal(listing, player);
    tbody.appendChild(tr);
  });
}


// ===============================
//  FETCH PLAYER
// ===============================
async function fetchPlayerByID(kid) {
  const { data, error } = await supabase
    .from("Players")
    .select("*")
    .eq("Konami_ID", kid)
    .single();

  if (error) {
    console.error("Player lookup failed", error);
    return null;
  }

  return data;
}


// ===============================
//  TIME REMAINING FORMATTER
// ===============================
function formatTimeRemaining(endTime) {
  const end = new Date(endTime);
  const now = new Date();
  const diff = end - now;

  if (diff <= 0) return "Expired";

  const hours = Math.floor(diff / 3600000);
  const mins = Math.floor((diff % 3600000) / 60000);

  return `${hours}h ${mins}m`;
}


// ===============================
//  OPEN BID MODAL
// ===============================
function openBidModal(listing, player) {
  selectedListing = listing;

  document.getElementById("bid-player-name").textContent = player?.Name || "Unknown";
  document.getElementById("bid-player-position").textContent = player?.Position || "-";
  document.getElementById("bid-player-playstyle").textContent = player?.Playstyle || "-";
  document.getElementById("bid-player-rating").textContent = player?.Rating || "-";

  document.getElementById("bid-selling-club").textContent = listing.seller_club_id;
  document.getElementById("bid-market-value").textContent = `₿ ${listing.market_value}`;
  document.getElementById("bid-reserve-price").textContent = `₿ ${listing.reserve_price}`;
  document.getElementById("bid-status").textContent = listing.status;
  document.getElementById("bid-time-remaining").textContent = formatTimeRemaining(listing.end_time);

  document.getElementById("bid-highest-bid").textContent = listing.current_highest_bid || "-";
  document.getElementById("bid-highest-club").textContent = listing.current_highest_bidder || "-";

  document.getElementById("bid-amount").value = "";
  document.getElementById("bid-error").textContent = "";

  document.getElementById("bid-modal").style.display = "block";
}


// ===============================
//  MODAL CONTROLS
// ===============================
function wireModalControls() {
  document.getElementById("bid-modal-close").onclick = () => {
    document.getElementById("bid-modal").style.display = "none";
  };

  window.onclick = function(event) {
    const modal = document.getElementById("bid-modal");
    if (event.target === modal) {
      modal.style.display = "none";
    }
  };
}


// ===============================
//  PLACE BID BUTTON
// ===============================
function wirePlaceBidButton() {
  document.getElementById("place-bid-btn").onclick = placeBid;
}


// ===============================
//  PLACE BID
// ===============================
async function placeBid() {
  const errorBox = document.getElementById("bid-error");
  errorBox.textContent = "";

  if (!selectedListing) {
    errorBox.textContent = "No listing selected.";
    return;
  }

  if (!currentUserShort) {
    errorBox.textContent = "Your club identity could not be determined.";
    return;
  }

  const bidAmount = Number(document.getElementById("bid-amount").value);

  if (!bidAmount || bidAmount <= 0) {
    errorBox.textContent = "Enter a valid bid amount.";
    return;
  }

  const currentHighest = selectedListing.current_highest_bid || 0;

  if (bidAmount <= currentHighest) {
    errorBox.textContent = "Bid must exceed current highest bid.";
    return;
  }

  // Insert bid
  const { error: bidError } = await supabase
    .from("Player_Transfer_Bids")
    .insert({
      listing_id: selectedListing.id,
      bidder_club: currentUserShort,
      bid_amount: bidAmount,
      bid_time: new Date().toISOString()
    });

  if (bidError) {
    console.error("Bid insert error", bidError);
    errorBox.textContent = "Bid failed. Please try again.";
    return;
  }

  // Update listing with new highest bid
  const { error: updateError } = await supabase
    .from("Player_Transfer_Listings")
    .update({
      current_highest_bid: bidAmount,
      current_highest_bidder: currentUserShort
    })
    .eq("id", selectedListing.id);

  if (updateError) {
    console.error("Listing update error", updateError);
    errorBox.textContent = "Bid saved, but listing update failed.";
    return;
  }

  document.getElementById("bid-modal").style.display = "none";
  await loadListings();
}
