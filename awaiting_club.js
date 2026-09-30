import { supabase, initGlobal } from "./global.js";
import { getAuthUser } from "./supabase_client.js";
import { mountAvailabilityPanel } from "./owner_availability.js?v=20260930-world-tz";
import {
  loadOnboardingAvailabilityContext,
  saveOnboardingWeeklyAvailability,
  setOnboardingTimezone,
} from "./match_scheduling.js";
import { renderOwnerSeasonStatus } from "./owner_season_status.js?v=20260930-no-test-season";
import { mountNextClubAuctionCountdown } from "./next_club_auction_countdown.js?v=20260930-next-auction";

let clubAssignmentPollTimer = null;
let registrySelf = null;
let interestMine = null;
let preclubHolidays = [];

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function loadInterestMine() {
  const { data, error } = await supabase.rpc("club_auction_interest_list");
  interestMine = error ? null : data;
}

function entryItem({ done, optional = false, title, detail }) {
  const state = optional ? (done ? "done" : "optional") : done ? "done" : "todo";
  const pill = state === "done" ? "Done" : state === "optional" ? "Optional" : "To do";
  return `<li class="${state === "todo" ? "is-todo" : state === "done" ? "is-done" : ""}">
    <div class="entry-main">${title}${detail ? `<small>${detail}</small>` : ""}</div>
    <span class="entry-pill ${state}">${pill}</span>
  </li>`;
}

function renderEntryChecklist() {
  const list = document.getElementById("entryChecklist");
  const summary = document.getElementById("entrySummary");
  if (!list) return;
  const self = registrySelf || {};

  const tagDone = Boolean((self.owner_tag || "").trim());
  const tzDone = Boolean(self.owner_timezone);
  const availDone = Number(self.availability_slot_count || 0) > 0;
  const primary = interestMine?.mine_interest || null;
  const backup = interestMine?.mine_backup || null;
  const primaryDone = Boolean(self.has_club_interest || primary);
  const backupDone = Boolean(self.has_club_backup || backup);

  let interestNote = "";
  if (interestMine && !interestMine.can_mark && !primaryDone) {
    interestNote = interestMine.frozen
      ? "Marking is closed right now (auction running)."
      : interestMine.season1_confirmed
        ? "Marking isn't open for your account yet."
        : "Marking opens once you've accepted your Season 1 invite.";
  }

  const clubLink = `<a href="club_database.html">Club Database</a>`;
  const items = [
    entryItem({
      done: tagDone,
      title: "Owner tag",
      detail: tagDone ? `“${escapeHtml(self.owner_tag)}”` : "Set it in the Owner tag box below.",
    }),
    entryItem({
      done: tzDone,
      title: "Timezone",
      detail: tzDone
        ? escapeHtml(String(self.owner_timezone).replace(/_/g, " "))
        : "Pick your timezone below (or save your availability to confirm the one shown).",
    }),
    entryItem({
      done: availDone,
      title: "Match availability",
      detail: availDone
        ? `${Number(self.availability_slot_count)} time block(s) saved`
        : "Mark when you can usually play, then Save availability.",
    }),
    entryItem({
      done: primaryDone,
      title: `Primary club interest — ${clubLink}`,
      detail: primary
        ? escapeHtml(primary.club_name || primary.club_short_name)
        : `Mark 1 club as your interest. ${interestNote}`.trim(),
    }),
    entryItem({
      done: backupDone,
      title: `Backup club — ${clubLink}`,
      detail: backup
        ? escapeHtml(backup.club_name || backup.club_short_name)
        : `Mark 1 different club as your backup. ${interestNote}`.trim(),
    }),
    entryItem({
      done: preclubHolidays.length > 0,
      optional: true,
      title: "Upcoming holidays",
      detail: preclubHolidays.length
        ? `${preclubHolidays.length} holiday(s) noted`
        : "Optional — add any planned time away below. Not required for the auction.",
    }),
  ];
  list.innerHTML = items.join("");

  const required = [tagDone, tzDone, availDone, primaryDone, backupDone];
  const left = required.filter((d) => !d).length;
  if (summary) {
    summary.textContent = left
      ? `${left} required item${left === 1 ? "" : "s"} left before you can enter the club auction.`
      : "All required items done — you're ready for the club auction.";
    summary.style.color = left ? "#ffcf99" : "#9f9";
  }
}

function formatHolidayRange(h) {
  const opts = { timeZone: "Europe/London", day: "numeric", month: "short", year: "numeric" };
  const start = new Date(h.starts_at).toLocaleDateString("en-GB", opts);
  const endDay = new Date(new Date(h.ends_at).getTime() - 1);
  const end = endDay.toLocaleDateString("en-GB", opts);
  return start === end ? start : `${start} – ${end}`;
}

