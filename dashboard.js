import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
console.log("LIVE DASHBOARD VERSION:", Math.random());

/* ============================================================
   MODULE A: GLOBAL STATE
   ============================================================ */
let currentUserEmail = null;
let currentUserShort = null;
let currentUserClub = null;
let currentUserClubID = null;
let clubId = null;

let selectedPlayerForListing = null;
let activeListingsCache = [];

/* ============================================================
   MODULE B: STADIUM INFO LOADER
   ============================================================ */
async function loadStadiumInfo(clubId) {
  const { data: club, error: clubError } = await supabase
    .from("Clubs")
    .select("Capacity, last_stadium_upgrade_season")
    .eq("Club_ID", clubId)
    .single();

  if (clubError || !club) {
    console.error("Stadium club load error", clubError);
    return;
  }

  const { data: season, error: seasonError } = await supabase
    .from("seasons")
    .select("season_id")
    .eq("is_active", true)
    .single();

  if (seasonError || !season) {
    console.error("Season load error", seasonError);
    return;
  }

  const currentCapacity = club.Capacity;

  const { data: nextCapData, error: nextCapError } = await supabase.rpc(
    "upgrade_stadium_capacity",
    { current_capacity: currentCapacity }
  );

  if (nextCapError || nextCapData == null) {
    console.error("Next capacity RPC error", nextCapError);
    return;
  }

  const nextCapacity = nextCapData;

  const { data: costData, error: costError } = await supabase.rpc(
    "calculate_stadium_upgrade_cost",
    {
      current_capacity: currentCapacity,
      new_capacity: nextCapacity
    }
  );

  if (costError || costData == null) {
    console.error("Upgrade cost RPC error", costError);
    return;
  }

  const upgradeCost = costData;

  document.getElementById("current-capacity").textContent =
    currentCapacity.toLocaleString();
  document.getElementById("next-capacity").textContent =
    nextCapacity.toLocaleString();
  document.getElementById("upgrade-cost").textContent =
    "£" + upgradeCost.toLocaleString();

  const upgradeBtn = document.getElementById("upgrade-stadium-btn");

  if (nextCapacity === currentCapacity) {
    upgradeBtn.disabled = true;
    upgradeBtn.textContent = "Max Capacity Reached";
    return;
  }

  if (club.last_stadium_upgrade_season === season.season_id) {
    upgradeBtn.disabled = true;
    upgradeBtn.textContent = "Already Upgraded This Season";
    return;
  }

  upgradeBtn.disabled = false;
  upgradeBtn.textContent = "Upgrade Stadium";
  upgradeBtn.onclick = () => upgradeStadium(clubId);
}

/* ============================================================
   MODULE B: STADIUM UPGRADE HANDLER
   ============================================================ */
async function upgradeStadium(clubId) {
  const message = document.getElementById("upgrade-message");
  message.textContent = "Processing upgrade...";

  const { data, error } = await supabase.rpc("upgrade_stadium_for_club", {
    p_Club: clubId
  });

  if (error) {
    message.textContent = "Error: " + error.message;
    return;
  }

  switch (data) {
    case "SUCCESS":
      message.textContent = "✅ Stadium upgraded successfully!";
      loadStadiumInfo(clubId);
      loadClubBalance?.(clubId);
      break;

    case "INSUFFICIENT_FUNDS":
      message.textContent = "❌ Not enough funds for upgrade.";
      break;

    case "ALREADY_UPGRADED_THIS_SEASON":
      message.textContent = "❌ You have already upgraded this season.";
      break;

    case "NO_UPGRADE_AVAILABLE":
      message.textContent = "❌ Stadium is already at maximum capacity.";
      break;

    default:
      message.textContent = "❌ Unknown error.";
  }
}

/* ============================================================
   MODULE F: LOAD FINANCES
   ============================================================ */
async function loadFinance() {
  const { data, error } = await supabase
    .from("Club_Finances")
    .select("*")
    .eq("club_name", currentUserShort)
    .single();

  if (error || !data) {
    console.error("Finance lookup failed:", error);
    return;
  }

  document.getElementById("finance-balance").textContent =
    `₿ ${data.balance.toLocaleString()}`;
}

