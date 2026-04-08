console.log("DASHBOARD JS — FULLY REWRITTEN & FIXED");

// ======================================================
//  GLOBAL STATE
// ======================================================
let currentUserClub = null;        // FULL club name (e.g. "Urawa Reds")
let currentUserShort = null;       // Short code (e.g. "URD")
let listings = [];
let financeBalance = 0;

// DOM references
const activeBody = document.getElementById("active-listings-body");
const sellerReviewBody = document.getElementById("seller-review-body");
const closedBody = document.getElementById("closed-listings-body");
const financeBox = document.getElementById("finance-balance");


// ======================================================
//  FIREBASE → RESOLVE FULL CLUB NAME → LOAD DASHBOARD
// ======================================================
firebase.auth().onAuthStateChanged(async user => {
  if (!user) return;

  const db = firebase.firestore();
  const doc = await db.collection("users").doc(user.uid).get();

  if (!doc.exists) return;

  // Step 1: Get short code (URD)
  currentUserShort = doc.data().club;

  // Step 2: Resolve full club name from Clubs table
  const { data: clubRow, error: clubErr } = await supabase
    .from("Clubs")
    .select("*")
    .eq("ShortName", currentUserShort)
    .single();

  if (clubErr || !clubRow) {
    console.error("Club lookup failed:", clubErr);
    return;
  }

  // Step 3: Set full club name
  currentUserClub = clubRow.Club;   // e.g. "Urawa Reds"

  console.log("Resolved club:", currentUserShort, "→", currentUserClub);

  // Step 4: Load dashboard sections
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
    .eq("club_name", currentUserClub)
    .single();

  if (error || !data) {
    console.error("Finance load error:", error);
    financeBox.textContent = "Balance unavailable";
    return;
  }

  financeBalance = data.balance;
  financeBox.textContent = `Balance: ₿ ${Number(financeBalance).toLocaleString()}`;
}


// ======================================================
//  LOAD LISTINGS (NO JOINS MODE)
// ======================================================
async function loadListings() {
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", currentUserClub);

  if (error) {
    console.error("Error loading listings:", error);
    return;
  }

  listings = data.map(l => ({
    listing_id: l.Id,
    selling_club: l.seller_club_id,

    // TEMP placeholders
    player_name: l.player_name ?? "(unknown)",
    position: l.position ?? "-",
    playstyle: l.playstyle ?? "-",
    rating: l.rating ?? 0,
    market_value: l.market_value ?? 0,

    reserve_price: l.reserve_price,
    end_time: l.end_time,
    status: l.status,

    highest_bid: l.current_highest_bid ?? null,
    highest_bidder_club: l.current_highest_bidder ?? null,
    bids: []
  }));

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

    // ACTIVE
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

      if (diffMs <= 0) moveToSellerReview(listing);
    }

    // SELLER REVIEW
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

      tr.querySelector(".accept-btn").addEventListener("click", () => acceptSale(listing));
      tr.querySelector(".reject-btn").addEventListener("click", () => rejectSale(listing));

      sellerReviewBody.appendChild(tr);

      if (remaining <= 0) rejectSale(listing, true);
    }

    // CLOSED
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

  // Move player
  await supabase
    .from("Players")
    .update({ Contracted_Team: listing.highest_bidder_club })
    .eq("Name", listing.player_name);

  // Money movement
  await adjustBalance(listing.highest_bidder_club, -listing.highest_bid);
  await adjustBalance(listing.selling_club, listing.highest_bid);

  // Close listing
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
  await supabase
    .from("Player_Transfer_Listings")
    .update({ status: "Closed" })
    .eq("Id", listing.listing_id);

  listing.status = "Closed";
  renderDashboard();
}


// ======================================================
//  FINANCE UPDATE + LEDGER ENTRY
// ======================================================
async function adjustBalance(club, amount) {
  const { data } = await supabase
    .from("Club_Finances")
    .select("*")
    .eq("club_name", club)
    .single();

  if (!data) return;

  const newBalance = Number(data.balance) + Number(amount);

  await supabase
    .from("Club_Finances")
    .update({ balance: newBalance })
    .eq("club_name", club);

  await supabase
    .from("Club_Finance_Transactions")
    .insert({
      club_name: club,
      amount: amount,
      type: amount > 0 ? "credit" : "debit",
      reference_id: null,
      timestamp: new Date().toISOString(),
      notes: "Transfer Market Transaction"
    });
}
