import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const POSITION_ORDER = [
  "GK", "LB", "CB", "RB",
  "DMF", "LMF", "CMF", "RMF",
  "AMF", "LWF", "SS", "RWF", "CF",
];

const DROPDOWN_COLS = ["Position", "Nation", "Playstyle"];
const RANGE_COLS = ["Age", "Rating", "market_value"];
const MV_STEP = 1_000_000;

const FILTER_OPTIONS = {
  Position: [],
  Nation: [],
  Playstyle: [],
};

const RANGE_BOUNDS = {
  Age: { min: 15, max: 45 },
  Rating: { min: 40, max: 99 },
  market_value: { min: 0, max: 200_000_000 },
};

const RANGE_ACTIVE = {
  Age: { min: 15, max: 45 },
  Rating: { min: 40, max: 99 },
  market_value: { min: 0, max: 200_000_000 },
};

const CURRENT_FILTERS = {
  Position: [],
  Nation: [],
  Playstyle: [],
};

let suggestTimer = null;
let suggestItems = [];
let suggestIndex = -1;

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function formatMoney(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `₿ ${v.toLocaleString("en-GB")}`;
}

function snapMv(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return 0;
  return Math.round(v / MV_STEP) * MV_STEP;
}

function rangeLabel(col) {
  if (col === "market_value") return "Market value";
  return col;
}

function isRangeActive(col) {
  const b = RANGE_BOUNDS[col];
  const a = RANGE_ACTIVE[col];
  return a.min > b.min || a.max < b.max;
}

function formatRangeBracket(col) {
  const a = RANGE_ACTIVE[col];
  if (col === "market_value") return `(${formatMoney(a.min)}-${formatMoney(a.max)})`;
  return `(${a.min}-${a.max})`;
}

function updateRangeUi(col) {
  const a = RANGE_ACTIVE[col];
  const b = RANGE_BOUNDS[col];
  const readout = document.getElementById(`filter-${col}-range`);
  if (readout) readout.textContent = formatRangeBracket(col);
  const wrap = document.getElementById(`filter-${col}-sliders`);
  if (wrap) {
    const span = Math.max(b.max - b.min, 1);
    wrap.style.setProperty("--range-min", `${((a.min - b.min) / span) * 100}%`);
    wrap.style.setProperty("--range-max", `${((a.max - b.min) / span) * 100}%`);
  }
}

function multiDisplayText(col) {
  const vals = CURRENT_FILTERS[col] || [];
  if (!vals.length) return "All";
  if (vals.length === 1) return vals[0];
  return `${vals.length} selected`;
}

function updateMultiDisplay(col) {
  const el = document.getElementById(`filter-${col}-display`);
  if (el) el.textContent = multiDisplayText(col);
}

function closeAllMultiFilters() {
  document.querySelectorAll(".multi-filter.open").forEach((el) => el.classList.remove("open"));
}

function renderMultiOptions(col, query = "") {
  const panel = document.querySelector(`.multi-filter[data-col="${col}"] .multi-filter-options`);
  if (!panel) return;
  const q = String(query || "").trim().toLowerCase();
  let opts = FILTER_OPTIONS[col] || [];
  if (q) opts = opts.filter((v) => String(v).toLowerCase().includes(q));
  if (!opts.length) {
    panel.innerHTML = `<div class="multi-filter-empty">No matches</div>`;
    return;
  }
  const selected = new Set(CURRENT_FILTERS[col] || []);
  panel.innerHTML = opts
    .map((v) => {
      const id = `mf-${col}-${escapeHtml(v).replace(/\W+/g, "_")}`;
      return `<label class="multi-filter-option">
        <input type="checkbox" data-col="${escapeHtml(col)}" value="${escapeHtml(v)}" ${
          selected.has(v) ? "checked" : ""
        } id="${id}">
        <span>${escapeHtml(v)}</span>
      </label>`;
    })
    .join("");

  panel.querySelectorAll("input[type=checkbox]").forEach((cb) => {
    cb.addEventListener("change", () => {
      const c = cb.getAttribute("data-col");
      const val = cb.value;
      const set = new Set(CURRENT_FILTERS[c] || []);
      if (cb.checked) set.add(val);
      else set.delete(val);
      CURRENT_FILTERS[c] = [...set];
      updateMultiDisplay(c);
    });
  });
}

