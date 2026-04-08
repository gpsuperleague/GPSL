// ===============================
//  GLOBAL STATE
// ===============================
let currentUserEmail = null;
let currentUserClub = null;       // Full club name (e.g., "Urawa Reds")
let currentUserShort = null;      // Short code (e.g., "URD")
let currentUserClubID = null;     // Numeric club ID

let selectedPlayerForListing = null; // Player object for modal


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

  await resolveClubFromEmail();
  await loadClubDetails();
  await loadSquad();
  await loadListedPlayers();
  await loadFinance();
  await loadListings();
});


// ===============================
//  RESOLVE CLUB FROM EMAIL
// ===============================
async function resolveClubFromEmail() {
  const { data, error } = await supabase
    .from("Users")
    .select("Club, ShortName, Club_ID")
    .eq("Email", currentUserEmail)
    .single();

  if (error || !data) {
    console.error("User lookup failed", error);
    return;
  }

  currentUserClub = data.Club;
  currentUserShort = data.ShortName;
  currentUserClubID = data.Club_ID;

  document.getElementById("clubNameField").textContent = currentUserClub;
  document.getElementById("dashboardTitle").textContent = `${currentUserClub} Dashboard`;

  // Load badge
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${currentUserShort}.png`;
}


// ===============================
//  LOAD CLUB DETAILS
// ===============================
async function loadClubDetails() {
  const { data, error } = await supabase
    .from("Clubs")
    .select("*")
    .eq("Club", currentUserClub)
    .single();

  if (error || !data) {
    console.error("Club details error", error);
    return;
  }

  document.getElementById("ownerInput").value = data.Owner || "";
  document.getElementById("stadiumField").textContent = data.Stadium || "Unknown";
  document.getElementById("capacityField").textContent = data.Capacity || "Unknown";

  // Owner editing
  document.getElementById("editOwnerBtn").onclick = () => {
    document.getElementById("ownerInput").disabled = false;
  };

  document.getElementById("saveOwnerBtn").onclick = async () => {
    const newOwner = document.getElementById("ownerInput").value.trim();

    await supabase
      .from("Clubs")
      .update({ Owner: newOwner })
      .eq("Club", currentUserClub);

    document.getElementById("ownerInput").disabled = true;
  };
}


// ===============================
//  LOAD SQUAD
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
    const tr = document.createElement("tr");

    const status = p.Listed ? 
      `<span class="status-pill status-listed">Listed</span>` :
      `<span class="status-pill status-not-listed">Not Listed</span>`;

    const actionBtn = p.Listed
      ? `<button class="button" disabled>Listed</button>`
      : `<button class="button" onclick='openListPlayerModal(${JSON.stringify(p).replace(/"/g, '&quot;')})'>List</button>`;

    tr.innerHTML = `
      <td>${p.Player_Name}</td>
      <td>${p.Position}</td>
      <td>${p.Rating}</td>
      <td>${p.Playstyle || "-"}</td>
      <td>₿ ${p.Market_Value}</td>
      <td>${status}</td>
      <td>${actionBtn}</td>
    `;

    tbody.appendChild(tr);
  });
}


// ===============================
//  LIST PLAYER MODAL
// ===============================
function openListPlayerModal(player) {
  selectedPlayerForListing = player;

  document.getElementById("modalPlayerName").textContent = player.Player_Name;
  document.getElementById("modalPlayerInfo").textContent =
    `${player.Position} • Rating ${player.Rating}`;

  document.getElementById("modalMarketValue").textContent = `₿ ${player.Market_Value}`;
  document.getElementById("modalMaxReserve").textContent = `₿ ${player.Reserve_Cap}`;

  document.getElementById("reserveInput").value = "";
  document.getElementById("reserveError").textContent = "";

  document.getElementById("list-player-modal-backdrop").style.display = "flex";
}

document.getElementById("cancelListBtn").onclick = () => {
  document.getElementById("list-player-modal-backdrop").style.display = "none";
};

document.getElementById("confirmListBtn").onclick = validateAndCreateListing;


// ===============================
//  VALIDATE + CREATE LISTING
// ===============================
async function validateAndCreateListing() {
  const reserveInput = document.getElementById("reserveInput");
  const reserve = Number(reserveInput.value);

  const mv = selectedPlayerForListing.Market_Value;
  const max = selectedPlayerForListing.Reserve_Cap;

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

  // Create listing
  const endTime = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();

  await supabase.from("Player_Transfer_Listings").insert({
    Player_Name: selectedPlayerForListing.Player_Name,
    Player_ID: selectedPlayerForListing.Player_ID,
    seller_club_id: currentUserClubID,
    seller_club_name: currentUserClub,
    reserve_price: reserve,
    market_value: mv,
    status: "Active",
    end_time: endTime
  });

  // Mark player as listed
  await supabase
    .from("Players")
    .update({ Listed: true })
    .eq("Player_ID", selectedPlayerForListing.Player_ID);

  document.getElementById("list-player-modal-backdrop").style.display = "none";

  await loadSquad();
  await loadListedPlayers();
  await loadListings();
}


// ===============================
//  LOAD LISTED PLAYERS
// ===============================
async function loadListedPlayers() {
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", currentUserClubID);

  if (error) {
    console.error("Listed players error", error);
    return;
  }

  renderListedPlayers(data);
}

function renderListedPlayers(listings) {
  const tbody = document.getElementById("listed-players-body");
  tbody.innerHTML = "";

  listings.forEach(l => {
    const tr = document.createElement("tr");

    tr.innerHTML = `
      <td>${l.Player_Name}</td>
      <td>${l.Position || "-"}</td>
      <td>${l.Rating || "-"}</td>
      <td>₿ ${l.market_value}</td>
      <td>₿ ${l.reserve_price}</td>
      <td>${l.status}</td>
      <td>${l.highest_bid || "-"}</td>
      <td>${l.highest_club || "-"}</td>
    `;

    tbody.appendChild(tr);
  });
}


// ===============================
//  LOAD FINANCE
// ===============================
async function loadFinance() {
  const { data, error } = await supabase
    .from("Clubs")
    .select("Balance")
    .eq("Club", currentUserClub)
    .single();

  if (error || !data) {
    console.error("Finance error", error);
    return;
  }

  document.getElementById("finance-balance").textContent =
    `₿ ${data.Balance.toLocaleString()}`;
}


// ===============================
//  LOAD LISTINGS (ACTIVE + REVIEW + CLOSED)
// ===============================
async function loadListings() {
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", currentUserClubID);

  if (error) {
    console.error("Listings error", error);
    return;
  }

  const now = new Date();

  const active = data.filter(l => l.status === "Active");
  const review = data.filter(l => l.status === "Review");
  const closed = data.filter(l => l.status === "Closed");

  renderActiveListings(active);
  renderSellerReview(review);
  renderClosedListings(closed);
}


// ===============================
//  ACTIVE LISTINGS
// ===============================
function renderActiveListings(listings) {
  const tbody = document.getElementById("active-listings-body");
  tbody.innerHTML = "";

  listings.forEach(l => {
    const tr = document.createElement("tr");

    tr.innerHTML = `
      <td>${l.Player_Name}</td>
      <td>${l.Position || "-"}</td>
      <td>${l.Rating || "-"}</td>
      <td>₿ ${l.market_value}</td>
      <td>₿ ${l.reserve_price}</td>
      <td>${formatTimeRemaining(l.end_time)}</td>
      <td>${l.highest_bid || "-"}</td>
      <td>${l.highest_club || "-"}</td>
    `;

    tbody.appendChild(tr);
  });
}


// ===============================
//  SELLER REVIEW
// ===============================
function renderSellerReview(listings) {
  const tbody = document.getElementById("seller-review-body");
  tbody.innerHTML = "";

  listings.forEach(l => {
    const tr = document.createElement("tr");

    tr.innerHTML = `
      <td>${l.Player_Name}</td>
      <td>${l.Position || "-"}</td>
      <td>${l.Rating || "-"}</td>
      <td>${l.highest_bid || "-"}</td>
      <td>${l.highest_club || "-"}</td>
      <td>${new Date(l.end_time).toLocaleString()}</td>
      <td>
        <div class="decision-buttons">
          <button class="button" onclick="acceptSale(${l.id}, ${l.highest_bid})">Accept</button>
          <button class="button" onclick="rejectSale(${l.id})">Reject</button>
        </div>
      </td>
    `;

    tbody.appendChild(tr);
  });
}


// ===============================
//  CLOSED LISTINGS
// ===============================
function renderClosedListings(listings) {
  const tbody = document.getElementById("closed-listings-body");
  tbody.innerHTML = "";

  listings.forEach(l => {
    const tr = document.createElement("tr");

    tr.innerHTML = `
      <td>${l.Player_Name}</td>
      <td>${l.Position || "-"}</td>
      <td>${l.Rating || "-"}</td>
      <td>${l.final_bid || "-"}</td>
      <td>${l.winner || "-"}</td>
      <td>${l.status}</td>
    `;

    tbody.appendChild(tr);
  });
}


// ===============================
//  ACCEPT / REJECT SALE
// ===============================
async function acceptSale(listingID, amount) {
  // Add money
  await supabase
    .from("Clubs")
    .update({ Balance: supabase.rpc("increment_balance", { club_id: currentUserClubID, amount }) })
    .eq("Club_ID", currentUserClubID);

  // Mark listing closed
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
