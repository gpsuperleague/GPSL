// ======================================================
// MODULE A: GLOBAL STATE
// ======================================================
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";

let currentUserShort = null;
let allListings = [];
let selectedListing = null;

// Load club map immediately
await loadClubsMap();

// ⭐ NEW — format numbers as ₿ 1,234,567
function formatMoney(amount) {
  if (amount == null || isNaN(amount)) return "-";
  return "₿ " + Number(amount).toLocaleString("en-GB");
}

// ⭐ NEW — convert "1,234,567" → 1234567
function parseMoneyInput(value) {
  if (!value) return 0;
  return Number(String(value).replace(/,/g, ""));
}

// ======================================================
// MODULE A: AUTH + INITIAL LOAD
// ======================================================
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
  wireIncrementButtons();     // ⭐ NEW
  wireQuickBidButton();       // ⭐ NEW
});

// ======================================================
// MODULE A: FIRESTORE → SHORTNAME
// ======================================================
async function loadShortNameFromFirestore() {
  const uid = auth.currentUser.uid;
  const doc = await db.collection("users").doc(uid).get();

  if (!doc.exists) {
    console.error("Firestore user doc missing ShortName");
    return;
  }

  currentUserShort = doc.data().ShortName;
}

// ======================================================
// MODULE B: LOAD LISTINGS
// ======================================================
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

// ======================================================
// MODULE C: FILTER CHECKBOXES
// ======================================================
function wireFilterCheckboxes() {
  document.getElementById("filter-active").addEventListener("change", renderListings);
  document.getElementById("filter-closed").addEventListener("change", renderListings);
}

// ======================================================
// MODULE D: RENDER LISTINGS TABLE
// ======================================================
function renderListings() {
  const tbody = document.getElementById("listings-body");
  tbody.innerHTML = "";

  const showActive = document.getElementById("filter-active").checked;
  const showClosed = document.getElementById("filter-closed").checked;

  const now = new Date();

  const filtered = allListings.filter(l => {
    const end = new Date(l.end_time);

    if (l.status !== "Active" && !l.was_extended) return false;

    if (l.status === "Active") {
      if (end > now) return showActive;
      return false;
    }

    if (l.status === "Review" || l.status === "Closed") {
      return showClosed;
    }

    return false;
  });

  filtered.forEach(async listing => {
    const player = await fetchPlayerByID(listing.player_id);

    const extendedLabel = listing.was_extended
      ? ` <span style="color:#d9534f;font-weight:bold;">(Extended)</span>`
      : "";

    const tr = document.createElement("tr");

    // ⭐ NEW — highlight if user is leading
    if (listing.current_highest_bidder === currentUserShort) {
      tr.classList.add("leading-row");
    }

    // ⭐ NEW — badge logic
    let highestClubText = "- (No bids)";
    if (listing.current_highest_bidder) {
      highestClubText =
        `${fullClubName(listing.current_highest_bidder)} ` +
        `${
          listing.current_highest_bidder === currentUserShort
            ? "(You’re leading)"
            : "(Outbid)"
        }`;
    }

    tr.innerHTML = `
      <td>${fullClubName(listing.seller_club_id)}</td>
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>${player?.Playstyle || "-"}</td>
      <td>${player?.Rating || "-"}</td>
      <td>${formatMoney(listing.market_value)}</td>
      <td>${formatMoney(listing.reserve_price)}</td>
      <td>${listing.status} ${extendedLabel}</td>
      <td>${formatTimeRemaining(listing.end_time)}</td>
      <td>${formatMoney(listing.current_highest_bid)}</td>
      <td>${highestClubText}</td>
    `;

    tr.onclick = () => openBidModal(listing, player);
    tbody.appendChild(tr);
  });
}

// ======================================================
// MODULE B: FETCH PLAYER
// ======================================================
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

// ======================================================
// MODULE D: TIME REMAINING FORMATTER
// ======================================================
function formatTimeRemaining(endTime) {
  const end = new Date(endTime);
  const now = new Date();
  const diff = end - now;

  if (diff <= 0) return "Expired";

  const hours = Math.floor(diff / 3600000);
  const mins = Math.floor((diff % 3600000) / 60000);

  return `${hours}h ${mins}m`;
}

