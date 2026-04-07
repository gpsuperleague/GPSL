import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

const supabase = createClient(
  "https://omyyogfumrjoaweuawjn.supabase.co",
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9teXlvZ2Z1bXJqb2F3ZXVhd2puIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ5NTUxMzUsImV4cCI6MjA5MDUzMTEzNX0.7UVkpi4DOtC9VNjFLnE_ZnK6vhDtlfesZ_8rfnrkno4"
);

// --------------------------------------------------
// POSITION ORDER
// --------------------------------------------------
const POSITION_ORDER = [
  "GK", "LB", "CB", "RB",
  "DMF", "LMF", "CMF", "RMF",
  "AMF", "LWF", "CF", "RWF"
];

function sortPlayersByPosition(players) {
  return players.sort((a, b) => {
    const posA = POSITION_ORDER.indexOf(a.Position);
    const posB = POSITION_ORDER.indexOf(b.Position);
    return posA - posB;
  });
}

// --------------------------------------------------
// HELPERS
// --------------------------------------------------
function formatBTC(num) {
  if (!num || isNaN(num)) return "₿ 0";
  return "₿ " + Number(num).toLocaleString("en-GB");
}

function lockOwnerField() {
  ownerInput.setAttribute("readonly", true);
  saveOwnerBtn.style.display = "none";
}

function unlockOwnerField() {
  ownerInput.removeAttribute("readonly");
  saveOwnerBtn.style.display = "inline-block";
}

function getListingStatus(endTime) {
  const end = Date.parse(endTime);
  const now = Date.now();

  if (isNaN(end)) return "Closed";
  return end > now ? "Active" : "Closed";
}

function timeRemaining(endTime) {
  const end = Date.parse(endTime);
  const now = Date.now();

  if (isNaN(end) || end <= now) return "Expired";

  const diff = end - now;
  const hours = Math.floor(diff / (1000 * 60 * 60));
  const mins = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60));

  return `${hours}h ${mins}m`;
}

// --------------------------------------------------
// AUTH
// --------------------------------------------------
auth.onAuthStateChanged(async user => {
  if (!user) {
    window.location = "login.html";
    return;
  }

  userEmail.textContent = `User: ${user.email}`;

  nav.innerHTML = `
    <a href="index.html" class="button">Home</a>
    <a href="GPDB.html" class="button">Player Database</a>
    <a href="clubs.html" class="button">Clubs</a>
    <a href="all_listings.html" class="button">Transfer-List</a>
    <button onclick="logout()" class="button">Logout</button>
  `;

  loadClub(user.uid);
});

function logout() {
  auth.signOut().then(() => window.location = "login.html");
}

// --------------------------------------------------
// LOAD CLUB
// --------------------------------------------------
async function loadClub(uid) {
  const userDoc = await db.collection("users").doc(uid).get();
  if (!userDoc.exists) return;

  const shortName = userDoc.data().club;
  loadClubDetails(shortName);
}

// --------------------------------------------------
// LOAD CLUB DETAILS
// --------------------------------------------------
async function loadClubDetails(shortName) {

  document.body.dataset.shortname = shortName;

  const badgePath = `images/club_badges/${shortName}.png`;

  const { data: club } = await supabase
    .from("Clubs")
    .select("Club, owner, Stadium, Capacity, ShortName")
    .eq("ShortName", shortName)
    .single();

  if (!club) return;

  const fullName = club.Club;

  clubBadgeHeader.src = badgePath;
  dashboardTitle.textContent = `${fullName} Dashboard`;

  clubNameField.textContent = fullName;

  ownerInput.value = club.owner || "";
  ownerInput.style.width = (ownerInput.value.length + 2) + "ch";

  if (ownerInput.value.trim() !== "") {
    lockOwnerField();
    editOwnerBtn.style.display = "inline-block";
    saveOwnerBtn.style.display = "none";
  } else {
    unlockOwnerField();
    editOwnerBtn.style.display = "none";
    saveOwnerBtn.style.display = "inline-block";
  }

  editOwnerBtn.onclick = () => {
    unlockOwnerField();
    editOwnerBtn.style.display = "none";
  };

  saveOwnerBtn.onclick = async () => {
    const newOwner = ownerInput.value.trim();
    if (!newOwner) return alert("Owner cannot be empty");

    const sn = document.body.dataset.shortname;

    const { error } = await supabase
      .from("Clubs")
      .update({ owner: newOwner })
      .eq("ShortName", sn);

    if (error) {
      console.error(error);
      alert("Error saving owner");
      return;
    }

    lockOwnerField();
    editOwnerBtn.style.display = "inline-block";
    saveOwnerBtn.style.display = "none";

    alert("Owner updated");
  };

  ownerInput.addEventListener("input", () => {
    ownerInput.style.width = (ownerInput.value.length + 2) + "ch";
  });

  stadiumField.textContent = club.Stadium || "—";
  capacityField.textContent = club.Capacity || "—";

  loadSquad(fullName);
  loadListings(fullName);
}

// --------------------------------------------------
// SQUAD
// --------------------------------------------------
async function loadSquad(fullName) {
  const { data: players } = await supabase
    .from("Players")
    .select("*")
    .eq("Contracted_Team", fullName);

  if (!players) return;

  let html = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Name</th><th>Pos</th><th>Nation</th><th>Age</th>
          <th>Rating</th><th>Style</th><th>Value</th><th>List</th>
        </tr>
      </thead>
      <tbody>
  `;

  sortPlayersByPosition(players).forEach(p => {
    html += `
      <tr>
        <td>${p.Name}</td>
        <td>${p.Position}</td>
        <td>${p.Nation}</td>
        <td>${p.Age}</td>
        <td>${p.Rating}</td>
        <td>${p.Playstyle}</td>
        <td>${formatBTC(p.market_value)}</td>
        <td><input type="checkbox" class="listPlayer" data-id="${p.Konami_ID}" data-name="${p.Name}" data-mv="${p.market_value}"></td>
      </tr>
    `;
  });

  html += "</tbody></table>";
  squadContainer.innerHTML = html;
}

// --------------------------------------------------
// LISTINGS
// --------------------------------------------------
let currentListings = [];

async function loadListings(fullName) {
  const { data: listings } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", fullName);

  if (!listings) return;

  currentListings = listings;
  renderListings();
}

async function renderListings() {
  const showActive = filterActive.checked;
  const showClosed = filterExpired.checked;

  let html = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Name</th><th>Pos</th><th>Rating</th>
          <th>Reserve</th><th>Time Left</th><th>Status</th>
        </tr>
      </thead>
      <tbody>
  `;

  for (const l of currentListings) {
    const { data: player } = await supabase
      .from("Players")
      .select("Name, Position, Rating")
      .eq("Konami_ID", l.player_id)
      .single();

    if (!player) continue;

    const status = getListingStatus(l.end_time);

    if ((status === "Active" && !showActive) ||
        (status === "Closed" && !showClosed)) {
      continue;
    }

    html += `
      <tr>
        <td>${player.Name}</td>
        <td>${player.Position}</td>
        <td>${player.Rating}</td>
        <td>${formatBTC(l.reserve_price)}</td>
        <td>${timeRemaining(l.end_time)}</td>
        <td>${status}</td>
      </tr>
    `;
  }

  html += "</tbody></table>";
  listedContainer.innerHTML = html;
}

filterActive.addEventListener("change", renderListings);
filterExpired.addEventListener("change", renderListings);