function buildFiltersHtml() {
  const row1 = document.getElementById("filters-row-1");
  const row2 = document.getElementById("filters-row-2");
  if (!row1 || !row2) return;

  const multiHtml = (col) => `
    <div class="multi-filter" data-col="${escapeHtml(col)}">
      <div class="multi-filter-label">${escapeHtml(col)}</div>
      <div class="multi-filter-control" id="filter-${escapeHtml(col)}-display">All</div>
      <div class="multi-filter-panel" id="filter-${escapeHtml(col)}-panel">
        <input type="text" class="multi-filter-search" autocomplete="off" aria-label="Search ${escapeHtml(col)}">
        <div class="multi-filter-options"></div>
      </div>
    </div>`;

  const rangeHtml = (col) => {
    const b = RANGE_BOUNDS[col];
    const a = RANGE_ACTIVE[col];
    const step = col === "market_value" ? MV_STEP : 1;
    return `
      <div class="range-filter" data-col="${escapeHtml(col)}">
        <div class="range-filter-label">${escapeHtml(rangeLabel(col))}
          <span class="range-filter-range" id="filter-${escapeHtml(col)}-range">${formatRangeBracket(col)}</span>
        </div>
        <div class="range-filter-sliders" id="filter-${escapeHtml(col)}-sliders">
          <div class="range-filter-track"></div>
          <input type="range" class="range-filter-min" id="filter-${escapeHtml(col)}-min"
            min="${b.min}" max="${b.max}" value="${a.min}" step="${step}" aria-label="${escapeHtml(rangeLabel(col))} minimum">
          <input type="range" class="range-filter-max" id="filter-${escapeHtml(col)}-max"
            min="${b.min}" max="${b.max}" value="${a.max}" step="${step}" aria-label="${escapeHtml(rangeLabel(col))} maximum">
        </div>
      </div>`;
  };

  row1.innerHTML = [
    multiHtml("Position"),
    multiHtml("Nation"),
    rangeHtml("Age"),
    rangeHtml("Rating"),
    multiHtml("Playstyle"),
  ].join("");

  row2.innerHTML = `
    <div class="name-typeahead">
      <label for="searchQuery">Name / Konami ID</label>
      <input id="searchQuery" type="text" placeholder="Start typing a name…" autocomplete="off">
      <div id="nameSuggest" class="name-suggest" role="listbox"></div>
    </div>
    ${rangeHtml("market_value")}
  `;
}

function wireFilters() {
  document.addEventListener("click", () => {
    closeAllMultiFilters();
    closeSuggest();
  });

  document.querySelectorAll(".multi-filter").forEach((wrap) => {
    const col = wrap.getAttribute("data-col");
    const control = wrap.querySelector(".multi-filter-control");
    const search = wrap.querySelector(".multi-filter-search");
    control?.addEventListener("click", (e) => {
      e.stopPropagation();
      const open = wrap.classList.contains("open");
      closeAllMultiFilters();
      if (!open) {
        wrap.classList.add("open");
        renderMultiOptions(col, search?.value || "");
        search?.focus();
      }
    });
    wrap.querySelector(".multi-filter-panel")?.addEventListener("click", (e) => e.stopPropagation());
    search?.addEventListener("input", () => renderMultiOptions(col, search.value));
    search?.addEventListener("click", (e) => e.stopPropagation());
  });

  for (const col of RANGE_COLS) {
    const minEl = document.getElementById(`filter-${col}-min`);
    const maxEl = document.getElementById(`filter-${col}-max`);
    if (!minEl || !maxEl) continue;

    const sync = (which) => {
      let lo = Number(minEl.value);
      let hi = Number(maxEl.value);
      if (col === "market_value") {
        lo = snapMv(lo);
        hi = snapMv(hi);
      }
      if (lo > hi) {
        if (which === "min") hi = lo;
        else lo = hi;
      }
      RANGE_ACTIVE[col] = { min: lo, max: hi };
      minEl.value = String(lo);
      maxEl.value = String(hi);
      updateRangeUi(col);
    };

    minEl.addEventListener("input", () => sync("min"));
    maxEl.addEventListener("input", () => sync("max"));
    updateRangeUi(col);
  }

  const nameInput = document.getElementById("searchQuery");
  const suggest = document.getElementById("nameSuggest");
  nameInput?.addEventListener("click", (e) => e.stopPropagation());
  suggest?.addEventListener("click", (e) => e.stopPropagation());

  nameInput?.addEventListener("input", () => {
    clearTimeout(suggestTimer);
    suggestTimer = setTimeout(() => loadSuggestions(nameInput.value.trim()), 220);
  });

  nameInput?.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      if (suggestIndex >= 0 && suggestItems[suggestIndex]) {
        pickSuggestion(suggestItems[suggestIndex]);
      } else {
        closeSuggest();
        runSearch();
      }
      return;
    }
    if (e.key === "ArrowDown") {
      e.preventDefault();
      moveSuggest(1);
      return;
    }
    if (e.key === "ArrowUp") {
      e.preventDefault();
      moveSuggest(-1);
      return;
    }
    if (e.key === "Escape") closeSuggest();
  });
}

