/**
 * Advanced attribute filters for Draft Auction (nation / pos / playstyle + range sliders).
 */

import { wageFromMarketValue } from "./wages.js";

const POSITION_ORDER = [
  "GK", "LB", "CB", "RB",
  "DMF", "LMF", "CMF", "RMF",
  "AMF", "LWF", "SS", "RWF", "CF",
];

export const DRAFT_MULTI_COLS = ["Nation", "Position", "Playstyle"];
export const DRAFT_RANGE_COLS = ["Age", "Rating", "current_bid", "contract_wage"];

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function escapeAttr(s) {
  return escapeHtml(s).replace(/'/g, "&#39;");
}

function formatMoneyCompact(n) {
  const v = Number(n) || 0;
  if (v >= 1_000_000) {
    const m = v / 1_000_000;
    return `₿${m % 1 === 0 ? m.toFixed(0) : m.toFixed(1)}m`;
  }
  if (v >= 1_000) return `₿${Math.round(v / 1000)}k`;
  return `₿${Math.round(v).toLocaleString("en-GB")}`;
}

export function effectiveDraftWage(player, wageSettings) {
  const stored = Number(player?.contract_wage);
  if (Number.isFinite(stored) && stored > 0) return stored;
  return wageFromMarketValue(player?.market_value, "championship", wageSettings);
}

/**
 * @param {{
 *   rootId?: string,
 *   onChange?: () => void,
 * }} opts
 */
export function createDraftAdvancedFilterController(opts = {}) {
  const rootId = opts.rootId || "draftAdvancedFilters";
  const onChange = typeof opts.onChange === "function" ? opts.onChange : () => {};

  /** @type {Record<string, string[]>} */
  const multiSelected = {
    Nation: [],
    Position: [],
    Playstyle: [],
  };

  /** @type {Record<string, { value: string, label: string }[]>} */
  const multiOptions = {
    Nation: [],
    Position: [],
    Playstyle: [],
  };

  /** @type {Record<string, { min: number, max: number } | null>} */
  const rangeBounds = {
    Age: null,
    Rating: null,
    current_bid: null,
    contract_wage: null,
  };

  /** @type {Record<string, { min: number, max: number }>} */
  const rangeActive = {
    Age: { min: 0, max: 0 },
    Rating: { min: 0, max: 0 },
    current_bid: { min: 0, max: 0 },
    contract_wage: { min: 0, max: 0 },
  };

  let wired = false;
  let wageSettings = { superleague: 5, championship: 4 };

  function root() {
    return document.getElementById(rootId);
  }

  function sortMultiOptions(col, values) {
    const uniq = [...new Set(values.filter(Boolean).map(String))];
    if (col === "Position") {
      return uniq.sort((a, b) => {
        const ai = POSITION_ORDER.indexOf(a);
        const bi = POSITION_ORDER.indexOf(b);
        if (ai === -1 && bi === -1) return a.localeCompare(b);
        if (ai === -1) return 1;
        if (bi === -1) return -1;
        return ai - bi;
      });
    }
    return uniq.sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" }));
  }

  function closeAllMultiFilters() {
    root()
      ?.querySelectorAll(".multi-filter.open")
      .forEach((el) => el.classList.remove("open"));
  }

  function renderMultiFilterOptions(col, searchText = "") {
    const wrapper = root()?.querySelector(`.multi-filter[data-col="${col}"]`);
    const optionsEl = wrapper?.querySelector(".multi-filter-options");
    if (!optionsEl) return;

    const q = String(searchText || "").trim().toLowerCase();
    const opts = multiOptions[col] || [];
    const filtered = q
      ? opts.filter((o) => o.label.toLowerCase().includes(q))
      : opts;
    const selected = new Set(multiSelected[col] || []);

    if (!filtered.length) {
      optionsEl.innerHTML = `<div class="multi-filter-empty">No options</div>`;
      return;
    }

    optionsEl.innerHTML = filtered
      .map(
        (o) => `
      <label class="multi-filter-option">
        <input type="checkbox" value="${escapeAttr(o.value)}" ${
          selected.has(o.value) ? "checked" : ""
        }>
        <span>${escapeHtml(o.label)}</span>
      </label>`
      )
      .join("");
  }

  function updateMultiFilterDisplay(col) {
    const wrapper = root()?.querySelector(`.multi-filter[data-col="${col}"]`);
    const control = wrapper?.querySelector(".multi-filter-control");
    if (!control) return;
    const selected = multiSelected[col] || [];
    if (!selected.length) {
      control.textContent = "All";
      return;
    }
    if (selected.length <= 2) {
      control.textContent = selected.join(", ");
      return;
    }
    control.textContent = `${selected.length} selected`;
  }

  function refreshMultiFilterDisplays() {
    for (const col of DRAFT_MULTI_COLS) {
      renderMultiFilterOptions(
        col,
        root()?.querySelector(
          `.multi-filter[data-col="${col}"] .multi-filter-search`
        )?.value || ""
      );
      updateMultiFilterDisplay(col);
    }
  }

  function updateRangeReadout(col) {
    const el = document.getElementById(`draftRange-${col}`);
    const bounds = rangeBounds[col];
    const active = rangeActive[col];
    if (!el || !bounds || !active) {
      if (el) el.textContent = "(—)";
      return;
    }
    const fmt =
      col === "current_bid" || col === "contract_wage"
        ? formatMoneyCompact
        : (n) => String(n);
    el.textContent = `(${fmt(active.min)} – ${fmt(active.max)})`;
  }

  function updateRangeTrack(col) {
    const sliders = document.getElementById(`draftSliders-${col}`);
    const bounds = rangeBounds[col];
    const active = rangeActive[col];
    if (!sliders || !bounds || !active) return;
    const span = bounds.max - bounds.min;
    const pct = (v) => (span <= 0 ? 0 : ((v - bounds.min) / span) * 100);
    sliders.style.setProperty("--range-min", `${pct(active.min)}%`);
    sliders.style.setProperty("--range-max", `${pct(active.max)}%`);
  }

  function syncRangeInputs(col) {
    const bounds = rangeBounds[col];
    const active = rangeActive[col];
    const minEl = document.getElementById(`draftRange-${col}-min`);
    const maxEl = document.getElementById(`draftRange-${col}-max`);
    if (!bounds || !active || !minEl || !maxEl) return;

    minEl.disabled = false;
    maxEl.disabled = false;
    minEl.min = String(bounds.min);
    minEl.max = String(bounds.max);
    maxEl.min = String(bounds.min);
    maxEl.max = String(bounds.max);
    minEl.value = String(active.min);
    maxEl.value = String(active.max);
    updateRangeReadout(col);
    updateRangeTrack(col);
  }

  function isRangeNarrowed(col) {
    const bounds = rangeBounds[col];
    const active = rangeActive[col];
    if (!bounds || !active) return false;
    return active.min > bounds.min || active.max < bounds.max;
  }

  function setBound(col, values, fallbackMin, fallbackMax) {
    const b = values.length
      ? { min: Math.min(...values), max: Math.max(...values) }
      : { min: fallbackMin, max: fallbackMax };
    if (b.max < b.min) b.max = b.min;

    const prevBounds = rangeBounds[col];
    const prev = rangeActive[col];
    const prevWasFull =
      !prevBounds ||
      !prev ||
      (prev.min === prevBounds.min && prev.max === prevBounds.max) ||
      (prev.min === 0 && prev.max === 0 && !prevBounds);

    rangeBounds[col] = b;

    if (prevWasFull) {
      rangeActive[col] = { min: b.min, max: b.max };
    } else {
      let lo = Math.max(b.min, Math.min(b.max, prev.min));
      let hi = Math.max(b.min, Math.min(b.max, prev.max));
      if (lo > hi) [lo, hi] = [b.min, b.max];
      rangeActive[col] = { min: lo, max: hi };
    }
    syncRangeInputs(col);
  }

  function wire() {
    if (wired) return;
    wired = true;

    document.addEventListener("click", () => closeAllMultiFilters());

    root()?.querySelectorAll(".multi-filter").forEach((wrapper) => {
      const control = wrapper.querySelector(".multi-filter-control");
      const search = wrapper.querySelector(".multi-filter-search");
      const optionsEl = wrapper.querySelector(".multi-filter-options");

      control?.addEventListener("click", (e) => {
        e.stopPropagation();
        const wasOpen = wrapper.classList.contains("open");
        closeAllMultiFilters();
        if (!wasOpen) {
          wrapper.classList.add("open");
          search?.focus();
          search?.select();
        }
      });

      wrapper.querySelector(".multi-filter-panel")?.addEventListener("click", (e) => {
        e.stopPropagation();
      });

      search?.addEventListener("input", () => {
        const col = wrapper.dataset.col;
        renderMultiFilterOptions(col, search.value);
      });

      optionsEl?.addEventListener("change", (e) => {
        const input = e.target;
        if (!(input instanceof HTMLInputElement) || input.type !== "checkbox") return;
        const col = wrapper.dataset.col;
        const val = input.value;
        const set = new Set(multiSelected[col] || []);
        if (input.checked) set.add(val);
        else set.delete(val);
        multiSelected[col] = [...set];
        updateMultiFilterDisplay(col);
        onChange();
      });
    });

    for (const col of DRAFT_RANGE_COLS) {
      const minEl = document.getElementById(`draftRange-${col}-min`);
      const maxEl = document.getElementById(`draftRange-${col}-max`);
      if (!minEl || !maxEl) continue;

      const onInput = () => {
        let lo = Number(minEl.value);
        let hi = Number(maxEl.value);
        if (!Number.isFinite(lo) || !Number.isFinite(hi)) return;
        if (document.activeElement === minEl && lo > hi) {
          hi = lo;
          maxEl.value = String(hi);
        } else if (document.activeElement === maxEl && hi < lo) {
          lo = hi;
          minEl.value = String(lo);
        }
        rangeActive[col] = { min: lo, max: hi };
        updateRangeReadout(col);
        updateRangeTrack(col);
        onChange();
      };

      minEl.addEventListener("input", onInput);
      maxEl.addEventListener("input", onInput);
    }
  }

  function setWageSettings(settings) {
    if (settings) wageSettings = settings;
  }

  function rebuildFromRows(rows) {
    const nations = [];
    const positions = [];
    const playstyles = [];
    const ages = [];
    const ratings = [];
    const bids = [];
    const wages = [];

    for (const row of rows || []) {
      const player = row.player || {};
      if (player.Nation) nations.push(String(player.Nation));
      if (player.Position) positions.push(String(player.Position));
      if (player.Playstyle) playstyles.push(String(player.Playstyle));
      const age = Number(player.Age);
      if (Number.isFinite(age)) ages.push(age);
      const rating = Number(player.Rating);
      if (Number.isFinite(rating)) ratings.push(rating);
      const bid = Number(row.highestAmount);
      bids.push(Number.isFinite(bid) && bid > 0 ? bid : 0);
      const wage = effectiveDraftWage(player, wageSettings);
      if (Number.isFinite(wage) && wage >= 0) wages.push(wage);
    }

    multiOptions.Nation = sortMultiOptions("Nation", nations).map((v) => ({
      value: v,
      label: v,
    }));
    multiOptions.Position = sortMultiOptions("Position", positions).map((v) => ({
      value: v,
      label: v,
    }));
    multiOptions.Playstyle = sortMultiOptions("Playstyle", playstyles).map((v) => ({
      value: v,
      label: v,
    }));

    for (const col of DRAFT_MULTI_COLS) {
      const allowed = new Set(multiOptions[col].map((o) => o.value));
      multiSelected[col] = (multiSelected[col] || []).filter((v) => allowed.has(v));
    }

    setBound("Age", ages, 15, 45);
    setBound("Rating", ratings, 40, 99);
    setBound("current_bid", bids, 0, 1_000_000);
    setBound("contract_wage", wages, 0, 1_000_000);

    refreshMultiFilterDisplays();
  }

  function rowPasses(row) {
    const player = row?.player || {};

    for (const col of DRAFT_MULTI_COLS) {
      const selected = multiSelected[col] || [];
      if (!selected.length) continue;
      const val = String(player?.[col] ?? "");
      if (!selected.includes(val)) return false;
    }

    if (isRangeNarrowed("Age")) {
      const age = Number(player.Age);
      if (!Number.isFinite(age)) return false;
      if (age < rangeActive.Age.min || age > rangeActive.Age.max) return false;
    }

    if (isRangeNarrowed("Rating")) {
      const rating = Number(player.Rating);
      if (!Number.isFinite(rating)) return false;
      if (rating < rangeActive.Rating.min || rating > rangeActive.Rating.max) {
        return false;
      }
    }

    if (isRangeNarrowed("current_bid")) {
      const bid = Number(row.highestAmount);
      const v = Number.isFinite(bid) && bid > 0 ? bid : 0;
      if (v < rangeActive.current_bid.min || v > rangeActive.current_bid.max) {
        return false;
      }
    }

    if (isRangeNarrowed("contract_wage")) {
      const wage = effectiveDraftWage(player, wageSettings);
      if (!Number.isFinite(wage)) return false;
      if (
        wage < rangeActive.contract_wage.min ||
        wage > rangeActive.contract_wage.max
      ) {
        return false;
      }
    }

    return true;
  }

  function isActive() {
    for (const col of DRAFT_MULTI_COLS) {
      if ((multiSelected[col] || []).length) return true;
    }
    for (const col of DRAFT_RANGE_COLS) {
      if (isRangeNarrowed(col)) return true;
    }
    return false;
  }

  function getPersistState() {
    return {
      multi: {
        Nation: [...multiSelected.Nation],
        Position: [...multiSelected.Position],
        Playstyle: [...multiSelected.Playstyle],
      },
      ranges: {
        Age: { ...rangeActive.Age },
        Rating: { ...rangeActive.Rating },
        current_bid: { ...rangeActive.current_bid },
        contract_wage: { ...rangeActive.contract_wage },
      },
    };
  }

  function restorePersistState(saved) {
    if (!saved || typeof saved !== "object") return;
    if (saved.multi) {
      for (const col of DRAFT_MULTI_COLS) {
        if (Array.isArray(saved.multi[col])) {
          multiSelected[col] = saved.multi[col].map(String);
        }
      }
    }
    if (saved.ranges) {
      for (const col of DRAFT_RANGE_COLS) {
        const r = saved.ranges[col];
        if (r && Number.isFinite(Number(r.min)) && Number.isFinite(Number(r.max))) {
          rangeActive[col] = { min: Number(r.min), max: Number(r.max) };
        }
      }
    }
    refreshMultiFilterDisplays();
    for (const col of DRAFT_RANGE_COLS) syncRangeInputs(col);
  }

  function clear() {
    for (const col of DRAFT_MULTI_COLS) multiSelected[col] = [];
    for (const col of DRAFT_RANGE_COLS) {
      const b = rangeBounds[col];
      if (b) rangeActive[col] = { min: b.min, max: b.max };
    }
    refreshMultiFilterDisplays();
    for (const col of DRAFT_RANGE_COLS) syncRangeInputs(col);
  }

  function setMultiSelected(col, values) {
    if (!DRAFT_MULTI_COLS.includes(col)) return;
    multiSelected[col] = [...new Set((values || []).map(String))];
    refreshMultiFilterDisplays();
  }

  function getMultiOptions(col) {
    return multiOptions[col] || [];
  }

  return {
    wire,
    setWageSettings,
    rebuildFromRows,
    rowPasses,
    isActive,
    getPersistState,
    restorePersistState,
    clear,
    setMultiSelected,
    getMultiOptions,
  };
}
