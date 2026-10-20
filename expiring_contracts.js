import { initGlobal, supabase } from "./global.js";
import { initGpslInfoTips } from "./gpsl_info_tips.js";
import { loadClubsMap, displayClubName } from "./clubs_lookup.js";
import {
  formatWage,
  expiryWageMinUpliftPct,
  minExpiryWageOffer,
} from "./wages.js?v=20260805-nbsp";
import { renderExpiringContractRules, CHAMP_SL_SIGNING_FEE_PCT } from "./expiring_contracts_rules.js?v=20261018-season-phases";
import { createDraftAdvancedFilterController } from "./draft_auction_filters.js?v=20260811-step-pairs";
import { textMatchesSearch } from "./search_normalize.js";
import { leagueBadgeHtml } from "./competition.js";
import { installRangeSteppers } from "./range_filter_steppers.js?v=20260811-step-pairs";
import { loadCalendarStatus } from "./competition_calendar.js";
import {
  isPendingContractedDirectOffer,
  getBidPlayerId,
} from "./direct_offers.js";

const POSITION_ORDER = [
  "GK",
  "LB",
  "CB",
  "RB",
  "DMF",
  "LMF",
  "CMF",
  "RMF",
  "AMF",
  "LWF",
  "SS",
  "RWF",
  "CF",
];

const POSITION_ALIASES = {
  LW: "LWF",
  RW: "RWF",
};

const RANGE_COLS = ["Rating", "Age"];
const RANGE_DEFAULTS = {
  Rating: { min: 40, max: 99 },
  Age: { min: 15, max: 45 },
};

/** @type {Record<string, { min: number, max: number }>} */
const RANGE_BOUNDS = {
  Rating: { ...RANGE_DEFAULTS.Rating },
  Age: { ...RANGE_DEFAULTS.Age },
};

/** @type {Record<string, { min: number, max: number }>} */
const RANGE_ACTIVE = {
  Rating: { ...RANGE_DEFAULTS.Rating },
  Age: { ...RANGE_DEFAULTS.Age },
};

let myClubShort = null;
/** @type {'superleague'|'championship'|null} */
let myViewerTier = null;
let marketRows = [];
let bidTarget = null;
let bidMinOffer = 0;
/** @type {'transfer'|'wage'|'playoff'|'other'} */
let marketPhase = "other";
let transferTarget = null;
let transferMinOffer = 0;
/** @type {Set<string>} */
let pendingDirectOfferPlayers = new Set();

function phaseFromCalendarMonth(month) {
  const m = String(month || "").toLowerCase();
  if (["august", "september", "october", "november", "december"].includes(m)) {
    return "transfer";
  }
  if (["january", "february", "march", "april", "may"].includes(m)) {
    return "wage";
  }
  if (m === "playoffs" || m === "playoff") return "playoff";
  return "other";
}

function phaseBannerText(phase) {
  if (phase === "transfer") {
    return "August–December: Make a transfer offer (fee) to the holding club. Wage contract offers open from GPSL January.";
  }
  if (phase === "wage") {
    return "January–May: Wage contract offers only. Place one locked hidden wage bid per player.";
  }
  if (phase === "playoff") {
    return "Playoffs: Only the holding club can make a contract offer. Rivals are locked out. Holding clubs can bribe the agent with a Side door brown envelope from Owners Shop to reveal rival offer amounts (20% chance a Leaked bids stamp appears — amounts stay private).";
  }
  return "Expiring-contract actions are closed this GPSL month.";
}

function updatePhaseBanner() {
  const el = document.getElementById("phaseBanner");
  if (el) el.textContent = phaseBannerText(marketPhase);
}

function isHoldingClub(row) {
  if (!myClubShort || !row?.holding_club) return false;
  return (
    String(row.holding_club).trim().toUpperCase() ===
    String(myClubShort).trim().toUpperCase()
  );
}

const multiFilters = createDraftAdvancedFilterController({
  rootId: "expiryMultiFilters",
  onChange: () => renderMarket(),
});

function marketRowAsFilterRow(row) {
  return {
    player: {
      Position: row.position,
      Nation: row.nation,
      Playstyle: row.playstyle,
      Age: row.age,
      Rating: row.rating,
    },
    highestAmount: 0,
  };
}

