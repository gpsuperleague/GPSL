console.log("LIVE DASHBOARD VERSION:", Math.random());

// ===============================
//  GLOBAL STATE
// ===============================
let currentUserEmail = null;
let currentUserShort = null;
let currentUserClub = null;
let currentUserClubID = null;

let selectedPlayerForListing = null;
let activeListingsCache = []; // used to determine "Listed" status


// ===============================
//  DASHBOARD REFRESH WRAPPER
// ===============================
async function loadDashboard() {
  await loadShortNameFromFirestore();
  await loadClubFromSupabase();
  await loadActiveListingsCache();
  await loadClubDetails();
  await loadFinance();
  await loadSquad();
  await loadListings();
  await loadMyActiveBids();   // NEW
}


// ===============================
//  AUTH + INITIAL LOAD
// ===============================
auth.onAuthStateChanged(async user => {
  if (!user) {
    window.location = "login.html";
    return;
  }

  currentUserEmail = user.email;
  document.getElementById("userEmail").textContent = currentUserEmail;

  await loadDashboard();
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
//  SUPABASE → CLUB INFO
// ===============================
async function loadClubFromSupabase() {
  const { data, error } = await supabase
    .from("Clubs")
    .select("*")
    .eq("ShortName", currentUserShort)
    .single();

  if (error || !data) {
    console.error("Club lookup failed", error);
    return;
  }

  currentUserClub = data.Club;
  currentUserClubID = data.Club_ID;

  document.getElementById("clubNameField").textContent = currentUserClub;
  document.getElementById("dashboardTitle").textContent = `${currentUserClub} Dashboard`;

  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${currentUserShort}.png`;
}


// ===============================
//  ACTIVE LISTINGS CACHE
// ===============================
async function loadActiveListingsCache() {
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", currentUserClub)
    .eq("status", "Active");

  activeListingsCache = data || [];
}


// ===============================
//  CLUB DETAILS PANEL
// ===============================
async function loadClubDetails() {
  const { data, error } = await supabase
    .from("Clubs")
    .select("*")
    .eq("Club_ID", currentUserClubID)
    .single();

  if (error || !data) {
    console.error("Club details error", error);
    return;
  }

  const ownerInput = document.getElementById("ownerInput");
  const editBtn = document.getElementById("editOwnerBtn");
  const saveBtn = document.getElementById("saveOwnerBtn");

  ownerInput.value = data.owner || "";
  ownerInput.disabled = true;
  saveBtn.style.display = "none";
  editBtn.style.display = "inline-block";

  document.getElementById("stadiumField").textContent = data.Stadium || "Unknown";
  document.getElementById("capacityField").textContent = data.Capacity || "Unknown";

  editBtn.onclick = () => {
    ownerInput.disabled = false;
    ownerInput.focus();
    saveBtn.style.display = "inline-block";
    editBtn.style.display = "none";
  };

  saveBtn.onclick = async () => {
    const newOwner = ownerInput.value.trim();

    await supabase
      .from("Clubs")
      .update({ owner: newOwner })
      .eq("Club_ID", currentUserClubID);

    ownerInput.disabled = true;
    saveBtn.style.display = "none";
    editBtn.style.display = "inline-block";

    await loadClubDetails();
  };
}


// ===============================
//  SQUAD
// ===============================
async function loadSquad() {
  const { data, error } = await supabase
    .from("Players")
    .select("*")
    .eq("Contracted_Team", currentUserClub);

  if (error) {
    console.error("Squad load error", error);
    return;
  }

  renderSquad(data);
}

function renderSquad(players) {
  const tbody = document.getElementById("squad-body");
  tbody.innerHTML = "";

  players.forEach(p => {
    const isListed = activeListingsCache.some(l => l.player_id === p.Konami_ID);

    const status = isListed
      ? `<span class="status-pill status-listed">Listed</span>`
      : `<span class="status-pill status-not-listed">Not Listed</span>`;

    const actionDropdown = `
      <select onchange="handlePlayerAction('${p.Konami_ID}', this.value)">
        <option value="">Action</option>
        <option value="list">Transfer List</option>
      </select>
    `;

    const tr = document.createElement("tr");

    tr.innerHTML = `
      <td>${p.Name}</td>
      <td>${p.Position}</td>
      <td>${p.Rating}</td>
      <td>${p.Playstyle || "-"}</td>
      <td>₿ ${p.market_value}</td>
      <td>${status}</td>
      <td>${actionDropdown}</td>
    `;

    tbody.appendChild(tr);
  });
}

function handlePlayerAction(konamiID, action) {
  if (action === "list") {
    const player = { Konami_ID: konamiID };
    openListPlayerModalByID(player);
  }
}


// ===============================
//  LIST PLAYER MODAL
// ===============================
async function openListPlayerModalByID(playerRef) {
  const { data, error } = await supabase
    .from("Players")
    .select("*")
    .eq("Konami_ID", playerRef.Konami_ID)
    .single();

  if (error || !data) {
    console.error("Player lookup failed", error);
    return;
  }

  openListPlayerModal(data);
}

function openListPlayerModal(player) {
  selectedPlayerForListing = player;

  document.getElementById("modalPlayerName").textContent = player.Name;
  document.getElementById("modalPlayerInfo").textContent =
    `${player.Position} • Rating ${player.Rating}`;

  document.getElementById("modalMarketValue").textContent = `₿ ${player.market_value}`;
  document.getElementById("modalMaxReserve").textContent = `₿ ${player.Maximum_Reserve_Price}`;

  document.getElementById("reserveInput").value = "";
  document.getElementById("reserveError").textContent = "";

  document.getElementById("list-player-modal-backdrop").style.display = "flex";
}

document.getElementById("useMaxReserveBtn").onclick = () => {
  const max = selectedPlayerForListing.Maximum_Reserve_Price;
  document.getElementById("reserveInput").value = max;
  document.getElementById("reserveError").textContent = "";
};

document.getElementById("cancelListBtn").onclick = () => {
  document.getElementById("list-player-modal-backdrop").style.display = "none";
};

document.getElementById("confirmListBtn").onclick = validateAndCreateListing;


// ===============================
//  CREATE LISTING
// ===============================
async function validateAndCreateListing() {
  const reserve = Number(document.getElementById("reserveInput").value);
  const mv = selectedPlayerForListing.market_value;
  const max = selectedPlayerForListing.Maximum_Reserve_Price;

  if (reserve < mv) {
    document.getElementById("reserveError").textContent =
      `Reserve must be at least market value (₿ ${mv}).`;
    return;
  }

  if (reserve > max) {
    document.getElementById("reserveError").textContent =
      `Reserve cannot exceed max allowed (₿ ${max}).`;
    return;
  }

  const endTime = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();

  await supabase.from("Player_Transfer_Listings").insert({
    player_id: selectedPlayerForListing.Konami_ID,
    seller_club_id: currentUserClub,
    reserve_price: reserve,
    market_value: mv,
    status: "Active",
    end_time: endTime
  });

  document.getElementById("list-player-modal-backdrop").style.display = "none";

  await loadActiveListingsCache();
  await loadSquad();
  await loadDashboard();
  await loadListings();
}

async function fetchPlayerByID(kid) {
  const { data } = await supabase
    .from("Players")
    .select("*")
    .eq("Konami_ID", kid)
    .single();

  return data;
}


// ===============================
//  FINANCE (Club_Finances.balance)
// ===============================
async function loadFinance() {
  const { data, error } = await supabase
    .from("Club_Finances")
    .select("balance")
    .eq("club_name", currentUserClub)
    .single();

  if (error || !data) {
    console.error("Finance error", error);
    return;
  }

  document.getElementById("finance-balance").textContent =
    `₿ ${data.balance.toLocaleString()}`;
}


// ===============================
//  LOAD LISTINGS (with auto-expiry)
// ===============================
async function loadListings() {
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", currentUserClub);

  if (error) {
    console.error("Listings error", error);
    return;
  }

  // AUTO-UPDATE EXPIRED LISTINGS (transfer engine)
  for (const l of data) {
    const now = new Date();
    const end = new Date(l.end_time);

    // Listing expired and still Active → evaluate with engine
    if (end < now && l.status === "Active") {
      await transferEngine.evaluateExpiredListing(l);
    }

    // Seller review timeout (24h)
    if (l.status === "Review" && l.review_deadline) {
      const reviewEnd = new Date(l.review_deadline);
      if (reviewEnd < now) {
        await transferEngine.rejectSale(l.id);
      }
    }
  }

  // Refresh after updates
  const refreshed = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", currentUserClub);

  const updatedListings = refreshed.data || [];

  const active = updatedListings.filter(l => l.status === "Active");
  const review = updatedListings.filter(l => l.status === "Review");
  const closed = updatedListings.filter(l => l.status === "Closed");

  renderActiveListings(active);
  renderSellerReview(review);
  renderClosedListings(closed);

  await loadActiveListingsCache();
  await loadSquad();
}
// ===============================
//  ACTIVE LISTINGS
// ===============================
async function renderActiveListings(listings) {
  const tbody = document.getElementById("active-listings-body");
  tbody.innerHTML = "";

  for (const l of listings) {
    const player = await fetchPlayerByID(l.player_id);

    const tr = document.createElement("tr");

    tr.innerHTML = `
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>${player?.Rating || "-"}</td>
      <td>₿ ${l.market_value}</td>
      <td>₿ ${l.reserve_price}</td>
      <td>${formatTimeRemaining(l.end_time)}</td>
      <td>${l.current_highest_bid || "-"}</td>
      <td>${l.current_highest_bidder || "-"}</td>
    `;

    tbody.appendChild(tr);
  }
}


// ===============================
//  SELLER REVIEW
// ===============================
async function renderSellerReview(listings) {
  const tbody = document.getElementById("seller-review-body");
  tbody.innerHTML = "";

  for (const l of listings) {
    const player = await fetchPlayerByID(l.player_id);

    const tr = document.createElement("tr");

    tr.innerHTML = `
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>${player?.Rating || "-"}</td>
      <td>₿ ${l.current_highest_bid || "-"}</td>
      <td>${l.current_highest_bidder || "-"}</td>
      <td>${new Date(l.end_time).toLocaleString()}</td>
      <td>
        <div class="decision-buttons">
          <button class="button" onclick="acceptSale(${l.id}, ${l.current_highest_bid})">Accept</button>
          <button class="button" onclick="rejectSale(${l.id})">Reject</button>
        </div>
      </td>
    `;

    tbody.appendChild(tr);
  }
}


// ===============================
//  CLOSED LISTINGS
// ===============================
async function renderClosedListings(listings) {
  const tbody = document.getElementById("closed-listings-body");
  tbody.innerHTML = "";

  for (const l of listings) {
    const player = await fetchPlayerByID(l.player_id);

    const tr = document.createElement("tr");

    tr.innerHTML = `
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>${player?.Rating || "-"}</td>
      <td>${l.final_bid || "-"}</td>
      <td>${l.winner || "-"}</td>
      <td>${l.status}</td>
    `;

    tbody.appendChild(tr);
  }
}

// ===============================
//  ACCEPT / REJECT SALE
// ===============================
async function acceptSale(listingID, amount) {
  const { data: finance } = await supabase
    .from("Club_Finances")
    .select("balance")
    .eq("club_name", currentUserClub)
    .single();

  const newBalance = finance.balance + amount;

  await supabase
    .from("Club_Finances")
    .update({ balance: newBalance })
    .eq("club_name", currentUserClub);

  await supabase
    .from("Player_Transfer_Listings")
    .update({ status: "Closed", final_bid: amount })
    .eq("id", listingID);

  await loadFinance();
  await loadListings();
}

async function rejectSale(listingID) {
  await supabase
    .from("Player_Transfer_Listings")
    .update({ status: "Closed", final_bid: null })
    .eq("id", listingID);

  await loadListings();
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
//  MY ACTIVE BIDS (NEW)
// ===============================
async function loadMyActiveBids() {
  const { data, error } = await supabase
    .from("Player_Transfer_Bids")
    .select(`
      listing_id,
      bid_amount,
      bid_time,
      Player_Transfer_Listings (
        id,
        player_id,
        reserve_price,
        current_highest_bid,
        current_highest_bidder,
        end_time
      )
    `)
    .eq("bidder_club_id", currentUserShort)
    .order("bid_time", { ascending: false });

  if (error) {
    console.error("Active bids error:", error);
    return;
  }

  renderMyActiveBids(data);
}

async function renderMyActiveBids(bids) {
  const tbody = document.getElementById("my-active-bids-body");
  tbody.innerHTML = "";

  for (const b of bids) {
    const l = b.Player_Transfer_Listings;
    const player = await fetchPlayerByID(l.player_id);

    const tr = document.createElement("tr");

    tr.innerHTML = `
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>₿ ${b.bid_amount}</td>
      <td>₿ ${l.current_highest_bid || "-"}</td>
      <td>${l.current_highest_bidder || "-"}</td>
      <td>${new Date(l.end_time).toLocaleString()}</td>
    `;

    tbody.appendChild(tr);
  }
}
// END OF DASHBOARD.JS
console.log("Dashboard JS loaded successfully.");
