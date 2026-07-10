import {
  supabase,
  initGlobal,
  getManagerDraftEnabled,
  getUKNow,
  refreshDraftBiddingOpen,
  getDraftPhaseOptions,
} from "./global.js";
import {
  isManagerGpdbFreeAgentOfferAllowed,
  getManagerDraftEffectivePhase,
} from "./draft_timeline.js";
import {
  getClubManagerVacancy,
  fetchClubSackedManagerIds,
} from "./manager_draft_engine.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";

const TABLE_COLUMNS = [
  { key: "name", label: "Manager" },
  { key: "rating", label: "Rating" },
  { key: "expectancy", label: "Expectation" },
  { key: "draft_action", label: "Draft" },
  { key: "contracted_display", label: "Contracted Club" },
  { key: "nation", label: "Nation" },
  { key: "possession", label: "Possession" },
  { key: "quick_counter", label: "Quick Counter" },
  { key: "long_ball_counter", label: "Long Ball Counter" },
  { key: "out_wide", label: "Out Wide" },
  { key: "long_ball", label: "Long Ball" },
  { key: "age", label: "Age" },
  { key: "market_value", label: "Market Value" },
];

const DROPDOWN_FILTER_COLUMNS = [
  { key: "nation", label: "Nation" },
  { key: "contracted_display", label: "Club" },
];
const RANGE_FILTER_COLUMNS = [
  { key: "age", label: "Age" },
  { key: "rating", label: "Rating" },
  { key: "market_value", label: "Market Value" },
];

let PAGE_SIZE = 100;
let CURRENT_PAGE = 1;
let TOTAL_ROWS = 0;
let CURRENT_SORT_COLUMN = "rating";
let CURRENT_SORT_DIR = "desc";
let CURRENT_FILTERS = {};
let FREE_AGENTS_ONLY = false;
let FILTER_OPTION_CACHE = {};
let RANGE_BOUNDS = {};
let RANGE_ACTIVE = {};
let allRowsCache = [];
let managerDraftOn = false;
let draftStartTime = null;
let viewerClubShort = null;
let viewerClubHasManager = false;
let viewerSackedManagerIds = new Set();
let multiFilterClickWired = false;