/* ============================================================
   MODULE C: DASHBOARD REFRESH WRAPPER
   ============================================================ */
async function loadDashboard() {
  await loadShortNameFromFirestore();
  await loadClubFromSupabase();
  await loadActiveListingsCache();
  await loadClubDetails();
  await loadFinance();
  await loadSquad();
  await loadListings();
  await loadMyActiveBids();

  /* ⭐ NEW: Load Season Signings */
  await loadSeasonSignings();

  if (clubId != null) {
    await loadStadiumInfo(clubId);
  } else {
    console.error("clubId is null, cannot load stadium info");
  }
}

/* ============================================================
   MODULE D: AUTH + INITIAL LOAD
   ============================================================ */
auth.onAuthStateChanged(async user => {
  if (!user) {
    window.location = "login.html";
    return;
  }

  const token = await user.getIdToken();

  await loadClubsMap();
  console.log("Clubs map loaded");

  currentUserEmail = user.email;
  document.getElementById("userEmail").textContent = currentUserEmail;

  await loadDashboard();
});

/* ============================================================
   MODULE D: FIRESTORE → SHORTNAME
   ============================================================ */
async function loadShortNameFromFirestore() {
  const uid = auth.currentUser.uid;

  const doc = await db.collection("users").doc(uid).get();

  if (!doc.exists) {
    console.error("Firestore user doc missing ShortName");
    return;
  }

  currentUserShort = doc.data().ShortName;
}

