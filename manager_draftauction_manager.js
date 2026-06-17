import {
  loadGlobalSettings,
  buildNav,
  getUKNow,
  refreshDraftBiddingOpen,
  getDraftCountdownOptions,
  getDraftPhaseOptions,
} from "./global.js";
import {
  supabase,
  getManagerDraftCountdownTick,
  isManagerDraftAuctionEnded,
  managerDraftPhaseLabel,
  fetchCurrentManagerDraftBids,
  highestManagerDraftBid,
  managerDraftMinimumBid,
  getManagerDraftBidEligibility,
  getClubLeadingManagerDraftId,
  getClubManagerVacancy,
  submitManagerDraftBid,
} from "./manager_draft_engine.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  applyManagerPortrait,
  managerInitials,
} from "./manager_images.js";
import {
  formatLiveCountdownLines,
  formatDraftConclusionLines,
  prefixDraftCountdownDuration,
  formatTargetTimesSubline,
  isValidInstant,
} from "./countdown_display.js";
import { formatMoney } from "./competition.js";
import {
  parseMoneyInput,
  setMoneyInputValue,
  wireMoneyBidInput,
} from "./money_input.js";

let buyerShortName = null;
let managerDraftEnabled = false;
let draftAuctionStartTime = null;
let currentManager = null;
let auctionEnded = false;
let managerVacancyBlocked = "";
let bidAmountControl = null;
let currentMinBid = 0;

function getBidInput() {
  return document.getElementById("bidAmount");
}

function resolveMinBid() {
  return currentMinBid;
}

async function loadBuyerClub(userId) {
  const { data } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", userId)
    .maybeSingle();
  buyerShortName = data?.ShortName || null;
}

async function updateCountdown() {
  if (managerDraftEnabled && draftAuctionStartTime) {
    await refreshDraftBiddingOpen();
  }
  const nowUK = getUKNow();
  const uiOpts = getDraftCountdownOptions();
  const engineOpts = getDraftPhaseOptions();
  const tick = getManagerDraftCountdownTick(
    nowUK,
    draftAuctionStartTime,
    uiOpts
  );
  auctionEnded = isManagerDraftAuctionEnded(
    nowUK,
    draftAuctionStartTime,
    engineOpts
  );

  const el = document.getElementById("timeRemaining");
  const sub = document.getElementById("timeRemainingSub");
  if (tick.phase === "ended") {
    const finish = tick.finishInstant;
    if (isValidInstant(finish)) {
      const { duration, subline } = formatDraftConclusionLines(finish, "manager");
      if (el) el.textContent = prefixDraftCountdownDuration(duration, "manager");
      if (sub) sub.textContent = subline;
    } else {
      if (el) el.textContent = managerDraftPhaseLabel(tick.phase);
      if (sub) sub.textContent = "";
    }
    return;
  }
  const { duration, subline } = formatLiveCountdownLines(
    tick.label,
    tick.ms,
    tick.target,
    {
      countUp: tick.countUp,
      frozen: tick.frozen,
      finishInstant: tick.finishInstant,
    }
  );
  if (el) el.textContent = prefixDraftCountdownDuration(duration, "manager");
  if (sub) {
    sub.textContent =
      subline ||
      (!tick.frozen && tick.target ? formatTargetTimesSubline(tick.target) : "");
  }
}

async function loadManager() {
  const params = new URLSearchParams(window.location.search);
  const managerId = Number(params.get("manager"));
  if (!Number.isFinite(managerId)) {
    document.getElementById("managerName").textContent = "No manager selected.";
    return;
  }

  const { data: mgr, error } = await supabase
    .from("Managers")
    .select("*")
    .eq("id", managerId)
    .maybeSingle();

  if (error || !mgr) {
    document.getElementById("managerName").textContent = "Manager not found.";
    return;
  }

  if (mgr.contracted_club) {
    document.getElementById("managerName").textContent =
      `${mgr.name} is not a free agent.`;
    return;
  }

  currentManager = mgr;
  document.getElementById("managerName").textContent = mgr.name;
  document.getElementById("managerMeta").textContent =
    `${mgr.nation || "—"} · Rating ${mgr.rating} · Age ${mgr.age ?? "—"}`;

  const fallbackEl = document.getElementById("managerPortraitFallback");
  if (fallbackEl) {
    fallbackEl.textContent = managerInitials(mgr.name);
  }
  applyManagerPortrait(document.getElementById("managerPortrait"), mgr.slug, {
    fallbackEl,
    name: mgr.name,
  }).catch((err) => console.warn("manager portrait", err));

  document.getElementById("managerValue").textContent =
    `Market value: ${formatMoney(mgr.market_value)}`;

  await refreshBids();
  await refreshLeadPanel();
  updateBidControls();
}