function parseMoneyInput(value) {
  if (!value) return null;
  const n = Number(String(value).replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

function rangeStep(col) {
  if (col !== "market_value") return 1;
  const bounds = RANGE_BOUNDS[col];
  if (!bounds) return 100000;
  const span = Math.max(bounds.max - bounds.min, 1);
  // ~100 steps across the range, snapped to nice money increments
  const rough = span / 100;
  if (rough <= 100000) return 100000;
  if (rough <= 250000) return 250000;
  if (rough <= 500000) return 500000;
  if (rough <= 1000000) return 1000000;
  return Math.ceil(rough / 1000000) * 1000000;
}

function snapRangeValue(col, n) {
  if (col !== "market_value") return Math.round(n);
  const step = rangeStep(col);
  const bounds = RANGE_BOUNDS[col];
  let v = Math.round(n / step) * step;
  if (bounds) {
    v = Math.max(bounds.min, Math.min(bounds.max, v));
  }
  return v;
}

function normalizeSearchText(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function displayClub(contracted) {
  const raw = String(contracted || "").trim();
  if (!raw || raw === "FREE AGENT") return "FREE AGENT";
  return fullClubName(raw) || raw;
}

function formatExpectancy(row) {
  const sl = row.target_superleague;
  const ca = row.target_championship_a;
  const cb = row.target_championship_b;
  const champ =
    ca && cb && ca === cb
      ? `Champ: ${ca}`
      : [ca && `CA: ${ca}`, cb && `CB: ${cb}`].filter(Boolean).join(" · ");

  const parts = [sl && `SL: ${sl}`, champ].filter(Boolean);
  if (!parts.length) return "—";
  return `<span class="mgdb-exp-targets">${parts.join(" · ")}</span>`;
}

function buildTableHead() {
  const head = document.getElementById("tableHead");
  if (!head) return;
  head.innerHTML = `<tr>${TABLE_COLUMNS.map((col) => {
    const sortClass =
      CURRENT_SORT_COLUMN === col.key
        ? CURRENT_SORT_DIR === "asc"
          ? "sort-asc"
          : "sort-desc"
        : "";
    return `<th data-col="${col.key}" class="${sortClass}">${col.label}</th>`;
  }).join("")}</tr>`;

  head.querySelectorAll("th").forEach((th) => {
    th.addEventListener("click", () => {
      const col = th.dataset.col;
      if (col === "expectancy" || col === "draft_action") return;
      if (CURRENT_SORT_COLUMN === col) {
        CURRENT_SORT_DIR = CURRENT_SORT_DIR === "asc" ? "desc" : "asc";
      } else {
        CURRENT_SORT_COLUMN = col;
        CURRENT_SORT_DIR = col === "name" || col === "nation" ? "asc" : "desc";
      }
      renderPage();
    });
  });
}

function sortRows(rows) {
  const asc = CURRENT_SORT_DIR === "asc";
  const col = CURRENT_SORT_COLUMN;
  return [...rows].sort((a, b) => {
    const av = a[col];
    const bv = b[col];
    if (col === "market_value" || col === "age" || col === "rating" || col.includes("counter") || col === "possession" || col === "out_wide" || col === "long_ball") {
      const an = Number(av) || 0;
      const bn = Number(bv) || 0;
      return asc ? an - bn : bn - an;
    }
    return asc
      ? String(av ?? "").localeCompare(String(bv ?? ""))
      : String(bv ?? "").localeCompare(String(av ?? ""));
  });
}

function applyFilters(rows) {
  let filtered = rows;

  const nameQ = normalizeSearchText(CURRENT_FILTERS.name);
  if (nameQ) {
    filtered = filtered.filter((r) =>
      normalizeSearchText(r.name).includes(nameQ)
    );
  }

  for (const { key } of DROPDOWN_FILTER_COLUMNS) {
    const values = CURRENT_FILTERS[key];
    if (!Array.isArray(values) || !values.length) continue;
    filtered = filtered.filter((r) => values.includes(String(r[key] ?? "")));
  }

  for (const { key } of RANGE_FILTER_COLUMNS) {
    const bounds = RANGE_BOUNDS[key];
    const active = RANGE_ACTIVE[key];
    if (!bounds || !active) continue;
    const fullRange = active.min <= bounds.min && active.max >= bounds.max;
    if (fullRange) continue;
    filtered = filtered.filter((r) => {
      const n = Number(r[key]);
      if (!Number.isFinite(n)) return false;
      return n >= active.min && n <= active.max;
    });
  }

  if (FREE_AGENTS_ONLY) {
    filtered = filtered.filter(
      (r) =>
        !r.contracted_club ||
        !String(r.contracted_club).trim() ||
        String(r.contracted_display) === "FREE AGENT"
    );
  }

  return filtered;
}

function renderPage() {
  const filtered = sortRows(applyFilters(allRowsCache));
  TOTAL_ROWS = filtered.length;
  const totalPages = Math.max(1, Math.ceil(TOTAL_ROWS / PAGE_SIZE));
  if (CURRENT_PAGE > totalPages) CURRENT_PAGE = totalPages;

  const from = (CURRENT_PAGE - 1) * PAGE_SIZE;
  const pageRows = filtered.slice(from, from + PAGE_SIZE);

  const body = document.getElementById("tableBody");
  if (!body) return;

  body.innerHTML = pageRows
    .map((row) => {
      const cells = TABLE_COLUMNS.map((col) => {
        if (col.key === "draft_action") {
          const isFa =
            !row.contracted_club || String(row.contracted_display) === "FREE AGENT";
          const phaseOpts = getDraftPhaseOptions();
          const now = getUKNow();
          const phase = draftStartTime
            ? getManagerDraftEffectivePhase(now, draftStartTime, phaseOpts)
            : "ended";
          const canOpen =
            managerDraftOn &&
            isFa &&
            draftStartTime &&
            isManagerGpdbFreeAgentOfferAllowed(now, draftStartTime, phaseOpts);
          if (!managerDraftOn) return `<td>—</td>`;
          if (!isFa) return `<td>—</td>`;
          if (!viewerClubShort) {
            return `<td style="color:#888;font-size:11px;">No club</td>`;
          }
          if (viewerClubHasManager) {
            const clubLabel = fullClubName(viewerClubShort) || viewerClubShort;
            return `<td style="color:#888;font-size:11px;" title="Sack your current manager first">${clubLabel}: have a contracted Manager</td>`;
          }
          if (viewerSackedManagerIds.has(Number(row.id))) {
            return `<td style="color:#f88;font-size:11px;" title="You sacked this manager earlier this season">Sacked — closed</td>`;
          }
          if (canOpen) {
            return `<td><a href="manager_draftauction_manager.html?manager=${row.id}" class="button" style="padding:4px 8px;font-size:11px;">Open</a></td>`;
          }
          if (phase === "random_locked") {
            return `<td style="color:#888;font-size:11px;">Locked</td>`;
          }
          return `<td><a href="manager_draftauction.html" style="color:#ff9900;font-size:11px;">Auction</a></td>`;
        }
        let val = row[col.key];
        if (col.key === "contracted_display") val = displayClub(val);
        if (col.key === "market_value") {
          return `<td class="money">${formatMoney(val)}</td>`;
        }
        if (col.key === "expectancy") {
          return `<td class="mgdb-expectancy">${formatExpectancy(row)}</td>`;
        }
        if (col.key === "rating") {
          return `<td>${val ?? "—"}</td>`;
        }
        if (col.key === "name") {
          const href = `manager_career.html?manager=${encodeURIComponent(row.id)}`;
          return `<td><a href="${href}" class="gpsl-link" style="color:#ffcc66;text-decoration:none;">${val ?? "—"}</a></td>`;
        }
        return `<td>${val ?? "—"}</td>`;
      }).join("");
      return `<tr>${cells}</tr>`;
    })
    .join("");

  const pagination = document.getElementById("pagination");
  if (pagination) {
    pagination.innerHTML = `
      Page ${CURRENT_PAGE} of ${totalPages} (${TOTAL_ROWS} managers)
      <button class="button" id="prevPage" ${CURRENT_PAGE <= 1 ? "disabled" : ""}>Prev</button>
      <button class="button" id="nextPage" ${CURRENT_PAGE >= totalPages ? "disabled" : ""}>Next</button>
    `;
    document.getElementById("prevPage")?.addEventListener("click", () => {
      if (CURRENT_PAGE > 1) {
        CURRENT_PAGE -= 1;
        renderPage();
      }
    });
    document.getElementById("nextPage")?.addEventListener("click", () => {
      if (CURRENT_PAGE < totalPages) {
        CURRENT_PAGE += 1;
        renderPage();
      }
    });
  }

  buildTableHead();
}

async function loadViewerClub() {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return;

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();

  viewerClubShort = club?.ShortName ?? null;
  if (!viewerClubShort) {
    viewerClubHasManager = false;
    return;
  }

  const vacancy = await getClubManagerVacancy(viewerClubShort);
  viewerClubHasManager = !vacancy.vacant;

  const sacked = await fetchClubSackedManagerIds({ force: true });
  viewerSackedManagerIds = new Set((sacked || []).map((id) => Number(id)));
}

function computeRangeBounds() {
  RANGE_BOUNDS = {};
  RANGE_ACTIVE = {};
  for (const { key } of RANGE_FILTER_COLUMNS) {
    const nums = allRowsCache
      .map((r) => Number(r[key]))
      .filter((n) => Number.isFinite(n));
    if (!nums.length) {
      RANGE_BOUNDS[key] = { min: 0, max: 0 };
      RANGE_ACTIVE[key] = { min: 0, max: 0 };
      continue;
    }
    const min = Math.min(...nums);
    const max = Math.max(...nums);
    RANGE_BOUNDS[key] = { min, max };
    RANGE_ACTIVE[key] = { min, max };
  }
}

function closeAllMultiFilters() {
  document.querySelectorAll("#filters .multi-filter.open").forEach((el) => {
    el.classList.remove("open");
  });
}

function textMatchesSearch(label, query) {
  const q = normalizeSearchText(query);
  if (!q) return true;
  return normalizeSearchText(label).includes(q);
}

function renderMultiFilterOptions(col, searchQuery = "") {
  const panel = document.getElementById(`filter-${col}-panel`);
  const container = panel?.querySelector(".multi-filter-options");
  if (!container) return;

  const options = FILTER_OPTION_CACHE[col] || [];
  const checkedBefore = new Set(
    Array.isArray(CURRENT_FILTERS[col]) ? CURRENT_FILTERS[col] : []
  );
  container.querySelectorAll("input[type='checkbox']:checked").forEach((cb) => {
    checkedBefore.add(cb.value);
  });

  container.innerHTML = "";
  let matchCount = 0;

  options.forEach((opt) => {
    if (!textMatchesSearch(opt.label, searchQuery)) return;
    matchCount += 1;

    const optionDiv = document.createElement("div");
    optionDiv.className = "multi-filter-option";

    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.value = opt.value;
    cb.setAttribute("data-label", opt.label);
    cb.checked = checkedBefore.has(opt.value);
    cb.addEventListener("change", () => updateMultiFilterDisplay(col));

    const span = document.createElement("span");
    span.textContent = opt.label;

    optionDiv.appendChild(cb);
    optionDiv.appendChild(span);
    container.appendChild(optionDiv);
  });

  if (matchCount === 0) {
    container.innerHTML =
      '<div class="multi-filter-empty">No matches — try fewer letters</div>';
  }
}

function updateMultiFilterDisplay(col) {
  const panel = document.getElementById(`filter-${col}-panel`);
  const display = document.getElementById(`filter-${col}-display`);
  if (!panel || !display) return;

  const checkboxes = panel.querySelectorAll(
    ".multi-filter-options input[type='checkbox']"
  );
  const selected = [];
  const labels = [];
  checkboxes.forEach((cb) => {
    if (cb.checked) {
      selected.push(cb.value);
      labels.push(cb.getAttribute("data-label") || cb.value);
    }
  });

  if (!selected.length) {
    display.textContent = "All";
    delete CURRENT_FILTERS[col];
  } else {
    CURRENT_FILTERS[col] = selected;
    display.textContent =
      selected.length === 1 ? labels[0] : `${labels[0]} +${selected.length - 1}`;
  }

  CURRENT_PAGE = 1;
  renderPage();
}

function updateRangeReadout(col) {
  const el = document.getElementById(`filter-${col}-range`);
  const active = RANGE_ACTIVE[col];
  if (!el || !active) return;
  if (col === "market_value") {
    el.textContent = `(${formatMoney(active.min)}–${formatMoney(active.max)})`;
    return;
  }
  el.textContent = `(${active.min}–${active.max})`;
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

function setupRangeFilters() {
  let debounceTimer = null;

  for (const { key: col } of RANGE_FILTER_COLUMNS) {
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

    const apply = () => {
      let lo = Number(minEl.value);
      let hi = Number(maxEl.value);
      if (Number.isNaN(lo)) lo = RANGE_BOUNDS[col]?.min ?? 0;
      if (Number.isNaN(hi)) hi = RANGE_BOUNDS[col]?.max ?? lo;
      lo = snapRangeValue(col, lo);
      hi = snapRangeValue(col, hi);
      minEl.value = String(lo);
      maxEl.value = String(hi);
      if (lo > hi) {
        if (document.activeElement === minEl) {
          hi = lo;
          maxEl.value = String(hi);
        } else {
          lo = hi;
          minEl.value = String(lo);
        }
      }
      RANGE_ACTIVE[col] = { min: lo, max: hi };
      updateRangeReadout(col);
      updateRangeTrack(col);
      syncThumbZIndex();
      CURRENT_PAGE = 1;
      renderPage();
    };

    const scheduleApply = () => {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(apply, 200);
    };

    minEl.addEventListener("input", () => {
      syncThumbZIndex();
      scheduleApply();
    });
    maxEl.addEventListener("input", () => {
      syncThumbZIndex();
      scheduleApply();
    });
    minEl.addEventListener("mousedown", syncThumbZIndex);
    maxEl.addEventListener("mousedown", syncThumbZIndex);
    syncThumbZIndex();
    updateRangeTrack(col);
  }
}

function wireMultiFilterClicks() {
  if (multiFilterClickWired) return;
  multiFilterClickWired = true;

  document.addEventListener("click", () => {
    closeAllMultiFilters();
  });

  document.addEventListener("click", (e) => {
    const wrapper = e.target.closest("#filters .multi-filter");
    if (!wrapper) return;
    e.stopPropagation();
    const wasOpen = wrapper.classList.contains("open");
    closeAllMultiFilters();
    if (!wasOpen) {
      wrapper.classList.add("open");
      const search = wrapper.querySelector(".multi-filter-search");
      if (search) {
        search.focus();
        search.select();
      }
    }
  });
}

function buildFilterControls() {
  const container = document.getElementById("filters");
  if (!container) return;

  FILTER_OPTION_CACHE = {};
  for (const { key } of DROPDOWN_FILTER_COLUMNS) {
    const values = [
      ...new Set(
        allRowsCache.map((r) => String(r[key] ?? "").trim()).filter(Boolean)
      ),
    ].sort((a, b) => {
      if (key === "contracted_display") {
        if (a === "FREE AGENT") return -1;
        if (b === "FREE AGENT") return 1;
        return displayClub(a).localeCompare(displayClub(b));
      }
      return a.localeCompare(b);
    });
    FILTER_OPTION_CACHE[key] = values.map((v) => ({
      value: v,
      label: key === "contracted_display" ? displayClub(v) : v,
    }));
  }

  const parts = [`<strong>Filters</strong>`];

  parts.push(`
    <label class="mgdb-free-only">
      <input type="checkbox" id="filter-free-only" ${FREE_AGENTS_ONLY ? "checked" : ""}>
      Not contracted only
    </label>
  `);

  parts.push(`
    <label class="text-filter">
      Manager name
      <input type="text" id="filter-name" placeholder="Search…" value="${String(
        CURRENT_FILTERS.name || ""
      ).replace(/"/g, "&quot;")}">
    </label>
  `);

  for (const { key, label } of DROPDOWN_FILTER_COLUMNS) {
    const selected = Array.isArray(CURRENT_FILTERS[key]) ? CURRENT_FILTERS[key] : [];
    let display = "All";
    if (selected.length === 1) {
      const opt = FILTER_OPTION_CACHE[key]?.find((o) => o.value === selected[0]);
      display = opt?.label || selected[0];
    } else if (selected.length > 1) {
      const opt = FILTER_OPTION_CACHE[key]?.find((o) => o.value === selected[0]);
      display = `${opt?.label || selected[0]} +${selected.length - 1}`;
    }
    parts.push(`
      <div class="multi-filter" data-col="${key}">
        <div class="multi-filter-label">${label}</div>
        <div class="multi-filter-control" id="filter-${key}-display">${display}</div>
        <div class="multi-filter-panel" id="filter-${key}-panel">
          <input type="text" class="multi-filter-search" autocomplete="off" placeholder="Type to narrow…" aria-label="Search ${label}">
          <div class="multi-filter-options"></div>
        </div>
      </div>
    `);
  }

  for (const { key, label } of RANGE_FILTER_COLUMNS) {
    const bounds = RANGE_BOUNDS[key] || { min: 0, max: 0 };
    const active = RANGE_ACTIVE[key] || bounds;
    const step = rangeStep(key);
    const disabled = bounds.max <= bounds.min ? "disabled" : "";
    const rangeText =
      key === "market_value"
        ? `(${formatMoney(active.min)}–${formatMoney(active.max)})`
        : `(${active.min}–${active.max})`;
    const wide = key === "market_value" ? " range-filter--money" : "";
    parts.push(`
      <div class="range-filter${wide}" data-col="${key}">
        <div class="range-filter-label">${label} <span class="range-filter-range" id="filter-${key}-range">${rangeText}</span></div>
        <div class="range-filter-sliders" id="filter-${key}-sliders">
          <div class="range-filter-track"></div>
          <input type="range" class="range-filter-min" id="filter-${key}-min" min="${bounds.min}" max="${bounds.max}" value="${active.min}" step="${step}" aria-label="${label} minimum" ${disabled}>
          <input type="range" class="range-filter-max" id="filter-${key}-max" min="${bounds.min}" max="${bounds.max}" value="${active.max}" step="${step}" aria-label="${label} maximum" ${disabled}>
        </div>
      </div>
    `);
  }

  container.innerHTML = parts.join("");

  document.getElementById("filter-free-only")?.addEventListener("change", (e) => {
    FREE_AGENTS_ONLY = !!e.target.checked;
    CURRENT_PAGE = 1;
    renderPage();
  });

  let nameDebounce = null;
  document.getElementById("filter-name")?.addEventListener("input", (e) => {
    clearTimeout(nameDebounce);
    nameDebounce = setTimeout(() => {
      CURRENT_FILTERS.name = e.target.value;
      CURRENT_PAGE = 1;
      renderPage();
    }, 200);
  });

  for (const { key } of DROPDOWN_FILTER_COLUMNS) {
    const panel = document.getElementById(`filter-${key}-panel`);
    const searchInput = panel?.querySelector(".multi-filter-search");
    if (searchInput) {
      let searchDebounce = null;
      searchInput.addEventListener("input", () => {
        clearTimeout(searchDebounce);
        searchDebounce = setTimeout(() => {
          renderMultiFilterOptions(key, searchInput.value);
        }, 120);
      });
      searchInput.addEventListener("click", (e) => e.stopPropagation());
      searchInput.addEventListener("keydown", (e) => e.stopPropagation());
    }
    panel?.addEventListener("click", (e) => e.stopPropagation());
    renderMultiFilterOptions(key, "");
  }

  setupRangeFilters();
  wireMultiFilterClicks();
}

async function loadManagers() {
  const errEl = document.getElementById("mgdbError");
  const { data, error } = await supabase
    .from("managers_gpdb_public")
    .select("*")
    .order("rating", { ascending: false })
    .order("market_value", { ascending: false });

  if (error) {
    if (errEl) {
      errEl.hidden = false;
      errEl.textContent = `Could not load managers: ${error.message}. Apply managers_system.sql in Supabase.`;
    }
    return;
  }

  allRowsCache = (data || []).map((row) => ({
    ...row,
    contracted_display:
      row.contracted_club && String(row.contracted_club).trim()
        ? row.contracted_club
        : "FREE AGENT",
  }));

  if (errEl) errEl.hidden = true;
  computeRangeBounds();
  buildFilterControls();
  renderPage();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();

  const status = document.getElementById("statusNote");
  managerDraftOn = getManagerDraftEnabled();
  const { data: settings } = await supabase
    .from("global_settings_public")
    .select("manager_draft_auction_enabled, transfer_window_open, draft_auction_start_time")
    .eq("id", 1)
    .maybeSingle();
  draftStartTime = settings?.draft_auction_start_time
    ? new Date(settings.draft_auction_start_time)
    : null;

  if (status) {
    const parts = [];
    if (settings?.manager_draft_auction_enabled) {
      parts.push(
        'Manager draft is <b>on</b> — <a href="manager_draftauction.html" style="color:#ff9900;">Manager Draft Auction</a> · bidding from Day 1 7pm UK until the Day 2 6:50pm random window.'
      );
    }
    if (settings?.transfer_window_open) {
      parts.push("Transfer window open — use <a href=\"manager_listings.html\">Manager Transfer Market</a>.");
    }
    status.innerHTML = parts.join(" ");
  }

  document.getElementById("applyMV")?.addEventListener("click", () => {
    MV_MIN = parseMoneyInput(document.getElementById("mv-min")?.value);
    MV_MAX = parseMoneyInput(document.getElementById("mv-max")?.value);
    CURRENT_PAGE = 1;
    renderPage();
  });

  document.getElementById("clearFiltersBtn")?.addEventListener("click", () => {
    CURRENT_FILTERS = {};
    FREE_AGENTS_ONLY = false;
    computeRangeBounds();
    CURRENT_PAGE = 1;
    buildFilterControls();
    renderPage();
  });

  document.getElementById("pageSizeSelect")?.addEventListener("change", (e) => {
    PAGE_SIZE = Number(e.target.value) || 100;
    CURRENT_PAGE = 1;
    renderPage();
  });

  buildTableHead();
  await loadViewerClub();
  await loadManagers();

  if (managerDraftOn && draftStartTime) {
    const pollDraftState = async () => {
      await refreshDraftBiddingOpen();
      renderPage();
    };
    setInterval(pollDraftState, 1500);
  }
});