function closeSuggest() {
  const el = document.getElementById("nameSuggest");
  if (el) {
    el.classList.remove("open");
    el.innerHTML = "";
  }
  suggestItems = [];
  suggestIndex = -1;
}

function moveSuggest(delta) {
  if (!suggestItems.length) return;
  suggestIndex = (suggestIndex + delta + suggestItems.length) % suggestItems.length;
  const el = document.getElementById("nameSuggest");
  if (!el) return;
  el.querySelectorAll(".name-suggest-item").forEach((node, i) => {
    node.classList.toggle("active", i === suggestIndex);
  });
}

function pickSuggestion(row) {
  const input = document.getElementById("searchQuery");
  if (input) input.value = row.player_name || row.player_id || "";
  closeSuggest();
  renderResults([row], `Selected ${row.player_name || row.player_id}`);
}

async function loadSuggestions(q) {
  const el = document.getElementById("nameSuggest");
  if (!el) return;
  if (!q || q.length < 2) {
    closeSuggest();
    return;
  }
  const params = buildSearchParams(q, 12);
  const { data, error } = await supabase.rpc("admin_auction_search_players_for_exclusion", params);
  if (error) {
    el.classList.add("open");
    el.innerHTML = `<div class="name-suggest-empty">${escapeHtml(error.message)}</div>`;
    return;
  }
  suggestItems = data || [];
  suggestIndex = -1;
  if (!suggestItems.length) {
    el.classList.add("open");
    el.innerHTML = `<div class="name-suggest-empty">No free agents matched</div>`;
    return;
  }
  el.classList.add("open");
  el.innerHTML = suggestItems
    .map(
      (r, i) => `
    <div class="name-suggest-item" data-idx="${i}" role="option">
      <b>${escapeHtml(r.player_name)}</b>
      <div class="meta">${escapeHtml(r.player_position || "—")} · ${escapeHtml(r.nation || "—")} · Age ${escapeHtml(
        r.age ?? "—"
      )} · OVR ${escapeHtml(r.rating ?? "—")} · ${formatMoney(r.market_value)}${
        r.already_excluded ? " · Reserved" : ""
      }</div>
    </div>`
    )
    .join("");

  el.querySelectorAll(".name-suggest-item").forEach((node) => {
    node.addEventListener("mousedown", (e) => {
      e.preventDefault();
      const idx = Number(node.getAttribute("data-idx"));
      if (suggestItems[idx]) pickSuggestion(suggestItems[idx]);
    });
  });
}

function buildSearchParams(query, limit = 40) {
  const filters = {};
  if (CURRENT_FILTERS.Position?.length) filters.positions = CURRENT_FILTERS.Position;
  if (CURRENT_FILTERS.Nation?.length) filters.nations = CURRENT_FILTERS.Nation;
  if (CURRENT_FILTERS.Playstyle?.length) filters.playstyles = CURRENT_FILTERS.Playstyle;
  if (isRangeActive("Age")) {
    filters.age_min = RANGE_ACTIVE.Age.min;
    filters.age_max = RANGE_ACTIVE.Age.max;
  }
  if (isRangeActive("Rating")) {
    filters.rating_min = RANGE_ACTIVE.Rating.min;
    filters.rating_max = RANGE_ACTIVE.Rating.max;
  }
  if (isRangeActive("market_value")) {
    filters.mv_min = RANGE_ACTIVE.market_value.min;
    filters.mv_max = RANGE_ACTIVE.market_value.max;
  }
  return {
    p_query: query || "",
    p_limit: limit,
    p_filters: filters,
  };
}