document.addEventListener("DOMContentLoaded", async () => {
  initGpslInfoTips();
  await initGlobal();
  await loadClubsMap();
  renderExpiringContractRules();
  multiFilters.wire();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();

  myClubShort = club?.ShortName ?? null;
  myViewerTier = await loadMyViewerTier(myClubShort);

  const cal = await loadCalendarStatus(supabase);
  marketPhase = phaseFromCalendarMonth(cal?.active_gpsl_month);
  updatePhaseBanner();

  wireBidModal();
  wireTransferOfferModal();
  wireFilters();
  await loadPendingDirectOffers();
  await loadMarket();

  // Prefer tier from market RPC if present
  if (marketRows[0]?.viewer_tier === "superleague" || marketRows[0]?.viewer_tier === "championship") {
    myViewerTier = marketRows[0].viewer_tier;
  }
  const params = new URLSearchParams(window.location.search);
  const pid = params.get("player");
  if (pid) {
    const row = marketRows.find((r) => String(r.player_id) === String(pid));
    if (row) openBidModal(row);
    // Drop ?player= so refresh does not reopen the bid modal.
    params.delete("player");
    const next = params.toString();
    const cleanUrl = `${window.location.pathname}${next ? `?${next}` : ""}${
      window.location.hash || ""
    }`;
    window.history.replaceState({}, "", cleanUrl);
  }
});

async function loadMyViewerTier(clubShort) {
  if (!clubShort) return null;
  try {
    const { data: season } = await supabase
      .from("competition_seasons")
      .select("id, status, is_current")
      .order("id", { ascending: false })
      .limit(8);
    const seasons = Array.isArray(season) ? season : [];
    const ordered = [...seasons].sort((a, b) => {
      const cur = (b.is_current === true) - (a.is_current === true);
      if (cur) return cur;
      const rank = (s) =>
        s.status === "active" ? 0 : s.status === "preseason" ? 1 : 2;
      return rank(a) - rank(b) || Number(b.id) - Number(a.id);
    });
    for (const s of ordered) {
      const { data: row } = await supabase
        .from("competition_club_seasons")
        .select("division")
        .eq("season_id", s.id)
        .eq("club_short_name", clubShort)
        .maybeSingle();
      const div = row?.division;
      if (div === "superleague") return "superleague";
      if (div === "championship_a" || div === "championship_b") {
        return "championship";
      }
    }
  } catch (e) {
    console.warn("loadMyViewerTier failed", e);
  }
  return null;
}

function champSlFeeApplies(row) {
  if (row?.champ_sl_fee_applies === true) return true;
  if (row?.champ_sl_fee_applies === false && row?.viewer_tier) return false;
  const holderTier = row?.holding_tier || (
    row?.holding_division === "superleague" || row?.holding_league === "Super League"
      ? "superleague"
      : null
  );
  return myViewerTier === "championship" && holderTier === "superleague";
}

function champSlFeeEstimate(row) {
  if (row?.champ_sl_fee_estimate != null) return Number(row.champ_sl_fee_estimate);
  const pct = Number(row?.champ_sl_fee_pct) || CHAMP_SL_SIGNING_FEE_PCT;
  const mv = Number(row?.market_value);
  if (!Number.isFinite(mv) || mv <= 0) return null;
  return Math.round((mv * pct) / 100);
}

function wireFilters() {
  const ids = ["fName", "fClub", "fMyBid"];
  for (const id of ids) {
    const el = document.getElementById(id);
    if (!el) continue;
    el.addEventListener(el.tagName === "SELECT" ? "change" : "input", () => {
      if (id === "fClub") syncMyClubFilterBtn();
      renderMarket();
    });
  }
  wireRangeFilters();
  document.getElementById("fClearBtn")?.addEventListener("click", () => {
    for (const id of ids) {
      const el = document.getElementById(id);
      if (el) el.value = "";
    }
    multiFilters.clear();
    resetRangeFilters();
    syncMyClubFilterBtn();
    renderMarket();
  });

  const myClubBtn = document.getElementById("fMyClubBtn");
  if (myClubBtn) {
    myClubBtn.hidden = !myClubShort;
    myClubBtn.addEventListener("click", () => {
      if (!myClubShort) return;
      const clubSel = document.getElementById("fClub");
      if (!clubSel) return;
      const already = clubSel.value === myClubShort;
      clubSel.value = already ? "" : myClubShort;
      syncMyClubFilterBtn();
      renderMarket();
    });
  }
}

function isRangeNarrowed(col) {
  const bounds = RANGE_BOUNDS[col];
  const active = RANGE_ACTIVE[col];
  if (!bounds || !active) return false;
  return active.min > bounds.min || active.max < bounds.max;
}

function updateRangeReadout(col) {
  const el = document.getElementById(`filter-${col}-range`);
  const active = RANGE_ACTIVE[col];
  if (!el || !active) return;
  el.textContent = `(${active.min}-${active.max})`;
}

