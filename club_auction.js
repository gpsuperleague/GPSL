window.CURRENT_PAGE = "club_auction";

import {
  supabase,
  initGlobal,
  getAuthUser,
  getUKNow,
  getDraftAuctionStartTime,
  getDraftCountdownOptions,
  getDraftRandomFinishRevealed,
  isGpslAdminUser,
} from "./global.js";
import {
  formatDraftConclusionLines,
} from "./countdown_display.js";
import {
  getClubAuctionEffectivePhase,
  clubAuctionPhaseLabel,
} from "./draft_timeline.js";
import { stadiumImageUrl } from "./stadium_images.js";

const GATE_PRICE_PER_SEAT = 20;
const STADIUM_VALUE_PER_SEAT = 1500;
const MAINTENANCE_RATE = 0.125;
const BID_INCREMENT = 500000;
const TABLE_COLS = 10;

function formatMoney(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `₿\u00a0${Math.round(v).toLocaleString("en-GB")}`;
}

function parseMoneyInput(value) {
  if (!value) return 0;
  return Number(String(value).replace(/,/g, "")) || 0;
}

function roundBidToMillion(amount) {
  return Math.round(amount / 1000000) * 1000000;
}

function listingMinimumBid(row) {
  const min = Number(row.min_next_bid);
  if (Number.isFinite(min) && min > 0) return min;
  const opening = Number(row.opening_bid) || stadiumCost(row);
  const high = Number(row.current_highest_bid) || 0;
  if (!high) return opening;
  return Math.max(opening, high + BID_INCREMENT);
}

function minimumBidHelpText(row) {
  const min = listingMinimumBid(row);
  const high = Number(row.current_highest_bid) || 0;
  const cost = stadiumCost(row);
  if (!high) {
    return `Opening bid is stadium cost (${formatMoney(cost)} = capacity × ₿1,000). Bids round to the nearest ₿1,000,000.`;
  }
  return `Minimum bid is ${formatMoney(min)} (stadium cost or ₿500,000 above the current highest). Bids round to the nearest ₿1,000,000.`;
}

function formatNum(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return Math.round(v).toLocaleString("en-GB");
}

function ordinal(n) {
  const v = Number(n);
  if (!Number.isFinite(v) || v < 1) return "—";
  const mod100 = v % 100;
  if (mod100 >= 11 && mod100 <= 13) return `${v}th`;
  const mod10 = v % 10;
  if (mod10 === 1) return `${v}st`;
  if (mod10 === 2) return `${v}nd`;
  if (mod10 === 3) return `${v}rd`;
  return `${v}th`;
}

function clubBadgeSrc(shortName) {
  if (!shortName) return null;
  return `images/club_badges/${shortName}.png`;
}

function fullGateMatchday(row) {
  const fromView = Number(row.full_gate_matchday);
  if (Number.isFinite(fromView) && fromView > 0) return fromView;
  const cap = Number(row.capacity) || 0;
  return cap * GATE_PRICE_PER_SEAT;
}

function seasonMaintenance(row) {
  const fromView = Number(row.season_maintenance_cost);
  if (Number.isFinite(fromView) && fromView > 0) return fromView;
  const cap = Number(row.capacity) || 0;
  return Math.round(cap * STADIUM_VALUE_PER_SEAT * MAINTENANCE_RATE);
}

function stadiumCost(row) {
  const fromView = Number(row.stadium_cost);
  if (Number.isFinite(fromView) && fromView > 0) return fromView;
  const cap = Number(row.capacity) || 0;
  return cap * 1000;
}

function season1Expected(row) {
  return row.season1_expected_position ?? row.expected_position ?? row.prestige_rank;
}

