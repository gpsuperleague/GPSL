import {
  supabase,
  initGlobal,
  buildNav,
  getUKNow,
  loadGlobalSettings,
  wireDraftCountdownUI,
  startDraftCountdown,
} from "./global.js";

function formatMoney(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `₿${Math.round(v).toLocaleString("en-GB")}`;
}

let ownerId = null;
let ownerTag = null;
let budget = 0;
let auctionState = null;
let pollTimer = null;

async function loadOwnerContext() {
  const { data: self, error } = await supabase.rpc("owner_registry_get_self");
  if (error || !self?.needs_club_auction) {
    window.location = "awaiting_club.html";
    return false;
  }
  ownerId = (await supabase.auth.getUser()).data.user?.id || null;
  ownerTag = self.owner_tag || null;
  budget = Number(self.pending_starting_balance) || 0;
  return true;
}

async function refreshAuctionState() {
  const { data, error } = await supabase.rpc("club_auction_get_state");
  if (error) {
    auctionState = { error: error.message };
    return;
  }
  auctionState = data;
}

function renderStatus() {
  const el = document.getElementById("auctionStatus");
  if (!el) return;

  if (auctionState?.error) {
    el.textContent = `Auction unavailable — run patches/club_auction.sql. (${auctionState.error})`;
    el.style.color = "#f88";
    return;
  }

  if (!auctionState?.enabled) {
    el.textContent =
      "Club auction is not enabled yet. Admin must turn it on under Transfer management.";
    el.style.color = "#faa";
    return;
  }

  if (!ownerTag) {
    el.innerHTML =
      'Set your <a href="awaiting_club.html" style="color:#ff9900;">owner tag</a> before bidding.';
    el.style.color = "#faa";
    return;
  }

  if (auctionState.bidding_open) {
    el.textContent = `Bidding is open · ${auctionState.active_listings ?? 0} clubs listed · Budget ${formatMoney(budget)}`;
    el.style.color = "#9f9";
    return;
  }

  if (auctionState.start_time) {
    const start = new Date(auctionState.start_time);
    const now = getUKNow();
    if (now < start) {
      el.textContent = `Auction opens at ${start.toLocaleString("en-GB", { timeZone: "Europe/London" })} UK`;
      el.style.color = "#ccc";
      return;
    }
  }

  el.textContent =
    "Bidding is closed. If the random finish has passed, admin will settle winners.";
  el.style.color = "#aaa";
}

async function updateLeadPanel() {
  const el = document.getElementById("leadPanel");
  if (!el || !ownerId) return;

  const { data: rows } = await supabase
    .from("club_auction_listings_public")
    .select("club_short_name, club_name, current_highest_bid")
    .eq("current_highest_bidder", ownerId);

  if (!rows?.length) {
    el.innerHTML =
      '<span style="color:#888;">You are not leading any club auction.</span>';
    return;
  }

  const r = rows[0];
  el.innerHTML = `<b>Your leading bid:</b> ${r.club_name || r.club_short_name} — ${formatMoney(r.current_highest_bid)}`;
}

async function loadListings() {
  const tbody = document.getElementById("auctionTableBody");
  if (!tbody) return;

  if (!auctionState?.enabled) {
    tbody.innerHTML = `<tr><td colspan="6">Club auction is off.</td></tr>`;
    return;
  }

  const { data: listings, error } = await supabase
    .from("club_auction_listings_public")
    .select("*")
    .order("prestige_rank", { ascending: true, nullsFirst: false });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="6">Could not load listings — ${error.message}</td></tr>`;
    return;
  }

  if (!listings?.length) {
    tbody.innerHTML = `<tr><td colspan="6">No vacant clubs listed. Admin: Transfer management → Seed vacant club listings.</td></tr>`;
    return;
  }

  const canBid = auctionState?.bidding_open && ownerTag;
  tbody.innerHTML = "";

  for (const row of listings) {
    const tr = document.createElement("tr");
    const minBid = Number(row.min_next_bid) || Number(row.opening_bid) || 0;
    const isLeader = row.current_highest_bidder === ownerId;
    tr.innerHTML = `
      <td><b>${row.club_name || row.club_short_name}</b> <span style="color:#666;">${row.club_short_name}</span></td>
      <td>${row.prestige_rank ?? "—"}</td>
      <td>${formatMoney(row.opening_bid)}</td>
      <td>${row.current_highest_bid ? formatMoney(row.current_highest_bid) : "—"}</td>
      <td>${row.current_leader_tag || "—"}${isLeader ? " (you)" : ""}</td>
      <td></td>
    `;
    const bidCell = tr.lastElementChild;
    if (canBid) {
      const input = document.createElement("input");
      input.type = "number";
      input.className = "bid-input";
      input.step = "1000000";
      input.min = String(minBid);
      input.value = String(minBid);
      input.placeholder = formatMoney(minBid);
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "bid-btn";
      btn.textContent = "Bid";
      btn.onclick = () => placeBid(row.club_short_name, input.value, btn);
      bidCell.appendChild(input);
      bidCell.appendChild(document.createTextNode(" "));
      bidCell.appendChild(btn);
    } else {
      bidCell.textContent = "—";
    }
    tbody.appendChild(tr);
  }
}

async function placeBid(shortName, rawAmount, btn) {
  const amount = Number(rawAmount);
  if (!Number.isFinite(amount) || amount <= 0) {
    alert("Enter a valid bid amount.");
    return;
  }
  btn.disabled = true;
  const { data, error } = await supabase.rpc("club_auction_place_bid", {
    p_club_short_name: shortName,
    p_amount: amount,
  });
  btn.disabled = false;
  if (error) {
    alert(error.message);
    return;
  }
  budget = Number(data?.remaining_budget) ?? budget;
  await refreshAuctionState();
  renderStatus();
  await updateLeadPanel();
  await loadListings();
}

async function refreshAll() {
  await refreshAuctionState();
  renderStatus();
  await updateLeadPanel();
  await loadListings();
}

document.addEventListener("DOMContentLoaded", async () => {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  await initGlobal();
  await buildNav();

  if (!(await loadOwnerContext())) return;

  await loadGlobalSettings();
  wireDraftCountdownUI();
  if (document.getElementById("draftCountdown")) {
    startDraftCountdown();
  }

  await refreshAll();
  pollTimer = setInterval(refreshAll, 15000);
});
