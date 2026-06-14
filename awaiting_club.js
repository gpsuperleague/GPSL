import { supabase, initGlobal, buildNav } from "./global.js";

function formatMoney(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `₿${Math.round(v).toLocaleString("en-GB")}`;
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

  const statusEl = document.getElementById("status");
  const tagInput = document.getElementById("ownerTag");
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

  if (!self?.needs_club_auction && self?.status !== "awaiting_club_auction") {
    window.location = "dashboard.html";
    return;
  }

  if (self?.owner_tag && tagInput) tagInput.value = self.owner_tag;
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
      statusEl.textContent = `Saved tag “${data?.owner_tag || tag}”.`;
      statusEl.style.color = "#9f9";
    }
  });
});
