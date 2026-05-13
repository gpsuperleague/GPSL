// ======================================================
// MODULE A: GLOBAL STATE
// ======================================================
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";

// Use global Supabase client (created in all_listings.html)
const supabase = window.supabase;

let currentUserShort = null;
let allListings = [];
let selectedListing = null;

// Load club map immediately
await loadClubsMap();

// ⭐ Format numbers as ₿ 1,234,567
function formatMoney(amount) {
  if (amount == null || isNaN(amount)) return "-";
  return "₿ " + Number(amount).toLocaleString("en-GB");
}

// ⭐ Convert "1,234,567" → 1234567
function parseMoneyInput(value) {
  if (!value) return 0;
  return Number(String(value).replace(/,/g, ""));
}

// ======================================================
// MODULE A: AUTH + INITIAL LOAD (SUPABASE)
// ======================================================
(async function init() {
  const { data: { user }, error: userError } = await supabase.auth.getUser();

  if (userError) {
    console.error("Supabase auth error:", userError);
    window.location = "login.html";
    return;
  }

  if (!user) {
    window.location = "login.html";
    return;
  }

  await loadShortNameFromSupabase(user.id);
  await loadListings();

  wireFilterCheckboxes();
  wireModalControls();
  wirePlaceBidButton();
  wireIncrementButtons();
  wireQuickBidButton();

  console.log("all_listings.js initialized successfully");
})();

// ======================================================
// MODULE A: SUPABASE → SHORTNAME
// ======================================================
async function loadShortNameFromSupabase(userId) {
  // Assumes Clubs table has Owner_ID (UUID) and ShortName
  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", userId)
    .maybeSingle();

  if (error) {
    console.error("Error loading club ShortName from Supabase:", error);
    return;
  }

  if (!data) {
    console.warn("No club found for this user; currentUserShort will be null");
    return;
  }

  currentUserShort = data.ShortName;
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

    // Only show listings that were ever active/extended
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

    // ⭐ Highlight if user is leading
    if (listing.current_highest_bidder === currentUserShort) {
      tr.classList.add("leading-row");
    }

    // ⭐ Badge logic
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
  input.focus();
  input.select();

  document.getElementById("bid-error").textContent = "";

  const minBid = Math.max(
    listing.market_value,
    (listing.current_highest_bid || 0) + 500000
  );

  input.placeholder = `Minimum bid: ${formatMoney(minBid)}`;

  document.getElementById("place-bid-btn").disabled = true;

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
// MODULE E: MODAL CONTROLS
// ======================================================
function wireModalControls() {
  const modal = document.getElementById("bid-modal");
  const closeBtn = document.getElementById("bid-modal-close");

  closeBtn.onclick = () => {
    modal.style.display = "none";
    selectedListing = null;
  };

  window.onclick = function(event) {
    if (event.target === modal) {
      modal.style.display = "none";
      selectedListing = null;
    }
  };

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
  const btns = [
    ["inc-500k",   500000],
    ["inc-1m",    1000000],
    ["inc-5m",    5000000],
    ["dec-500k-bid", -500000],
    ["dec-1m-bid",  -1000000],
    ["dec-5m-bid",  -5000000],
  ];

  btns.forEach(([id, amount]) => {
    const el = document.getElementById(id);
    if (el) {
      el.onclick = () => adjustBid(amount);
    }
  });
}

// ======================================================
// ⭐ NEW — QUICK BID BUTTON
// ======================================================
function wireQuickBidButton() {
  document.getElementById("quick-bid-btn").onclick = () => {
    if (!selectedListing) return;

    const minBid = Math.max(
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

  // Insert bid
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

  // Close modal + refresh
  document.getElementById("bid-modal").style.display = "none";
  await loadListings();
}
