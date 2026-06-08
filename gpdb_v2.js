/* ============================================================
   MODULE A: Imports
   ============================================================ */

import {
  supabase,
  initGlobal,
  getUKNow,
  getUKWallClockParts,
  ukLocalToInstant,
  isValidDate,
} from "./global.js";

import {
  loadGlobalSettings as loadGlobalSettingsEngine,
  getDraftTimelineFromStart,
  getDraftPhaseFromStart,
  isGpdbFreeAgentOfferAllowed,
  gpdbFreeAgentLockMessage,
  getDraftCredits,
  syncDraftListingHighBid,
  fetchCurrentDraftAuctionBids,
  draftMinimumBidAmount,
} from "./draft_engine.js";
import {
  loadPendingDirectOfferState,
  sellerPendingPlayerIds,
  playerHasPendingDirectOffer,
} from "./direct_offers.js";
import {
  loadTransferStatusState,
  buildGpdbContractedBidCellHtml,
  formatForeignContractGpdbHtml,
} from "./player_transfer_status.js";
import {
  playerForeignContractLocked,
  playerForeignContractStatusLabel,
} from "./player_foreign_contract.js";
import {
  playerBlockedSameSeasonTransfer,
  playerBlockedFromTransferMarket,
  SAME_SEASON_TRANSFER_MESSAGE,
  FINAL_YEAR_TRANSFER_MESSAGE,
} from "./player_season_transfer.js";
import { isContractFinalYear } from "./player_contracts.js";
import {
  confirmSquadRulesBeforeBid,
  squadRulesBidWarningLines,
} from "./squad_rules.js";
import {
  loadPlayerValueTables,
  calcPotentialForPlayer,
} from "./player_economics.js";

let draftAuctionStartTime = null;
let draftJoinWindowEnd = null;

/* ============================================================
   DRAFT CREDITS PANEL (GPDB VIEW)
   ============================================================ */

async function loadDraftCreditsForOwner() {
  try {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;

    const { data: club } = await supabase
      .from("Clubs")
      .select("ShortName")
      .eq("owner_id", user.id)
      .single();

    if (!club) return;

    const buyerShortName = club.ShortName;

    const { data: settings } = await supabase
      .from("global_settings_public")
      .select("draft_auction_enabled")
      .eq("id", 1)
      .single();

    if (!settings?.draft_auction_enabled) {
      const panel = document.getElementById("draftCreditsPanel");
      if (panel) panel.textContent = "";
      return;
    }

    const { earned, used, credits } = await getDraftCredits(
      buyerShortName,
      draftAuctionStartTime
    );
    const remaining = credits;

    const panel = document.getElementById("draftCreditsPanel");
    if (panel) {
      panel.innerHTML = `
        <b>Draft Credits:</b> ${remaining}<br>
        <span style="font-size:11px;color:#aaa;">
          Earned: ${earned} | Used: ${used}
        </span>
      `;
    }
  } catch (err) {
    console.error("Error loading draft credits:", err);
  }
}