function updateRangeTrack(col) {
  const wrap = document.getElementById(`filter-${col}-sliders`);
  const bounds = RANGE_BOUNDS[col];
  const active = RANGE_ACTIVE[col];
  if (!wrap || !bounds || !active) return;
  const span = Math.max(bounds.max - bounds.min, 1);
  const minPct = ((active.min - bounds.min) / span) * 100;
  const maxPct = ((active.max - bounds.min) / span) * 100;
  wrap.style.setProperty("--range-min", `${minPct}%`);
  wrap.style.setProperty("--range-max", `${maxPct}%`);
}

function applyRangeToInputs(col) {
  const bounds = RANGE_BOUNDS[col];
  const active = RANGE_ACTIVE[col];
  const minEl = document.getElementById(`filter-${col}-min`);
  const maxEl = document.getElementById(`filter-${col}-max`);
  if (!bounds || !active || !minEl || !maxEl) return;

  minEl.min = String(bounds.min);
  minEl.max = String(bounds.max);
  maxEl.min = String(bounds.min);
  maxEl.max = String(bounds.max);
  minEl.value = String(active.min);
  maxEl.value = String(active.max);
  const disabled = bounds.max <= bounds.min;
  minEl.disabled = disabled;
  maxEl.disabled = disabled;
  updateRangeReadout(col);
  updateRangeTrack(col);
}

function resetRangeFilters() {
  for (const col of RANGE_COLS) {
    RANGE_ACTIVE[col] = { ...RANGE_BOUNDS[col] };
    applyRangeToInputs(col);
  }
}

function syncRangeBoundsFromMarket() {
  for (const col of RANGE_COLS) {
    const key = col === "Rating" ? "rating" : "age";
    const values = marketRows
      .map((r) => Number(r[key]))
      .filter((n) => Number.isFinite(n));
    const fallback = RANGE_DEFAULTS[col];
    const prevBounds = { ...RANGE_BOUNDS[col] };
    const prevActive = { ...(RANGE_ACTIVE[col] || fallback) };
    const wasFull =
      prevActive.min === prevBounds.min && prevActive.max === prevBounds.max;

    RANGE_BOUNDS[col] = values.length
      ? { min: Math.min(...values), max: Math.max(...values) }
      : { ...fallback };

    const b = RANGE_BOUNDS[col];
    if (wasFull) {
      RANGE_ACTIVE[col] = { ...b };
    } else {
      const lo = Math.min(Math.max(prevActive.min, b.min), b.max);
      const hi = Math.max(Math.min(prevActive.max, b.max), b.min);
      RANGE_ACTIVE[col] =
        lo <= hi ? { min: lo, max: hi } : { ...b };
    }
    applyRangeToInputs(col);
  }
}

function wireRangeFilters() {
  for (const col of RANGE_COLS) {
    const minEl = document.getElementById(`filter-${col}-min`);
    const maxEl = document.getElementById(`filter-${col}-max`);
    if (!minEl || !maxEl) continue;

    const syncThumbZIndex = () => {
      const lo = Number(minEl.value);
      const hi = Number(maxEl.value);
      if (document.activeElement === minEl) {
        minEl.style.zIndex = "5";
        maxEl.style.zIndex = "4";
      } else if (document.activeElement === maxEl) {
        maxEl.style.zIndex = "5";
        minEl.style.zIndex = "4";
      } else if (lo > hi) {
        minEl.style.zIndex = "5";
        maxEl.style.zIndex = "4";
      } else {
        minEl.style.zIndex = "3";
        maxEl.style.zIndex = "4";
      }
    };

    const onInput = () => {
      let lo = Number(minEl.value);
      let hi = Number(maxEl.value);
      if (!Number.isFinite(lo)) lo = RANGE_BOUNDS[col].min;
      if (!Number.isFinite(hi)) hi = RANGE_BOUNDS[col].max;
      if (lo > hi) {
        // Allow crossing while dragging; store ordered values.
        RANGE_ACTIVE[col] = { min: hi, max: lo };
      } else {
        RANGE_ACTIVE[col] = { min: lo, max: hi };
      }
      syncThumbZIndex();
      updateRangeReadout(col);
      updateRangeTrack(col);
      renderMarket();
    };

    minEl.addEventListener("input", onInput);
    maxEl.addEventListener("input", onInput);
    minEl.addEventListener("focus", syncThumbZIndex);
    maxEl.addEventListener("focus", syncThumbZIndex);
    applyRangeToInputs(col);
  }

  installRangeSteppers({
    root: document.getElementById("filterBar") || document,
    cols: ["Age", "Rating"],
  });
}

function syncMyClubFilterBtn() {
  const btn = document.getElementById("fMyClubBtn");
  const clubSel = document.getElementById("fClub");
  if (!btn) return;
  const active = Boolean(myClubShort && clubSel?.value === myClubShort);
  btn.classList.toggle("is-active", active);
  btn.style.background = active ? "#3d3200" : "";
  btn.style.borderColor = active ? "#ff9900" : "";
  btn.style.color = active ? "#ffcc66" : "";
}