function renderClubCell(row) {
  const wrap = document.createElement("div");
  wrap.className = "club-cell";

  const shortName = row.club_short_name || "";
  const badgeSrc = clubBadgeSrc(shortName);
  const initials = shortName.slice(0, 3) || "?";

  if (badgeSrc) {
    const img = document.createElement("img");
    img.className = "club-badge";
    img.src = badgeSrc;
    img.alt = "";
    img.loading = "lazy";
    img.onerror = () => {
      const fallback = document.createElement("div");
      fallback.className = "club-badge-fallback";
      fallback.textContent = initials;
      img.replaceWith(fallback);
    };
    wrap.appendChild(img);
  } else {
    const fallback = document.createElement("div");
    fallback.className = "club-badge-fallback";
    fallback.textContent = initials;
    wrap.appendChild(fallback);
  }

  const meta = document.createElement("div");
  meta.className = "club-meta";

  const title = document.createElement("div");
  title.className = "club-title";
  title.textContent = row.club_name || shortName;
  meta.appendChild(title);

  if (row.stadium) {
    const stadium = document.createElement("div");
    stadium.className = "club-stadium";
    stadium.textContent = row.stadium;
    meta.appendChild(stadium);
  }

  wrap.appendChild(meta);
  return wrap;
}

let ownerId = null;
let ownerTag = null;
let budget = 0;
let auctionState = null;
let pollTimer = null;
let selectedListing = null;
let listingsCache = [];
let viewOnly = false;

function applyViewOnlyIntro(isAdmin) {
  const intro = document.getElementById("clubAuctionIntro");
  const lead = document.getElementById("leadPanel");
  if (intro) {
    intro.innerHTML = isAdmin
      ? "<b>Admin view</b> — you already have a club, so you cannot bid here. " +
        "Use <b>History</b> on each listing to inspect bids. Owners without a club bid from this page during the auction window."
      : "<b>View only</b> — you already manage a club, so bidding here is not available. " +
        "You can still review listings and bid history.";
  }
  if (lead) {
    lead.innerHTML = isAdmin
      ? '<span style="color:#888;">Admin preview — bidding disabled while you hold a club.</span>'
      : '<span style="color:#888;">You already have a club — bidding is disabled on this page.</span>';
  }
}

async function userHasClub(userId) {
  if (!userId) return false;
  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", userId)
    .maybeSingle();
  if (error) {
    console.warn("club_auction: club lookup failed", error);
    return false;
  }
  return Boolean(data?.ShortName);
}

