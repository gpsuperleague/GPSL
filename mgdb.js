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

const FILTER_COLUMNS = ["nation", "contracted_display", "age", "rating"];

let PAGE_SIZE = 100;
let CURRENT_PAGE = 1;
let TOTAL_ROWS = 0;
let CURRENT_SORT_COLUMN = "rating";
let CURRENT_SORT_DIR = "desc";
let MV_MIN = null;
let MV_MAX = null;
let CURRENT_FILTERS = {};
let FREE_AGENTS_ONLY = false;
let allRowsCache = [];
let managerDraftOn = false;
let draftStartTime = null;
let viewerClubShort = null;
let viewerClubHasManager = false;
let viewerSackedManagerIds = new Set();

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

  const freeWrap = document.createElement("label");
  freeWrap.style.cssText =
    "display:flex;align-items:center;gap:8px;min-width:180px;color:#ddd;font-size:13px;cursor:pointer;";
  freeWrap.innerHTML = `<input type="checkbox" id="filter-free-only" ${
    FREE_AGENTS_ONLY ? "checked" : ""
  }> Not contracted only`;
  container.appendChild(freeWrap);
  document.getElementById("filter-free-only")?.addEventListener("change", (e) => {
    FREE_AGENTS_ONLY = !!e.target.checked;
    CURRENT_PAGE = 1;
    renderPage();
  });

  const nameLabel = document.createElement("label");
  nameLabel.innerHTML = `Manager name <input type="text" id="filter-name" placeholder="Search…">`;
  container.appendChild(nameLabel);

  document.getElementById("filter-name")?.addEventListener("input", (e) => {
    CURRENT_FILTERS.name = e.target.value;
    CURRENT_PAGE = 1;
    renderPage();
  });
  if (CURRENT_FILTERS.name) {
    const nameInput = document.getElementById("filter-name");
    if (nameInput) nameInput.value = CURRENT_FILTERS.name;
  }

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