function fillSelect(id, values, labelFn = (v) => v) {
  const sel = document.getElementById(id);
  if (!sel) return;
  const current = sel.value;
  const opts = ['<option value="">All</option>'].concat(
    values.map((v) => `<option value="${escapeAttr(v)}">${escapeHtml(labelFn(v))}</option>`)
  );
  sel.innerHTML = opts.join("");
  if (current && values.includes(current)) sel.value = current;
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function escapeAttr(text) {
  return escapeHtml(text).replace(/'/g, "&#39;");
}

function rebuildFilterOptions() {
  const clubs = [
    ...new Set(marketRows.map((r) => r.holding_club).filter(Boolean)),
  ].sort((a, b) =>
    displayClubName(a).localeCompare(displayClubName(b), undefined, {
      sensitivity: "base",
    })
  );

  multiFilters.rebuildFromRows(marketRows.map(marketRowAsFilterRow));
  fillSelect("fClub", clubs, (v) => displayClubName(v));
  syncRangeBoundsFromMarket();
  syncMyClubFilterBtn();
}

function positionSortIndex(position) {
  const raw = String(position || "").trim().toUpperCase();
  const p = POSITION_ALIASES[raw] || raw;
  const i = POSITION_ORDER.indexOf(p);
  return i >= 0 ? i : 999;
}

function sortMarketRows(rows) {
  return [...rows].sort((a, b) => {
    const ra = Number(a.rating);
    const rb = Number(b.rating);
    const aOk = Number.isFinite(ra);
    const bOk = Number.isFinite(rb);
    if (aOk && bOk && rb !== ra) return rb - ra; // highest rating first
    if (aOk !== bOk) return aOk ? -1 : 1;
    const pos =
      positionSortIndex(a.position) - positionSortIndex(b.position);
    if (pos !== 0) return pos;
    return String(a.player_name || "").localeCompare(
      String(b.player_name || ""),
      "en",
      { sensitivity: "base" }
    );
  });
}

function filteredRows() {
  const name = (document.getElementById("fName")?.value || "").trim();
  const club = document.getElementById("fClub")?.value || "";
  const myBid = document.getElementById("fMyBid")?.value || "";
  const ratingActive = isRangeNarrowed("Rating") ? RANGE_ACTIVE.Rating : null;
  const ageActive = isRangeNarrowed("Age") ? RANGE_ACTIVE.Age : null;

  const rows = marketRows.filter((row) => {
    if (name && !textMatchesSearch(row.player_name || "", name)) {
      return false;
    }
    if (!multiFilters.rowPasses(marketRowAsFilterRow(row))) return false;
    if (club && row.holding_club !== club) return false;

    if (ratingActive) {
      const rating = Number(row.rating);
      if (!Number.isFinite(rating) || rating < ratingActive.min || rating > ratingActive.max) {
        return false;
      }
    }

    if (ageActive) {
      const age = Number(row.age);
      if (!Number.isFinite(age) || age < ageActive.min || age > ageActive.max) {
        return false;
      }
    }

    if (myBid === "yes" && row.my_wage_bid == null) return false;
    if (myBid === "no" && row.my_wage_bid != null) return false;

    return true;
  });

  return sortMarketRows(rows);
}

function formatMv(value) {
  if (value == null || value === "") return "—";
  const n = Number(value);
  if (!Number.isFinite(n)) return "—";
  return `<span class="money">₿\u00a0${n.toLocaleString("en-GB")}</span>`;
}

function actionCellHtml(row) {
  const phase = row.market_phase || marketPhase;
  const pid = String(row.player_id);
  const isMine = isHoldingClub(row);
  const pendingOffer = pendingDirectOfferPlayers.has(pid);

  if (phase === "transfer") {
    if (isMine) {
      return `<span class="muted" title="Your player">Your player</span>`;
    }
    if (pendingOffer) {
      return `<span class="my-bid" title="Direct offer under review">Offer pending</span>`;
    }
    return `<button type="button" class="transfer-btn button" data-player-id="${pid}">Make transfer offer</button>`;
  }

  if (phase === "wage" || phase === "playoff") {
    if (row.my_wage_bid != null) {
      return `<span class="my-bid" title="Wage bid locked — cannot be changed">Locked</span>`;
    }
    if (phase === "playoff" && !isMine) {
      return `<span class="muted" title="Playoffs: only the holding club can offer">Playoff lock</span>`;
    }
    if (row.bidding_open === false && phase !== "playoff") {
      return `<span class="muted" title="Wage bids open GPSL January–May">Closed</span>`;
    }
    if (phase === "playoff" && isMine) {
      return `<button type="button" class="bid-btn" data-player-id="${pid}">Contract offer</button>`;
    }
    if (row.bidding_open !== false) {
      return `<button type="button" class="bid-btn" data-player-id="${pid}">Place bid</button>`;
    }
    return `<span class="muted">Closed</span>`;
  }

  return `<span class="muted">Closed</span>`;
}

function interestCellHtml(row) {
  const isMine = isHoldingClub(row);
  if (!isMine) return "—";

  const revealed = Array.isArray(row.revealed_offers) ? row.revealed_offers : null;
  if (revealed?.length) {
    return revealed
      .map(
        (o) =>
          `${escapeHtml(displayClubName(o.club_short_name))} ${formatWage(o.wage_offer)}`
      )
      .join("<br>");
  }

  const clubs = Array.isArray(row.interested_clubs) ? row.interested_clubs : [];
  const names = clubs
    .map((c) => displayClubName(c.club_short_name || c))
    .filter(Boolean);
  const phase = row.market_phase || marketPhase;
  let html = names.length
    ? escapeHtml(names.join(", "))
    : `<span class="muted">None yet</span>`;

  if (phase === "playoff") {
    if (row.bribe_used) {
      html += `<div class="muted" style="margin-top:4px;">Offers revealed</div>`;
    } else {
      html += `<div style="margin-top:6px;"><button type="button" class="bribe-btn button secondary" data-player-id="${row.player_id}" style="font-size:11px;padding:4px 8px;">Bribe agent (brown envelope)</button></div>`;
    }
  }
  return html;
}

function renderMarket() {
  const status = document.getElementById("marketStatus");
  const tbody = document.getElementById("marketBody");
  const rows = filteredRows();

  if (marketRows[0]?.market_phase) {
    marketPhase = marketRows[0].market_phase;
    updatePhaseBanner();
  }

  if (!marketRows.length) {
    status.textContent =
      "No players on the expiring-contract market right now (final-year standard players only).";
    tbody.innerHTML = '<tr><td colspan="13">—</td></tr>';
    return;
  }

  const phaseNote = phaseBannerText(marketPhase);
  status.textContent =
    rows.length === marketRows.length
      ? `${marketRows.length} player(s). ${phaseNote}`
      : `Showing ${rows.length} of ${marketRows.length}. ${phaseNote}`;

  if (!rows.length) {
    tbody.innerHTML = '<tr><td colspan="13">No players match these filters.</td></tr>';
    return;
  }

  tbody.innerHTML = rows
    .map((row) => {
      const myBid =
        row.my_wage_bid != null
          ? `<span class="my-bid">${formatWage(row.my_wage_bid)}</span>`
          : "—";
      const league = row.holding_league || row.holding_division || "—";
      const feePct = Number(row.champ_sl_fee_pct) || CHAMP_SL_SIGNING_FEE_PCT;
      const feeApplies = champSlFeeApplies(row);
      const feeEst = feeApplies ? champSlFeeEstimate(row) : null;
      const feeBadge = feeApplies
        ? `<span class="fee-badge" title="Championship club winning this Super League player pays ${feePct}% of market value to the player as a signing-on fee${
            feeEst != null ? ` (≈ ${formatWage(feeEst)})` : ""
          }.">+${feePct}% MV fee</span>`
        : "";
      const leagueBadge = leagueBadgeHtml(
        row.holding_division || row.holding_league,
        { size: "xs" }
      );
      const endsJan =
        String(row.contract_end_window || "").toLowerCase() === "january";
      const endBadge = endsJan
        ? ` <span class="fee-badge" title="January contract — bids resolve when GPSL January unlocks">Ends Jan</span>`
        : "";
      const leakStamp = row.bribe_leaked
        ? ` <span class="leak-stamp" title="Someone used a brown envelope here — bid amounts stay private">Leaked bids</span>`
        : "";
      return `
        <tr data-player-id="${row.player_id}">
          <td class="name-cell">${escapeHtml(row.player_name)}${endBadge}${leakStamp}</td>
          <td>${escapeHtml(row.position || "—")}</td>
          <td>${escapeHtml(row.nation || "—")}</td>
          <td>${row.age ?? "—"}</td>
          <td>${row.rating ?? "—"}</td>
          <td>${escapeHtml(row.playstyle || "—")}</td>
          <td class="wage-cell">${formatMv(row.market_value)}</td>
          <td>${escapeHtml(displayClubName(row.holding_club))}</td>
          <td class="league-cell">${leagueBadge}${escapeHtml(league)}${feeBadge}</td>
          <td class="wage-cell">${formatWage(row.current_wage)}</td>
          <td class="wage-cell">${myBid}</td>
          <td class="interest-cell" style="font-size:12px;max-width:12rem;">${interestCellHtml(row)}</td>
          <td>${actionCellHtml(row)}</td>
        </tr>
      `;
    })
    .join("");

  tbody.querySelectorAll(".bid-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.dataset.playerId;
      const row = marketRows.find((r) => String(r.player_id) === String(id));
      if (row) openBidModal(row);
    });
  });
  tbody.querySelectorAll(".transfer-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.dataset.playerId;
      const row = marketRows.find((r) => String(r.player_id) === String(id));
      if (row) openTransferOfferModal(row);
    });
  });
  tbody.querySelectorAll(".bribe-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.dataset.playerId;
      void submitAgentBribe(id);
    });
  });
}