async function loadOwnerContext() {
  const user = await getAuthUser();
  ownerId = user?.id || null;
  const isAdmin = isGpslAdminUser(user);

  const { data: self, error } = await supabase.rpc("owner_registry_get_self");
  const hasClub = Boolean(self?.has_club) || (await userHasClub(ownerId));

  if (hasClub) {
    viewOnly = true;
    ownerTag = self?.owner_tag || null;
    budget = 0;
    applyViewOnlyIntro(isAdmin);
    return true;
  }

  if (error) {
    ownerTag = null;
    budget = 0;
    return true;
  }

  ownerTag = self?.owner_tag || null;
  budget = Number(self?.pending_starting_balance) || 0;

  const intro = document.getElementById("clubAuctionIntro");
  if (intro && budget > 0) {
    intro.innerHTML =
      `Bid for a GPSL club from your <b>${formatMoney(budget)}</b> starting budget. You may only lead one club at a time. ` +
      "When the auction closes, the highest bidder wins the club and your balance is set to budget minus your winning bid.";
  }
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

function resolveClubAuctionFinishInstant() {
  const fromState = auctionState?.finish_time;
  if (fromState) {
    const d = new Date(fromState);
    if (!Number.isNaN(d.getTime())) return d;
  }
  const revealed = getDraftRandomFinishRevealed();
  if (revealed) {
    const d = new Date(revealed);
    if (!Number.isNaN(d.getTime())) return d;
  }
  return null;
}

function renderClosedAuctionStatus(el) {
  const finish = resolveClubAuctionFinishInstant();
  const active = Number(auctionState?.active_listings ?? 0);

  if (finish) {
    const { duration, subline } = formatDraftConclusionLines(finish, "club");
    const settleNote =
      active > 0
        ? `${active} club listing${active === 1 ? "" : "s"} still open — winners assign automatically when the transfer engine runs (Supabase schedule, about every 5 minutes).`
        : "All club listings settled — winners should see their club on the dashboard; refresh if you just won.";
    el.innerHTML = `
      <div style="color:#ddd;font-weight:600;">${duration}</div>
      <div style="font-size:12px;color:#aaa;margin-top:6px;white-space:pre-line;line-height:1.45;">${subline}</div>
      <div style="font-size:12px;color:${active > 0 ? "#ffcc00" : "#9f9"};margin-top:8px;">${settleNote}</div>`;
    el.style.color = "#ddd";
    return;
  }

  const start = getDraftAuctionStartTime();
  const phase = start
    ? getClubAuctionEffectivePhase(getUKNow(), start, getDraftCountdownOptions())
    : null;
  if (phase === "random_active") {
    el.textContent =
      "Random closing window (6:50–6:59pm UK Day 2) — bidding stops at a secret second; exact time appears here once closed.";
    el.style.color = "#ffcc00";
    return;
  }
  if (phase === "random_locked") {
    el.textContent =
      "Bidding locked — waiting for the secret random finish time to publish, then the transfer engine assigns winners.";
    el.style.color = "#ccc";
    return;
  }

  el.textContent =
    "Bidding is closed. Exact random finish time appears here once the window ends; winners assign via the transfer engine or Admin → Settle club auctions.";
  el.style.color = "#aaa";
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

  if (viewOnly) {
    const start = getDraftAuctionStartTime();
    const phase = start
      ? getClubAuctionEffectivePhase(getUKNow(), start, getDraftCountdownOptions())
      : null;
    const phaseHint = phase ? clubAuctionPhaseLabel(phase) : "";
    el.textContent = `View only · ${auctionState.active_listings ?? 0} clubs listed${phaseHint ? ` · ${phaseHint}` : ""}`;
    el.style.color = "#ccc";
    return;
  }

  if (!ownerTag) {
    el.innerHTML =
      'Set your <a href="awaiting_club.html" style="color:#ff9900;">owner tag</a> before bidding.';
    el.style.color = "#faa";
    return;
  }

  if (auctionState.bidding_open) {
    const start = getDraftAuctionStartTime();
    const phase = start
      ? getClubAuctionEffectivePhase(getUKNow(), start, getDraftCountdownOptions())
      : null;
    const phaseHint = phase ? clubAuctionPhaseLabel(phase) : "";
    el.textContent = `Bidding is open · ${auctionState.active_listings ?? 0} clubs listed · Budget ${formatMoney(budget)}${phaseHint ? ` · ${phaseHint}` : ""}`;
    el.style.color = "#9f9";
    return;
  }

  if (auctionState.start_time) {
    const start = new Date(auctionState.start_time);
    const now = getUKNow();
    if (now < start) {
      el.textContent = `Club auction opens at ${start.toLocaleString("en-GB", { timeZone: "Europe/London" })} UK (Day 1 · 7pm)`;
      el.style.color = "#ccc";
      return;
    }
    const phase = getClubAuctionEffectivePhase(now, start, getDraftCountdownOptions());
    if (phase && phase !== "ended" && phase !== "random_locked") {
      el.textContent = clubAuctionPhaseLabel(phase);
      el.style.color = phase === "random_active" ? "#ffcc00" : "#ccc";
      return;
    }
  }

  renderClosedAuctionStatus(el);
}

async function updateLeadPanel() {
  const el = document.getElementById("leadPanel");
  if (!el || !ownerId) return;
  if (viewOnly) return;

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
    tbody.innerHTML = `<tr><td colspan="${TABLE_COLS}" class="empty-row">Club auction is off.</td></tr>`;
    return;
  }

  const { data: listings, error } = await supabase
    .from("club_auction_listings_public")
    .select("*")
    .order("prestige_rank", { ascending: true, nullsFirst: false });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="${TABLE_COLS}" class="empty-row">Could not load listings — ${error.message}</td></tr>`;
    return;
  }

  if (!listings?.length) {
    tbody.innerHTML = `<tr><td colspan="${TABLE_COLS}" class="empty-row">No vacant clubs listed. Admin: Transfer management → Seed vacant club listings.</td></tr>`;
    return;
  }

  listingsCache = listings;
  const canBid = !viewOnly && auctionState?.bidding_open && ownerTag;
  tbody.innerHTML = "";

  for (const row of listings) {
    const tr = document.createElement("tr");
    const minBid = listingMinimumBid(row);
    const isLeader = row.current_highest_bidder === ownerId;
    const expPos = season1Expected(row);
    const gate = fullGateMatchday(row);
    const maint = seasonMaintenance(row);
    const cost = stadiumCost(row);
    const highBidHtml = row.current_highest_bid
      ? `<span class="high-bid-link" data-listing-id="${row.id}" title="View bid history">${formatMoney(row.current_highest_bid)}</span>`
      : "—";

    tr.innerHTML = `
      <td></td>
      <td>${row.prestige_rank != null ? `<span class="rank-pill">${row.prestige_rank}</span>` : "—"}</td>
      <td class="stat-num">${formatNum(row.capacity)}<span class="stat-sub">seats</span></td>
      <td class="stat-num">${formatMoney(gate)}<span class="stat-sub">100% fill · ₿${GATE_PRICE_PER_SEAT}/seat</span></td>
      <td class="stat-num">${formatMoney(maint)}<span class="stat-sub">12.5% × cap × ₿${STADIUM_VALUE_PER_SEAT.toLocaleString("en-GB")}</span></td>
      <td class="exp-pos">${ordinal(expPos)}<span class="stat-sub">league table</span></td>
      <td class="stat-num">${formatMoney(cost)}<span class="stat-sub">capacity × ₿1,000</span></td>
      <td class="stat-num">${highBidHtml}</td>
      <td>${row.current_leader_tag ? `<span class="club-owner-tag">${row.current_leader_tag}</span>` : "—"}${isLeader ? ' <span class="leader-you">(you)</span>' : ""}</td>
      <td class="bid-col"></td>
    `;
    tr.firstElementChild.appendChild(renderClubCell(row));

    const bidCell = tr.querySelector(".bid-col");
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = canBid ? "bid-btn" : "history-btn";
    btn.textContent = canBid ? "Bid" : "History";
    btn.onclick = () => openClubBidModal(row, canBid);
    bidCell.appendChild(btn);

    tr.querySelector(".high-bid-link")?.addEventListener("click", () => {
      openClubBidModal(row, canBid);
    });

    tbody.appendChild(tr);
  }
}

async function resolveOwnerTags(ownerIds) {
  const unique = [...new Set(ownerIds.filter(Boolean))];
  const map = {};
  await Promise.all(
    unique.map(async (id) => {
      const { data, error } = await supabase.rpc("owner_registry_resolve_tag", {
        p_owner_id: id,
      });
      map[id] = !error && data ? String(data) : "—";
    })
  );
  return map;
}

async function loadBidHistory(listingId) {
  const tbody = document.getElementById("clubBidHistoryBody");
  if (!tbody) return;

  tbody.innerHTML = `<tr><td colspan="3">Loading…</td></tr>`;

  const { data: bids, error } = await supabase
    .from("Club_Auction_Bids")
    .select("bid_amount, bid_time, bidder_owner_id")
    .eq("listing_id", listingId)
    .order("bid_time", { ascending: false });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="3">Could not load bids — ${error.message}</td></tr>`;
    return;
  }

  if (!bids?.length) {
    tbody.innerHTML = `<tr><td colspan="3">No bids yet</td></tr>`;
    return;
  }

  const tagMap = await resolveOwnerTags(bids.map((b) => b.bidder_owner_id));
  tbody.innerHTML = bids
    .map((b) => {
      const isYou = b.bidder_owner_id === ownerId;
      const tag = isYou ? `${tagMap[b.bidder_owner_id] || "—"} (you)` : tagMap[b.bidder_owner_id] || "—";
      return `<tr>
        <td>${tag}</td>
        <td>${formatMoney(b.bid_amount)}</td>
        <td>${new Date(b.bid_time).toLocaleString("en-GB")}</td>
      </tr>`;
    })
    .join("");
}

