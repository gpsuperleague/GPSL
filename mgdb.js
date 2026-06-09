import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";

const TABLE_COLUMNS = [
  { key: "name", label: "Manager" },
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

const FILTER_COLUMNS = ["nation", "contracted_display", "age", "rating"];

let PAGE_SIZE = 100;
let CURRENT_PAGE = 1;
let TOTAL_ROWS = 0;
let CURRENT_SORT_COLUMN = "rating";
let CURRENT_SORT_DIR = "desc";
let MV_MIN = null;
let MV_MAX = null;
let CURRENT_FILTERS = {};
let allRowsCache = [];

function parseMoneyInput(value) {
  if (!value) return null;
  const n = Number(String(value).replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
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

  for (const [col, value] of Object.entries(CURRENT_FILTERS)) {
    if (col === "name" || !value) continue;
    const values = Array.isArray(value) ? value : [value];
    if (!values.length) continue;
    filtered = filtered.filter((r) => values.includes(String(r[col] ?? "")));
  }

  if (MV_MIN !== null) {
    filtered = filtered.filter((r) => Number(r.market_value) >= MV_MIN);
  }
  if (MV_MAX !== null) {
    filtered = filtered.filter((r) => Number(r.market_value) <= MV_MAX);
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
        let val = row[col.key];
        if (col.key === "contracted_display") val = displayClub(val);
        if (col.key === "market_value") {
          return `<td class="money">${formatMoney(val)}</td>`;
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
  buildFilterControls();
  renderPage();
}

function buildFilterControls() {
  const container = document.getElementById("filters");
  if (!container) return;

  const unique = (key) =>
    [...new Set(allRowsCache.map((r) => String(r[key] ?? "").trim()).filter(Boolean))].sort();

  container.innerHTML = `<strong>Filters</strong>`;

  const nameLabel = document.createElement("label");
  nameLabel.innerHTML = `Manager name <input type="text" id="filter-name" placeholder="Search…">`;
  container.appendChild(nameLabel);

  document.getElementById("filter-name")?.addEventListener("input", (e) => {
    CURRENT_FILTERS.name = e.target.value;
    CURRENT_PAGE = 1;
    renderPage();
  });

  for (const col of FILTER_COLUMNS) {
    const values = unique(col === "contracted_display" ? "contracted_display" : col);
    const wrap = document.createElement("div");
    wrap.style.minWidth = "160px";
    const label = col === "rating" ? "Rating" : col === "contracted_display" ? "Club" : col;
    wrap.innerHTML = `<div style="font-size:12px;color:#ffaa22;margin-bottom:4px;">${label}</div>`;
    const sel = document.createElement("select");
    sel.multiple = true;
    sel.size = Math.min(6, values.length + 1);
    sel.style.minWidth = "150px";
    values.forEach((v) => {
      const opt = document.createElement("option");
      opt.value = v;
      opt.textContent = col === "contracted_display" ? displayClub(v) : v;
      sel.appendChild(opt);
    });
    sel.addEventListener("change", () => {
      CURRENT_FILTERS[col] = [...sel.selectedOptions].map((o) => o.value);
      CURRENT_PAGE = 1;
      renderPage();
    });
    wrap.appendChild(sel);
    container.appendChild(wrap);
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();

  const status = document.getElementById("statusNote");
  const { data: settings } = await supabase
    .from("global_settings_public")
    .select("manager_draft_auction_enabled, transfer_window_open")
    .eq("id", 1)
    .maybeSingle();

  if (status) {
    const parts = [];
    if (settings?.manager_draft_auction_enabled) {
      parts.push(
        "Manager draft auction is <b>enabled</b> (same 7pm UK window as player draft)."
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
    MV_MIN = null;
    MV_MAX = null;
    const mvMin = document.getElementById("mv-min");
    const mvMax = document.getElementById("mv-max");
    if (mvMin) mvMin.value = "";
    if (mvMax) mvMax.value = "";
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
  await loadManagers();
});
