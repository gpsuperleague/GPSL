// ======================================================
// MODULE A: GLOBAL STATE
// ======================================================
import { loadClubsMap, fullClubName, clubPageHref } from "./clubs_lookup.js";

function pesdbPlayerUrl(konamiId) {
  return `https://pesdb.net/efootball/?id=${encodeURIComponent(konamiId)}`;
}

// Use global Supabase client (created in all_listings.html)
const supabase = window.supabase;

let currentUserShort = null;
let openListings = [];
let reviewListings = [];
let selectedListing = null;
let renderGeneration = 0;

// Load club map immediately
await loadClubsMap();

// ⭐ Format numbers as ₿ 1,234,567
function formatMoney(amount) {
  if (amount == null || isNaN(amount)) return "-";
  return "₿ " + Number(amount).toLocaleString("en-GB");
}

const BID_INCREMENT = 500000;

function listingMinimumBid(listing) {
  const mv = Number(listing.market_value) || 0;
  const high = Number(listing.current_highest_bid) || 0;
  if (!high) return mv;
  return Math.max(mv, high + BID_INCREMENT);
}

function listingBidWarningText(listing) {
  const mv = Number(listing.market_value) || 0;
  const high = Number(listing.current_highest_bid) || 0;
  const min = listingMinimumBid(listing);
  if (!high) {
    return `Minimum bid is market value (${formatMoney(mv)}).`;
  }
  return `Minimum bid is ${formatMoney(min)} (at least market value and ₿500,000 above the current highest).`;
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
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

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

  // ⭐ Auto-refresh listings every 30 seconds so status/time stay live
  setInterval(loadListings, 30000);

  console.log("all_listings.js initialized successfully");
})();

// ======================================================
// MODULE A: SUPABASE → SHORTNAME
// ======================================================
async function loadShortNameFromSupabase(userId) {
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
  const nowIso = new Date().toISOString();

  const [openRes, reviewRes] = await Promise.all([
    supabase
      .from("Player_Transfer_Listings")
      .select("*")
      .neq("listing_type", "draft")
      .eq("status", "Active")
      .gt("end_time", nowIso)
      .order("end_time", { ascending: true }),
    supabase
      .from("Player_Transfer_Listings")
      .select("*")
      .neq("listing_type", "draft")
      .in("status", ["Review", "Seller Review"])
      .order("end_time", { ascending: true }),
  ]);

  if (openRes.error) {
    console.error("Open listings error", openRes.error);
    return;
  }
  if (reviewRes.error) {
    console.error("Review listings error", reviewRes.error);
    return;
  }

  openListings = dedupeOpenListingsByPlayer(openRes.data || []);
  reviewListings = reviewRes.data || [];
  await renderListings();
}

function dedupeOpenListingsByPlayer(listings) {
  const byPlayer = new Map();
  for (const row of listings) {
    const key = String(row.player_id);
    const existing = byPlayer.get(key);
    if (!existing || new Date(row.end_time) > new Date(existing.end_time)) {
      byPlayer.set(key, row);
    }
  }
  return [...byPlayer.values()].sort(
    (a, b) => new Date(a.end_time) - new Date(b.end_time)
  );
}

function allLoadedListings() {
  return [...openListings, ...reviewListings];
}

// ======================================================
// MODULE C: FILTER CHECKBOXES
// ======================================================
function wireFilterCheckboxes() {
  document
    .getElementById("filter-active")
    .addEventListener("change", () => {
      void renderListings();
    });
  document
    .getElementById("filter-closed")
    .addEventListener("change", () => {
      void renderListings();
    });
}