function validateClubBidInput() {
  const input = document.getElementById("clubBidAmount");
  const errorBox = document.getElementById("clubBidError");
  const submitBtn = document.getElementById("clubBidSubmitBtn");
  if (!input || !selectedListing) return;

  const raw = parseMoneyInput(input.value);
  const rounded = raw > 0 ? roundBidToMillion(raw) : 0;
  const minBid = listingMinimumBid(selectedListing);

  if (input.value !== "" && rounded > 0) {
    input.value = rounded.toLocaleString("en-GB");
  }

  if (!rounded || rounded < minBid) {
    input.style.border = "2px solid #a44";
    if (errorBox) {
      errorBox.textContent = rounded && rounded < minBid
        ? `Minimum bid is ${formatMoney(minBid)} (after rounding to nearest ₿1m).`
        : `Enter at least ${formatMoney(minBid)}.`;
    }
    if (submitBtn) submitBtn.disabled = true;
    return;
  }

  if (rounded > budget) {
    input.style.border = "2px solid #a44";
    if (errorBox) errorBox.textContent = `Bid exceeds your budget (${formatMoney(budget)}).`;
    if (submitBtn) submitBtn.disabled = true;
    return;
  }

  input.style.border = "2px solid #4a4";
  if (errorBox) errorBox.textContent = "";
  if (submitBtn) submitBtn.disabled = false;
}