async function loadMarket() {
  const status = document.getElementById("marketStatus");
  const tbody = document.getElementById("marketBody");
  status.textContent = "Loading…";

  const { data, error } = await supabase.rpc("list_expiring_contract_market");

  if (error) {
    status.textContent =
      "Could not load market — run patches/expiring_contracts_league_fee_badge.sql in Supabase.";
    tbody.innerHTML = "";
    console.error(error);
    return;
  }

  marketRows = Array.isArray(data) ? data : [];
  rebuildFilterOptions();
  renderMarket();

  if (
    marketRows.length &&
    marketRows.every((r) => r.holding_league == null && r.champ_sl_fee_applies == null)
  ) {
    status.textContent =
      (status.textContent || "") +
      " — League/fee columns need SQL: run supabase/sql/patches/expiring_contracts_league_fee_badge.sql then hard-refresh.";
  }
}

function formatWageInputValue(n) {
  const v = Number(n);
  if (!Number.isFinite(v) || v < 0) return "";
  return Math.round(v).toLocaleString("en-GB");
}

function parseWageInputValue(raw) {
  const n = Number(String(raw || "").replace(/[^\d]/g, ""));
  return Number.isFinite(n) ? n : NaN;
}

function adjustBidWage(delta) {
  const input = document.getElementById("bidWageInput");
  if (!input || input.disabled) return;
  const current = parseWageInputValue(input.value);
  const base = Number.isFinite(current) && current > 0 ? current : bidMinOffer;
  const next = Math.max(bidMinOffer || 0, Math.round(base + Number(delta)));
  input.value = formatWageInputValue(next);
  const errEl = document.getElementById("bidModalError");
  if (errEl) errEl.textContent = "";
}