/* ============================================================
   MODULE E: SUPABASE → CLUB INFO
   ============================================================ */
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

  clubId = data.Club_ID;
  currentUserClubID = data.Club_ID;
  currentUserClub = data.Club;

  document.getElementById("clubNameField").textContent =
    fullClubName(currentUserShort);

  document.getElementById("dashboardTitle").textContent =
    `${fullClubName(currentUserShort)} Dashboard`;

  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${currentUserShort}.png`;
}

/* ============================================================
   MODULE F: ACTIVE LISTINGS CACHE
   ============================================================ */
async function loadActiveListingsCache() {
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", currentUserShort)
    .eq("status", "Active");

  if (error) {
    console.error("Active listings cache error", error);
  }

  activeListingsCache = data || [];
}

/* ============================================================
   MODULE F: CLUB DETAILS PANEL
   ============================================================ */
async function loadClubDetails() {
  const { data, error } = await supabase
    .from("Clubs")
    .select("*")
    .eq("Club_ID", clubId)
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

  document.getElementById("stadiumField").textContent =
    data.Stadium || "Unknown";
  document.getElementById("capacityField").textContent =
    data.Capacity || "Unknown";

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
      .eq("Club_ID", clubId);

    ownerInput.disabled = true;
    saveBtn.style.display = "none";
    editBtn.style.display = "inline-block";

    await loadClubDetails();
  };
}

/* ============================================================
   ⭐ MODULE N: SEASON SIGNINGS (NEW)
   ============================================================ */
async function loadSeasonSignings() {
  const { data, error } = await supabase
    .from("Transfer_History")
    .select(`
      player_id,
      fee,
      seller_club_id,
      transfer_time,
      Players ( Name )
    `)
    .eq("buyer_club_id", currentUserShort)
    .order("transfer_time", { ascending: false });

  if (error) {
    console.error("Season signings load error:", error);
    return;
  }

  renderSeasonSignings(data || []);
}

function renderSeasonSignings(rows) {
  const tbody = document.getElementById("season-signings-body");
  tbody.innerHTML = "";

  if (!rows.length) {
    tbody.innerHTML = `
      <tr>
        <td colspan="3" style="text-align:center; opacity:0.7;">
          No signings this season.
        </td>
      </tr>
    `;
    return;
  }

  rows.forEach(r => {
    const tr = document.createElement("tr");
    tr.dataset.konamiId = r.player_id;

    tr.innerHTML = `
      <td>${r.Players?.Name || "Unknown"}</td>
      <td>${r.seller_club_id || "-"}</td>
      <td>₿ ${r.final_fee?.toLocaleString() || "-"}</td>
    `;

    tbody.appendChild(tr);
  });

  applyPESDBRowClicks("season-signings-body");
}

/* ============================================================
   MODULE G: SQUAD
   ============================================================ */
async function loadSquad() {
  const { data, error } = await supabase
    .from("Players")
    .select("*")
    .eq("Contracted_Team", currentUserShort);

  if (error) {
    console.error("Squad load error", error);
    return;
  }

  renderSquad(data);
}

function renderSquad(players) {
  const tbody = document.getElementById("squad-body");
  tbody.innerHTML = "";

  const groups = {
    "Goalkeepers": ["GK"],
    "Defenders": ["LB", "CB", "RB"],
    "Midfielders": ["DMF", "LMF", "CMF", "RMF", "AMF"],
    "Attackers": ["SS", "LW", "CF", "RW"]
  };

  for (const [groupName, positions] of Object.entries(groups)) {
    const headerRow = document.createElement("tr");
    headerRow.classList.add("squad-section-row");
    headerRow.innerHTML = `
      <td colspan="8" class="squad-section-title">${groupName}</td>
    `;
    tbody.appendChild(headerRow);

    const groupPlayers = players
      .filter(p => positions.includes(p.Position))
      .sort((a, b) => {
        const posA = positions.indexOf(a.Position);
        const posB = positions.indexOf(b.Position);
        if (posA !== posB) return posA - posB;
        return b.market_value - a.market_value;
      });

    groupPlayers.forEach(p => {
      const isListed = activeListingsCache.some(
        l => l.player_id === p.Konami_ID
      );

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
      tr.dataset.konamiId = p.Konami_ID;

      tr.innerHTML = `
        <td>${p.Name}</td>
        <td>${p.Nation || "-"}</td>
        <td>${p.Position}</td>
        <td>${p.Rating || p.OVR}</td>
        <td>${p.Playstyle || "-"}</td>
        <td>₿ ${p.market_value}</td>
        <td>${status}</td>
        <td>${actionDropdown}</td>
      `;

      tbody.appendChild(tr);
    });
  }

  applyPESDBRowClicks("squad-body");
}

function handlePlayerAction(playerId, action) {
  if (action === "list") {
    openListPlayerModalByID({ Konami_ID: playerId });
  }
}

window.handlePlayerAction = handlePlayerAction;

/* ============================================================
   MODULE H: LIST PLAYER MODAL
   ============================================================ */
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

  document.getElementById("modalMarketValue").textContent =
    `₿ ${player.market_value}`;
  document.getElementById("modalMaxReserve").textContent =
    `₿ ${player.Maximum_Reserve_Price}`;

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

/* ============================================================
   MODULE H: CREATE LISTING
   ============================================================ */
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
    seller_club_id: currentUserShort,
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

/* ============================================================
   UTILITY: FETCH PLAYER BY KONAMI ID
   ============================================================ */
async function fetchPlayerByID(kid) {
  const { data } = await supabase
    .from("Players")
    .select("*")
    .eq("Konami_ID", kid)
    .single();

  return data;
}

/* ============================================================
   DISMISS LOGIC
   ============================================================ */
async function dismissListingForUser(listingId) {
  const userId = auth.currentUser.uid;

  await supabase
    .from("User_Dismissed_Listings")
    .insert({
      user_id: userId,
      listing_id: listingId,
      dismissed_at: new Date().toISOString()
    });
}

/* ============================================================
   MODULE J: LOAD LISTINGS
   ============================================================ */
async function loadListings() {

  console.log("🔄 loadListings() called — filtering archived listings");

  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", currentUserShort)
    .eq("archived", false);

  if (error) {
    console.error("❌ Listings error:", error);
    return;
  }

  console.log("📦 Listings returned:", data.length);

  for (const l of data) {
    const now = new Date();
    const end = new Date(l.end_time);

    if (end < now && l.status === "Active") {
      await transferEngine.evaluateExpiredListing(l);
    }

    if (l.status === "Review" && l.review_deadline) {
      const reviewEnd = new Date(l.review_deadline);
      if (reviewEnd < now) {
        await transferEngine.rejectSale(l.id);
      }
    }
  }

  // 3. Reload listings after updates
   const refreshed = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("seller_club_id", currentUserShort)
    .eq("archived", false);

  const updatedListings = refreshed.data || [];

  // Load per-user dismissed listing IDs
  const { data: dismissedRows } = await supabase
    .from("User_Dismissed_Listings")
    .select("listing_id")
    .eq("user_id", auth.currentUser.uid);

  const dismissedIds = new Set((dismissedRows || []).map(r => r.listing_id));

  // ⭐ Collapse duplicates: keep only newest bid per listing
  const latestByListing = new Map();

  for (const b of data || []) {
    if (!latestByListing.has(b.listing_id)) {
      latestByListing.set(b.listing_id, b);
    }
  }

  const uniqueBids = Array.from(latestByListing.values());

  // Remove dismissed ones
  const filtered = uniqueBids.filter(b => !dismissedIds.has(b.listing_id));

  renderMyActiveBids(filtered);

  // 4. Split into categories
  const active = updatedListings.filter(l => l.status === "Active");
  const review = updatedListings.filter(l => l.status === "Review");
  const closed = updatedListings.filter(l => l.status === "Closed");

  // 5. Render UI
  const activeForView = active.filter(l => !dismissedIds.has(l.id));
  renderActiveListings(activeForView);
  renderSellerReview(review);
  renderClosedListings(closed);

  // 6. Refresh squad + cache
  await loadActiveListingsCache();
  await loadSquad();
}

/* ============================================================
   MODULE J: ACTIVE LISTINGS
   ============================================================ */
async function renderActiveListings(listings) {
  const tbody = document.getElementById("active-listings-body");
  tbody.innerHTML = "";

  for (const l of listings) {
    const player = await fetchPlayerByID(l.player_id);

    const tr = document.createElement("tr");
    tr.dataset.konamiId = l.player_id;
    tr.dataset.listingId = l.id;

    const showDismiss = l.status && l.status !== "Active";

    tr.innerHTML = `
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>${player?.Rating || "-"}</td>
      <td>₿ ${l.market_value}</td>
      <td>₿ ${l.reserve_price}</td>
      <td>${formatTimeRemaining(l.end_time)}</td>
      <td>${l.current_highest_bid || "-"}</td>
      <td>${l.current_highest_bidder || "-"}</td>
      <td>
        ${
          showDismiss
            ? `<button class="button dismiss-btn" data-listing-id="${l.id}">❌</button>`
            : ""
        }
      </td>
    `;

    tbody.appendChild(tr);
  }

  tbody.querySelectorAll(".dismiss-btn").forEach(btn => {
    btn.addEventListener("click", async (e) => {
      e.stopPropagation();
      const listingId = e.currentTarget.dataset.listingId;
      await dismissListingForUser(listingId);
      const row = e.currentTarget.closest("tr");
      if (row) row.remove();
    });
  });

  applyPESDBRowClicks("active-listings-body");
}

/* ============================================================
   MODULE J: SELLER REVIEW
   ============================================================ */
async function renderSellerReview(listings) {
  const tbody = document.getElementById("seller-review-body");
  tbody.innerHTML = "";

  for (const l of listings) {
    const player = await fetchPlayerByID(l.player_id);

    const tr = document.createElement("tr");
    tr.dataset.konamiId = l.player_id;

    tr.innerHTML = `
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>${player?.Rating || "-"}</td>
      <td>₿ ${l.current_highest_bid || "-"}</td>
      <td>${l.current_highest_bidder || "-"}</td>
      <td>${new Date(l.end_time).toLocaleString()}</td>
      <td>
        <div class="decision-buttons">
          <button class="button" onclick="transferEngine.acceptSale(${l.id})">Accept</button>
          <button class="button" onclick="transferEngine.rejectSale(${l.id})">Reject</button>
        </div>
      </td>
    `;

    tbody.appendChild(tr);
  }

  applyPESDBRowClicks("seller-review-body");
}

/* ============================================================
   MODULE J: CLOSED LISTINGS
   ============================================================ */
async function renderClosedListings(listings) {
  const tbody = document.getElementById("closed-listings-body");
  tbody.innerHTML = "";

  for (const l of listings) {
    const player = await fetchPlayerByID(l.player_id);

    const tr = document.createElement("tr");
    tr.dataset.konamiId = l.player_id;

    tr.innerHTML = `
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>${player?.Rating || "-"}</td>
      <td>${l.final_bid || "-"}</td>
      <td>${l.winner || "-"}</td>
      <td>${l.status}</td>
      <td>
        <button class="button" style="background:#aa2222; color:#fff;"
                onclick="dismissClosedListing(${l.id})">❌</button>
      </td>
    `;

    tbody.appendChild(tr);
  }

  applyPESDBRowClicks("closed-listings-body");
}

async function dismissClosedListing(id) {
  await supabase
    .from("Player_Transfer_Listings")
    .update({ archived: true })
    .eq("id", id);

  loadListings();
}

window.dismissClosedListing = dismissClosedListing;

/* ============================================================
   MODULE K: MY ACTIVE BIDS
   ============================================================ */
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
        end_time,
        status
      )
    `)
    .eq("bidder_club_id", currentUserShort)
    .order("bid_time", { ascending: false });

  if (error) {
    console.error("Active bids error:", error);
    return;
  }

  const { data: dismissedRows } = await supabase
    .from("User_Dismissed_Listings")
    .select("listing_id")
    .eq("user_id", auth.currentUser.uid);

  const dismissedIds = new Set((dismissedRows || []).map(r => r.listing_id));

  const latestByListing = new Map();

  for (const b of data || []) {
    if (!latestByListing.has(b.listing_id)) {
      latestByListing.set(b.listing_id, b);
    }
  }

  const uniqueBids = Array.from(latestByListing.values());

  const filtered = uniqueBids.filter(b => !dismissedIds.has(b.listing_id));

  renderMyActiveBids(filtered);
}