async function loadFilterOptions() {
  const distinct = async (col) => {
    const { data, error } = await supabase.from("Players").select(col, { distinct: true });
    if (error) {
      console.warn(`Could not load ${col} options`, error);
      return [];
    }
    const set = new Set();
    for (const row of data || []) {
      const v = row?.[col];
      if (v == null) continue;
      const s = String(v).trim();
      if (s) set.add(s);
    }
    return [...set];
  };

  const [positions, nations, playstyles, ages, ratings, mvs] = await Promise.all([
    distinct("Position"),
    distinct("Nation"),
    distinct("Playstyle"),
    distinct("Age"),
    distinct("Rating"),
    distinct("market_value"),
  ]);

  FILTER_OPTIONS.Position = positions.sort((a, b) => {
    const ia = POSITION_ORDER.indexOf(a);
    const ib = POSITION_ORDER.indexOf(b);
    if (ia >= 0 && ib >= 0) return ia - ib;
    if (ia >= 0) return -1;
    if (ib >= 0) return 1;
    return a.localeCompare(b);
  });
  FILTER_OPTIONS.Nation = nations.sort((a, b) => a.localeCompare(b));
  FILTER_OPTIONS.Playstyle = playstyles.sort((a, b) => a.localeCompare(b));

  const ageNums = ages.map(Number).filter((n) => Number.isFinite(n));
  const ratingNums = ratings.map(Number).filter((n) => Number.isFinite(n));
  const mvNums = mvs.map(Number).filter((n) => Number.isFinite(n) && n >= 0);

  if (ageNums.length) {
    RANGE_BOUNDS.Age = { min: Math.min(...ageNums), max: Math.max(...ageNums) };
    RANGE_ACTIVE.Age = { ...RANGE_BOUNDS.Age };
  }
  if (ratingNums.length) {
    RANGE_BOUNDS.Rating = { min: Math.min(...ratingNums), max: Math.max(...ratingNums) };
    RANGE_ACTIVE.Rating = { ...RANGE_BOUNDS.Rating };
  }
  if (mvNums.length) {
    const mn = snapMv(Math.min(...mvNums));
    const mx = snapMv(Math.max(...mvNums));
    RANGE_BOUNDS.market_value = { min: mn, max: Math.max(mx, mn + MV_STEP) };
    RANGE_ACTIVE.market_value = { ...RANGE_BOUNDS.market_value };
  }
}

function clearFilters() {
  CURRENT_FILTERS.Position = [];
  CURRENT_FILTERS.Nation = [];
  CURRENT_FILTERS.Playstyle = [];
  for (const col of RANGE_COLS) {
    RANGE_ACTIVE[col] = { ...RANGE_BOUNDS[col] };
    const minEl = document.getElementById(`filter-${col}-min`);
    const maxEl = document.getElementById(`filter-${col}-max`);
    if (minEl) minEl.value = String(RANGE_ACTIVE[col].min);
    if (maxEl) maxEl.value = String(RANGE_ACTIVE[col].max);
    updateRangeUi(col);
  }
  DROPDOWN_COLS.forEach(updateMultiDisplay);
  const input = document.getElementById("searchQuery");
  if (input) input.value = "";
  closeSuggest();
  const wrap = document.getElementById("searchResults");
  if (wrap) wrap.innerHTML = "";
  setStatus("searchStatus", "Filters cleared.");
}