function adjustClubBid(delta) {
  const input = document.getElementById("clubBidAmount");
  if (!input || !selectedListing) return;

  let current = parseMoneyInput(input.value);
  if (!current) current = listingMinimumBid(selectedListing);
  current = Math.max(0, current + delta);
  const minBid = listingMinimumBid(selectedListing);
  if (current < minBid) current = minBid;
  input.value = roundBidToMillion(current).toLocaleString("en-GB");
  validateClubBidInput();
}

function renderClubBidModalPhoto(row) {
  const slot = document.getElementById("clubBidModalPhoto");
  if (!slot) return;

  const shortName = row.club_short_name || "";
  const stadiumName = row.stadium || row.club_name || "Stadium";
  const src = stadiumImageUrl(shortName);
  slot.innerHTML = "";

  if (!src) {
    slot.style.display = "none";
    return;
  }

  slot.style.display = "";
  const img = new Image();
  img.onload = () => {
    const alt = stadiumName.replace(/"/g, "&quot;");
    slot.innerHTML = `
      <div class="club-bid-photo-wrap">
        <img src="${src}" alt="${alt}">
        <span class="club-bid-photo-credit">StadiumDB</span>
      </div>
    `;
  };
  img.onerror = () => {
    const badgeSrc = clubBadgeSrc(shortName);
    if (badgeSrc) {
      slot.innerHTML = `
        <div class="club-bid-photo-fallback">
          <img src="${badgeSrc}" alt="">
        </div>
      `;
      return;
    }
    slot.style.display = "none";
  };
  img.src = src;
}

async function openClubBidModal(row, allowBid = true) {
  selectedListing = row;
  const modal = document.getElementById("clubBidModal");
  const form = document.getElementById("clubBidFormSection");
  if (!modal) return;

  renderClubBidModalPhoto(row);

  document.getElementById("clubBidModalTitle").textContent =
    row.club_name || row.club_short_name || "Club";
  document.getElementById("clubBidModalStadium").textContent = row.stadium
    ? row.stadium
    : "";
  document.getElementById("clubBidModalStadiumCost").textContent = formatMoney(
    stadiumCost(row)
  );
  document.getElementById("clubBidModalHighBid").textContent = row.current_highest_bid
    ? formatMoney(row.current_highest_bid)
    : "—";
  const leader = row.current_leader_tag || "—";
  const isLeader = row.current_highest_bidder === ownerId;
  document.getElementById("clubBidModalLeader").textContent = isLeader
    ? `${leader} (you)`
    : leader;
  document.getElementById("clubBidModalBudget").textContent = formatMoney(budget);
  document.getElementById("clubBidWarning").textContent = minimumBidHelpText(row);

  if (form) form.style.display = allowBid ? "" : "none";

  const input = document.getElementById("clubBidAmount");
  const errorBox = document.getElementById("clubBidError");
  const submitBtn = document.getElementById("clubBidSubmitBtn");
  if (input) {
    const minBid = listingMinimumBid(row);
    input.value = roundBidToMillion(minBid).toLocaleString("en-GB");
    input.style.border = "1px solid #444";
    input.oninput = validateClubBidInput;
  }
  if (errorBox) errorBox.textContent = "";
  if (submitBtn) submitBtn.disabled = !allowBid;

  await loadBidHistory(row.id);

  modal.classList.add("open");
  modal.setAttribute("aria-hidden", "false");
  validateClubBidInput();
}

function closeClubBidModal() {
  const modal = document.getElementById("clubBidModal");
  if (!modal) return;
  modal.classList.remove("open");
  modal.setAttribute("aria-hidden", "true");
  selectedListing = null;
}

function wireClubBidModal() {
  document.getElementById("clubBidModalClose")?.addEventListener("click", closeClubBidModal);
  document.getElementById("clubBidModal")?.addEventListener("click", (e) => {
    if (e.target.id === "clubBidModal") closeClubBidModal();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeClubBidModal();
  });

  document.getElementById("clubBidQuickBtn")?.addEventListener("click", () => {
    if (!selectedListing) return;
    const input = document.getElementById("clubBidAmount");
    input.value = roundBidToMillion(listingMinimumBid(selectedListing)).toLocaleString("en-GB");
    validateClubBidInput();
  });

  document.querySelectorAll(".club-bid-inc-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      adjustClubBid(Number(btn.dataset.delta) || 0);
    });
  });

  document.getElementById("clubBidSubmitBtn")?.addEventListener("click", async () => {
    if (!selectedListing) return;
    const input = document.getElementById("clubBidAmount");
    const amount = roundBidToMillion(parseMoneyInput(input?.value));
    const minBid = listingMinimumBid(selectedListing);
    if (!amount || amount < minBid) {
      validateClubBidInput();
      return;
    }
    await placeBid(selectedListing.club_short_name, amount, document.getElementById("clubBidSubmitBtn"));
  });
}