async function renderMyActiveBids(bids) {
  const tbody = document.getElementById("my-active-bids-body");
  tbody.innerHTML = "";

  for (const b of bids) {
    if (!b.Player_Transfer_Listings) continue;

    const l = b.Player_Transfer_Listings;
    if (!l) continue;

    const player = await fetchPlayerByID(l.player_id);

    const tr = document.createElement("tr");
    tr.dataset.konamiId = l.player_id;
    tr.dataset.listingId = l.id;

    const showDismiss = l.status && l.status !== "Active";

    tr.innerHTML = `
      <td>${player?.Name || "Unknown"}</td>
      <td>${player?.Position || "-"}</td>
      <td>₿ ${b.bid_amount}</td>
      <td>₿ ${l.current_highest_bid || "-"}</td>
      <td>${l.current_highest_bidder || "-"}</td>
      <td>${new Date(l.end_time).toLocaleString()}</td>
      <td>
        ${
          showDismiss
            ? `<button class="button dismiss-bid-btn" data-listing-id="${l.id}">❌</button>`
            : ""
        }
      </td>
    `;

    tbody.appendChild(tr);
  }

  tbody.querySelectorAll(".dismiss-bid-btn").forEach(btn => {
    btn.addEventListener("click", async (e) => {
      e.stopPropagation();
      const listingId = e.currentTarget.dataset.listingId;
      await dismissListingForUser(listingId);
      const row = e.currentTarget.closest("tr");
      if (row) row.remove();
    });
  });

  applyPESDBRowClicks("my-active-bids-body");
}

/* ============================================================
   MODULE L: UNIVERSAL PESDB ROW CLICK HANDLER
   ============================================================ */
function applyPESDBRowClicks(tbodyId) {
  const tbody = document.getElementById(tbodyId);
  if (!tbody) return;

  tbody.querySelectorAll("tr").forEach(row => {
    row.style.cursor = "pointer";

    row.addEventListener("click", e => {
      if (
        e.target.closest("select") ||
        e.target.closest("button") ||
        e.target.closest(".decision-buttons")
      ) {
        return;
      }

      const id = row.dataset.konamiId;
      if (id) {
        window.open(
          `https://pesdb.net/efootball/?id=${id}`,
          "_blank",
          "noopener"
        );
      }
    });
  });
}

/* ============================================================
   MODULE M: TIME REMAINING FORMATTER
   ============================================================ */
function formatTimeRemaining(endTime) {
  const end = new Date(endTime);
  const now = new Date();
  const diff = end - now;

  if (diff <= 0) return "Expired";

  const hours = Math.floor(diff / 3600000);
  const mins = Math.floor((diff % 3600000) / 60000);

  return `${hours}h ${mins}m`;
}

console.log("Dashboard JS loaded successfully.");