async function refreshBids() {
  if (!currentManager) return;
  const bids = await fetchCurrentManagerDraftBids(
    currentManager.id,
    draftAuctionStartTime
  );
  const top = highestManagerDraftBid(bids);
  await loadClubsMap();

  document.getElementById("currentHighest").textContent = top
    ? `Highest bid: ${formatMoney(top.bid_amount)}`
    : "Highest bid: —";

  document.getElementById("leadingClub").textContent = top
    ? `Leading club: ${fullClubName(top.bidder_club_id) || top.bidder_club_id}`
    : "Leading club: —";

  const tbody = document.getElementById("bidHistory");
  if (!tbody) return;
  tbody.innerHTML = bids.length
    ? bids
        .slice()
        .reverse()
        .map(
          (b) => `<tr>
        <td>${fullClubName(b.bidder_club_id) || b.bidder_club_id}</td>
        <td>${formatMoney(b.bid_amount)}</td>
        <td>${new Date(b.bid_time).toLocaleString("en-GB")}</td>
      </tr>`
        )
        .join("")
    : `<tr><td colspan="3">No bids yet</td></tr>`;

  const min = managerDraftMinimumBid(currentManager.market_value, bids);
  currentMinBid = min;
  const input = getBidInput();
  if (input && !input.dataset.touched) {
    setMoneyInputValue(input, min);
  }
}

async function refreshLeadPanel() {
  const el = document.getElementById("leadInfo");
  if (!el || !buyerShortName) return;

  const leadingId = await getClubLeadingManagerDraftId(
    buyerShortName,
    draftAuctionStartTime
  );
  if (!leadingId) {
    el.textContent = "You are not leading any manager draft auction.";
    return;
  }

  const { data: mgr } = await supabase
    .from("Managers")
    .select("name")
    .eq("id", leadingId)
    .maybeSingle();

  const here =
    currentManager && Number(leadingId) === Number(currentManager.id);
  el.textContent = here
    ? `You hold the highest bid on this manager.`
    : `You lead ${mgr?.name || `manager #${leadingId}`} — finish or get outbid there before leading another auction.`;
}

function updateBidControls() {
  const submit = document.getElementById("submitBidBtn");
  const err = document.getElementById("bidError");
  const blocked = auctionEnded || Boolean(managerVacancyBlocked);
  if (submit) {
    submit.disabled = blocked;
    submit.textContent = auctionEnded
      ? "Auction ended"
      : managerVacancyBlocked
        ? "Manager vacancy required"
        : "Submit bid";
  }
  if (err && managerVacancyBlocked) {
    err.textContent = managerVacancyBlocked;
  } else if (auctionEnded && err) {
    err.textContent = "";
  }
}

function wireBidControls() {
  const input = getBidInput();
  bidAmountControl = wireMoneyBidInput(input, { min: resolveMinBid });

  input?.addEventListener("focus", () => {
    input.dataset.touched = "1";
  });

  document.querySelectorAll(".inc-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const delta = Number(btn.dataset.delta) || 0;
      input.dataset.touched = "1";
      bidAmountControl?.adjust(delta);
    });
  });

  document.querySelectorAll(".dec-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const delta = Number(btn.dataset.delta) || 0;
      input.dataset.touched = "1";
      bidAmountControl?.adjust(delta);
    });
  });

  document.getElementById("quickBidBtn")?.addEventListener("click", async () => {
    if (!currentManager) return;
    const bids = await fetchCurrentManagerDraftBids(
      currentManager.id,
      draftAuctionStartTime
    );
    const min = managerDraftMinimumBid(currentManager.market_value, bids);
    currentMinBid = min;
    const bidInput = getBidInput();
    bidInput.dataset.touched = "1";
    bidAmountControl?.set(min);
  });

  document.getElementById("submitBidBtn")?.addEventListener("click", async () => {
    const err = document.getElementById("bidError");
    if (!currentManager || !buyerShortName) {
      if (err) err.textContent = "No club linked to your account.";
      return;
    }
    const amount = parseMoneyInput(getBidInput()?.value);
    if (amount < currentMinBid) {
      if (err) {
        err.textContent = `Minimum bid is ${formatMoney(currentMinBid)}.`;
      }
      return;
    }
    const eligibility = await getManagerDraftBidEligibility({
      managerId: currentManager.id,
      buyerShortName,
      managerDraftEnabled,
      draftAuctionStartTime,
    });
    if (!eligibility.allowed && !auctionEnded) {
      if (err) err.textContent = eligibility.reason;
      return;
    }
    if (auctionEnded) return;

    const result = await submitManagerDraftBid(
      currentManager,
      amount,
      buyerShortName,
      draftAuctionStartTime
    );
    if (!result.ok) {
      if (err) err.textContent = result.msg;
      return;
    }
    if (err) err.textContent = "";
    const bidInput = getBidInput();
    bidInput.dataset.touched = "";
    alert(
      `Bid placed: ${formatMoney(amount)} for ${currentManager.name}.\n\nYou are now the leading bidder unless someone outbids you.`
    );
    await refreshBids();
    await refreshLeadPanel();
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const settings = await loadGlobalSettings();
  managerDraftEnabled = settings.managerDraftEnabled;
  draftAuctionStartTime = settings.draftStart;

  await buildNav();
  await loadBuyerClub(user.id);
  if (buyerShortName) {
    const vacancy = await getClubManagerVacancy(buyerShortName);
    if (!vacancy.vacant) {
      managerVacancyBlocked = vacancy.reason;
    }
  }
  wireBidControls();
  await loadManager();
  updateBidControls();
  if (managerDraftEnabled && draftAuctionStartTime) {
    await updateCountdown();
    setInterval(updateCountdown, 1000);
  } else {
    const el = document.getElementById("timeRemaining");
    const sub = document.getElementById("timeRemainingSub");
    if (el) el.textContent = "";
    if (sub) sub.textContent = "";
  }
});
