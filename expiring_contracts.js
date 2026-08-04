import { initGlobal, supabase } from "./global.js";
import { loadClubsMap, displayClubName } from "./clubs_lookup.js";
import {
  formatWage,
  expiryWageMinUpliftPct,
  minExpiryWageOffer,
} from "./wages.js";
import { renderExpiringContractRules } from "./expiring_contracts_rules.js?v=20260804-signing-15pct";

const POSITION_ORDER = [
  "GK", "LB", "CB", "RB",
  "DMF", "LMF", "CMF", "RMF",
  "AMF", "LWF", "SS", "RWF", "CF",
];

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
let marketRows = [];
let bidTarget = null;

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();
  renderExpiringContractRules();

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

  wireBidModal();
  wireFilters();
  await loadMarket();

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

function wireFilters() {
  const ids = ["fName", "fPosition", "fNation", "fPlaystyle", "fClub", "fMyBid"];
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
  const positions = [
    ...new Set(marketRows.map((r) => r.position).filter(Boolean)),
  ].sort((a, b) => {
    const ai = POSITION_ORDER.indexOf(a);
    const bi = POSITION_ORDER.indexOf(b);
    return (ai === -1 ? 999 : ai) - (bi === -1 ? 999 : bi);
  });
  const nations = [...new Set(marketRows.map((r) => r.nation).filter(Boolean))].sort(
    (a, b) => a.localeCompare(b)
  );
  const playstyles = [
    ...new Set(marketRows.map((r) => r.playstyle).filter(Boolean)),
  ].sort((a, b) => a.localeCompare(b));
  const clubs = [
    ...new Set(marketRows.map((r) => r.holding_club).filter(Boolean)),
  ].sort((a, b) =>
    displayClubName(a).localeCompare(displayClubName(b), undefined, {
      sensitivity: "base",
    })
  );

  fillSelect("fPosition", positions);
  fillSelect("fNation", nations);
  fillSelect("fPlaystyle", playstyles);
  fillSelect("fClub", clubs, (v) => displayClubName(v));
  syncRangeBoundsFromMarket();
  syncMyClubFilterBtn();
}

function filteredRows() {
  const name = (document.getElementById("fName")?.value || "").trim().toLowerCase();
  const position = document.getElementById("fPosition")?.value || "";
  const nation = document.getElementById("fNation")?.value || "";
  const playstyle = document.getElementById("fPlaystyle")?.value || "";
  const club = document.getElementById("fClub")?.value || "";
  const myBid = document.getElementById("fMyBid")?.value || "";
  const ratingActive = isRangeNarrowed("Rating") ? RANGE_ACTIVE.Rating : null;
  const ageActive = isRangeNarrowed("Age") ? RANGE_ACTIVE.Age : null;

  return marketRows.filter((row) => {
    if (name && !String(row.player_name || "").toLowerCase().includes(name)) {
      return false;
    }
    if (position && row.position !== position) return false;
    if (nation && row.nation !== nation) return false;
    if (playstyle && row.playstyle !== playstyle) return false;
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
}

function formatMv(value) {
  if (value == null || value === "") return "—";
  const n = Number(value);
  if (!Number.isFinite(n)) return "—";
  return `<span class="money">₿ ${n.toLocaleString("en-GB")}</span>`;
}

function renderMarket() {
  const status = document.getElementById("marketStatus");
  const tbody = document.getElementById("marketBody");
  const rows = filteredRows();

  if (!marketRows.length) {
    status.textContent =
      "No players on the expiring-contract market right now (final-year standard players only).";
    tbody.innerHTML = '<tr><td colspan="11">—</td></tr>';
    return;
  }

  status.textContent =
    rows.length === marketRows.length
      ? `${marketRows.length} player(s) — hidden bids until season rollover (min +${expiryWageMinUpliftPct()}% wage).`
      : `Showing ${rows.length} of ${marketRows.length} — hidden bids until season rollover (min +${expiryWageMinUpliftPct()}% wage).`;

  if (!rows.length) {
    tbody.innerHTML = '<tr><td colspan="11">No players match these filters.</td></tr>';
    return;
  }

  tbody.innerHTML = rows
    .map((row) => {
      const myBid =
        row.my_wage_bid != null
          ? `<span class="my-bid">${formatWage(row.my_wage_bid)}</span>`
          : "—";
      return `
        <tr data-player-id="${row.player_id}">
          <td class="name-cell">${escapeHtml(row.player_name)}</td>
          <td>${escapeHtml(row.position || "—")}</td>
          <td>${escapeHtml(row.nation || "—")}</td>
          <td>${row.age ?? "—"}</td>
          <td>${row.rating ?? "—"}</td>
          <td>${escapeHtml(row.playstyle || "—")}</td>
          <td>${formatMv(row.market_value)}</td>
          <td>${escapeHtml(displayClubName(row.holding_club))}</td>
          <td>${formatWage(row.current_wage)}</td>
          <td>${myBid}</td>
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
      "Could not load market — run patches/expiring_contracts_gpdb_filters.sql if filters/columns are missing.";
    tbody.innerHTML = "";
    console.error(error);
    return;
  }

  marketRows = Array.isArray(data) ? data : [];
  rebuildFilterOptions();
  renderMarket();
}

function wireBidModal() {
  document.getElementById("bidCancelBtn").onclick = closeBidModal;
  document.getElementById("bidSubmitBtn").onclick = submitBid;
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

  document.getElementById("bidModalTitle").textContent = `Bid — ${row.player_name}`;
  document.getElementById("bidModalHint").textContent =
    `Current wage ${formatWage(row.current_wage)}. Minimum offer ${formatWage(minOffer)} (+${uplift}% or more). ` +
    `Any whole ₿ amount at or above the minimum. Your bid is locked once submitted and cannot be changed. Bids stay hidden until season rollover.`;
  document.getElementById("bidWageInput").value = String(minOffer);
  document.getElementById("bidWageInput").disabled = false;
  document.getElementById("bidSubmitBtn").disabled = false;
  document.getElementById("bidModalError").textContent = "";
  modal.style.display = "flex";
}

function closeBidModal() {
  document.getElementById("bidModal").style.display = "none";
  bidTarget = null;
}

async function submitBid() {
  const errEl = document.getElementById("bidModalError");
  errEl.textContent = "";
  if (!bidTarget) return;

  const raw = document.getElementById("bidWageInput").value;
  const wage = Number(String(raw).replace(/[^\d]/g, ""));
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
