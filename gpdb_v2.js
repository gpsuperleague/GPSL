/* ============================================================
   MODULE A: Supabase Client
   ============================================================ */
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm'

const supabase = createClient(
  'https://omyyogfumrjoaweuawjn.supabase.co',
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9teXlvZ2Z1bXJqb2F3ZXVhd2puIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ5NTUxMzUsImV4cCI6MjA5MDUzMTEzNX0.7UVkpi4DOtC9VNjFLnE_ZnK6vhDtlfesZ_8rfnrkno4'
);


/* ============================================================
   MODULE B: Column Definitions
   ============================================================ */
const COLUMNS = [
  "Name",
  "Position",
  "Nation",
  "Age",
  "Rating",
  "Playstyle",
  "Maximum_Reserve_Price",
  "market_value",
  "Contracted_Team",
  "Season_Signed",
  "Konami_ID" // needed for PESDB
];

const FILTER_EXCLUDE = [
  "Maximum_Reserve_Price",
  "market_value",
  "Konami_ID"
];

const DROPDOWN_COLUMNS = [
  "Nation",
  "Position",
  "Age",
  "Rating",
  "Playstyle",
  "Contracted_Team",
  "Season_Signed"
];


/* ============================================================
   MODULE C: Pagination + State
   ============================================================ */
let PAGE_SIZE = 1000;
let TOTAL_ROWS = 0;
let CURRENT_PAGE = 1;

let CURRENT_FILTERS = {};
let CURRENT_SORT_COLUMN = null;
let CURRENT_SORT_DIR = 'asc';

let MV_MIN = null;
let MV_MAX = null;


/* ============================================================
   MODULE D: Data Loading
   ============================================================ */
async function loadTotalCount() {
  const { count } = await supabase
    .from('Players')
    .select('*', { count: 'exact', head: true });

  TOTAL_ROWS = count;
}

async function loadPage(page = 1) {
  CURRENT_PAGE = page;

  const from = (page - 1) * PAGE_SIZE;
  const to = from + PAGE_SIZE - 1;

  let query = supabase
    .from('Players')
    .select(COLUMNS.join(','), { count: 'exact' });

  // Apply filters
  Object.entries(CURRENT_FILTERS).forEach(([col, value]) => {
    if (value.trim() === "") return;

    if (DROPDOWN_COLUMNS.includes(col)) {
      if (col === "Contracted_Team" && value === "FREE AGENT") {
        query = query.or(
          `${col}.is.null,${col}.eq.'',${col}.eq.' '`
        );
      } else {
        query = query.eq(col, value);
      }
    } else {
      query = query.ilike(col, `%${value}%`);
    }
  });

  // Market value filters
  if (MV_MIN !== null) query = query.gte("market_value", MV_MIN);
  if (MV_MAX !== null) query = query.lte("market_value", MV_MAX);

  // Sorting
  if (CURRENT_SORT_COLUMN) {
    query = query.order(CURRENT_SORT_COLUMN, {
      ascending: CURRENT_SORT_DIR === 'asc'
    });
  }

  // Pagination
  query = query.range(from, to);

  const { data, error, count } = await query;

  if (error) {
    console.error(error);
    return;
  }

  TOTAL_ROWS = count;
  renderTable(data);
  renderPagination();
}


/* ============================================================
   MODULE E: Rendering
   ============================================================ */
function renderTable(players) {
  const tableHead = document.getElementById("tableHead");
  const tableBody = document.getElementById("tableBody");

  if (!players || players.length === 0) {
    tableHead.innerHTML = "<tr><th>No data</th></tr>";
    tableBody.innerHTML = "";
    return;
  }

  // Header
  tableHead.innerHTML = `
    <tr>
      ${COLUMNS.filter(col => col !== "Konami_ID").map(col => {
        let cls = "";
        if (CURRENT_SORT_COLUMN === col) {
          cls = CURRENT_SORT_DIR === 'asc' ? 'sort-asc' : 'sort-desc';
        }
        return `<th data-col="${col}" class="${cls}">${col.replace(/_/g, " ")}</th>`;
      }).join("")}
    </tr>
  `;

  // Rows
  tableBody.innerHTML = players
    .map(player => `
      <tr data-konami-id="${player.Konami_ID || player.konami_id || ''}">
        ${COLUMNS.filter(col => col !== "Konami_ID").map(col => {
          let value = player[col];

          if (col === "market_value" && value !== null) {
            value = "₿ " + new Intl.NumberFormat("en-GB", {
              maximumFractionDigits: 0,
              minimumFractionDigits: 0
            }).format(value);
          }

          return `<td>${value}</td>`;
        }).join("")}
      </tr>
    `)
    .join("");

  // Sorting
  Array.from(tableHead.querySelectorAll("th")).forEach(th => {
    const col = th.getAttribute("data-col");
    th.onclick = () => {
      if (CURRENT_SORT_COLUMN === col) {
        CURRENT_SORT_DIR = CURRENT_SORT_DIR === 'asc' ? 'desc' : 'asc';
      } else {
        CURRENT_SORT_COLUMN = col;
        CURRENT_SORT_DIR = 'asc';
      }
      loadPage(1);
    };
  });

  // PESDB row click
  Array.from(tableBody.querySelectorAll("tr")).forEach(row => {
    row.style.cursor = "pointer";
    row.addEventListener("click", () => {
      const konamiId = row.getAttribute("data-konami-id");
      if (!konamiId) return;
      window.open(
        `https://pesdb.net/efootball/?id=${konamiId}`,
        "_blank",
        "noopener"
      );
    });
  });
}

