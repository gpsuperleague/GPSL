window.CURRENT_PAGE = "club_auction";

import {
  supabase,
  initGlobal,
  getUKNow,
  getDraftAuctionStartTime,
  getDraftCountdownOptions,
} from "./global.js";
import {
  getClubAuctionEffectivePhase,
  clubAuctionPhaseLabel,
} from "./draft_timeline.js";

const GATE_PRICE_PER_SEAT = 20;
const STADIUM_VALUE_PER_SEAT = 1500;
const MAINTENANCE_RATE = 0.125;
const TABLE_COLS = 10;

function formatMoney(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `₿${Math.round(v).toLocaleString("en-GB")}`;
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

async function loadOwnerContext() {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  ownerId = user?.id || null;

  const { data: self, error } = await supabase.rpc("owner_registry_get_self");

  if (self?.has_club) {
    window.location = "dashboard.html";
    return false;
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
    if (phase && phase !== "ended") {
      el.textContent = clubAuctionPhaseLabel(phase);
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

  const canBid = auctionState?.bidding_open && ownerTag;
  tbody.innerHTML = "";

  for (const row of listings) {
    const tr = document.createElement("tr");
    const minBid = Number(row.min_next_bid) || Number(row.opening_bid) || stadiumCost(row);
    const isLeader = row.current_highest_bidder === ownerId;
    const expPos = season1Expected(row);
    const gate = fullGateMatchday(row);
    const maint = seasonMaintenance(row);
    const cost = stadiumCost(row);

    tr.innerHTML = `
      <td></td>
      <td>${row.prestige_rank != null ? `<span class="rank-pill">${row.prestige_rank}</span>` : "—"}</td>
      <td class="stat-num">${formatNum(row.capacity)}<span class="stat-sub">seats</span></td>
      <td class="stat-num">${formatMoney(gate)}<span class="stat-sub">100% fill · ₿${GATE_PRICE_PER_SEAT}/seat</span></td>
      <td class="stat-num">${formatMoney(maint)}<span class="stat-sub">12.5% × cap × ₿${STADIUM_VALUE_PER_SEAT.toLocaleString("en-GB")}</span></td>
      <td class="exp-pos">${ordinal(expPos)}<span class="stat-sub">league table</span></td>
      <td class="stat-num">${formatMoney(cost)}<span class="stat-sub">capacity × ₿1,000</span></td>
      <td class="stat-num">${row.current_highest_bid ? formatMoney(row.current_highest_bid) : "—"}</td>
      <td>${row.current_leader_tag || "—"}${isLeader ? ' <span class="leader-you">(you)</span>' : ""}</td>
      <td class="bid-col"></td>
    `;
    tr.firstElementChild.appendChild(renderClubCell(row));

    const bidCell = tr.querySelector(".bid-col");
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

  if (!(await loadOwnerContext())) return;

  await initGlobal();

  await refreshAll();
  pollTimer = setInterval(refreshAll, 15000);
});
