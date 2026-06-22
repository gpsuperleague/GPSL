import { supabase, initGlobal } from "./global.js";
import { getAuthUser } from "./supabase_client.js";

let clubAssignmentPollTimer = null;

function formatMoney(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `₿${Math.round(v).toLocaleString("en-GB")}`;
}

async function showWonAwaitingSettlement(userId, statusEl) {
  if (!userId || !statusEl) return;

  const [{ data: auctionState }, { data: listings }] = await Promise.all([
    supabase.rpc("club_auction_get_state"),
    supabase
      .from("Club_Auction_Listings")
      .select("club_short_name, status, transfer_completed, current_highest_bid")
      .eq("current_highest_bidder", userId)
      .eq("status", "Active"),
  ]);

  const finishPassed =
    auctionState?.finish_time != null &&
    Date.now() >= new Date(auctionState.finish_time).getTime();
  const biddingClosed = auctionState?.enabled && !auctionState?.bidding_open;

  const wonActive = (listings || []).filter(
    (row) => Number(row.current_highest_bid) > 0
  );

  if (!wonActive.length || (!finishPassed && !biddingClosed)) return;

  const clubs = wonActive.map((row) => row.club_short_name).join(", ");
  statusEl.innerHTML =
    `<strong style="color:#9f9;">You won ${clubs}</strong> — waiting for auction settlement. ` +
    "The site opens once admin settles club auctions (Transfer management → Settle club auctions now). " +
    "This page will refresh automatically when your club is assigned.";
  statusEl.style.color = "#ccc";

  if (clubAssignmentPollTimer) clearInterval(clubAssignmentPollTimer);
  clubAssignmentPollTimer = setInterval(async () => {
    const { data: fresh } = await supabase.rpc("owner_registry_get_self");
    if (fresh?.has_club) {
      clearInterval(clubAssignmentPollTimer);
      window.location = "dashboard.html";
    }
  }, 15000);
}

document.addEventListener("DOMContentLoaded", async () => {
  const user = await getAuthUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  await initGlobal();

  const statusEl = document.getElementById("status");
  const tagInput = document.getElementById("ownerTag");
  const saveTagBtn = document.getElementById("saveTagBtn");
  const tagLockedLine = document.getElementById("tagLockedLine");
  const budgetEl = document.getElementById("budgetLine");

  const { data: self, error } = await supabase.rpc("owner_registry_get_self");
  if (error) {
    if (statusEl) {
      statusEl.textContent =
        "Run supabase/sql/patches/owner_onboarding_club_auction.sql in Supabase to enable owner onboarding.";
      statusEl.style.color = "#f88";
    }
    return;
  }

  if (self?.has_club) {
    window.location = "dashboard.html";
    return;
  }

  // Members belong on member home; only auction invitees use this page
  if (self?.is_member) {
    window.location = "member_home.html";
    return;
  }

  if (self?.is_archived) {
    window.location = "member_home.html?archived=1";
    return;
  }

  if (self?.status === "on_break") {
    window.location = "member_home.html";
    return;
  }

  await showWonAwaitingSettlement(user.id, statusEl);

  const displayTag = (self?.owner_tag || "").trim();
  if (displayTag && tagInput) {
    tagInput.value = displayTag;
    tagInput.disabled = true;
    if (saveTagBtn) saveTagBtn.disabled = true;
    if (tagLockedLine) {
      tagLockedLine.hidden = false;
      tagLockedLine.textContent =
        `Tag locked: “${displayTag}” — shown on club auction bids and your club if you win.`;
    }
  }
  if (budgetEl && self?.pending_starting_balance > 0) {
    budgetEl.hidden = false;
    budgetEl.textContent = `Starting budget: ${formatMoney(self.pending_starting_balance)}`;
  }

  const { data: auctionState } = await supabase.rpc("club_auction_get_state");
  const scheduleEl = document.getElementById("scheduleLine");
  if (scheduleEl && auctionState) {
    if (!auctionState.enabled) {
      scheduleEl.textContent = "Club auction is not enabled yet (admin: Transfer management).";
      scheduleEl.style.color = "#faa";
    } else if (auctionState.bidding_open) {
      scheduleEl.textContent = "Bidding is open now — use the club auction room.";
      scheduleEl.style.color = "#9f9";
    } else if (auctionState.start_time) {
      const start = new Date(auctionState.start_time);
      scheduleEl.textContent = `Auction opens: ${start.toLocaleString("en-GB", { timeZone: "Europe/London" })} UK`;
    } else {
      scheduleEl.textContent =
        "No start time scheduled — admin: Transfer management → Club auction On → Save settings.";
      scheduleEl.style.color = "#faa";
    }
  }

  document.getElementById("saveTagBtn")?.addEventListener("click", async () => {
    if (tagInput?.disabled) return;
    const tag = tagInput?.value?.trim();
    if (!tag) {
      if (statusEl) statusEl.textContent = "Enter a tag.";
      return;
    }
    const { data, error: saveErr } = await supabase.rpc("owner_registry_set_tag", {
      p_tag: tag,
    });
    if (saveErr) {
      if (statusEl) {
        statusEl.textContent = saveErr.message;
        statusEl.style.color = "#f88";
      }
      return;
    }
    if (statusEl) {
      statusEl.textContent = `Saved tag “${data?.owner_tag || tag}”. It is now locked for the club auction.`;
      statusEl.style.color = "#9f9";
    }
    if (tagInput) {
      tagInput.disabled = true;
      tagInput.value = data?.owner_tag || tag;
    }
    if (saveTagBtn) saveTagBtn.disabled = true;
    if (tagLockedLine) {
      tagLockedLine.hidden = false;
      tagLockedLine.textContent =
        `Tag locked: “${data?.owner_tag || tag}” — shown on club auction bids and your club if you win.`;
    }
  });
});