function renderPagination() {
  const pages = Math.ceil(TOTAL_ROWS / PAGE_SIZE);
  const container = document.getElementById("pagination");

  container.innerHTML = "";

  if (pages <= 1) return;

  for (let i = 1; i <= pages; i++) {
    const btn = document.createElement("button");
    btn.textContent = i;
    btn.style.margin = "4px";
    btn.disabled = i === CURRENT_PAGE;
    btn.onclick = () => loadPage(i);
    container.appendChild(btn);
  }
}


/* ============================================================
   MODULE F: Filters
   ============================================================ */
async function populateDropdowns() {
  for (const col of DROPDOWN_COLUMNS) {
    const select = document.getElementById(`filter-${col}`);
    let allValues = [];
    const batchSize = 1000;

    const { count } = await supabase
      .from("Players")
      .select("Konami_ID", { count: "exact" })
      .limit(1);

    if (!count) continue;

    for (let from = 0; from < count; from += batchSize) {
      const to = Math.min(from + batchSize - 1, count - 1);

      const { data } = await supabase
        .from("Players")
        .select(`Konami_ID, ${col}`)
        .range(from, to);

      if (data) {
        allValues.push(
          ...data.map(row => {
            const v = row[col];

            if (col === "Contracted_Team") {
              if (!v || v.trim() === "") return "FREE AGENT";
            }

            return v;
          })
        );
      }
    }

    let uniqueValues;

    if (col === "Season_Signed") {
      uniqueValues = [...new Set(
        allValues.filter(v => v).map(v => Number(v))
      )].sort((a, b) => a - b);
    } else {
      uniqueValues = [...new Set(
        allValues.filter(v => v).map(v => String(v).trim())
      )].sort((a, b) => a.localeCompare(b));

      if (col === "Contracted_Team") {
        uniqueValues = [
          "FREE AGENT",
          ...uniqueValues.filter(v => v !== "FREE AGENT")
        ];
      }
    }

    uniqueValues.forEach(v => {
      const opt = document.createElement("option");
      opt.value = v;
      opt.textContent = v;
      select.appendChild(opt);
    });
  }
}

function setupFilters() {
  const filtersDiv = document.getElementById("filters");

  filtersDiv.innerHTML = COLUMNS
    .filter(col => !FILTER_EXCLUDE.includes(col))
    .map(col => {
      if (DROPDOWN_COLUMNS.includes(col)) {
        return `
          <label>${col.replace(/_/g, " ")}:
            <select id="filter-${col}">
              <option value="">All</option>
            </select>
          </label>
        `;
      } else {
        return `
          <label>${col.replace(/_/g, " ")}:
            <input type="text" id="filter-${col}" placeholder="Filter ${col}">
          </label>
        `;
      }
    })
    .join(" ");

  COLUMNS
    .filter(col => !FILTER_EXCLUDE.includes(col))
    .forEach(col => {
      const el = document.getElementById(`filter-${col}`);
      el.addEventListener("change", () => {
        CURRENT_FILTERS[col] = el.value;
        loadPage(1);
      });
    });
}

function setupControls() {
  const pageSizeSelect = document.getElementById("pageSizeSelect");
  pageSizeSelect.addEventListener("change", () => {
    PAGE_SIZE = Number(pageSizeSelect.value);
    loadPage(1);
  });

  const mvMinInput = document.getElementById("mv-min");
  const mvMaxInput = document.getElementById("mv-max");
  const applyMV = document.getElementById("applyMV");

  applyMV.addEventListener("click", () => {
    MV_MIN = mvMinInput.value.trim() === "" ? null : Number(mvMinInput.value);
    MV_MAX = mvMaxInput.value.trim() === "" ? null : Number(mvMaxInput.value);
    loadPage(1);
  });

  document.getElementById("clearFiltersBtn").addEventListener("click", () => {
    CURRENT_FILTERS = {};
    MV_MIN = null;
    MV_MAX = null;
    CURRENT_SORT_COLUMN = null;
    CURRENT_SORT_DIR = 'asc';

    document.querySelectorAll('#filters input, #filters select').forEach(i => i.value = "");
    mvMinInput.value = "";
    mvMaxInput.value = "";

    loadPage(1);
  });
}


/* ============================================================
   MODULE G: Initialisation
   ============================================================ */
async function init() {
  setupControls();
  setupFilters();
  await populateDropdowns();
  await loadTotalCount();
  loadPage(1);
}

init();