function wireBidModal() {
  document.getElementById("bidCancelBtn").onclick = closeBidModal;
  document.getElementById("bidSubmitBtn").onclick = submitBid;

  const stepRow = document.getElementById("bidStepRow");
  if (stepRow && stepRow.dataset.wired !== "1") {
    stepRow.dataset.wired = "1";
    stepRow.addEventListener("click", (e) => {
      const btn = e.target.closest(".bid-step-btn");
      if (!btn) return;
      const delta = Number(btn.dataset.delta);
      if (!Number.isFinite(delta)) return;
      adjustBidWage(delta);
    });
  }

  const input = document.getElementById("bidWageInput");
  if (!input || input.dataset.wired === "1") return;
  input.dataset.wired = "1";

  input.addEventListener("input", () => {
    const caretAtEnd = input.selectionStart === input.value.length;
    const n = parseWageInputValue(input.value);
    if (!Number.isFinite(n) || n <= 0) {
      // Allow clearing / partial typing of leading digits only
      const digits = String(input.value).replace(/[^\d]/g, "");
      input.value = digits ? formatWageInputValue(Number(digits)) : "";
      return;
    }
    input.value = formatWageInputValue(n);
    if (caretAtEnd) {
      const len = input.value.length;
      input.setSelectionRange(len, len);
    }
  });

  input.addEventListener("blur", () => {
    const n = parseWageInputValue(input.value);
    if (Number.isFinite(n) && n > 0) {
      input.value = formatWageInputValue(n);
    }
  });
}

