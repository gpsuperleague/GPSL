// ======================================================
//  GPSL CLUB DASHBOARD — FULL AUCTION + FINANCE ENGINE
//  dashboard.js
// ======================================================

let currentUserClub = null;
let listings = [];
let financeBalance = 0;

// DOM references
const activeBody = document.getElementById("active-listings-body");
const sellerReviewBody = document.getElementById("seller-review-body");
const closedBody = document.getElementById("closed-listings-body");
const financeBox = document.getElementById("finance-balance");


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

  await loadFinance();
  await loadListings();
});


// ======================================================
//  LOAD CLUB FINANCE
// ======================================================
async function loadFinance() {
  const { data, error } = await supabase
    .from("Club_Finances")
    .select("*")
    .eq("club_id", currentUserClub)
    .single();

  if (error || !data) {
    financeBox.textContent = "Balance unavailable";
    return;
  }

  financeBalance = data.balance;
  financeBox.textContent = `Balance: ₿ ${Number(financeBalance).toLocaleString()}`;
}


// ======================================================
//  SUPABASE — LOAD LISTINGS (JOINED QUERY)
// ======================================================
async function loadListings() {
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
    `)
    .eq("seller_club_id", currentUserClub);

  if (error) {
    console.error("Error loading listings:", error);
    return;
  }

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

  renderDashboard();
}


// ======================================================
//  RENDER DASHBOARD
// ======================================================
function renderDashboard() {
  activeBody.innerHTML = "";
  sellerReviewBody.innerHTML = "";
  closedBody.innerHTML = "";

  listings.forEach(listing => {
    const now = new Date();
    const end = new Date(listing.end_time);
    const diffMs = end - now;
    const diffMin = Math.floor(diffMs / 60000);
    const timeLeft = diffMs > 0 ? `${diffMin}m` : "Expired";

    // -----------------------------
    // ACTIVE LISTINGS
    // -----------------------------
    if (listing.status === "Active") {
      const tr = document.createElement("tr");
      tr.innerHTML = `
        <td>${listing.player_name}</td>
        <td>${listing.position}</td>
        <td>${listing.rating}</td>
        <td>₿ ${Number(listing.market_value).toLocaleString()}</td>
        <td>₿ ${Number(listing.reserve_price).toLocaleString()}</td>
        <td>${timeLeft}</td>
        <td>${listing.highest_bid ? "₿ " + Number(listing.highest_bid).toLocaleString() : "—"}</td>
        <td>${listing.highest_bidder_club ?? "—"}</td>
      `;
      activeBody.appendChild(tr);

      // Auto‑move to Seller Review if expired
      if (diffMs <= 0) {
        moveToSellerReview(listing);
      }
    }

    // -----------------------------
    // SELLER REVIEW
    // -----------------------------
    if (listing.status === "Seller Review") {
      const deadline = new Date(end.getTime() + 24 * 3600 * 1000);
      const remaining = Math.max(0, Math.floor((deadline - now) / 60000));

      const tr = document.createElement("tr");
      tr.innerHTML = `
        <td>${listing.player_name}</td>
        <td>${listing.position}</td>
        <td>${listing.rating}</td>
        <td>${listing.highest_bid ? "₿ " + Number(listing.highest_bid).toLocaleString() : "—"}</td>
        <td>${listing.highest_bidder_club ?? "—"}</td>
        <td>${remaining}m</td>
        <td>
          <div class="decision-buttons">
            <button class="button accept-btn">Accept</button>
            <button class="button reject-btn">Reject</button>
          </div>
        </td>
      `;

      // Accept
      tr.querySelector(".accept-btn").addEventListener("click", () => {
        acceptSale(listing);
      });

      // Reject
      tr.querySelector(".reject-btn").addEventListener("click", () => {
        rejectSale(listing);
      });

      sellerReviewBody.appendChild(tr);

      // Auto‑reject if deadline passed
      if (remaining <= 0) {
        rejectSale(listing, true);
      }
    }

    // -----------------------------
    // CLOSED LISTINGS
    // -----------------------------
    if (listing.status === "Closed") {
      const tr = document.createElement("tr");
      tr.innerHTML = `
        <td>${listing.player_name}</td>
        <td>${listing.position}</td>
        <td>${listing.rating}</td>
        <td>${listing.highest_bid ? "₿ " + Number(listing.highest_bid).toLocaleString() : "—"}</td>
        <td>${listing.highest_bidder_club ?? "—"}</td>
        <td>Closed</td>
      `;
      closedBody.appendChild(tr);
    }
  });
}


// ======================================================
//  MOVE TO SELLER REVIEW
// ======================================================
async function moveToSellerReview(listing) {
  if (listing.status !== "Active") return;

  await supabase
    .from("Player_Transfer_Listings")
    .update({ status: "Seller Review" })
    .eq("Id", listing.listing_id);

  listing.status = "Seller Review";
  renderDashboard();
}


// ======================================================
//  ACCEPT SALE
// ======================================================
async function acceptSale(listing) {
  if (!listing.highest_bid || !listing.highest_bidder_club) return;

  // 1. Transfer player to winning club
  await supabase
    .from("Players")
    .update({ Contracted_Team: listing.highest_bidder_club })
    .eq("Name", listing.player_name);

  // 2. Buyer pays
  await adjustBalance(listing.highest_bidder_club, -listing.highest_bid);

  // 3. Seller receives
  await adjustBalance(listing.selling_club, listing.highest_bid);

  // 4. Mark listing closed
  await supabase
    .from("Player_Transfer_Listings")
    .update({ status: "Closed" })
    .eq("Id", listing.listing_id);

  listing.status = "Closed";

  await loadFinance();
  renderDashboard();
}


// ======================================================
//  REJECT SALE
// ======================================================
async function rejectSale(listing, auto = false) {
  // Simply close the listing with no transfer
  await supabase
    .from("Player_Transfer_Listings")
    .update({ status: "Closed" })
    .eq("Id", listing.listing_id);

  listing.status = "Closed";

  renderDashboard();
}


// ======================================================
//  FINANCE UPDATE HELPER
// ======================================================
async function adjustBalance(club, amount) {
  // Fetch current balance
  const { data, error } = await supabase
    .from("Club_Finances")
    .select("*")
    .eq("club_id", club)
    .single();

  if (!data) return;

  const newBalance = Number(data.balance) + Number(amount);

  await supabase
    .from("Club_Finances")
    .update({ balance: newBalance })
    .eq("club_id", club);

  // Log transaction
  await supabase
    .from("Club_Finance_Transactions")
    .insert({
      club_id: club,
      amount: amount,
      description: "Transfer Market Transaction",
      timestamp: new Date().toISOString()
    });
}