function renderPreclubHolidays() {
  const list = document.getElementById("holList");
  if (!list) return;
  list.innerHTML = preclubHolidays.length
    ? preclubHolidays
        .map(
          (h) => `<li><span>${escapeHtml(formatHolidayRange(h))} · ${h.day_count} day${
            h.day_count === 1 ? "" : "s"
          }</span><button type="button" data-hol-id="${h.id}">Remove</button></li>`
        )
        .join("")
    : `<li style="color:#777;">No holidays noted.</li>`;
}

async function loadPreclubHolidays() {
  const { data, error } = await supabase.rpc("owner_preclub_holiday_list");
  const statusEl = document.getElementById("holStatus");
  if (error) {
    preclubHolidays = [];
    const card = document.getElementById("holidayCard");
    if (card) card.hidden = true;
    return;
  }
  preclubHolidays = Array.isArray(data?.holidays) ? data.holidays : [];
  if (statusEl && data?.max_days && !statusEl.textContent) {
    statusEl.textContent = `Up to ${data.max_days} days per season.`;
    statusEl.style.color = "#888";
  }
  renderPreclubHolidays();
  renderEntryChecklist();
}

function wirePreclubHolidays() {
  const statusEl = document.getElementById("holStatus");
  const setStatus = (msg, ok) => {
    if (!statusEl) return;
    statusEl.textContent = msg;
    statusEl.style.color = ok ? "#9f9" : "#f88";
  };

  document.getElementById("holBookBtn")?.addEventListener("click", async () => {
    const start = document.getElementById("holStart")?.value;
    const end = document.getElementById("holEnd")?.value || start;
    if (!start) {
      setStatus("Pick a start date.", false);
      return;
    }
    const { error } = await supabase.rpc("owner_preclub_holiday_book", {
      p_start_date: start,
      p_end_date: end,
    });
    if (error) {
      setStatus(error.message, false);
      return;
    }
    setStatus("Holiday added.", true);
    await loadPreclubHolidays();
  });

  document.getElementById("holList")?.addEventListener("click", async (e) => {
    const btn = e.target.closest?.("button[data-hol-id]");
    if (!btn) return;
    btn.disabled = true;
    const { error } = await supabase.rpc("owner_preclub_holiday_cancel", {
      p_id: Number(btn.dataset.holId),
    });
    if (error) {
      btn.disabled = false;
      setStatus(error.message, false);
      return;
    }
    setStatus("Holiday removed.", true);
    await loadPreclubHolidays();
  });
}

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
        "Complete your owner tag, timezone, match availability, and club interest + backup (Club Database) before entering the club auction room.";
    }
  }

  if (readyLine) {
    if (invited && ready) {
      readyLine.hidden = false;
      readyLine.textContent =
        "Owner tag, timezone, availability, and club interest + backup are set — you can enter the club auction room.";
    } else if (!invited && registrySelf?.owner_tag && registrySelf?.owner_timezone) {
      const needInterest =
        registrySelf?.needs_club_interest || registrySelf?.needs_club_backup;
      readyLine.hidden = false;
      readyLine.textContent = needInterest
        ? "Details saved. Still needed: mark 1 interest and 1 backup on Club Database before auction invite."
        : "Details saved. You will use these when invited to the club draft auction.";
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
    renderEntryChecklist();
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
  renderEntryChecklist();

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
        "You are on the <b>owner waiting list</b>. Set your owner tag, timezone and match availability here, " +
        "and mark a <b>primary</b> and <b>backup</b> club on the Club Database — all are needed to enter the club auction. " +
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
        "You are on the waiting list. The next auction countdown is shown at the top of this page; you can bid once invited.";
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

  void mountNextClubAuctionCountdown({
    card: document.getElementById("nextAuctionCard"),
    countdownEl: document.getElementById("nextAuctionCountdown"),
    whenEl: document.getElementById("nextAuctionWhen"),
    titleEl: document.getElementById("nextAuctionTitle"),
    suppressWhenVisible: () => {
      if (isWaitingList && !isAuctionInvitee) return false;
      const shared = document.getElementById("draftCountdownContainer");
      const text = document.getElementById("draftCountdown")?.textContent?.trim();
      return Boolean(shared && shared.style.display !== "none" && text);
    },
  });

  await mountOnboardingAvailability();

  wirePreclubHolidays();
  await Promise.all([loadInterestMine(), loadPreclubHolidays()]);
  renderEntryChecklist();

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