function openBidModal(row) {
  if (!myClubShort) {
    alert("Link a club to your account to place bids.");
    return;
  }

  if (row.my_wage_bid != null) {
    alert(
      `Your wage bid for ${row.player_name} is locked at ${formatWage(row.my_wage_bid)} and cannot be changed.`
    );
    return;
  }

  bidTarget = row;
  const modal = document.getElementById("bidModal");
  const uplift = expiryWageMinUpliftPct();
  const minOffer =
    row.min_wage_offer != null
      ? Number(row.min_wage_offer)
      : minExpiryWageOffer(row.current_wage, uplift);
  bidMinOffer = Number.isFinite(minOffer) ? minOffer : 0;

  document.getElementById("bidModalTitle").textContent = `Bid — ${row.player_name}`;
  document.getElementById("bidModalHint").innerHTML = `
    <dl>
      <dt>Current wage</dt>
      <dd>${formatWage(row.current_wage)}</dd>
      <dt>Minimum offer</dt>
      <dd>${formatWage(minOffer)} <span style="font-weight:normal;color:#999;">(+${uplift}%)</span></dd>
      ${
        row.holding_league
          ? `<dt>League</dt><dd>${leagueBadgeHtml(
              row.holding_division || row.holding_league,
              { size: "xs" }
            )}${escapeHtml(row.holding_league)}</dd>`
          : ""
      }
    </dl>
    <ul>
      <li>Bid any whole ₿ amount at or above the minimum</li>
      <li>Locked once submitted — cannot be changed</li>
      <li>Bids stay hidden until season rollover</li>
      ${
        champSlFeeApplies(row)
          ? `<li style="color:#e8b84a;"><b>Championship signing-on fee:</b> if you win this Super League player you also pay <b>${
              Number(row.champ_sl_fee_pct) || CHAMP_SL_SIGNING_FEE_PCT
            }% of MV</b> to the player${
              (() => {
                const est = champSlFeeEstimate(row);
                return est != null ? ` (≈ ${formatWage(est)})` : "";
              })()
            }.</li>`
          : ""
      }
    </ul>`;
  document.getElementById("bidWageInput").value = formatWageInputValue(minOffer);
  document.getElementById("bidWageInput").disabled = false;
  document.getElementById("bidSubmitBtn").disabled = false;
  document.getElementById("bidModalError").textContent = "";
  modal.style.display = "flex";
}

function closeBidModal() {
  document.getElementById("bidModal").style.display = "none";
  bidTarget = null;
  bidMinOffer = 0;
}

async function submitBid() {
  const errEl = document.getElementById("bidModalError");
  errEl.textContent = "";
  if (!bidTarget) return;

  const wage = parseWageInputValue(document.getElementById("bidWageInput").value);
  const uplift = expiryWageMinUpliftPct();
  const minOffer =
    bidTarget.min_wage_offer != null
      ? Number(bidTarget.min_wage_offer)
      : minExpiryWageOffer(bidTarget.current_wage, uplift);

  if (!Number.isFinite(wage) || wage <= 0) {
    errEl.textContent = "Enter a valid wage amount.";
    return;
  }
  if (wage < minOffer) {
    errEl.textContent = `Minimum offer is ${formatWage(minOffer)} (+${uplift}% above current wage).`;
    return;
  }

  const { error } = await supabase.rpc("contract_submit_expiry_wage_bid", {
    p_player_id: String(bidTarget.player_id),
    p_wage_offer: wage,
  });

  if (error) {
    errEl.textContent = error.message || "Bid failed.";
    return;
  }

  closeBidModal();
  await loadMarket();
}

async function loadPendingDirectOffers() {
  pendingDirectOfferPlayers = new Set();
  if (!myClubShort) return;
  try {
    const { data, error } = await supabase
      .from("Player_Transfer_Bids")
      .select("player_id, direct_bid_id, bidder_club_id, is_direct, status, listing_id")
      .eq("bidder_club_id", myClubShort)
      .eq("is_direct", true)
      .eq("status", "active");
    if (error || !Array.isArray(data)) return;
    for (const row of data) {
      if (!isPendingContractedDirectOffer(row)) continue;
      const id = getBidPlayerId(row);
      if (id) pendingDirectOfferPlayers.add(String(id).trim());
    }
  } catch (e) {
    console.warn("loadPendingDirectOffers", e);
  }
}

function wireTransferOfferModal() {
  const cancel = document.getElementById("transferOfferCancelBtn");
  const submit = document.getElementById("transferOfferSubmitBtn");
  const stepRow = document.getElementById("transferOfferStepRow");
  const input = document.getElementById("transferOfferAmount");
  if (cancel) cancel.onclick = closeTransferOfferModal;
  if (submit) submit.onclick = () => void submitTransferOffer();
  if (stepRow && stepRow.dataset.wired !== "1") {
    stepRow.dataset.wired = "1";
    stepRow.addEventListener("click", (e) => {
      const btn = e.target.closest(".bid-step-btn");
      if (!btn || !input) return;
      const delta = Number(btn.dataset.delta);
      if (!Number.isFinite(delta)) return;
      const current = parseWageInputValue(input.value);
      const base =
        Number.isFinite(current) && current > 0 ? current : transferMinOffer;
      input.value = formatWageInputValue(
        Math.max(transferMinOffer || 0, Math.round(base + delta))
      );
    });
  }
  if (input && input.dataset.wired !== "1") {
    input.dataset.wired = "1";
    input.addEventListener("input", () => {
      const n = parseWageInputValue(input.value);
      const digits = String(input.value).replace(/[^\d]/g, "");
      input.value = digits ? formatWageInputValue(Number(digits)) : "";
      if (Number.isFinite(n) && n > 0) input.value = formatWageInputValue(n);
    });
  }
}

