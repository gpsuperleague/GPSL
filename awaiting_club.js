import { supabase, initGlobal } from "./global.js";
import { getAuthUser } from "./supabase_client.js";
import { mountAvailabilityPanel } from "./owner_availability.js";
import {
  loadOnboardingAvailabilityContext,
  saveOnboardingWeeklyAvailability,
  setOnboardingTimezone,
} from "./match_scheduling.js";
import { renderOwnerSeasonStatus } from "./owner_season_status.js";

let clubAssignmentPollTimer = null;
let registrySelf = null;

function formatMoney(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `₿${Math.round(v).toLocaleString("en-GB")}`;
}

function updateAuctionRoomGate() {
  const ready = Boolean(registrySelf?.auction_onboarding_ready);
  const invited = Boolean(registrySelf?.needs_club_auction);
  const linkWrap = document.getElementById("auctionRoomLinkWrap");
  const blocked = document.getElementById("auctionRoomBlocked");
  const readyLine = document.getElementById("availabilityReadyLine");

  if (linkWrap) linkWrap.hidden = !(invited && ready);
  if (blocked) {
    if (!invited) {
      blocked.hidden = false;
      blocked.textContent =
        "Club draft auction bidding opens when admin invites you from the waiting list. You can still set your details above now.";
    } else {
      blocked.hidden = ready;
      blocked.textContent =
        "Complete your owner tag, timezone, and match availability above before entering the club auction room.";
    }
  }

  if (readyLine) {
    if (invited && ready) {
      readyLine.hidden = false;
      readyLine.textContent =
        "Owner tag, timezone, and availability are set — you can enter the club auction room.";
    } else if (!invited && registrySelf?.owner_tag && registrySelf?.owner_timezone) {
      readyLine.hidden = false;
      readyLine.textContent =
        "Details saved. You will use these when invited to the club draft auction.";
    } else {
      readyLine.hidden = true;
      readyLine.textContent = "";
    }
  }
}

function paintSeasonStatus(self) {
  renderOwnerSeasonStatus(document.getElementById("ownerSeasonStatus"), self);
}

