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