// ======================================================
// MODULE E: OPEN BID MODAL
// ======================================================
function openBidModal(listing, player) {

  if (listing.seller_club_id === currentUserShort) {
    alert("You already own this player. You cannot bid on your own listing.");
    return;
  }

  selectedListing = listing;

  document.getElementById("bid-player-name").textContent = player?.Name || "Unknown";
  document.getElementById("bid-player-position").textContent = player?.Position || "-";
  document.getElementById("bid-player-playstyle").textContent = player?.Playstyle || "-";
  document.getElementById("bid-player-rating").textContent = player?.Rating || "-";

  document.getElementById("bid-selling-club").textContent = fullClubName(listing.seller_club_id);
  document.getElementById("bid-market-value").textContent = formatMoney(listing.market_value);
  document.getElementById("bid-reserve-price").textContent = formatMoney(listing.reserve_price);
  document.getElementById("bid-status").textContent = listing.status;
  document.getElementById("bid-time-remaining").textContent = formatTimeRemaining(listing.end_time);

  document.getElementById("bid-highest-bid").textContent = formatMoney(listing.current_highest_bid);
  document.getElementById("bid-highest-club").textContent =
    fullClubName(listing.current_highest_bidder) || "-";

  const input = document.getElementById("bid-amount");
  input.value = "";
  input.focus();     // ⭐ NEW
  input.select();    // ⭐ NEW

  document.getElementById("bid-error").textContent = "";

  // ⭐ NEW — minimum bid = max(market value, highest bid + 500k)
  const minBid = Math.max(
    listing.market_value,
    (listing.current_highest_bid || 0) + 500000
  );

  input.placeholder = `Minimum bid: ${formatMoney(minBid)}`;

  // ⭐ NEW — disable button initially
  document.getElementById("place-bid-btn").disabled = true;

  // ⭐ NEW — live validation
  input.oninput = validateBidInput;

  document.getElementById("bid-modal").style.display = "block";
}

// ======================================================
// MODULE E: LIVE VALIDATION
// ======================================================
function validateBidInput() {
  const input = document.getElementById("bid-amount");
  const errorBox = document.getElementById("bid-error");
  const button = document.getElementById("place-bid-btn");

  const bidAmount = parseMoneyInput(input.value);

  // ⭐ NEW — auto-format input as user types
  if (input.value !== "") {
    input.value = bidAmount.toLocaleString("en-GB");
  }

  const minBid = Math.max(
    selectedListing.market_value,
    (selectedListing.current_highest_bid || 0) + 500000
  );

  if (!bidAmount || bidAmount < minBid) {
    input.style.border = "2px solid red";
    errorBox.textContent = `Minimum allowed bid is ${formatMoney(minBid)}`;
    button.disabled = true;
    return;
  }

  input.style.border = "2px solid #4CAF50";
  errorBox.textContent = "";
  button.disabled = false;
}

// ======================================================
// MODULE E: MODAL CONTROLS (FIXED)
// ======================================================
function wireModalControls() {
  const modal = document.getElementById("bid-modal");
  const closeBtn = document.getElementById("bid-modal-close");

  // Close when clicking X
  closeBtn.onclick = () => {
    modal.style.display = "none";
    selectedListing = null;
  };

  // Close when clicking outside
  window.onclick = function(event) {
    if (event.target === modal) {
      modal.style.display = "none";
      selectedListing = null;
    }
  };

  // Close on ESC
  document.addEventListener("keydown", function(event) {
    if (event.key === "Escape") {
      modal.style.display = "none";
      selectedListing = null;
    }
  });
}

// ======================================================
// ⭐ NEW — INCREMENT BUTTONS
// ======================================================
function wireIncrementButtons() {
  document.getElementById("inc-500k").onclick = () => addIncrement(500000);
  document.getElementById("inc-1m").onclick = () => addIncrement(1000000);
  document.getElementById("inc-5m").onclick = () => addIncrement(5000000);
}

function addIncrement(amount) {
  const input = document.getElementById("bid-amount");
  let current = parseMoneyInput(input.value);
  current += amount;
  input.value = current.toLocaleString("en-GB");
  validateBidInput();
}

// ======================================================
// ⭐ NEW — QUICK BID BUTTON
// ======================================================
function wireQuickBidButton() {
  document.getElementById("quick-bid-btn").onclick = () => {
    if (!selectedListing) return;

    const minBid =
      Math.max(
        selectedListing.market_value,
        (selectedListing.current_highest_bid || 0) + 500000
      );

    const input = document.getElementById("bid-amount");
    input.value = minBid.toLocaleString("en-GB");
    validateBidInput();
  };
}

// ======================================================
// MODULE F: PLACE BID BUTTON
// ======================================================
function wirePlaceBidButton() {
  document.getElementById("place-bid-btn").onclick = placeBid;
}

// ======================================================
// MODULE F: PLACE BID
// ======================================================
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

  const rawInput = document.getElementById("bid-amount").value;
  const bidAmount = parseMoneyInput(rawInput);
  const currentHighest = selectedListing.current_highest_bid || 0;

  const minBid = Math.max(
    selectedListing.market_value,
    currentHighest + 500000
  );

  if (bidAmount < minBid) {
    errorBox.textContent = `Your bid must be at least ${formatMoney(minBid)}.`;
    return;
  }

  const { error: bidError } = await supabase
    .from("Player_Transfer_Bids")
    .insert({
      listing_id: selectedListing.id,
      bidder_club_id: currentUserShort,
      bid_amount: bidAmount,
      bid_time: new Date().toISOString()
    });

  if (bidError) {
    console.error("Bid insert error", bidError);
    errorBox.textContent = "Bid failed. Please try again.";
    return;
  }

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