async function refreshRegistrySelf() {
  const { data, error } = await supabase.rpc("owner_registry_get_self");
  if (!error && data) {
    registrySelf = data;
    updateAuctionRoomGate();
    paintSeasonStatus(data);
  }
  return { data, error };
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

async function mountOnboardingAvailability() {
  const root = document.getElementById("onboardingAvailabilityRoot");
  if (!root) return;

  await mountAvailabilityPanel(root, {
    loadContext: loadOnboardingAvailabilityContext,
    saveWeekly: async (slots) => {
      const tzSel = document.getElementById("availTimezoneSelect");
      if (registrySelf?.needs_onboarding_timezone && tzSel?.value) {
        await setOnboardingTimezone(tzSel.value);
      }
      const res = await saveOnboardingWeeklyAvailability(slots);
      if (res.ok) await refreshRegistrySelf();
      return res;
    },
    setTimezone: async (timezone) => {
      const res = await setOnboardingTimezone(timezone);
      if (res.ok) await refreshRegistrySelf();
      return res;
    },
    showHolidays: false,
  });
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

  registrySelf = self;
  paintSeasonStatus(self);

  if (self?.has_club) {
    window.location = "dashboard.html";
    return;
  }

  if (self?.is_archived) {
    window.location = "member_home.html?archived=1";
    return;
  }

  if (self?.status === "on_break") {
    window.location = "waiting_list.html";
    return;
  }

  const isWaitingList = Boolean(self?.is_member);
  const isAuctionInvitee = Boolean(self?.needs_club_auction);

  const introEl = document.getElementById("introBudgetLine");
  if (introEl) {
    if (isWaitingList) {
      introEl.innerHTML =
        "You are on the <b>owner waiting list</b>. Set your owner tag, timezone, and match availability here. " +
        "Your starting bank balance is shown below. When admin invites you, you can bid in the <b>club draft auction</b>.";
    } else {
      introEl.innerHTML =
        "You are registered for GPSL but do not have a club yet. The <b>club auction</b> is the first step — " +
        "you will bid from your starting budget (shown below). When the auction completes, your club is assigned, " +
        "your balance is set, and the full site opens.";
    }
  }

  if (isAuctionInvitee) {
    await showWonAwaitingSettlement(user.id, statusEl);
  }
  updateAuctionRoomGate();

  const displayTag = (self?.owner_tag || "").trim();
  if (displayTag && tagInput) {
    tagInput.value = displayTag;
    // Tag locked only for auction invitees (waiting-list members may still change it).
    if (isAuctionInvitee) {
      tagInput.disabled = true;
      if (saveTagBtn) saveTagBtn.disabled = true;
      if (tagLockedLine) {
        tagLockedLine.hidden = false;
        tagLockedLine.textContent =
          `Tag locked: “${displayTag}” — shown on club auction bids and your club if you win.`;
      }
    }
  }
  if (budgetEl) {
    const bal = Number(self?.pending_starting_balance) || 0;
    if (bal > 0) {
      budgetEl.hidden = false;
      budgetEl.textContent = `Starting bank balance: ${formatMoney(bal)}`;
    } else if (isWaitingList) {
      budgetEl.hidden = false;
      budgetEl.textContent =
        "Starting bank balance will appear when you are invited to the club auction.";
      budgetEl.style.color = "#aaa";
      budgetEl.style.fontSize = "14px";
    }
  }

  const learningNote = document.getElementById("learningNote");
  if (learningNote) learningNote.hidden = true;

  const { data: auctionState } = await supabase.rpc("club_auction_get_state");
  const scheduleEl = document.getElementById("scheduleLine");
  if (scheduleEl) {
    if (isWaitingList && !isAuctionInvitee) {
      scheduleEl.textContent =
        "You are on the waiting list. Auction schedule appears here when you are invited to bid.";
      scheduleEl.style.color = "#aaa";
    } else if (auctionState) {
      if (!auctionState.enabled) {
        scheduleEl.textContent =
          "Club auction is not enabled yet (admin: Transfer management).";
        scheduleEl.style.color = "#faa";
      } else if (auctionState.bidding_open) {
        scheduleEl.textContent =
          "Bidding is open now — complete onboarding above, then use the club auction room.";
        scheduleEl.style.color = "#9f9";
      } else if (auctionState.start_time) {
        const start = new Date(auctionState.start_time);
        scheduleEl.textContent = `Auction opens: ${start.toLocaleString("en-GB", {
          timeZone: "Europe/London",
        })} UK`;
      } else {
        scheduleEl.textContent =
          "No start time scheduled — admin: Transfer management → Club auction On → Save settings.";
        scheduleEl.style.color = "#faa";
      }
    }
  }

  await mountOnboardingAvailability();

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
      statusEl.textContent = data?.locked
        ? `Saved tag “${data?.owner_tag || tag}”. It is now locked for the club auction.`
        : `Saved tag “${data?.owner_tag || tag}”.`;
      statusEl.style.color = "#9f9";
    }
    if (tagInput) {
      tagInput.value = data?.owner_tag || tag;
      if (data?.locked) tagInput.disabled = true;
    }
    if (saveTagBtn && data?.locked) saveTagBtn.disabled = true;
    if (tagLockedLine && data?.locked) {
      tagLockedLine.hidden = false;
      tagLockedLine.textContent =
        `Tag locked: “${data?.owner_tag || tag}” — shown on club auction bids and your club if you win.`;
    }
    if (budgetEl && data?.pending_starting_balance > 0) {
      budgetEl.hidden = false;
      budgetEl.style.color = "#9f9";
      budgetEl.style.fontSize = "18px";
      budgetEl.textContent = `Starting bank balance: ${formatMoney(
        data.pending_starting_balance
      )}`;
    }
    await refreshRegistrySelf();
  });
});
