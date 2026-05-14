/* ============================================================
   MODULE A: Supabase Client (imports MUST be at top)
   ============================================================ */

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm';

const supabase = createClient(
  'https://omyyogfumrjoaweuawjn.supabase.co',
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9teXlvZ2Z1bXJqb2F3ZXVhd2puIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ5NTUxMzUsImV4cCI6MjA5MDUzMTEzNX0.7UVkpi4DOtC9VNjFLnE_ZnK6vhDtlfesZ_8rfnrkno4'
);

/* ============================================================
   EVERYTHING ELSE MUST BE INSIDE DOMContentLoaded
   ============================================================ */

document.addEventListener("DOMContentLoaded", () => {

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
  "Konami_ID"
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
let CURRENT_SORT_DIR = "asc";

let MV_MIN = null;
let MV_MAX = null;

/* ============================================================
   MODULE D: Global Settings Loader
   ============================================================ */

async function loadGlobalSettings() {
  const { data, error } = await supabase
    .from("global_settings")
    .select("*")
    .eq("id", 1)
    .single();

  if (error || !data) {
    console.error("Failed to load global settings:", error);
    return {
      transferWindowOpen: false,
      draftAuctionEnabled: false
    };
  }

  return {
    transferWindowOpen: data.transfer_window_open,
    draftAuctionEnabled: data.draft_auction_enabled
  };
}

/* ============================================================
   MODULE E: Data Loading
   ============================================================ */

async function loadTotalCount() {
  const { count } = await supabase
    .from("Players")
    .select("*", { count: "exact", head: true });

  TOTAL_ROWS = count;
}

async function loadPage(page = 1) {
  CURRENT_PAGE = page;

  const from = (page - 1) * PAGE_SIZE;
  const to = from + PAGE_SIZE - 1;

  let query = supabase
    .from("Players")
    .select(COLUMNS.join(","), { count: "exact" });

  Object.entries(CURRENT_FILTERS).forEach(([col, value]) => {
    if (value.trim() === "") return;

    if (DROPDOWN_COLUMNS.includes(col)) {
      if (col === "Contracted_Team" && value === "FREE AGENT") {
        query = query.or(`${col}.is.null,${col}.eq.'',${col}.eq.' '`);
      } else {
        query = query.eq(col, value);
      }
    } else {
      query = query.ilike(col, `%${value}%`);
    }
  });

  if (MV_MIN !== null) query = query.gte("market_value", MV_MIN);
  if (MV_MAX !== null) query = query.lte("market_value", MV_MAX);

  if (CURRENT_SORT_COLUMN) {
    query = query.order(CURRENT_SORT_COLUMN, {
      ascending: CURRENT_SORT_DIR === "asc"
    });
  }

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
   MODULE F: Rendering (with Bid column)
   ============================================================ */

let GLOBAL_SETTINGS = null;
let CURRENT_USER = null;

async function loadUser() {
  const { data: { user } } = await supabase.auth.getUser();
  CURRENT_USER = user;
}

function renderTable(players) {
  const tableHead = document.getElementById("tableHead");
  const tableBody = document.getElementById("tableBody");

  if (!players || players.length === 0) {
    tableHead.innerHTML = "<tr><th>No data</th></tr>";
    tableBody.innerHTML = "";
    return;
  }

  tableHead.innerHTML = `
    <tr>
      ${COLUMNS.filter(col => col !== "Konami_ID")
        .map(col => {
          let cls = "";
          if (CURRENT_SORT_COLUMN === col) {
            cls = CURRENT_SORT_DIR === "asc" ? "sort-asc" : "sort-desc";
          }
          return `<th data-col="${col}" class="${cls}">${col.replace(/_/g, " ")}</th>`;
        })
        .join("")}
      <th>Bid</th>
    </tr>
  `;

  tableBody.innerHTML = players
    .map(player => {
      const hasClub = !!player.Contracted_Team;
      const isMyClub = player.Contracted_Team === CURRENT_USER?.user_metadata?.shortName;

      let bidCell = `<span class="locked-msg">Loading…</span>`;

      if (GLOBAL_SETTINGS) {
        if (hasClub) {
          if (!isMyClub && GLOBAL_SETTINGS.transferWindowOpen) {
            bidCell = `<button class="button make-offer-btn" data-player-id="${player.Konami_ID}">Make Offer</button>`;
          } else if (!GLOBAL_SETTINGS.transferWindowOpen) {
            bidCell = `<span class="locked-msg">Window Closed</span>`;
          } else {
            bidCell = `<span class="locked-msg">Your Player</span>`;
          }
        } else {
          if (GLOBAL_SETTINGS.draftAuctionEnabled) {
            bidCell = `<button class="button make-offer-btn" data-player-id="${player.Konami_ID}">Make Offer</button>`;
          } else {
            bidCell = `<span class="locked-msg">Draft Locked</span>`;
          }
        }
      }

      return `
        <tr data-konami-id="${player.Konami_ID}">
          ${COLUMNS.filter(col => col !== "Konami_ID")
            .map(col => {
              let value = player[col];
              if (col === "market_value" && value !== null) {
                value = "₿ " + Number(value).toLocaleString("en-GB");
              }
              return `<td>${value}</td>`;
            })
            .join("")}
          <td>${bidCell}</td>
        </tr>
      `;
    })
    .join("");

  Array.from(tableHead.querySelectorAll("th[data-col]")).forEach(th => {
    const col = th.getAttribute("data-col");
    th.onclick = () => {
      if (CURRENT_SORT_COLUMN === col) {
        CURRENT_SORT_DIR = CURRENT_SORT_DIR === "asc" ? "desc" : "asc";
      } else {
        CURRENT_SORT_COLUMN = col;
        CURRENT_SORT_DIR = "asc";
      }
      loadPage(1);
    };
  });

  Array.from(tableBody.querySelectorAll("tr")).forEach(row => {
    row.style.cursor = "pointer";
    row.addEventListener("click", e => {
      if (e.target.closest(".make-offer-btn")) return;
      const konamiId = row.getAttribute("data-konami-id");
      if (!konamiId) return;
      window.open(
        `https://pesdb.net/efootball/?id=${konamiId}`,
        "_blank",
        "noopener"
      );
    });
  });

  document.querySelectorAll(".make-offer-btn").forEach(btn => {
    btn.addEventListener("click", () => openMakeOfferModal(btn.dataset.playerId));
  });
}

/* ============================================================
   MODULE G: Make Offer Modal (updated)
   ============================================================ */

let CURRENT_OFFER_PLAYER = null;

async function openMakeOfferModal(playerId) {
  const { data: player, error } = await supabase
    .from("Players")
    .select("*")
    .eq("Konami_ID", playerId)
    .single();

  if (error || !player) {
    console.error("Failed to load player for offer", error);
    return;
  }

  CURRENT_OFFER_PLAYER = player;

  const imgEl = document.getElementById("offerPlayerImg");
  const nameEl = document.getElementById("offerPlayerName");
  const posEl = document.getElementById("offerPlayerPosition");
  const styleEl = document.getElementById("offerPlayerPlaystyle");
  const ratingEl = document.getElementById("offerPlayerRating");
  const mvEl = document.getElementById("offerPlayerMV");
  const amountInput = document.getElementById("offerAmount");
  const errorBox = document.getElementById("offerError");

  imgEl.src = `https://pesdb.net/efootball/img/players/${player.Konami_ID}.png`;
  imgEl.onerror = () => {
    imgEl.src = "https://i.imgur.com/3s8XQ7Y.png";
  };

  nameEl.textContent = player.Name;
  posEl.textContent = `Position: ${player.Position}`;
  styleEl.textContent = `Playstyle: ${player.Playstyle}`;
  ratingEl.textContent = `Rating: ${player.Rating}`;
  mvEl.textContent = `Market Value: ₿ ${Number(player.market_value).toLocaleString("en-GB")}`;

  amountInput.value = Number(player.market_value).toLocaleString("en-GB");
  errorBox.textContent = "";

  document.getElementById("make-offer-modal-backdrop").style.display = "flex";
}
/* ============================================================
   MODULE G (continued): Confirm Offer + Buttons
   ============================================================ */

document.getElementById("cancelOfferBtn").onclick = () => {
  document.getElementById("make-offer-modal-backdrop").style.display = "none";
};

document.getElementById("confirmOfferBtn").onclick = async () => {
  const input = document.getElementById("offerAmount");
  const errorBox = document.getElementById("offerError");

  let raw = input.value.replace(/,/g, "").trim();
  let offer = Number(raw);

  if (!offer || offer <= 0) {
    errorBox.textContent = "Enter a valid positive number.";
    return;
  }

  const mv = Number(CURRENT_OFFER_PLAYER.market_value) || 0;
  if (offer < mv) {
    offer = mv;
    input.value = offer.toLocaleString("en-GB");
  }

  const sellerClub = CURRENT_OFFER_PLAYER.Contracted_Team;
  const myClub = CURRENT_USER.user_metadata.shortName;

  if (!sellerClub && !GLOBAL_SETTINGS.draftAuctionEnabled) {
    errorBox.textContent = "Draft Auction is locked. You cannot bid on free agents.";
    return;
  }

  if (sellerClub === myClub) {
    errorBox.textContent = "You cannot make an offer for your own player.";
    return;
  }

  if (sellerClub && !GLOBAL_SETTINGS.transferWindowOpen) {
    errorBox.textContent = "Transfer window is closed for contracted players.";
    return;
  }

  const { error } = await supabase.from("Player_Transfer_Bids").insert({
    listing_id: null,
    player_id: CURRENT_OFFER_PLAYER.Konami_ID,
    bidder_club_id: CURRENT_USER.user_metadata.shortName,
    seller_club_id: sellerClub || null,
    bid_amount: offer,
    bid_time: new Date().toISOString(),
    is_direct: true,
    direct_bid_id: null
  });

  if (error) {
    errorBox.textContent = "Failed to submit offer.";
    console.error(error);
    return;
  }

  document.getElementById("make-offer-modal-backdrop").style.display = "none";
};

/* ============================================================
   Increment / Decrement Buttons
   ============================================================ */

document.querySelectorAll(".inc-btn, .dec-btn").forEach(btn => {
  btn.addEventListener("click", () => {
    if (!CURRENT_OFFER_PLAYER) return;

    const inc = Number(btn.dataset.inc);
    const input = document.getElementById("offerAmount");

    let raw = input.value.replace(/,/g, "").trim();
    let val = Number(raw) || 0;

    val += inc;

    const mv = Number(CURRENT_OFFER_PLAYER.market_value) || 0;
    if (val < mv) val = mv;

    input.value = val.toLocaleString("en-GB");
  });
});

/* ============================================================
   Quick Bid Button
   ============================================================ */

document.getElementById("quickBidBtn").onclick = () => {
  if (!CURRENT_OFFER_PLAYER) return;
  const mv = Number(CURRENT_OFFER_PLAYER.market_value) || 0;
  document.getElementById("offerAmount").value = mv.toLocaleString("en-GB");
};

/* ============================================================
   Intelligent Input Formatting
   ============================================================ */

document.getElementById("offerAmount").addEventListener("input", e => {
  if (!CURRENT_OFFER_PLAYER) return;

  let raw = e.target.value.replace(/,/g, "").trim();
  let val = Number(raw);

  const mv = Number(CURRENT_OFFER_PLAYER.market_value) || 0;

  if (isNaN(val) || val <= 0) {
    val = mv;
  }

  if (val < mv) val = mv;

  e.target.value = val.toLocaleString("en-GB");
});

/* ============================================================
   MODULE H: Filters + Controls
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
      uniqueValues = [...new Set(allValues.filter(v => v).map(v => Number(v)))].sort(
        (a, b) => a - b
      );
    } else {
      uniqueValues = [
        ...new Set(allValues.filter(v => v).map(v => String(v).trim()))
      ].sort((a, b) => a.localeCompare(b));

      if (col === "Contracted_Team") {
        uniqueValues = ["FREE AGENT", ...uniqueValues.filter(v => v !== "FREE AGENT")];
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

  filtersDiv.innerHTML = COLUMNS.filter(col => !FILTER_EXCLUDE.includes(col))
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

  COLUMNS.filter(col => !FILTER_EXCLUDE.includes(col)).forEach(col => {
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
    CURRENT_SORT_DIR = "asc";

    document
      .querySelectorAll("#filters input, #filters select")
      .forEach(i => (i.value = ""));
    mvMinInput.value = "";
    mvMaxInput.value = "";

    loadPage(1);
  });
}

/* ============================================================
   MODULE I: Pagination Rendering
   ============================================================ */

function renderPagination() {
  const totalPages = Math.ceil(TOTAL_ROWS / PAGE_SIZE);
  const pagination = document.getElementById("pagination");

  pagination.innerHTML = "";

  for (let i = 1; i <= totalPages; i++) {
    const btn = document.createElement("button");
    btn.textContent = i;
    btn.className = "page-btn";
    if (i === CURRENT_PAGE) btn.classList.add("active");

    btn.onclick = () => loadPage(i);
    pagination.appendChild(btn);
  }
}

/* ============================================================
   MODULE J: Initialisation
   ============================================================ */

async function init() {
  await loadUser();
  GLOBAL_SETTINGS = await loadGlobalSettings();

  setupControls();
  setupFilters();
  await populateDropdowns();
  await loadTotalCount();
  loadPage(1);
}

init();

/* END DOMContentLoaded WRAPPER */
});
