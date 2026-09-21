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
  getDraftTimelineFromStart,
} from "./draft_timeline.js";
import { stadiumImageUrl } from "./stadium_images.js";
import { mountClubBankBalance, setClubBankBalance } from "./club_bank_balance_ui.js";
import { downloadIcs, draftAuctionTimelineEvents } from "./calendar_ics.js";
import {
  clubAuctionGetMyMaxBid,
  clubAuctionSetMaxBid,
  clubAuctionClearMaxBid,
  maxBidStatusText,
  parseMaxBidInput,
} from "./auction_max_bid.js";
import { escapeHtml } from "./escape_html.js";
import {
  discordChatLinkHtml,
  wireDiscordChatLinks,
} from "./discord_open.js?v=20260921-app-first";

const GATE_PRICE_PER_SEAT = 20;
const STADIUM_VALUE_PER_SEAT = 1500;
const MAINTENANCE_RATE = 0.125;
const BID_INCREMENT = 500000;
const TABLE_COLS = 11;

function formatMoney(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `₿\u00a0${Math.round(v).toLocaleString("en-GB")}`;
}

function parseMoneyInput(value) {
  if (!value) return 0;
  return Number(String(value).replace(/,/g, "")) || 0;
}

/** Always round UP to the nearest ₿500,000 (matches club auction step). */
function ceilBidToIncrement(amount) {
  const n = Number(amount);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.ceil(n / BID_INCREMENT) * BID_INCREMENT;
}

function listingMinimumBid(row) {
  const min = Number(row.min_next_bid);
  if (Number.isFinite(min) && min > 0) return ceilBidToIncrement(min);
  const opening = Number(row.opening_bid) || stadiumCost(row);
  const high = Number(row.current_highest_bid) || 0;
  if (!high) return ceilBidToIncrement(opening);
  return ceilBidToIncrement(Math.max(opening, high + BID_INCREMENT));
}