function openTransferOfferModal(row) {
  if (!myClubShort) {
    alert("Link a club to your account to make offers.");
    return;
  }
  if (isHoldingClub(row)) {
    alert("You cannot make an offer for your own player.");
    return;
  }
  if (pendingDirectOfferPlayers.has(String(row.player_id))) {
    alert("An offer is already under review for this player.");
    return;
  }

  transferTarget = row;
  const mv = Number(row.market_value) || 0;
  transferMinOffer = mv;
  const modal = document.getElementById("transferOfferModal");
  document.getElementById("transferOfferTitle").textContent =
    `Transfer offer — ${row.player_name}`;
  document.getElementById("transferOfferHint").innerHTML = `
    <dl>
      <dt>Holding club</dt>
      <dd>${escapeHtml(displayClubName(row.holding_club))}</dd>
      <dt>Market value (minimum)</dt>
      <dd>${formatMv(mv)}</dd>
    </dl>
    <ul>
      <li>Same as a GPDB direct offer — seller reviews in Transfer Centre</li>
      <li>Minimum offer is market value</li>
      <li>Only one pending direct offer per player</li>
    </ul>`;
  document.getElementById("transferOfferAmount").value = formatWageInputValue(mv);
  document.getElementById("transferOfferError").textContent = "";
  if (modal) modal.style.display = "flex";
}

function closeTransferOfferModal() {
  const modal = document.getElementById("transferOfferModal");
  if (modal) modal.style.display = "none";
  transferTarget = null;
  transferMinOffer = 0;
}

async function submitTransferOffer() {
  const errEl = document.getElementById("transferOfferError");
  if (errEl) errEl.textContent = "";
  if (!transferTarget || !myClubShort) return;

  const offer = parseWageInputValue(
    document.getElementById("transferOfferAmount")?.value
  );
  const mv = Number(transferTarget.market_value) || 0;
  if (!Number.isFinite(offer) || offer <= 0) {
    if (errEl) errEl.textContent = "Enter a valid offer amount.";
    return;
  }
  if (offer < mv) {
    if (errEl) {
      errEl.textContent = `Minimum direct offer is market value (${formatMv(mv)}).`;
    }
    return;
  }

  const sellerShort = String(transferTarget.holding_club || "").trim();
  const konamiId = String(transferTarget.player_id).trim();
  const { error } = await supabase.from("Player_Transfer_Bids").insert({
    listing_id: null,
    player_id: konamiId,
    direct_bid_id: konamiId,
    bidder_club_id: myClubShort,
    seller_club_id: sellerShort,
    bid_amount: offer,
    bid_time: new Date().toISOString(),
    is_direct: true,
    status: "active",
  });

  if (error) {
    const msg = String(error.message || "");
    if (errEl) {
      errEl.textContent = msg.includes("already under review")
        ? "An offer is already under review for this player."
        : msg.includes("transfer window") || msg.includes("Transfer window")
          ? "Transfer window is closed."
          : msg || "Failed to submit offer.";
    }
    console.error(error);
    return;
  }

  pendingDirectOfferPlayers.add(konamiId);
  closeTransferOfferModal();
  await loadMarket();
  alert("Transfer offer submitted — the holding club will see it in Transfer Centre.");
}

async function submitAgentBribe(playerId) {
  if (
    !confirm(
      "Use a Side door brown envelope to bribe the agent and reveal rival contract offer amounts?\n\nOnly the holding club can do this. Buy envelopes from Owners Shop first (₿50,000).\n\n20% chance a public “Leaked bids” stamp appears on the listing (amounts stay private to you)."
    )
  ) {
    return;
  }

  const { data, error } = await supabase.rpc(
    "expiring_bribe_reveal_contract_offers",
    { p_player_id: String(playerId) }
  );

  if (error) {
    alert(error.message || "Bribe failed.");
    return;
  }

  const leaked = data?.leaked === true;
  const offers = Array.isArray(data?.offers) ? data.offers : [];
  const lines = offers.length
    ? offers
        .map(
          (o) =>
            `${displayClubName(o.club_short_name)}: ${formatWage(o.wage_offer)}`
        )
        .join("\n")
    : "No contract offers to reveal.";

  let preface;
  if (data?.already_bribed) {
    preface = "Already bribed this season — showing offers again.\n\n";
  } else {
    preface = leaked
      ? "Brown envelope used — a Leaked bids stamp is now on the listing (rivals see the stamp only).\n\n"
      : "Brown envelope used — offers revealed quietly.\n\n";
  }

  alert(preface + lines);
  await loadMarket();
}