function renderResults(data, statusMsg) {
  const wrap = document.getElementById("searchResults");
  if (statusMsg) setStatus("searchStatus", statusMsg, true);
  if (!wrap) return;
  if (!data?.length) {
    wrap.innerHTML = `<p class="muted">No free agents matched.</p>`;
    return;
  }
  wrap.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Player</th><th>Pos</th><th>Nation</th><th>Age</th><th>OVR</th><th>MV</th><th></th>
        </tr>
      </thead>
      <tbody>
        ${data
          .map(
            (r) => `
          <tr>
            <td>
              <b>${escapeHtml(r.player_name)}</b><br>
              <small class="muted">${escapeHtml(r.player_id)}</small>
            </td>
            <td>${escapeHtml(r.player_position || "—")}</td>
            <td>${escapeHtml(r.nation || "—")}</td>
            <td>${escapeHtml(r.age ?? "—")}</td>
            <td>${escapeHtml(r.rating ?? "—")}</td>
            <td>${formatMoney(r.market_value)}</td>
            <td>
              ${
                r.already_excluded
                  ? `<span class="muted">Reserved</span>`
                  : `<button type="button" class="button" data-reserve="${escapeHtml(r.player_id)}">Reserve</button>`
              }
            </td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;

  wrap.querySelectorAll("[data-reserve]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = btn.getAttribute("data-reserve");
      const { error: err } = await supabase.rpc("admin_auction_exclude_player", {
        p_player_id: id,
      });
      setStatus("searchStatus", err ? err.message : `Reserved ${id}`, !err);
      await loadReserved();
      await runSearch();
    });
  });
}

async function runSearch() {
  closeSuggest();
  const q = document.getElementById("searchQuery")?.value?.trim() || "";
  setStatus("searchStatus", "Searching…");
  const { data, error } = await supabase.rpc(
    "admin_auction_search_players_for_exclusion",
    buildSearchParams(q, 40)
  );
  if (error) {
    setStatus(
      "searchStatus",
      error.message + " — run auction_exclusions_search_filters.sql",
      false
    );
    const wrap = document.getElementById("searchResults");
    if (wrap) wrap.innerHTML = "";
    return;
  }
  renderResults(data, `${(data || []).length} result(s).`);
}

async function loadReserved() {
  const { data, error } = await supabase.rpc("admin_auction_exclusion_list");
  const body = document.getElementById("reservedBody");
  if (error) {
    setStatus("listStatus", error.message + " — run auction_exclusions.sql", false);
    if (body) body.innerHTML = `<tr><td colspan="6" class="muted">Unavailable</td></tr>`;
    return;
  }
  setStatus("listStatus", `${(data || []).length} reserved.`, true);
  if (!body) return;
  if (!data?.length) {
    body.innerHTML = `<tr><td colspan="6" class="muted">No reserved players.</td></tr>`;
    return;
  }
  body.innerHTML = data
    .map(
      (r) => `
    <tr>
      <td>
        <b>${escapeHtml(r.player_name || r.player_id)}</b><br>
        <small class="muted">${escapeHtml(r.player_id)}</small>
      </td>
      <td>${escapeHtml(r.player_position || r.position || "—")}</td>
      <td>${escapeHtml(r.rating ?? "—")}</td>
      <td>${formatMoney(r.market_value)}</td>
      <td>${r.reserved_at ? new Date(r.reserved_at).toLocaleString("en-GB") : "—"}</td>
      <td><button type="button" class="button secondary" data-unlock="${escapeHtml(r.player_id)}">Unlock</button></td>
    </tr>`
    )
    .join("");

  body.querySelectorAll("[data-unlock]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = btn.getAttribute("data-unlock");
      const { error: err } = await supabase.rpc("admin_auction_unexclude_player", {
        p_player_id: id,
      });
      setStatus("listStatus", err ? err.message : `Unlocked ${id}`, !err);
      await loadReserved();
    });
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  setStatus("searchStatus", "Loading filters…");
  await loadFilterOptions();
  buildFiltersHtml();
  wireFilters();
  DROPDOWN_COLS.forEach((col) => {
    updateMultiDisplay(col);
    renderMultiOptions(col);
  });

  document.getElementById("searchBtn")?.addEventListener("click", runSearch);
  document.getElementById("clearFiltersBtn")?.addEventListener("click", clearFilters);
  document.getElementById("reloadBtn")?.addEventListener("click", loadReserved);

  setStatus("searchStatus", "Ready — type a name or set filters, then Search.");
  await loadReserved();
});