async function getDraftCreditsForGPDB(clubShortName) {
  const { credits } = await getDraftCredits(clubShortName, draftAuctionStartTime);
  return credits;
}

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
    "Potential",
    "Calc_Potential",
    "Playstyle",
    "Maximum_Reserve_Price",
    "market_value",
    "Contracted_Team",
    "Season_Signed",
    "contract_seasons_remaining",
    "contract_wage",
    "foreign_contract_club",
    "foreign_contract_sold_season_id",
    "foreign_contract_unlock_season_label",
    "Konami_ID",
  ];

  /** Shown in table (Calc_Potential is used for compute but displayed as Pot.) */
  const TABLE_DISPLAY_COLUMNS = [
    "Name",
    "Position",
    "Nation",
    "Age",
    "Rating",
    "Potential",
    "Playstyle",
    "Maximum_Reserve_Price",
    "market_value",
    "Contracted_Team",
    "Season_Signed",
  ];

  const FILTER_EXCLUDE = [
    "Maximum_Reserve_Price",
    "market_value",
    "Konami_ID",
    "Calc_Potential",
  ];

  const ECONOMICS_DB_COLS = ["Potential", "Calc_Potential"];
  let useEconomicsDbColumns = true;

  function playerSelectList() {
    if (useEconomicsDbColumns) return COLUMNS.join(",");
    return COLUMNS.filter((c) => !ECONOMICS_DB_COLS.includes(c)).join(",");
  }

  function isMissingEconomicsColumnError(error) {
    const msg = String(error?.message || "").toLowerCase();
    return msg.includes("potential") || msg.includes("calc_potential");
  }

  const DROPDOWN_COLUMNS = [
    "Nation",
    "Position",
    "Age",
    "Rating",
    "Playstyle",
    "Contracted_Team",
    "Season_Signed"
  ];

  const POSITION_ORDER = [
    "GK", "LB", "CB", "RB",
    "DMF", "LMF", "CMF", "RMF",
    "AMF", "LWF", "SS", "RWF", "CF"
  ];

  /* ============================================================
     RESTORE MULTI-FILTER CLICK HANDLERS
     ============================================================ */

  document.addEventListener("click", () => {
    closeAllMultiFilters();
  });

  document.addEventListener("click", e => {
    const wrapper = e.target.closest(".multi-filter");
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

  /* ============================================================
     MODULE C: Pagination + State
     ============================================================ */

  let PAGE_SIZE = 1000;
  let TOTAL_ROWS = 0;
  let CURRENT_PAGE = 1;

  let CURRENT_FILTERS = {};
  const FILTER_OPTION_CACHE = {};
  const MAX_ROWS_FOR_NAME_SEARCH = 15000;

  let CURRENT_SORT_COLUMN = "Rating";
  let CURRENT_SORT_DIR = "desc";

  let MV_MIN = null;
  let MV_MAX = null;

  /* ============================================================
     MODULE D: Global Settings Loader
     ============================================================ */

  let GLOBAL_SETTINGS = null;
  let CURRENT_USER = null;
  let ACTIVE_DRAFT_PLAYERS = new Set();
  let PENDING_DIRECT_OFFER_PLAYERS = new Set();
  let PENDING_DIRECT_OFFERS_FOR_MY_CLUB = new Set();
  let TRANSFER_STATUS_STATE = null;
  let CURRENT_USER_CLUB_SHORT = null;

  let CLUB_NAME_MAP = {};
  let CLUB_NATION_MAP = {};
  /** Full Clubs.Club name → ShortName (for direct-offer seller_club_id). */
  let CLUB_SHORT_BY_FULL_NAME = {};

  async function loadUser() {
    const { data: { user } } = await supabase.auth.getUser();
    CURRENT_USER = user;
    CURRENT_USER_CLUB_SHORT = null;

    if (user) {
      const { data: club } = await supabase
        .from("Clubs")
        .select("ShortName")
        .eq("owner_id", user.id)
        .maybeSingle();

      CURRENT_USER_CLUB_SHORT = club?.ShortName ?? null;
    }
  }

  async function loadClubNames() {
    const { data, error } = await supabase
      .from("Clubs")
      .select("ShortName, Club, Nation");

    if (error || !data) {
      console.error("Failed to load club names:", error);
      CLUB_NAME_MAP = {};
      CLUB_NATION_MAP = {};
      CLUB_SHORT_BY_FULL_NAME = {};
      return;
    }

    CLUB_NAME_MAP = {};
    CLUB_NATION_MAP = {};
    CLUB_SHORT_BY_FULL_NAME = {};
    data.forEach(c => {
      if (c.ShortName) {
        CLUB_NAME_MAP[c.ShortName] = c.Club || c.ShortName;
        CLUB_NATION_MAP[c.ShortName] = c.Nation || "";
        if (c.Club) {
          CLUB_SHORT_BY_FULL_NAME[c.Club] = c.ShortName;
        }
      }
    });
  }

  /** Always store seller as Clubs.ShortName (GPDB table shows full club name). */
  function resolveContractedClubShort(contractedTeam) {
    const raw = String(contractedTeam || "").trim();
    if (!raw) return null;
    if (CLUB_NAME_MAP[raw]) return raw;
    return CLUB_SHORT_BY_FULL_NAME[raw] || raw;
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

  /** Fold accents & strip symbols for forgiving search (José → jose). */
  function normalizeSearchText(value) {
    return String(value ?? "")
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, " ")
      .replace(/\s+/g, " ")
      .trim();
  }

  function textMatchesSearch(displayText, rawQuery) {
    const query = normalizeSearchText(rawQuery);
    if (!query) return true;
    const haystack = normalizeSearchText(displayText);
    return haystack.includes(query);
  }

  function sortPlayersClient(rows, column, dir) {
    const asc = dir === "asc";
    const copy = [...rows];
    copy.sort((a, b) => {
      if (column === "Position") {
        const ai = POSITION_ORDER.indexOf(a.Position);
        const bi = POSITION_ORDER.indexOf(b.Position);
        const aIdx = ai === -1 ? 999 : ai;
        const bIdx = bi === -1 ? 999 : bi;
        return asc ? aIdx - bIdx : bIdx - aIdx;
      }
      const av = a[column];
      const bv = b[column];
      if (column === "Rating" || column === "Age" || column === "market_value") {
        const an = Number(av) || 0;
        const bn = Number(bv) || 0;
        return asc ? an - bn : bn - an;
      }
      const as = String(av ?? "");
      const bs = String(bv ?? "");
      return asc ? as.localeCompare(bs) : bs.localeCompare(as);
    });
    return copy;
  }

  function buildContractedTeamOrClause(values) {
    const hasFA = values.includes("FREE AGENT");
    const clubs = values.filter(v => v !== "FREE AGENT");

    const parts = [];

    if (clubs.length > 0) {
      const inList = clubs.join(",");
      parts.push(`Contracted_Team.in.(${inList})`);
    }

    if (hasFA) {
      parts.push("Contracted_Team.is.null", "Contracted_Team.eq.''", "Contracted_Team.eq.' '");
    }

    return parts.length ? parts.join(",") : null;
  }

  async function loadPage(page = 1) {
    CURRENT_PAGE = page;
    await loadPendingDirectOfferPlayers();

    const from = (page - 1) * PAGE_SIZE;
    const to = from + PAGE_SIZE - 1;
    const nameSearch = String(CURRENT_FILTERS.Name || "").trim();
    const useClientNameSearch = nameSearch.length > 0;

    let query = supabase
      .from("Players")
      .select(playerSelectList(), { count: "exact" });

    Object.entries(CURRENT_FILTERS).forEach(([col, value]) => {
      if (col === "Name") return;

      if (DROPDOWN_COLUMNS.includes(col)) {
        const values = Array.isArray(value) ? value : (value ? [value] : []);
        if (!values.length) return;

        if (col === "Contracted_Team") {
          const orClause = buildContractedTeamOrClause(values);
          if (orClause) {
            query = query.or(orClause);
          }
        } else {
          query = query.in(col, values);
        }
      } else {
        if (!value || value.trim() === "") return;
        query = query.ilike(col, `%${value}%`);
      }
    });

    if (MV_MIN !== null) query = query.gte("market_value", MV_MIN);
    if (MV_MAX !== null) query = query.lte("market_value", MV_MAX);

    if (CURRENT_SORT_COLUMN) {
      if (CURRENT_SORT_COLUMN === "Rating") {
        query = query
          .order("Rating", { ascending: false })
          .order("market_value", { ascending: false });
      } else if (CURRENT_SORT_COLUMN === "market_value") {
        query = query
          .order("market_value", { ascending: CURRENT_SORT_DIR === "asc" })
          .order("Rating", { ascending: false });
      } else if (CURRENT_SORT_COLUMN === "Position") {
        // client-side sort
      } else {
        query = query.order(CURRENT_SORT_COLUMN, {
          ascending: CURRENT_SORT_DIR === "asc"
        });
      }
    } else {
      query = query
        .order("Rating", { ascending: false })
        .order("market_value", { ascending: false });
    }

    if (useClientNameSearch) {
      query = query.limit(MAX_ROWS_FOR_NAME_SEARCH);
    } else {
      query = query.range(from, to);
    }

    let { data, error, count } = await query;

    if (error && isMissingEconomicsColumnError(error) && useEconomicsDbColumns) {
      useEconomicsDbColumns = false;
      return loadPage(page);
    }

    if (error) {
      console.error(error);
      return;
    }

    let filtered = data || [];

    if (useClientNameSearch) {
      filtered = filtered.filter((row) =>
        textMatchesSearch(row.Name, nameSearch)
      );
    }

    if (MV_MIN !== null || MV_MAX !== null) {
      filtered = filtered.filter(row => {
        const mv = Number(String(row.market_value).replace(/,/g, "").trim()) || 0;

        if (MV_MIN !== null && mv < MV_MIN) return false;
        if (MV_MAX !== null && mv > MV_MAX) return false;

        return true;
      });
    }

    if (useClientNameSearch) {
      filtered = sortPlayersClient(
        filtered,
        CURRENT_SORT_COLUMN,
        CURRENT_SORT_DIR
      );
      TOTAL_ROWS = filtered.length;
      filtered = filtered.slice(from, to + 1);
    } else if (CURRENT_SORT_COLUMN === "Position") {
      filtered.sort((a, b) => {
        const ai = POSITION_ORDER.indexOf(a.Position);
        const bi = POSITION_ORDER.indexOf(b.Position);
        const aIdx = ai === -1 ? 999 : ai;
        const bIdx = bi === -1 ? 999 : bi;
        return CURRENT_SORT_DIR === "asc" ? aIdx - bIdx : bIdx - aIdx;
      });
      TOTAL_ROWS = count;
    } else {
      TOTAL_ROWS = count;
    }

    renderTable(filtered);
    renderPagination();
  }

  function formatHeader(col) {
    if (col === "market_value") return "Market Value";
    if (col === "Maximum_Reserve_Price") return "Maximum Reserve Price";
    if (col === "Potential") return "Pot.";
    if (col === "Contracted_Team") return "Contracted Team";
    return col.replace(/_/g, " ");
  }

  /** Filter panel labels (Contracted Team highlights draft free agents). */
  function formatFilterLabel(col) {
    if (col === "Contracted_Team") {
      return 'Contracted Team <span class="gpdb-draft-filter-tag">(DRAFT)</span>';
    }
    return formatHeader(col);
  }

  function contractedTeamFilterHintHtml() {
    return `<div class="multi-filter-draft-hint">Select <b>FREE AGENT</b> to open draft bids here</div>`;
  }

  function formatCellValue(col, player) {
    let value = player[col];

    if (col === "Rating") {
      return player.Rating ?? "—";
    }

    if (col === "Potential") {
      const pot = calcPotentialForPlayer(player);
      return pot != null ? pot : "—";
    }

    if (col === "market_value" && value != null) {
      return `<span class="money">₿ ${Number(value).toLocaleString("en-GB")}</span>`;
    }

    if (col === "Maximum_Reserve_Price" && value != null) {
      return "₿ " + Number(value).toLocaleString("en-GB");
    }

    if (col === "Contracted_Team") {
      if (!value || String(value).trim() === "") return "";
      return CLUB_NAME_MAP[value] || value;
    }

    return value ?? "";
  }

  /* ============================================================
     MODULE F: Rendering (with Bid column)
     ============================================================ */

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
        <th></th>
        ${TABLE_DISPLAY_COLUMNS.map((col) => {
            let cls = "";
            if (CURRENT_SORT_COLUMN === col) {
              cls = CURRENT_SORT_DIR === "asc" ? "sort-asc" : "sort-desc";
            }
            return `<th data-col="${col}" class="${cls}">${formatHeader(col)}</th>`;
          })
          .join("")}
        <th>Bid</th>
      </tr>
    `;

    tableBody.innerHTML = players
      .map(player => {
        const hasClub = !!player.Contracted_Team;

        let bidCell = `<span class="locked-msg">Loading…</span>`;

        if (GLOBAL_SETTINGS) {
          if (hasClub) {
            const holderShort = resolveContractedClubShort(
              player.Contracted_Team
            );
            bidCell = TRANSFER_STATUS_STATE
              ? buildGpdbContractedBidCellHtml({
                  player,
                  viewerClubShort: CURRENT_USER_CLUB_SHORT,
                  state: TRANSFER_STATUS_STATE,
                  transferWindowOpen: GLOBAL_SETTINGS.transferWindowOpen,
                  holdingClubNation: CLUB_NATION_MAP[holderShort] || "",
                })
              : `<span class="locked-msg">Loading…</span>`;
          } else {
            const foreignLockHtml = formatForeignContractGpdbHtml(
              player,
              TRANSFER_STATUS_STATE
            );
            if (foreignLockHtml) {
              bidCell = foreignLockHtml;
            } else {
            const inDraft = ACTIVE_DRAFT_PLAYERS.has(String(player.Konami_ID).trim());

            if (inDraft) {
              bidCell = `<span class="locked-msg">In Draft Auction</span>`;
            } else if (GLOBAL_SETTINGS.draftAuctionEnabled) {
              const nowLocal = getUKNow();
              const draftStart = draftAuctionStartTime
                ? new Date(draftAuctionStartTime)
                : null;
              const phase = getDraftPhaseFromStart(nowLocal, draftStart);

              if (isGpdbFreeAgentOfferAllowed(nowLocal, draftStart)) {
                bidCell = `<button class="button make-offer-btn" data-player-id="${player.Konami_ID}">Draft Offer</button>`;
              } else {
                const lockMsg = gpdbFreeAgentLockMessage(phase) || "Draft Closed";
                bidCell = `<span class="locked-msg">${lockMsg}</span>`;
              }
            } else {
              bidCell = `<span class="locked-msg">Draft Closed</span>`;
            }
            }
          }
        }

        const imgURL = `https://pesdb.net/assets/img/card/b${player.Konami_ID}.png`;

        return `
          <tr data-konami-id="${player.Konami_ID}"
              data-rating="${player.Rating ?? ""}"
              data-playstyle="${player.Playstyle ?? ""}"
              data-market-value="${player.market_value ?? ""}"
              data-contracted-team="${player.Contracted_Team ?? ""}"
              data-season-signed="${player.Season_Signed ?? ""}"
              data-contract-seasons="${player.contract_seasons_remaining ?? ""}"
              data-nation="${player.Nation ?? ""}"
              data-age="${player.Age ?? ""}">
            <td>
              <img src="${imgURL}"
                   class="gpdb-thumb"
                   onerror="this.src='https://i.imgur.com/3s8XQ7Y.png'">
            </td>
            ${TABLE_DISPLAY_COLUMNS.map(
              (col) => `<td>${formatCellValue(col, player)}</td>`
            ).join("")}
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
     MODULE G: Offer Modal + Draft Helpers
     ============================================================ */

  let CURRENT_OFFER_PLAYER = null;
  let CURRENT_OFFER_MIN_BID = 0;

  async function openMakeOfferModal(konamiId) {
    const row = document.querySelector(`tr[data-konami-id="${konamiId}"]`);
    if (!row) return;

    const cells = row.querySelectorAll("td");
    const img = cells[0].querySelector("img");

    const name = cells[1].textContent.trim();
    const position = cells[2].textContent.trim();
    const playstyle = row.dataset.playstyle || cells[7]?.textContent?.trim() || "";
    const rating = row.dataset.rating || cells[5]?.textContent?.trim() || "";

    const mv =
      Number(row.dataset.marketValue) ||
      Number(String(cells[9]?.textContent || "").replace(/[^\d]/g, "")) ||
      0;

    const sellerRaw = row.dataset.contractedTeam || "";
    const sellerClub =
      !sellerRaw || sellerRaw === "FREE AGENT" ? null : sellerRaw.trim();

    CURRENT_OFFER_PLAYER = {
      Konami_ID: konamiId,
      Name: name,
      Position: position,
      Playstyle: playstyle,
      Rating: rating,
      Nation: row.dataset.nation || "",
      Age: row.dataset.age || "",
      market_value: mv,
      Contracted_Team: sellerClub,
      Season_Signed: row.dataset.seasonSigned || "",
      contract_seasons_remaining: row.dataset.contractSeasons || null,
    };

    const confirmBtn = document.getElementById("confirmOfferBtn");
    if (!sellerClub) {
      confirmBtn.textContent = "Submit opening draft bid";
    } else {
      confirmBtn.textContent = "Submit Offer for Review";
    }

    document.getElementById("offerPlayerImg").src = img.src;
    document.getElementById("offerPlayerName").textContent = name;
    document.getElementById("offerPlayerPosition").textContent = `Position: ${position}`;
    document.getElementById("offerPlayerPlaystyle").textContent = `Playstyle: ${playstyle}`;
    document.getElementById("offerPlayerRating").textContent = `Rating: ${rating}`;
    document.getElementById("offerPlayerMV").textContent = `Market Value: ₿ ${mv.toLocaleString("en-GB")}`;

    let draftWindowBids = [];
    if (!sellerClub) {
      draftWindowBids = await fetchCurrentDraftAuctionBids(
        konamiId,
        draftAuctionStartTime ? new Date(draftAuctionStartTime) : null
      );
    }
    CURRENT_OFFER_MIN_BID = sellerClub
      ? mv
      : draftMinimumBidAmount(mv, draftWindowBids);

    const offerMinNote = document.getElementById("offerMinNote");
    if (offerMinNote) {
      offerMinNote.textContent = sellerClub
        ? `Minimum offer for contracted players: market value (₿ ${mv.toLocaleString("en-GB")}).`
        : draftWindowBids.length
          ? `Minimum draft bid: current high + ₿500k (₿ ${CURRENT_OFFER_MIN_BID.toLocaleString("en-GB")}).`
          : `Opening draft bid: at least market value (₿ ${CURRENT_OFFER_MIN_BID.toLocaleString("en-GB")}).`;
    }

    document.getElementById("offerAmount").value =
      CURRENT_OFFER_MIN_BID.toLocaleString("en-GB");
    document.getElementById("offerError").textContent = "";

    let squadWarnEl = document.getElementById("offerSquadWarning");
    if (!squadWarnEl) {
      squadWarnEl = document.createElement("div");
      squadWarnEl.id = "offerSquadWarning";
      squadWarnEl.style.cssText =
        "color:#e6c200;font-size:12px;margin:8px 0;line-height:1.4;";
      const note = document.getElementById("offerMinNote");
      if (note?.parentNode) {
        note.parentNode.insertBefore(squadWarnEl, note.nextSibling);
      }
    }
    squadWarnEl.textContent = "";

    const { data: clubRow } = await supabase
      .from("Clubs")
      .select("ShortName")
      .eq("owner_id", CURRENT_USER?.id)
      .maybeSingle();

    if (clubRow?.ShortName) {
      const clubNation = CLUB_NATION_MAP[clubRow.ShortName] || "";
      const lines = await squadRulesBidWarningLines(
        supabase,
        clubRow.ShortName,
        clubNation,
        CURRENT_OFFER_PLAYER
      );
      if (lines.length) {
        squadWarnEl.textContent = lines.map((l) => `⚠ ${l}`).join("\n\n");
      }
    }

    const backdrop = document.getElementById("make-offer-modal-backdrop");
    backdrop.style.display = "flex";
  }

  function closeMakeOfferModal() {
    const backdrop = document.getElementById("make-offer-modal-backdrop");
    backdrop.style.display = "none";
    CURRENT_OFFER_PLAYER = null;
    CURRENT_OFFER_MIN_BID = 0;
  }

  document.getElementById("cancelOfferBtn").onclick = () => {
    closeMakeOfferModal();
  };

  document.getElementById("confirmOfferBtn").onclick = async () => {
    console.log("CONFIRM OFFER CLICKED", CURRENT_OFFER_PLAYER);

    const nowLocal = getUKNow();

    const input = document.getElementById("offerAmount");
    const errorBox = document.getElementById("offerError");

    let raw = input.value.replace(/,/g, "").trim();
    let offer = Number(raw);

    if (!offer || offer <= 0) {
      errorBox.textContent = "Enter a valid positive number.";
      return;
    }

    const mv = Number(CURRENT_OFFER_PLAYER.market_value) || 0;
    const sellerClub = CURRENT_OFFER_PLAYER.Contracted_Team;

    if (sellerClub && offer < mv) {
      errorBox.textContent = `Minimum direct offer is market value (₿ ${mv.toLocaleString("en-GB")}).`;
      return;
    }

    if (!sellerClub && offer < CURRENT_OFFER_MIN_BID) {
      errorBox.textContent = `Minimum draft bid is ₿ ${CURRENT_OFFER_MIN_BID.toLocaleString("en-GB")}.`;
      return;
    }

    if (
      sellerClub &&
      playerHasPendingDirectOffer(
        PENDING_DIRECT_OFFER_PLAYERS,
        CURRENT_OFFER_PLAYER.Konami_ID
      )
    ) {
      errorBox.textContent =
        "An offer is already under review for this player.";
      return;
    }
    console.log("CONFIRM: sellerClub =", sellerClub);

    if (
      !sellerClub &&
      playerForeignContractLocked(
        CURRENT_OFFER_PLAYER,
        TRANSFER_STATUS_STATE?.currentSeasonId
      )
    ) {
      errorBox.textContent = playerForeignContractStatusLabel(
        CURRENT_OFFER_PLAYER
      );
      return;
    }

    if (!sellerClub) {
      const draftStart = draftAuctionStartTime
        ? new Date(draftAuctionStartTime)
        : null;
      if (!isGpdbFreeAgentOfferAllowed(nowLocal, draftStart)) {
        const phase = getDraftPhaseFromStart(nowLocal, draftStart);
        errorBox.textContent =
          phase === "before_start"
            ? "Draft auction has not started yet."
            : "GPDB draft offers closed at 6pm UK. Use Draft Auction to bid on open threads until the random window ends.";
        return;
      }
    }

    console.log("CONFIRM: CURRENT_USER =", CURRENT_USER);

    const { data: clubRow, error: clubErr } = await supabase
      .from("Clubs")
      .select("ShortName, Nation")
      .eq("owner_id", CURRENT_USER.id)
      .single();

    console.log("CONFIRM: club lookup result =", { clubErr, clubRow });

    if (clubErr || !clubRow) {
      console.log("CONFIRM: aborting – club not found");
      errorBox.textContent = "Your club could not be found.";
      return;
    }

    const myClub = clubRow.ShortName;
    console.log("CONFIRM: myClub =", myClub);

    if (!sellerClub && !GLOBAL_SETTINGS.draftAuctionEnabled) {
      console.log("CONFIRM: draft disabled, free agent blocked");
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

    if (sellerClub && playerBlockedFromTransferMarket(
      CURRENT_OFFER_PLAYER,
      TRANSFER_STATUS_STATE?.currentSeasonLabel
    )) {
      errorBox.textContent = isContractFinalYear(CURRENT_OFFER_PLAYER)
        ? FINAL_YEAR_TRANSFER_MESSAGE
        : SAME_SEASON_TRANSFER_MESSAGE;
      return;
    }

    if (!sellerClub) {
      if (
        !(await confirmSquadRulesBeforeBid(
          supabase,
          myClub,
          clubRow.Nation,
          CURRENT_OFFER_PLAYER
        ))
      ) {
        return;
      }

      console.log("FREE AGENT DRAFT PATH: calling submitDraftBid with", {
        player: CURRENT_OFFER_PLAYER,
        offer,
        myClub
      });
      const result = await submitDraftBid(CURRENT_OFFER_PLAYER, offer, myClub);
      console.log("submitDraftBid RESULT:", result);

      if (!result.ok) {
        errorBox.textContent = result.msg;
        return;
      }

      ACTIVE_DRAFT_PLAYERS.add(String(CURRENT_OFFER_PLAYER.Konami_ID).trim());
      closeMakeOfferModal();
      await loadDraftCreditsForOwner();
      alert("Draft bid submitted!");
      loadPage(CURRENT_PAGE);
      return;
    }

    if (
      !(await confirmSquadRulesBeforeBid(
        supabase,
        myClub,
        clubRow.Nation,
        CURRENT_OFFER_PLAYER
      ))
    ) {
      return;
    }

    const konamiId = String(CURRENT_OFFER_PLAYER.Konami_ID).trim();
    const sellerShort = resolveContractedClubShort(sellerClub);
    const { error } = await supabase.from("Player_Transfer_Bids").insert({
      listing_id: null,
      player_id: konamiId,
      direct_bid_id: konamiId,
      bidder_club_id: myClub,
      seller_club_id: sellerShort,
      bid_amount: offer,
      bid_time: new Date().toISOString(),
      is_direct: true,
      status: "active",
    });

    if (error) {
      const msg = String(error.message || "");
      errorBox.textContent = msg.includes("current season")
        ? SAME_SEASON_TRANSFER_MESSAGE
        : msg.includes("already under review")
          ? "An offer is already under review for this player."
          : "Failed to submit offer.";
      console.error(error);
      return;
    }

    PENDING_DIRECT_OFFER_PLAYERS.add(
      String(CURRENT_OFFER_PLAYER.Konami_ID).trim()
    );
    closeMakeOfferModal();
    loadPage(CURRENT_PAGE);
  };

  /* ============================================================
     DRAFT AUCTION HELPERS
     ============================================================ */

  function getDraftAuctionTimesForNewListing() {
    const uk = getUKWallClockParts();

    const sevenPmToday = ukLocalToInstant(uk.year, uk.month, uk.day, 19, 0, 0);
    const baseEnd = ukLocalToInstant(uk.year, uk.month, uk.day + 1, 18, 50, 0);

    const extraSeconds = Math.floor(Math.random() * 600);
    const end = new Date(baseEnd.getTime() + extraSeconds * 1000);

    return { start: sevenPmToday, end };
  }

  async function ensureDraftListingForPlayer(player) {
    const konamiId = Number(player.Konami_ID);
    console.log("ensureDraftListingForPlayer START for", konamiId);

    const { data: existing, error: existingErr } = await supabase
      .from("Player_Transfer_Listings")
      .select("id, player_id, listing_type, status")
      .eq("player_id", String(konamiId))
      .eq("listing_type", "draft")
      .eq("status", "Active")
      .maybeSingle();

    console.log("ensureDraftListingForPlayer existing =", existing, "error =", existingErr);

    if (existing) {
      console.log("ensureDraftListingForPlayer: found existing listing", existing.id);
      return { ok: true, listingId: existing.id };
    }

    const { start, end } = getDraftAuctionTimesForNewListing();
    console.log("ensureDraftListingForPlayer: creating new listing with times", {
      start: start.toISOString(),
      end: end.toISOString()
    });

    const { data: listing, error } = await supabase
      .from("Player_Transfer_Listings")
      .insert({
        player_id: String(konamiId),
        seller_club_id: null,
        reserve_price: player.market_value || 0,
        listing_type: "draft",
        market_value: player.market_value || 0,
        status: "Active",
        start_time: start.toISOString(),
        end_time: end.toISOString(),
        initial_end_time: end.toISOString(),
        created_at: new Date().toISOString(),
      })
      .select("*")
      .single();

    console.log("ensureDraftListingForPlayer insert result =", listing, "error =", error);

    if (error || !listing) {
      console.error("Error creating draft listing:", error);
      return { ok: false, msg: "Error creating draft listing." };
    }

    console.log("ensureDraftListingForPlayer END OK listingId =", listing.id);
    return { ok: true, listingId: listing.id };
  }

  async function insertDraftBid(player, amount, club, isFirst, isJoin, consumeJoin, listingId) {
    const konamiKey = String(player.Konami_ID).trim();
    const { data, error } = await supabase
      .from("Player_Transfer_Bids")
      .insert({
        listing_id: listingId,
        player_id: konamiKey,
        direct_bid_id: konamiKey,
        bidder_club_id: club,
        bid_amount: amount,
        is_direct: true,
        is_first_draft_bid: isFirst,
        is_draft_join: isJoin,
        draft_join_consumed: consumeJoin,
        bid_time: new Date().toISOString()
      })
      .select("*")
      .single();

    if (error || !data) {
      console.error("Error inserting draft bid:", error);
      return { ok: false, msg: "Error submitting draft bid." };
    }

    return { ok: true, bid: data };
  }

  async function submitDraftBid(player, offerAmount, buyerShortName) {
    console.log("submitDraftBid START", { player, offerAmount, buyerShortName });

    const nowLocal = getUKNow();
    const draftStart = draftAuctionStartTime
      ? new Date(draftAuctionStartTime)
      : null;

    if (!isGpdbFreeAgentOfferAllowed(nowLocal, draftStart)) {
      const phase = getDraftPhaseFromStart(nowLocal, draftStart);
      console.log("submitDraftBid blocked: phase =", phase);
      return {
        ok: false,
        msg:
          phase === "before_start"
            ? "Draft auction has not started yet."
            : "GPDB draft offers closed at 6pm UK. Use Draft Auction to bid on open threads.",
      };
    }

    const existing = await fetchCurrentDraftAuctionBids(
      player.Konami_ID,
      draftStart
    );

    console.log("submitDraftBid existing draft bids (window) =", existing);

    const isFirstBid = existing.length === 0;
    const isJoining = !isFirstBid;

    console.log("submitDraftBid isFirstBid =", isFirstBid, "isJoining =", isJoining);

    const listingResult = await ensureDraftListingForPlayer(player);
    console.log("submitDraftBid listingResult =", listingResult);
    if (!listingResult.ok) return listingResult;

    const listingId = listingResult.listingId;
    console.log("submitDraftBid listingId =", listingId);

    let bidResult;

    if (isJoining) {
      console.log("submitDraftBid: JOINING existing auction");

      const priorJoin = existing.filter(
        (b) =>
          b.bidder_club_id === buyerShortName &&
          b.is_draft_join === true
      );

      console.log("submitDraftBid priorJoin =", priorJoin);

      if (priorJoin.length > 0) {
        bidResult = await insertDraftBid(
          player,
          offerAmount,
          buyerShortName,
          false,
          true,
          false,
          listingId
        );
      } else {
        const credits = await getDraftCreditsForGPDB(buyerShortName);
        console.log("submitDraftBid credits =", credits);

        if (credits <= 0) {
          console.log("submitDraftBid blocked: no credits");
          return {
            ok: false,
            msg:
              "You do not have enough draft credits to join this auction. Be the first club to bid on a free agent in GPDB to earn credits.",
          };
        }

        bidResult = await insertDraftBid(
          player,
          offerAmount,
          buyerShortName,
          false,
          true,
          true,
          listingId
        );
      }

    } else {
      console.log("submitDraftBid: FIRST BID path");
      bidResult = await insertDraftBid(
        player,
        offerAmount,
        buyerShortName,
        true,
        false,
        false,
        listingId
      );
    }

    console.log("submitDraftBid bidResult =", bidResult);

    if (!bidResult.ok) return bidResult;

    await syncDraftListingHighBid(
      supabase,
      listingId,
      player.Konami_ID,
      draftStart
    );

    console.log("submitDraftBid END OK");
    return { ok: true };
  }

  async function loadPendingDirectOfferPlayers() {
    TRANSFER_STATUS_STATE = await loadTransferStatusState(supabase);
    PENDING_DIRECT_OFFER_PLAYERS = TRANSFER_STATUS_STATE.pendingDirectAll;
    PENDING_DIRECT_OFFERS_FOR_MY_CLUB = sellerPendingPlayerIds(
      TRANSFER_STATUS_STATE,
      CURRENT_USER_CLUB_SHORT
    );
  }

  async function loadActiveDraftListings() {
    const { data, error } = await supabase
      .from("Player_Transfer_Listings")
      .select("player_id")
      .eq("listing_type", "draft")
      .eq("status", "Active");

    if (error) {
      console.error("Failed to load active draft listings", error);
      ACTIVE_DRAFT_PLAYERS = new Set();
      return;
    }

    ACTIVE_DRAFT_PLAYERS = new Set(
      (data || []).map(row => String(row.player_id).trim())
    );
  }

  document.querySelectorAll(".inc-btn, .dec-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      if (!CURRENT_OFFER_PLAYER) return;

      const inc = Number(btn.dataset.inc);
      const input = document.getElementById("offerAmount");

      let raw = input.value.replace(/,/g, "").trim();
      let val = Number(raw) || 0;

      val += inc;

      const minBid = CURRENT_OFFER_PLAYER.Contracted_Team
        ? Number(CURRENT_OFFER_PLAYER.market_value) || 0
        : CURRENT_OFFER_MIN_BID;
      if (val < minBid) val = minBid;

      input.value = val.toLocaleString("en-GB");
    });
  });

  document.getElementById("quickBidBtn").onclick = () => {
    if (!CURRENT_OFFER_PLAYER) return;
    const minBid = CURRENT_OFFER_PLAYER.Contracted_Team
      ? Number(CURRENT_OFFER_PLAYER.market_value) || 0
      : CURRENT_OFFER_MIN_BID;
    document.getElementById("offerAmount").value = minBid.toLocaleString("en-GB");
  };

  document.getElementById("offerAmount").addEventListener("input", e => {
    if (!CURRENT_OFFER_PLAYER) return;

    let raw = e.target.value.replace(/,/g, "").trim();
    let val = Number(raw);

    const minBid = CURRENT_OFFER_PLAYER.Contracted_Team
      ? Number(CURRENT_OFFER_PLAYER.market_value) || 0
      : CURRENT_OFFER_MIN_BID;

    if (isNaN(val) || val <= 0) {
      val = minBid;
    }

    if (val < minBid) val = minBid;

    e.target.value = val.toLocaleString("en-GB");
  });

  /* ============================================================
     MODULE H: Filters + Controls
     ============================================================ */

  function closeAllMultiFilters() {
    document.querySelectorAll(".multi-filter.open").forEach(el => {
      el.classList.remove("open");
    });
  }

  function renderMultiFilterOptions(col, searchQuery = "") {
    const panel = document.getElementById(`filter-${col}-panel`);
    const container = panel?.querySelector(".multi-filter-options");
    if (!container) return;

    const options = FILTER_OPTION_CACHE[col] || [];
    const checkedBefore = new Set();
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

    checkboxes.forEach(cb => {
      if (cb.checked) {
        selected.push(cb.value);
        labels.push(cb.getAttribute("data-label") || cb.value);
      }
    });

    CURRENT_FILTERS[col] = selected;

    if (selected.length === 0) {
      display.textContent = "All";
    } else if (selected.length === 1) {
      display.textContent = labels[0];
    } else {
      display.textContent = `${labels[0]} +${selected.length - 1}`;
    }

    loadPage(1);
  }

  async function populateDropdowns() {
    for (const col of DROPDOWN_COLUMNS) {
      const panel = document.getElementById(`filter-${col}-panel`);
      if (!panel) continue;

      let { data, error } = await supabase
        .from("Players")
        .select(col, { distinct: true });

      if (error || !data) {
        console.error(`Error loading distinct values for ${col}:`, error);
        continue;
      }

      let values = data
        .map(row => row[col])
        .filter(v => v !== null && v !== undefined);

      if (col === "Contracted_Team") {
        values = values.map(v => (v && String(v).trim() !== "" ? String(v).trim() : "FREE AGENT"));
      }

      let uniqueValues;

      if (col === "Season_Signed") {
        const nums = values.map((v) => Number(v)).filter((v) => !isNaN(v));
        const allNumeric = nums.length === values.length && values.length > 0;
        uniqueValues = allNumeric
          ? [...new Set(nums)].sort((a, b) => a - b)
          : [...new Set(values.map((v) => String(v).trim()))]
              .filter((v) => v !== "")
              .sort((a, b) => a.localeCompare(b));
      } else if (col === "Age" || col === "Rating") {
        uniqueValues = [...new Set(values.map(v => Number(v)))]
          .filter(v => !isNaN(v))
          .sort((a, b) => a - b);
      } else if (col === "Position") {
        uniqueValues = [...new Set(values.map(v => String(v).trim()))]
          .filter(v => v !== "")
          .sort((a, b) => {
            const ai = POSITION_ORDER.indexOf(a);
            const bi = POSITION_ORDER.indexOf(b);
            const aIdx = ai === -1 ? 999 : ai;
            const bIdx = bi === -1 ? 999 : bi;
            return aIdx - bIdx;
          });
      } else {
        uniqueValues = [...new Set(values.map(v => String(v).trim()))]
          .filter(v => v !== "")
          .sort((a, b) => a.localeCompare(b));
      }

      if (col === "Contracted_Team") {
        uniqueValues = ["FREE AGENT", ...uniqueValues.filter(v => v !== "FREE AGENT")];
      }

      FILTER_OPTION_CACHE[col] = uniqueValues.map((v) => {
        let value = v;
        let label = v;
        if (col === "Contracted_Team") {
          if (v === "FREE AGENT") {
            value = "FREE AGENT";
            label = "FREE AGENT";
          } else {
            value = v;
            label = CLUB_NAME_MAP[v] || v;
          }
        }
        return { value, label };
      });

      const searchInput = panel.querySelector(".multi-filter-search");
      if (searchInput && !searchInput.dataset.wired) {
        searchInput.dataset.wired = "1";
        searchInput.placeholder = "Type to narrow…";
        let searchDebounce = null;
        searchInput.addEventListener("input", () => {
          clearTimeout(searchDebounce);
          searchDebounce = setTimeout(() => {
            renderMultiFilterOptions(col, searchInput.value);
          }, 120);
        });
        searchInput.addEventListener("click", (e) => e.stopPropagation());
        searchInput.addEventListener("keydown", (e) => e.stopPropagation());
      }

      panel.addEventListener("click", (e) => e.stopPropagation());

      renderMultiFilterOptions(col, searchInput?.value || "");
    }
  }

  function setupFilters() {
    const filtersDiv = document.getElementById("filters");

    filtersDiv.innerHTML = COLUMNS
      .filter(col => !FILTER_EXCLUDE.includes(col))
      .map(col => {
        const labelPlain =
          col === "Contracted_Team"
            ? "Contracted Team (DRAFT)"
            : formatHeader(col);
        const labelHtml = formatFilterLabel(col);
        if (DROPDOWN_COLUMNS.includes(col)) {
          const draftHint =
            col === "Contracted_Team" ? contractedTeamFilterHintHtml() : "";
          return `
            <div class="multi-filter" data-col="${col}">
              <div class="multi-filter-label">${labelHtml}</div>
              ${draftHint}
              <div class="multi-filter-control" id="filter-${col}-display">All</div>
              <div class="multi-filter-panel" id="filter-${col}-panel">
                <input type="text" class="multi-filter-search" autocomplete="off" aria-label="Search ${labelPlain}">
                <div class="multi-filter-options"></div>
              </div>
            </div>
          `;
        } else {
          const textLabel = formatHeader(col);
          return `
            <label class="text-filter">
              ${textLabel}
              <input type="text" id="filter-${col}" placeholder="Filter ${textLabel} (ignores accents)">
            </label>
          `;
        }
      })
      .join("");
  }

  function setupTextFilters() {
    const textCols = COLUMNS.filter(
      (col) =>
        !FILTER_EXCLUDE.includes(col) && !DROPDOWN_COLUMNS.includes(col)
    );

    let debounceTimer = null;

    textCols.forEach((col) => {
      const input = document.getElementById(`filter-${col}`);
      if (!input) return;

      const apply = () => {
        const val = input.value.trim();
        if (val === "") {
          delete CURRENT_FILTERS[col];
        } else {
          CURRENT_FILTERS[col] = val;
        }
        loadPage(1);
      };

      input.addEventListener("input", () => {
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(apply, 300);
      });

      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          clearTimeout(debounceTimer);
          apply();
        }
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

    mvMinInput.style.width = "140px";
    mvMinInput.style.textAlign = "right";
    mvMaxInput.style.width = "140px";
    mvMaxInput.style.textAlign = "right";

    const parseMV = (val) => {
      const raw = val.replace(/[^\d]/g, "").trim();
      if (raw === "") return null;
      const num = Number(raw);
      return isNaN(num) ? null : num;
    };

    const formatMVInput = (inputEl) => {
      const raw = inputEl.value.replace(/[^\d]/g, "").trim();
      if (raw === "") {
        inputEl.value = "";
        return;
      }
      const num = Number(raw);
      if (!isNaN(num)) {
        inputEl.value = num.toLocaleString("en-GB");
      }
    };

    mvMinInput.addEventListener("input", () => formatMVInput(mvMinInput));
    mvMaxInput.addEventListener("input", () => formatMVInput(mvMaxInput));

    applyMV.addEventListener("click", () => {
      MV_MIN = parseMV(mvMinInput.value);
      MV_MAX = parseMV(mvMaxInput.value);
      loadPage(1);
    });

    document.getElementById("clearFiltersBtn").addEventListener("click", () => {
      CURRENT_FILTERS = {};
      MV_MIN = null;
      MV_MAX = null;
      CURRENT_SORT_COLUMN = "Rating";
      CURRENT_SORT_DIR = "desc";

      document
        .querySelectorAll("#filters input[type='text']")
        .forEach(i => (i.value = ""));

      document
        .querySelectorAll("#filters .multi-filter-options input[type='checkbox']")
        .forEach(cb => (cb.checked = false));

      document
        .querySelectorAll("#filters .multi-filter-search")
        .forEach((input) => {
          input.value = "";
          const col = input.closest(".multi-filter")?.dataset?.col;
          if (col) renderMultiFilterOptions(col, "");
        });

      DROPDOWN_COLUMNS.forEach(col => {
        const display = document.getElementById(`filter-${col}-display`);
        if (display) display.textContent = "All";
      });

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
    // Initialize global settings and build navigation
    await initGlobal();

    await loadUser();

    // Load global settings from draft_engine.js
    GLOBAL_SETTINGS = await loadGlobalSettingsEngine();

    draftAuctionStartTime =
      GLOBAL_SETTINGS.draftAuctionStartTime ||
      GLOBAL_SETTINGS.draftStart ||
      null;

    const timeline = getDraftTimelineFromStart(
      draftAuctionStartTime ? new Date(draftAuctionStartTime) : null
    );
    draftJoinWindowEnd = timeline?.publicEnd ?? null;

    await loadClubNames();
    await loadPlayerValueTables();

    setupControls();
    setupFilters();
    setupTextFilters();
    await populateDropdowns();
    await loadTotalCount();
    await loadActiveDraftListings();
    await loadPendingDirectOfferPlayers();
    await loadDraftCreditsForOwner();
    loadPage(1);
  }

  init();

}); // end DOMContentLoaded
