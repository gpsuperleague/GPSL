import { initGlobal, supabase } from "./global.js";
import { loadClubsMap, displayClubName } from "./clubs_lookup.js";
import {
  formatWage,
  expiryWageMinUpliftPct,
  minExpiryWageOffer,
} from "./wages.js?v=20260805-nbsp";
import { renderExpiringContractRules, CHAMP_SL_SIGNING_FEE_PCT } from "./expiring_contracts_rules.js?v=20260806-league-fee2";
import { createDraftAdvancedFilterController } from "./draft_auction_filters.js?v=20260805-opt-row";
import { textMatchesSearch } from "./search_normalize.js";
import { leagueBadgeHtml } from "./competition.js";
import { installRangeSteppers } from "./range_filter_steppers.js";

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

  wireBidModal();
  wireFilters();
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
    root: document.getElementById("filters") || document,
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

function renderMarket() {
  const status = document.getElementById("marketStatus");
  const tbody = document.getElementById("marketBody");
  const rows = filteredRows();

  if (!marketRows.length) {
    status.textContent =
      "No players on the expiring-contract market right now (final-year standard players only).";
    tbody.innerHTML = '<tr><td colspan="12">—</td></tr>';
    return;
  }

  status.textContent =
    rows.length === marketRows.length
      ? `${marketRows.length} player(s) — hidden bids until season rollover (min +${expiryWageMinUpliftPct()}% wage).`
      : `Showing ${rows.length} of ${marketRows.length} — hidden bids until season rollover (min +${expiryWageMinUpliftPct()}% wage).`;

  if (!rows.length) {
    tbody.innerHTML = '<tr><td colspan="12">No players match these filters.</td></tr>';
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
      return `
        <tr data-player-id="${row.player_id}">
          <td class="name-cell">${escapeHtml(row.player_name)}</td>
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
          <td>
            ${
              row.my_wage_bid != null
                ? `<span class="my-bid" title="Wage bid locked — cannot be changed">Locked</span>`
                : `<button type="button" class="bid-btn" data-player-id="${row.player_id}">Place bid</button>`
            }
          </td>
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