function minimumBidHelpText(row) {
  const min = listingMinimumBid(row);
  const high = Number(row.current_highest_bid) || 0;
  const cost = stadiumCost(row);
  if (!high) {
    return `Opening bid is stadium cost (${formatMoney(cost)} = capacity × ₿1,500), rounded up to the nearest ₿500,000 → ${formatMoney(min)}.`;
  }
  return `Minimum bid is ${formatMoney(min)} (stadium cost or ₿500,000 above the current highest, rounded up to the nearest ₿500,000).`;
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
  return cap * STADIUM_VALUE_PER_SEAT;
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
let auctionOnboardingReady = false;
let needsOnboardingTimezone = false;
let needsOnboardingAvailability = false;
let needsClubInterest = false;
let needsClubBackup = false;
let budget = 0;
let auctionState = null;
let pollTimer = null;
let selectedListing = null;
let listingsCache = [];
let viewOnly = false;
let interestState = null;
let interestModalClub = null;

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
    await mountClubBankBalance("clubBankBalance", { advisory: true });
    return true;
  }

  if (error) {
    ownerTag = null;
    budget = 0;
    setClubBankBalance("clubBankBalance", null);
    return true;
  }

  ownerTag = self?.owner_tag || null;
  auctionOnboardingReady = Boolean(self?.auction_onboarding_ready);
  needsOnboardingTimezone = Boolean(self?.needs_onboarding_timezone);
  needsOnboardingAvailability = Boolean(self?.needs_onboarding_availability);
  needsClubInterest = Boolean(self?.needs_club_interest);
  needsClubBackup = Boolean(self?.needs_club_backup);
  budget = Number(self?.pending_starting_balance) || 0;
  setClubBankBalance("clubBankBalance", budget > 0 ? budget : null, {
    href: "awaiting_club.html",
  });

  const intro = document.getElementById("clubAuctionIntro");
  if (intro) {
    if (self?.is_member && !self?.needs_club_auction) {
      intro.innerHTML =
        "You are on the <b>owner waiting list</b>. Bidding unlocks when admin invites you to the club draft auction. " +
        'Meanwhile set tag / timezone / availability on <a href="awaiting_club.html" style="color:#ff9900;">Owner details</a> and mark <b>1 interest + 1 backup</b> on <a href="club_database.html" style="color:#ff9900;">Club Database</a>.';
    } else if (budget > 0) {
      intro.innerHTML =
        `Bid for a GPSL club from your <b>${formatMoney(budget)}</b> starting budget. You may only lead one club at a time. ` +
        "When the auction closes, the highest bidder wins the club and your balance is set to budget minus your winning bid.";
    }
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
  const revealed = getDraftRandomFinishRevealed("club");
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

  const start = getDraftAuctionStartTime("club");
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

  const calBtn = document.getElementById("clubAuctionCalBtn");
  const startIso = auctionState?.start_time || getDraftAuctionStartTime("club");
  if (calBtn) {
    const show = Boolean(auctionState?.enabled && startIso);
    calBtn.hidden = !show;
    if (show) {
      calBtn.onclick = () => {
        const startAt =
          startIso instanceof Date ? startIso : new Date(startIso);
        const timeline = getDraftTimelineFromStart(startAt);
        if (!timeline) return;
        const events = draftAuctionTimelineEvents({
          id: "club",
          label: "GPSL club auction",
          startAt: timeline.start,
          cutoffAt: timeline.cutoff,
          randomStartAt: timeline.randomStart,
          url: new URL("club_auction.html", window.location.href).href,
          includeCutoff: true,
          filePrefix: "gpsl-club-auction",
        });
        downloadIcs(
          "gpsl-club-auction-times.ics",
          events.map((e) => e.vevent)
        );
      };
    }
  }

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
    const start = getDraftAuctionStartTime("club");
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

  if (!auctionOnboardingReady) {
    const parts = [];
    if (needsOnboardingTimezone) parts.push("timezone");
    if (needsOnboardingAvailability) parts.push("match availability");
    if (needsClubInterest) parts.push("primary club interest");
    if (needsClubBackup) parts.push("backup club");
    const detail = parts.length ? ` (${parts.join(", ")})` : "";
    el.innerHTML =
      `Complete onboarding on <a href="awaiting_club.html" style="color:#ff9900;">Owner details</a> and mark interest + backup on <a href="club_database.html" style="color:#ff9900;">Club Database</a>${detail} before bidding.`;
    el.style.color = "#faa";
    return;
  }

  if (auctionState.bidding_open) {
    const start = getDraftAuctionStartTime("club");
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

function interestsByClubMap() {
  const map = new Map();
  for (const row of interestState?.interests || []) {
    map.set(row.club_short_name, row);
  }
  return map;
}

function myMarkFor(clubShortName) {
  const interest = interestState?.mine_interest;
  const backup = interestState?.mine_backup;
  if (interest?.club_short_name === clubShortName) return interest;
  if (backup?.club_short_name === clubShortName) return backup;
  return (interestState?.mine || []).find((m) => m.club_short_name === clubShortName) || null;
}

function ownersTooltip(owners, label) {
  if (!owners?.length) return `${label}: none`;
  return (
    `${label}:\n` +
    owners
      .map((o) => {
        const tag = o.owner_tag || "—";
        return o.note ? `• ${tag} — ${o.note}` : `• ${tag}`;
      })
      .join("\n")
  );
}

function renderInterestBanner() {
  const el = document.getElementById("clubInterestBanner");
  if (!el) return;

  const url = interestState?.discord_chat_url || auctionState?.discord_chat_url || null;
  const frozen = Boolean(interestState?.frozen ?? auctionState?.interests_frozen);
  const canMark = Boolean(interestState?.can_mark);
  const canView = Boolean(interestState?.can_view);
  const mineI = interestState?.mine_interest;
  const mineB = interestState?.mine_backup;

  const parts = [];
  parts.push(
    `<b>Club interest</b> — mark <b>1 interest</b> and <b>1 backup</b> on any club (also on <a href="club_database.html" style="color:#e8c84a;">Club Database</a>). Hover ★ / ☆ to see who.`
  );
  if (url) {
    parts.push(
      ` ${discordChatLinkHtml(url)} to discuss with others.`
    );
  } else {
    parts.push(
      ' <span class="discord-missing">Discord chat link not set yet</span> (admin: Transfer management → Club auction → Discord auction chat URL).'
    );
  }
  if (frozen) {
    parts.push(' <span class="frozen">Marks are frozen while bidding is open.</span>');
  } else if (canMark) {
    const iLabel = mineI ? escapeHtml(mineI.club_name || mineI.club_short_name) : "none";
    const bLabel = mineB ? escapeHtml(mineB.club_name || mineB.club_short_name) : "none";
    parts.push(` Your interest: <b>${iLabel}</b> · backup: <b>${bLabel}</b>.`);
  } else if (canView) {
    parts.push(" You can view marks; set your owner tag to mark clubs.");
  } else if (!viewOnly) {
    parts.push(
      ' Set your owner tag on <a href="awaiting_club.html" style="color:#e8c84a;">Owner details</a> to mark interest.'
    );
  }

  el.innerHTML = parts.join("");
  el.hidden = false;
}

async function loadInterestState() {
  const { data, error } = await supabase.rpc("club_auction_interest_list");
  if (error) {
    console.warn("club_auction: interest list failed", error);
    interestState = {
      ok: false,
      frozen: Boolean(auctionState?.interests_frozen || auctionState?.bidding_open),
      can_mark: false,
      can_view: false,
      max_interests: 1,
      max_backups: 1,
      my_interest_count: 0,
      my_backup_count: 0,
      discord_chat_url: auctionState?.discord_chat_url || null,
      interests: [],
      mine: [],
      mine_interest: null,
      mine_backup: null,
    };
  } else {
    interestState = data;
  }
  renderInterestBanner();
}

function renderInterestCell(row, canMark) {
  const wrap = document.createElement("div");
  wrap.className = "interest-col";

  const clubShort = row.club_short_name || "";
  const group = interestsByClubMap().get(clubShort);
  const mine = myMarkFor(clubShort);
  const canView = Boolean(interestState?.can_view);
  const frozen = Boolean(interestState?.frozen);

  const iCount = Number(group?.interest_count || 0);
  const bCount = Number(group?.backup_count || 0);
  const iOwners = group?.interest_owners || [];
  const bOwners = group?.backup_owners || [];

  if (canView) {
    const counts = document.createElement("div");
    counts.className = "interest-counts";
    const iSpan = document.createElement("span");
    iSpan.className = "interest-count";
    iSpan.textContent = `★ ${iCount}`;
    iSpan.title = ownersTooltip(iOwners, "Interest");
    const bSpan = document.createElement("span");
    bSpan.className = "backup-count";
    bSpan.textContent = `☆ ${bCount}`;
    bSpan.title = ownersTooltip(bOwners, "Backup");
    counts.appendChild(iSpan);
    counts.appendChild(bSpan);
    wrap.appendChild(counts);
  } else {
    const empty = document.createElement("div");
    empty.style.color = "#666";
    empty.textContent = "—";
    wrap.appendChild(empty);
  }

  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "interest-btn" + (mine ? " is-marked" : "");
  btn.textContent = mine
    ? frozen
      ? mine.mark_kind === "backup"
        ? "Your backup"
        : "Your interest"
      : "Edit mark"
    : "Mark";
  btn.disabled = viewOnly || (!canMark && !mine);
  if (!btn.disabled) {
    btn.onclick = () => openInterestModal(row);
  }
  wrap.appendChild(btn);
  return wrap;
}

function openInterestModal(row) {
  interestModalClub = row;
  const modal = document.getElementById("clubInterestModal");
  const title = document.getElementById("clubInterestModalTitle");
  const note = document.getElementById("clubInterestNote");
  const err = document.getElementById("clubInterestModalError");
  const saveBtn = document.getElementById("clubInterestSaveBtn");
  const clearBtn = document.getElementById("clubInterestClearBtn");
  const help = document.getElementById("clubInterestModalHelp");
  if (!modal || !row) return;

  const mine = myMarkFor(row.club_short_name);
  const frozen = Boolean(interestState?.frozen);
  const canMark = Boolean(interestState?.can_mark);
  const kind = mine?.mark_kind === "backup" ? "backup" : "interest";

  const interestRadio = document.getElementById("clubMarkInterest");
  const backupRadio = document.getElementById("clubMarkBackup");
  if (interestRadio) {
    interestRadio.checked = kind === "interest";
    interestRadio.disabled = frozen || !canMark;
  }
  if (backupRadio) {
    backupRadio.checked = kind === "backup";
    backupRadio.disabled = frozen || !canMark;
  }

  if (title) {
    title.textContent = `${mine ? "Your mark" : "Mark club"} — ${row.club_name || row.club_short_name}`;
  }
  if (help) {
    help.textContent =
      "Choose Interest (primary) or Backup (1 of each on any club). Hover ★ / ☆ in the table to see who marked what.";
  }
  if (note) {
    note.value = mine?.note || "";
    note.disabled = frozen || (!canMark && !mine);
  }
  if (err) err.textContent = "";
  if (saveBtn) {
    saveBtn.disabled = frozen || !canMark;
    saveBtn.textContent = mine ? "Update mark" : "Save mark";
  }
  if (clearBtn) clearBtn.disabled = frozen || !mine;

  modal.classList.add("open");
  modal.setAttribute("aria-hidden", "false");
}

function closeInterestModal() {
  const modal = document.getElementById("clubInterestModal");
  if (modal) {
    modal.classList.remove("open");
    modal.setAttribute("aria-hidden", "true");
  }
  interestModalClub = null;
}

function wireInterestModal() {
  document.getElementById("clubInterestModalClose")?.addEventListener("click", closeInterestModal);
  document.getElementById("clubInterestModal")?.addEventListener("click", (e) => {
    if (e.target?.id === "clubInterestModal") closeInterestModal();
  });

  document.getElementById("clubInterestSaveBtn")?.addEventListener("click", async () => {
    if (!interestModalClub) return;
    const err = document.getElementById("clubInterestModalError");
    const noteVal = document.getElementById("clubInterestNote")?.value || "";
    const btn = document.getElementById("clubInterestSaveBtn");
    if (btn) btn.disabled = true;
    if (err) err.textContent = "";
    const markKind =
      document.querySelector('input[name="clubMarkKind"]:checked')?.value === "backup"
        ? "backup"
        : "interest";
    const { data, error } = await supabase.rpc("club_auction_interest_set", {
      p_club_short_name: interestModalClub.club_short_name,
      p_note: noteVal.trim() || null,
      p_mark_kind: markKind,
    });
    if (btn) btn.disabled = false;
    if (error) {
      if (err) err.textContent = error.message;
      return;
    }
    interestState = data;
    renderInterestBanner();
    closeInterestModal();
    await loadListings();
  });

  document.getElementById("clubInterestClearBtn")?.addEventListener("click", async () => {
    if (!interestModalClub) return;
    const err = document.getElementById("clubInterestModalError");
    const btn = document.getElementById("clubInterestClearBtn");
    if (btn) btn.disabled = true;
    if (err) err.textContent = "";
    const { data, error } = await supabase.rpc("club_auction_interest_clear", {
      p_club_short_name: interestModalClub.club_short_name,
    });
    if (btn) btn.disabled = false;
    if (error) {
      if (err) err.textContent = error.message;
      return;
    }
    interestState = data;
    renderInterestBanner();
    closeInterestModal();
    await loadListings();
  });
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
    tbody.innerHTML = `<tr><td colspan="${TABLE_COLS}" class="empty-row">Could not load listings — ${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  if (!listings?.length) {
    tbody.innerHTML = `<tr><td colspan="${TABLE_COLS}" class="empty-row">No vacant clubs listed. Admin: Transfer management → Seed vacant club listings.</td></tr>`;
    return;
  }

  listingsCache = listings;
  const canBid =
    !viewOnly && auctionState?.bidding_open && ownerTag && auctionOnboardingReady;
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
      <td class="stat-num">${formatMoney(cost)}<span class="stat-sub">capacity × ₿1,500</span></td>
      <td class="interest-slot"></td>
      <td class="stat-num">${highBidHtml}</td>
      <td>${row.current_leader_tag ? `<span class="club-owner-tag">${escapeHtml(row.current_leader_tag)}</span>` : "—"}${isLeader ? ' <span class="leader-you">(you)</span>' : ""}</td>
      <td class="bid-col"></td>
    `;
    tr.firstElementChild.appendChild(renderClubCell(row));

    const interestSlot = tr.querySelector(".interest-slot");
    if (interestSlot) {
      const interestTd = document.createElement("td");
      interestTd.appendChild(renderInterestCell(row, Boolean(interestState?.can_mark)));
      interestSlot.replaceWith(interestTd);
    }

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
    .select("id, bid_amount, bid_time, bidder_owner_id")
    .eq("listing_id", listingId)
    .order("bid_time", { ascending: false })
    .order("bid_amount", { ascending: false })
    .order("id", { ascending: false });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="3">Could not load bids — ${error.message}</td></tr>`;
    return;
  }

  if (!bids?.length) {
    tbody.innerHTML = `<tr><td colspan="3">No bids yet</td></tr>`;
    return;
  }

  // Same-second max-bid bursts can share bid_time — keep highest amount on top.
  const sorted = [...bids].sort((a, b) => {
    const t = new Date(b.bid_time).getTime() - new Date(a.bid_time).getTime();
    if (t !== 0) return t;
    const amt = Number(b.bid_amount || 0) - Number(a.bid_amount || 0);
    if (amt !== 0) return amt;
    return Number(b.id || 0) - Number(a.id || 0);
  });

  const tagMap = await resolveOwnerTags(sorted.map((b) => b.bidder_owner_id));
  tbody.innerHTML = sorted
    .map((b) => {
      const isYou = b.bidder_owner_id === ownerId;
      const rawTag = tagMap[b.bidder_owner_id] || "—";
      const tag = isYou ? `${escapeHtml(rawTag)} (you)` : escapeHtml(rawTag);
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
  const rounded = raw > 0 ? ceilBidToIncrement(raw) : 0;
  const minBid = listingMinimumBid(selectedListing);

  if (input.value !== "" && rounded > 0) {
    input.value = rounded.toLocaleString("en-GB");
  }

  if (!rounded || rounded < minBid) {
    input.style.border = "2px solid #a44";
    if (errorBox) {
      errorBox.textContent = rounded && rounded < minBid
        ? `Minimum bid is ${formatMoney(minBid)} (after rounding up to nearest ₿500k).`
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
  input.value = ceilBidToIncrement(current).toLocaleString("en-GB");
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
    input.value = ceilBidToIncrement(minBid).toLocaleString("en-GB");
    input.style.border = "1px solid #444";
    input.oninput = validateClubBidInput;
  }
  if (errorBox) errorBox.textContent = "";
  if (submitBtn) submitBtn.disabled = !allowBid;

  await loadBidHistory(row.id);
  await refreshClubMaxBidUi(row.club_short_name);

  modal.classList.add("open");
  modal.setAttribute("aria-hidden", "false");
  validateClubBidInput();
}

async function refreshClubMaxBidUi(clubShortName) {
  const statusEl = document.getElementById("clubBidMaxStatus");
  const maxInput = document.getElementById("clubBidMaxAmount");
  if (!statusEl) return;
  try {
    const max = await clubAuctionGetMyMaxBid(clubShortName);
    statusEl.textContent = maxBidStatusText(max).replace(/^Max bid /, "").replace(/^No max.*/, "Off");
    statusEl.style.color = max ? "#9f9" : "#aaa";
    if (maxInput && max) {
      maxInput.value = ceilBidToIncrement(max).toLocaleString("en-GB");
    } else if (maxInput && !maxInput.value) {
      maxInput.value = "";
    }
  } catch (err) {
    statusEl.textContent = "Max bid unavailable (run auction_max_bids.sql)";
    statusEl.style.color = "#c96";
  }
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
    input.value = ceilBidToIncrement(listingMinimumBid(selectedListing)).toLocaleString("en-GB");
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
    const amount = ceilBidToIncrement(parseMoneyInput(input?.value));
    const minBid = listingMinimumBid(selectedListing);
    if (!amount || amount < minBid) {
      validateClubBidInput();
      return;
    }
    await placeBid(selectedListing.club_short_name, amount, document.getElementById("clubBidSubmitBtn"));
  });

  document.getElementById("clubBidMaxSetBtn")?.addEventListener("click", async () => {
    if (!selectedListing) return;
    const errEl = document.getElementById("clubBidError");
    const amount = ceilBidToIncrement(
      parseMaxBidInput(document.getElementById("clubBidMaxAmount")?.value)
    );
    if (!amount) {
      if (errEl) errEl.textContent = "Enter a valid max bid.";
      return;
    }
    try {
      await clubAuctionSetMaxBid(selectedListing.club_short_name, amount);
      if (errEl) errEl.textContent = "";
      await refreshClubMaxBidUi(selectedListing.club_short_name);
      await refreshAll();
      const refreshed = listingsCache.find(
        (r) => r.club_short_name === selectedListing.club_short_name
      );
      if (refreshed) {
        selectedListing = refreshed;
        document.getElementById("clubBidModalHighBid").textContent =
          refreshed.current_highest_bid
            ? formatMoney(refreshed.current_highest_bid)
            : "—";
      }
    } catch (err) {
      if (errEl) errEl.textContent = err?.message || "Could not set max bid.";
    }
  });

  document.getElementById("clubBidMaxClearBtn")?.addEventListener("click", async () => {
    if (!selectedListing) return;
    try {
      await clubAuctionClearMaxBid(selectedListing.club_short_name);
      const maxInput = document.getElementById("clubBidMaxAmount");
      if (maxInput) maxInput.value = "";
      await refreshClubMaxBidUi(selectedListing.club_short_name);
    } catch (err) {
      const errEl = document.getElementById("clubBidError");
      if (errEl) errEl.textContent = err?.message || "Could not clear max bid.";
    }
  });
}

async function placeBid(shortName, rawAmount, btn) {
  const amount = ceilBidToIncrement(Number(rawAmount));
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
  setClubBankBalance("clubBankBalance", budget, { href: "awaiting_club.html" });
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
        input.value = ceilBidToIncrement(listingMinimumBid(refreshed)).toLocaleString("en-GB");
      }
      validateClubBidInput();
    }
  }
}

async function refreshAll() {
  await refreshAuctionState();
  renderStatus();
  await updateLeadPanel();
  await loadInterestState();
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
  wireInterestModal();
  wireDiscordChatLinks();
  await refreshAll();
  pollTimer = setInterval(refreshAll, 15000);
});