// ======================================================
// MODULE D: RENDER LISTINGS TABLE
// ======================================================
async function renderListings() {
  const gen = ++renderGeneration;
  const tbody = document.getElementById("listings-body");
  tbody.innerHTML = "";

  const showActive = document.getElementById("filter-active").checked;
  const showClosed = document.getElementById("filter-closed").checked;

  const rows = [];
  if (showActive) rows.push(...openListings);
  if (showClosed) rows.push(...reviewListings);

  if (rows.length === 0) {
    const tr = document.createElement("tr");
    tr.innerHTML =
      `<td colspan="12" style="text-align:center;color:#888;">No listings to show.</td>`;
    tbody.appendChild(tr);
    return;
  }

  const playerIds = [...new Set(rows.map((l) => String(l.player_id)))];
  const playerMap = await fetchPlayersMap(playerIds);
  if (gen !== renderGeneration) return;

  const now = new Date();

  for (const listing of rows) {
    const player = playerMap.get(String(listing.player_id));

    const extendedLabel = listing.was_extended
      ? ` <span style="color:#d9534f;font-weight:bold;">(Extended)</span>`
      : "";

    const tr = document.createElement("tr");

    if (listing.current_highest_bidder === currentUserShort) {
      tr.classList.add("leading-row");
    }

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

    const imgURL = `https://pesdb.net/assets/img/card/b${listing.player_id}.png`;
    const pesdbUrl = pesdbPlayerUrl(listing.player_id);
    const clubUrl = clubPageHref(listing.seller_club_id);
    const clubLabel = fullClubName(listing.seller_club_id);
    const playerName = player?.Name || "Unknown";

    const end = new Date(listing.end_time);
    const isOpen = listing.status === "Active" && end > now;
    const canBid =
      isOpen && listing.seller_club_id !== currentUserShort && !!currentUserShort;

    tr.innerHTML = `
      <td>
        <a href="${clubUrl}" class="gpsl-link club-link">${clubLabel}</a>
      </td>

      <td>
        <a href="${pesdbUrl}" target="_blank" rel="noopener" class="gpsl-link listing-thumb-link pesdb-link">
          <img src="${imgURL}"
               class="listing-thumb"
               alt="${playerName}"
               onerror="this.src='https://i.imgur.com/3s8XQ7Y.png'">
        </a>
      </td>

      <td>
        <a href="${pesdbUrl}" target="_blank" rel="noopener" class="gpsl-link pesdb-link">${playerName}</a>
      </td>
      <td>${player?.Position || "-"}</td>
      <td>${player?.Playstyle || "-"}</td>
      <td>${player?.Rating || "-"}</td>
      <td>${formatMoney(listing.market_value)}</td>
      <td>${formatMoney(listing.reserve_price)}</td>
      <td>${listing.status} ${extendedLabel}</td>
      <td>${formatTimeRemaining(listing.end_time)}</td>
      <td>${formatMoney(listing.current_highest_bid)}</td>
      <td>${highestClubText}</td>
      <td>
        ${
          canBid
            ? `<button type="button" class="make-offer-btn" data-id="${listing.id}">Make Offer</button>`
            : "-"
        }
      </td>
    `;

    tr.querySelectorAll(".pesdb-link, .club-link").forEach((link) => {
      link.addEventListener("click", (e) => e.stopPropagation());
    });

    tbody.appendChild(tr);
  }

  if (gen !== renderGeneration) return;

  tbody.querySelectorAll(".make-offer-btn").forEach((btn) => {
    btn.addEventListener("click", async (e) => {
      e.stopPropagation();
      const id = btn.dataset.id;
      const listing = allLoadedListings().find(
        (l) => String(l.id) === String(id)
      );
      if (!listing) return;

      const nowClick = new Date();
      const endClick = new Date(listing.end_time);

      if (listing.seller_club_id === currentUserShort) {
        alert("You already own this player. You cannot bid on your own listing.");
        return;
      }

      if (listing.status !== "Active" || endClick <= nowClick) {
        alert("This listing is no longer open for bidding.");
        return;
      }

      const player = await fetchPlayerByID(listing.player_id);
      openBidModal(listing, player);
    });
  });
}