async function placeBid(shortName, rawAmount, btn) {
  const amount = roundBidToMillion(Number(rawAmount));
  if (!Number.isFinite(amount) || amount <= 0) {
    alert("Enter a valid bid amount.");
    return;
  }
  if (btn) btn.disabled = true;
  const { data, error } = await supabase.rpc("club_auction_place_bid", {
    p_club_short_name: shortName,
    p_amount: amount,
  });
  if (btn) btn.disabled = false;
  if (error) {
    alert(error.message);
    validateClubBidInput();
    return;
  }
  budget = Number(data?.remaining_budget) ?? budget;
  document.getElementById("clubBidModalBudget").textContent = formatMoney(budget);
  await refreshAuctionState();
  renderStatus();
  await updateLeadPanel();
  await loadListings();
  if (selectedListing) {
    const refreshed = listingsCache.find(
      (r) => r.club_short_name === selectedListing.club_short_name
    );
    if (refreshed) {
      selectedListing = refreshed;
      document.getElementById("clubBidModalHighBid").textContent = refreshed.current_highest_bid
        ? formatMoney(refreshed.current_highest_bid)
        : "—";
      const leader = refreshed.current_leader_tag || "—";
      const isLeader = refreshed.current_highest_bidder === ownerId;
      document.getElementById("clubBidModalLeader").textContent = isLeader
        ? `${leader} (you)`
        : leader;
      document.getElementById("clubBidWarning").textContent = minimumBidHelpText(refreshed);
      await loadBidHistory(refreshed.id);
      const input = document.getElementById("clubBidAmount");
      if (input) {
        input.value = roundBidToMillion(listingMinimumBid(refreshed)).toLocaleString("en-GB");
      }
      validateClubBidInput();
    }
  }
}

async function refreshAll() {
  await refreshAuctionState();
  renderStatus();
  await updateLeadPanel();
  await loadListings();
}

document.addEventListener("DOMContentLoaded", async () => {
  const user = await getAuthUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  if (!(await loadOwnerContext())) return;

  await initGlobal();

  wireClubBidModal();
  await refreshAll();
  pollTimer = setInterval(refreshAll, 15000);
});