// ======================================================
// MODULE B: FETCH PLAYER
// ======================================================
async function fetchPlayersMap(playerIds) {
  const map = new Map();
  if (!playerIds.length) return map;

  const numericIds = playerIds
    .map((id) => Number(id))
    .filter((n) => Number.isFinite(n));

  const { data, error } = await supabase
    .from("Players")
    .select("*")
    .in("Konami_ID", numericIds);

  if (error) {
    console.error("Player batch lookup failed", error);
    return map;
  }

  for (const p of data || []) {
    map.set(String(p.Konami_ID), p);
  }
  return map;
}

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

  const now = new Date();
  const end = new Date(listing.end_time);
  if (end <= now || listing.status !== "Active") {
    alert("This listing has expired or is no longer open for bidding.");
    return;
  }

  selectedListing = listing;

  const konamiId = String(listing.player_id);
  const pesdbUrl = pesdbPlayerUrl(konamiId);
  const imgEl = document.getElementById("bid-modal-player-img");
  const pesdbLink = document.getElementById("bid-player-pesdb-link");

  imgEl.src = `https://pesdb.net/assets/img/card/b${konamiId}.png`;
  imgEl.onerror = () => {
    imgEl.src = "https://i.imgur.com/3s8XQ7Y.png";
  };
  pesdbLink.href = pesdbUrl;

  document.getElementById("bid-player-name").textContent =
    player?.Name || "Unknown";
  document.getElementById("bid-player-position").textContent =
    player?.Position || "-";
  document.getElementById("bid-player-playstyle").textContent =
    player?.Playstyle || "-";
  document.getElementById("bid-player-rating").textContent =
    player?.Rating || "-";

  const clubUrl = clubPageHref(listing.seller_club_id);
  const clubLink = document.getElementById("bid-selling-club-link");
  clubLink.href = clubUrl;
  document.getElementById("bid-selling-club").textContent = fullClubName(
    listing.seller_club_id
  );
  document.getElementById("bid-market-value").textContent = formatMoney(
    listing.market_value
  );
  document.getElementById("bid-reserve-price").textContent = formatMoney(
    listing.reserve_price
  );
  document.getElementById("bid-status").textContent = listing.status;
  document.getElementById("bid-time-remaining").textContent =
    formatTimeRemaining(listing.end_time);

  document.getElementById("bid-highest-bid").textContent = formatMoney(
    listing.current_highest_bid
  );
  document.getElementById("bid-highest-club").textContent =
    fullClubName(listing.current_highest_bidder) || "-";

  const input = document.getElementById("bid-amount");
  input.value = "";
  input.focus();
  input.select();

  document.getElementById("bid-error").textContent = "";

  const minBid = listingMinimumBid(listing);
  document.getElementById("bid-warning").textContent =
    `⚠️ ${listingBidWarningText(listing)}`;

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

  const minBid = listingMinimumBid(selectedListing);

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

  window.onclick = function (event) {
    if (event.target === modal) {
      modal.style.display = "none";
      selectedListing = null;
    }
  };

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") {
      modal.style.display = "none";
      selectedListing = null;
    }
  });
}

// ======================================================
// ⭐ UNIVERSAL BID ADJUSTMENT FUNCTION
// ======================================================
function adjustBid(amount) {
  const input = document.getElementById("bid-amount");
  let current = parseMoneyInput(input.value);

  current += amount;

  if (current < 0) current = 0;

  const minBid = listingMinimumBid(selectedListing);

  if (current < minBid) current = minBid;

  input.value = current.toLocaleString("en-GB");
  validateBidInput();
}

// ======================================================
// ⭐ INCREMENT & DECREMENT BUTTONS (FIXED IDS)
// ======================================================
function wireIncrementButtons() {
  const btns = [
    ["inc-500k-bid", 500000],
    ["inc-1m-bid", 1000000],
    ["inc-5m-bid", 5000000],
    ["dec-500k-bid", -500000],
    ["dec-1m-bid", -1000000],
    ["dec-5m-bid", -5000000],
  ];

  btns.forEach(([id, amount]) => {
    const el = document.getElementById(id);
    if (el) {
      el.onclick = () => adjustBid(amount);
    }
  });
}

// ======================================================
// ⭐ QUICK BID BUTTON
// ======================================================
function wireQuickBidButton() {
  document.getElementById("quick-bid-btn").onclick = () => {
    if (!selectedListing) return;

    const input = document.getElementById("bid-amount");
    input.value = listingMinimumBid(selectedListing).toLocaleString("en-GB");
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
  const minBid = listingMinimumBid(selectedListing);

  if (bidAmount < minBid) {
    errorBox.textContent = `Your bid must be at least ${formatMoney(minBid)}.`;
    return;
  }

  const { error: bidError } = await supabase
    .from("Player_Transfer_Bids")
    .insert({
      listing_id: selectedListing.id,
      player_id: String(selectedListing.player_id).trim(),
      bidder_club_id: currentUserShort,
      seller_club_id: selectedListing.seller_club_id,
      bid_amount: bidAmount,
      bid_time: new Date().toISOString(),
      is_direct: false,
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
      current_highest_bidder: currentUserShort,
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
