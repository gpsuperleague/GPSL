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

import { formatMoney } from "./competition.js";
import { loadWagePercentages, wageFromMarketValue } from "./wages.js";
import { mountClubBankBalance } from "./club_bank_balance_ui.js";

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
  loadActiveSuspensions,
  suspensionsByPlayerId,
  formatSuspensionBadgeHtml,
} from "./player_discipline.js";
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
import {
  loadMyNation,
  loadNationalSquad,
  loadInternationalCareerMap,
  callUpPlayer,
  releaseCallup,
  playerBelongsToNation,
  summarizeNationalSquad,
  gpdbNationFilterValues,
  clubNationFilterValues,
  resolveNationFromLabel,
  renderNationFlag,
  NATIONAL_SQUAD_MAX,
} from "./international.js";
import {
  playerThumbLinkHtml,
  playerNameLinkHtml,
  pesdbPlayerUrl,
} from "./player_links.js";
import {
  loadScoutingTargetMap,
  toggleScoutingTarget,
  scoutingStarChar,
  isScoutingAvailable,
} from "./scouting_targets.js";

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
    "foreign_contract_lock_kind",
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
    "intl_caps",
    "intl_goals",
    "intl_assists",
    "intl_potm",
    "intl_clean_sheets",
    "intl_avg_rating",
  ];

  const INTL_STAT_COLUMNS = new Set([
    "intl_caps",
    "intl_goals",
    "intl_assists",
    "intl_potm",
    "intl_clean_sheets",
    "intl_avg_rating",
  ]);

  const FILTER_EXCLUDE = [
    "Maximum_Reserve_Price",
    "Konami_ID",
    "Potential",
    "Calc_Potential",
    "foreign_contract_club",
    "foreign_contract_sold_season_id",
    "foreign_contract_unlock_season_label",
    "foreign_contract_lock_kind",
    "intl_caps",
    "intl_goals",
    "intl_assists",
    "intl_potm",
    "intl_clean_sheets",
    "intl_avg_rating",
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
    "Playstyle",
    "Contracted_Team",
  ];

  const RANGE_FILTER_COLUMNS = [
    "Rating",
    "Age",
    "Season_Signed",
    "market_value",
    "contract_seasons_remaining",
    "contract_wage",
  ];

  const MARKET_VALUE_FILTER_MIN = 0;
  const MARKET_VALUE_FILTER_MAX = 200_000_000;
  const MARKET_VALUE_FILTER_STEP = 1_000_000;
  /** Dual-range UI uses whole millions (0–200) so step aligns with the browser. */
  const MARKET_VALUE_SLIDER_MAX_M = 200;

  /** Championship % of MV — forecast wage for unsigned players in GPDB filters. */
  const WAGE_FORECAST_TIER = "championship";
  const CONTRACT_WAGE_FILTER_STEP = 10_000;

  let WAGE_FORECAST_SETTINGS = { superleague: 5, championship: 4 };
  const GPDB_PLAYERS_VIEW = "gpdb_players_view";
  let gpdbUseEffectiveWageView = false;
  let gpdbHasMarketValueN = false;

  async function probeGpdbPlayersView() {
    const { error } = await supabase
      .from(GPDB_PLAYERS_VIEW)
      .select("Konami_ID", { head: true, count: "exact" });

    gpdbUseEffectiveWageView = !error;
    gpdbHasMarketValueN = false;
    if (error) {
      console.warn(
        "GPDB effective_wage view unavailable — run supabase/sql/patches/gpdb_effective_wage_view.sql",
        error
      );
      return;
    }

    const probeN = await supabase
      .from(GPDB_PLAYERS_VIEW)
      .select("market_value_n", { head: true })
      .limit(1);
    gpdbHasMarketValueN = !probeN.error;
    if (probeN.error) {
      console.warn(
        "GPDB market_value_n missing — run supabase/sql/patches/gpdb_market_value_numeric_filter.sql",
        probeN.error
      );
    }
  }

  function gpdbPlayersFrom() {
    return supabase.from(gpdbUseEffectiveWageView ? GPDB_PLAYERS_VIEW : "Players");
  }

  function effectiveWageForPlayer(player) {
    const stored = Number(player?.contract_wage);
    if (Number.isFinite(stored) && stored > 0) return stored;
    return forecastWageFromMarketValue(player.market_value);
  }

  function refinePlayersByMarketValue(players, mvMin, mvMax) {
    const lo = Number(mvMin);
    const hi = Number(mvMax);
    if (!Number.isFinite(lo) || !Number.isFinite(hi)) return players;
    return players.filter((player) => {
      const mv = Number(
        nullifNumeric(player?.market_value_n ?? player?.market_value)
      );
      if (!Number.isFinite(mv)) return false;
      return mv >= lo && mv <= hi;
    });
  }

  function nullifNumeric(value) {
    if (value == null || value === "") return NaN;
    const n = Number(String(value).replace(/,/g, "").trim());
    return Number.isFinite(n) ? n : NaN;
  }

  function refinePlayersByContractWage(players, wMin, wMax) {
    return players.filter((player) => {
      const wage = effectiveWageForPlayer(player);
      return wage >= wMin && wage <= wMax;
    });
  }

  async function loadWageForecastSettings() {
    WAGE_FORECAST_SETTINGS = await loadWagePercentages(supabase);
  }

  function forecastWageFromMarketValue(mv) {
    return wageFromMarketValue(mv, WAGE_FORECAST_TIER, WAGE_FORECAST_SETTINGS);
  }

  function marketValueBoundsForForecastWage(wMin, wMax) {
    const pct =
      WAGE_FORECAST_TIER === "superleague"
        ? WAGE_FORECAST_SETTINGS.superleague
        : WAGE_FORECAST_SETTINGS.championship;
    const rate = pct / 100;
    if (rate <= 0) {
      return { mvMin: 0, mvMax: 0 };
    }
    const mvMin = wMin <= 0 ? 0 : Math.max(0, Math.ceil((wMin - 0.5) / rate));
    const mvMax = Math.min(
      MARKET_VALUE_FILTER_MAX,
      Math.floor((wMax + 0.5) / rate)
    );
    return { mvMin, mvMax: Math.max(mvMin, mvMax) };
  }

  function applyContractWageFilter(query, wMin, wMax) {
    if (gpdbUseEffectiveWageView) {
      return query.gte("effective_wage", wMin).lte("effective_wage", wMax);
    }

    const { mvMin, mvMax } = marketValueBoundsForForecastWage(wMin, wMax);
    const signedClause = `and(contract_wage.gt.0,contract_wage.gte.${wMin},contract_wage.lte.${wMax})`;
    const forecastClause = `and(or(contract_wage.is.null,contract_wage.lte.0),market_value.gte.${mvMin},market_value.lte.${mvMax})`;
    return query.or(`${signedClause},${forecastClause}`);
  }

  function snapContractWage(n) {
    const num = Number(n);
    if (!Number.isFinite(num)) return 0;
    const bounds = RANGE_BOUNDS.contract_wage;
    const floor = bounds?.min ?? 0;
    const ceiling = bounds?.max ?? num;
    const clamped = Math.max(floor, Math.min(num, ceiling));
    const snapped =
      Math.round(clamped / CONTRACT_WAGE_FILTER_STEP) * CONTRACT_WAGE_FILTER_STEP;
    return Math.max(floor, Math.min(snapped, ceiling));
  }

  function normalizeContractWageActive() {
    const bounds = RANGE_BOUNDS.contract_wage;
    if (!bounds) return;

    const active = RANGE_ACTIVE.contract_wage || {
      min: bounds.min,
      max: bounds.max,
    };
    let lo = snapContractWage(active.min);
    let hi = snapContractWage(active.max);
    if (lo > hi) [lo, hi] = [hi, lo];
    RANGE_ACTIVE.contract_wage = { min: lo, max: hi };
  }

  async function loadContractWageBounds() {
    const relation = gpdbUseEffectiveWageView ? GPDB_PLAYERS_VIEW : "Players";
    const wageCol = gpdbUseEffectiveWageView ? "effective_wage" : "contract_wage";

    const [{ data: minRows, error: minErr }, { data: maxRows, error: maxErr }] =
      await Promise.all([
        supabase
          .from(relation)
          .select(wageCol)
          .not(wageCol, "is", null)
          .gt(wageCol, 0)
          .order(wageCol, { ascending: true })
          .limit(1),
        supabase
          .from(relation)
          .select(wageCol)
          .not(wageCol, "is", null)
          .gt(wageCol, 0)
          .order(wageCol, { ascending: false })
          .limit(1),
      ]);

    if (minErr || maxErr) {
      console.error("Error loading contract wage bounds:", minErr || maxErr);
    }

    const forecastMin = forecastWageFromMarketValue(MARKET_VALUE_FILTER_MIN);
    const forecastMax = forecastWageFromMarketValue(MARKET_VALUE_FILTER_MAX);

    let min = Number(minRows?.[0]?.[wageCol]);
    let max = Number(maxRows?.[0]?.[wageCol]);
    if (!Number.isFinite(min)) min = forecastMin;
    if (!Number.isFinite(max)) max = forecastMax;

    min = Math.min(min, forecastMin);
    max = Math.max(max, forecastMax);

    RANGE_BOUNDS.contract_wage = {
      type: "numeric",
      min,
      max,
      step: CONTRACT_WAGE_FILTER_STEP,
    };
    RANGE_ACTIVE.contract_wage = { min, max };
  }

  function snapMarketValue(n) {
    const num = Number(n);
    if (!Number.isFinite(num)) return MARKET_VALUE_FILTER_MIN;
    const clamped = Math.max(
      MARKET_VALUE_FILTER_MIN,
      Math.min(num, MARKET_VALUE_FILTER_MAX)
    );
    const snapped =
      Math.round(clamped / MARKET_VALUE_FILTER_STEP) * MARKET_VALUE_FILTER_STEP;
    return Math.max(
      MARKET_VALUE_FILTER_MIN,
      Math.min(snapped, MARKET_VALUE_FILTER_MAX)
    );
  }

  function marketValueToSlider(value) {
    return Math.round(snapMarketValue(value) / MARKET_VALUE_FILTER_STEP);
  }

  function marketValueFromSlider(sliderVal) {
    const n = Number(sliderVal);
    if (!Number.isFinite(n)) return MARKET_VALUE_FILTER_MIN;
    return snapMarketValue(n * MARKET_VALUE_FILTER_STEP);
  }

  function normalizeMarketValueActive() {
    const bounds = RANGE_BOUNDS.market_value;
    if (!bounds) return;

    const active = RANGE_ACTIVE.market_value || {
      min: bounds.min,
      max: bounds.max,
    };
    let lo = snapMarketValue(active.min);
    let hi = snapMarketValue(active.max);
    if (lo > hi) [lo, hi] = [hi, lo];
    RANGE_ACTIVE.market_value = { min: lo, max: hi };
  }

  function setMarketValueBounds() {
    RANGE_BOUNDS.market_value = {
      type: "numeric",
      min: MARKET_VALUE_FILTER_MIN,
      max: MARKET_VALUE_FILTER_MAX,
      step: MARKET_VALUE_FILTER_STEP,
    };
    RANGE_ACTIVE.market_value = {
      min: MARKET_VALUE_FILTER_MIN,
      max: MARKET_VALUE_FILTER_MAX,
    };
  }

  function rangeFilterStep(col) {
    if (col === "market_value") return MARKET_VALUE_FILTER_STEP;
    if (col === "contract_wage") return CONTRACT_WAGE_FILTER_STEP;
    const bounds = RANGE_BOUNDS[col];
    if (bounds?.step) return bounds.step;
    return 1;
  }

  function normalizedRangeActive(col) {
    const active = RANGE_ACTIVE[col] || { min: 0, max: 0 };
    const lo = Math.min(active.min, active.max);
    const hi = Math.max(active.min, active.max);
    if (col === "market_value") {
      return { min: snapMarketValue(lo), max: snapMarketValue(hi) };
    }
    if (col === "contract_wage") {
      return { min: snapContractWage(lo), max: snapContractWage(hi) };
    }
    return { min: lo, max: hi };
  }

  const FILTER_LAYOUT_ROWS = [
    ["Position", "Nation", "Age", "Rating", "Playstyle"],
    ["Name", "market_value", "Contracted_Team"],
    ["Season_Signed", "contract_seasons_remaining", "contract_wage"],
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
  let TOTAL_PLAYERS_ALL = 0;
  let CURRENT_PAGE = 1;

  let CURRENT_FILTERS = {};
  const FILTER_OPTION_CACHE = {};

  let CURRENT_SORT_COLUMN = "Rating";
  let CURRENT_SORT_DIR = "desc";

  /** @type {Record<string, { type: 'numeric', min: number, max: number } | { type: 'ordinal', values: string[] }>} */
  const RANGE_BOUNDS = {};
  /** @type {Record<string, { min: number, max: number }>} */
  const RANGE_ACTIVE = {};
  let useNameSearchKey = true;

  /* ============================================================
     MODULE D: Global Settings Loader
     ============================================================ */

  let GLOBAL_SETTINGS = null;
  let CURRENT_USER = null;
  let ACTIVE_DRAFT_PLAYERS = new Set();
  let PENDING_DIRECT_OFFER_PLAYERS = new Set();
  let PENDING_DIRECT_OFFERS_FOR_MY_CLUB = new Set();
  let TRANSFER_STATUS_STATE = null;
  /** @type {Map<string, any[]>} */
  let GPDB_SUSPENSIONS_BY_PLAYER = new Map();
  let CURRENT_USER_CLUB_SHORT = null;
  /** @type {Map<string, number>} */
  let SCOUTING_TARGET_MAP = new Map();
  let SCOUTED_ONLY = false;

  const GPDB_FILTER_STORAGE_PREFIX = "gpsl_gpdb_filters_";

  function gpdbFilterStorageKey() {
    return CURRENT_USER?.id
      ? `${GPDB_FILTER_STORAGE_PREFIX}${CURRENT_USER.id}`
      : null;
  }

  function loadSavedGpdbFilters() {
    const key = gpdbFilterStorageKey();
    if (!key) return null;
    try {
      const raw = localStorage.getItem(key);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      return parsed && typeof parsed === "object" ? parsed : null;
    } catch {
      return null;
    }
  }

  function clampSavedRangeActive(col, savedRange) {
    const bounds = RANGE_BOUNDS[col];
    if (!bounds || !savedRange || typeof savedRange !== "object") return;

    if (bounds.type === "numeric") {
      let lo = Number(savedRange.min);
      let hi = Number(savedRange.max);
      if (isNaN(lo) || isNaN(hi)) return;
      if (col === "market_value") {
        lo = snapMarketValue(lo);
        hi = snapMarketValue(hi);
      } else if (col === "contract_wage") {
        lo = snapContractWage(lo);
        hi = snapContractWage(hi);
      } else {
        lo = Math.max(bounds.min, Math.min(lo, bounds.max));
        hi = Math.max(bounds.min, Math.min(hi, bounds.max));
      }
      if (lo > hi) [lo, hi] = [hi, lo];
      RANGE_ACTIVE[col] = { min: lo, max: hi };
      return;
    }

    const loVal = savedRange.minValue ?? savedRange.min;
    const hiVal = savedRange.maxValue ?? savedRange.max;
    if (loVal == null || hiVal == null) return;

    let minIdx = bounds.values.indexOf(String(loVal));
    let maxIdx = bounds.values.indexOf(String(hiVal));
    if (minIdx === -1) minIdx = 0;
    if (maxIdx === -1) maxIdx = Math.max(bounds.values.length - 1, 0);
    if (minIdx > maxIdx) [minIdx, maxIdx] = [maxIdx, minIdx];
    RANGE_ACTIVE[col] = { min: minIdx, max: maxIdx };
  }

  function applySavedGpdbFilterState(saved) {
    if (!saved || typeof saved !== "object") return;

    if (saved.filters && typeof saved.filters === "object") {
      CURRENT_FILTERS = {};
      for (const [col, value] of Object.entries(saved.filters)) {
        if (DROPDOWN_COLUMNS.includes(col)) {
          const values = Array.isArray(value) ? value : value ? [value] : [];
          if (values.length) CURRENT_FILTERS[col] = values.map(String);
        } else if (typeof value === "string" && value.trim() !== "") {
          CURRENT_FILTERS[col] = value;
        }
      }
    }

    if (saved.range && typeof saved.range === "object") {
      for (const [col, range] of Object.entries(saved.range)) {
        if (RANGE_FILTER_COLUMNS.includes(col)) {
          clampSavedRangeActive(col, range);
        }
      }
    }

    normalizeMarketValueActive();
    normalizeContractWageActive();

    if (typeof saved.scoutedOnly === "boolean") {
      SCOUTED_ONLY = saved.scoutedOnly;
    }
    if (saved.sortColumn) CURRENT_SORT_COLUMN = saved.sortColumn;
    if (saved.sortDir === "asc" || saved.sortDir === "desc") {
      CURRENT_SORT_DIR = saved.sortDir;
    }
  }

  function serializeGpdbFilters() {
    const range = {};
    for (const col of RANGE_FILTER_COLUMNS) {
      const bounds = RANGE_BOUNDS[col];
      const active = RANGE_ACTIVE[col];
      if (!bounds || !active || !isRangeFilterActive(col)) continue;

      if (bounds.type === "numeric") {
        range[col] = { min: active.min, max: active.max };
      } else {
        range[col] = {
          minValue: bounds.values[active.min],
          maxValue: bounds.values[active.max],
        };
      }
    }

    return {
      filters: CURRENT_FILTERS,
      range,
      scoutedOnly: SCOUTED_ONLY,
      sortColumn: CURRENT_SORT_COLUMN,
      sortDir: CURRENT_SORT_DIR,
    };
  }

  function saveGpdbFilters() {
    const key = gpdbFilterStorageKey();
    if (!key) return;

    const payload = serializeGpdbFilters();
    const hasDropdownOrText = Object.entries(payload.filters || {}).some(
      ([col, value]) => {
        if (DROPDOWN_COLUMNS.includes(col)) {
          return Array.isArray(value) && value.length > 0;
        }
        return typeof value === "string" && value.trim() !== "";
      }
    );
    const hasRange = Object.keys(payload.range || {}).length > 0;
    const hasScouted = !!payload.scoutedOnly;
    const hasCustomSort =
      payload.sortColumn !== "Rating" || payload.sortDir !== "desc";

    if (!hasDropdownOrText && !hasRange && !hasScouted && !hasCustomSort) {
      localStorage.removeItem(key);
      return;
    }

    try {
      localStorage.setItem(key, JSON.stringify(payload));
    } catch (err) {
      console.warn("GPDB filter save failed:", err);
    }
  }

  function clearGpdbFilterStorage() {
    const key = gpdbFilterStorageKey();
    if (key) localStorage.removeItem(key);
  }

  function restoreGpdbFilterUi() {
    const textCols = COLUMNS.filter(
      (col) =>
        !FILTER_EXCLUDE.includes(col) &&
        !DROPDOWN_COLUMNS.includes(col) &&
        !RANGE_FILTER_COLUMNS.includes(col)
    );

    textCols.forEach((col) => {
      const val = CURRENT_FILTERS[col];
      const input = document.getElementById(`filter-${col}`);
      if (input && typeof val === "string") input.value = val;
    });

    DROPDOWN_COLUMNS.forEach((col) => {
      const values = CURRENT_FILTERS[col];
      if (!Array.isArray(values) || !values.length) return;

      const panel = document.getElementById(`filter-${col}-panel`);
      if (!panel) return;

      const selected = new Set(values.map(String));
      panel
        .querySelectorAll(".multi-filter-options input[type='checkbox']")
        .forEach((cb) => {
          cb.checked = selected.has(cb.value);
        });
      updateMultiFilterDisplay(col, { reload: false });
    });

    const scoutedBtn = document.getElementById("myScoutedFilterBtn");
    if (scoutedBtn) scoutedBtn.classList.toggle("is-active", SCOUTED_ONLY);
  }

  let CLUB_NAME_MAP = {};
  let CLUB_NATION_MAP = {};
  /** Full Clubs.Club name → ShortName (for direct-offer seller_club_id). */
  let CLUB_SHORT_BY_FULL_NAME = {};

  let MY_NATION = null;
  let MY_CLUB_NATION = null;
  let NATIONAL_CALLED_UP = new Set();
  let NATIONAL_SQUAD_SUMMARY = null;
  /** Season exclusions — grey out + block bids/call-ups (player ids + nation labels/codes). */
  let SEASON_EXCLUDED_PLAYER_IDS = new Set();
  let SEASON_EXCLUDED_NATION_LABELS = new Set();
  let SEASON_EXCLUDED_NATION_CODES = new Set();
  /** Special-auction reserves — block draft bids in GPDB. */
  let AUCTION_EXCLUDED_PLAYER_IDS = new Set();

  async function loadSeasonExclusions() {
    SEASON_EXCLUDED_PLAYER_IDS = new Set();
    SEASON_EXCLUDED_NATION_LABELS = new Set();
    SEASON_EXCLUDED_NATION_CODES = new Set();
    try {
      const { data, error } = await supabase.rpc("gpdb_season_exclusions_bundle", {
        p_season_id: null,
      });
      if (error) {
        const retry = await supabase.rpc("gpdb_season_exclusions_bundle");
        if (retry.error) {
          console.warn("gpdb_season_exclusions_bundle:", error, retry.error);
          return;
        }
        applyExclusionBundle(retry.data);
        return;
      }
      applyExclusionBundle(data);
    } catch (e) {
      console.warn("loadSeasonExclusions:", e);
    }
  }

  async function loadAuctionExclusions() {
    AUCTION_EXCLUDED_PLAYER_IDS = new Set();
    try {
      const { data, error } = await supabase
        .from("auction_exclusion_players")
        .select("player_id");
      if (error) {
        console.warn("auction_exclusion_players:", error);
        return;
      }
      for (const row of data || []) {
        const s = String(row?.player_id ?? "").trim();
        if (s) AUCTION_EXCLUDED_PLAYER_IDS.add(s);
      }
    } catch (e) {
      console.warn("loadAuctionExclusions:", e);
    }
  }

  function applyExclusionBundle(data) {
    for (const id of data?.player_ids || []) {
      const s = String(id).trim();
      if (s) SEASON_EXCLUDED_PLAYER_IDS.add(s);
    }
    for (const lab of data?.nation_labels || []) {
      const s = String(lab).trim();
      if (s) {
        SEASON_EXCLUDED_NATION_LABELS.add(s);
        SEASON_EXCLUDED_NATION_LABELS.add(s.toLowerCase());
      }
    }
    for (const code of data?.nation_codes || []) {
      const s = String(code).trim().toUpperCase();
      if (s) SEASON_EXCLUDED_NATION_CODES.add(s);
    }
  }

  function isSeasonExcludedPlayer(player) {
    if (!player) return false;
    const id = String(player.Konami_ID ?? "").trim();
    if (id && SEASON_EXCLUDED_PLAYER_IDS.has(id)) return true;

    const nation = String(player.Nation ?? "").trim();
    if (!nation) return false;
    if (SEASON_EXCLUDED_NATION_LABELS.has(nation)) return true;
    if (SEASON_EXCLUDED_NATION_LABELS.has(nation.toLowerCase())) return true;
    if (SEASON_EXCLUDED_NATION_CODES.has(nation.toUpperCase())) return true;

    // Match international nation codes via same normalize used for call-ups
    for (const code of SEASON_EXCLUDED_NATION_CODES) {
      if (playerBelongsToNation(player, { code, name: code })) return true;
    }
    return false;
  }

  function isAuctionExcludedPlayer(player) {
    if (!player) return false;
    const id = String(player.Konami_ID ?? "").trim();
    return !!(id && AUCTION_EXCLUDED_PLAYER_IDS.has(id));
  }

  function seasonExcludedBidHtml() {
    return `<span class="locked-msg gpdb-excluded-msg" title="Admin season exclusion">Unavailable</span>`;
  }

  function auctionExcludedBidHtml() {
    return `<span class="locked-msg gpdb-auction-reserved-msg" title="Reserved for a special auction — not available in the draft">Reserved for special auction</span>`;
  }

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
      const scoutedBtn = document.getElementById("myScoutedFilterBtn");
      if (scoutedBtn) {
        scoutedBtn.hidden = !CURRENT_USER_CLUB_SHORT;
        scoutedBtn.classList.toggle("is-active", SCOUTED_ONLY);
      }
      if (CURRENT_USER_CLUB_SHORT) {
        try {
          SCOUTING_TARGET_MAP = await loadScoutingTargetMap(
            supabase,
            CURRENT_USER_CLUB_SHORT
          );
        } catch (err) {
          console.warn("Scouting targets:", err);
          SCOUTING_TARGET_MAP = new Map();
        }
      }
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

    TOTAL_PLAYERS_ALL = count ?? 0;
    updatePlayerCountDisplay();
  }

  function updatePlayerCountDisplay() {
    const el = document.getElementById("gpdbPlayerCount");
    if (!el) return;

    const filtered = Number(TOTAL_ROWS) || 0;
    const all = Number(TOTAL_PLAYERS_ALL) || 0;
    if (!all) {
      el.textContent = "";
      return;
    }

    el.textContent = `${filtered.toLocaleString("en-GB")} / ${all.toLocaleString("en-GB")} players`;
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

  function applyTextColumnFilter(query, col, value) {
    if (!value || value.trim() === "") return query;
    if (col === "Name" && useNameSearchKey) {
      const normalized = normalizeSearchText(value);
      if (!normalized) return query;
      return query.ilike("name_search_key", `%${normalized}%`);
    }
    return query.ilike(col, `%${value}%`);
  }

  async function loadPage(page = 1) {
    CURRENT_PAGE = page;
    await loadPendingDirectOfferPlayers();

    const from = (page - 1) * PAGE_SIZE;
    const to = from + PAGE_SIZE - 1;

    let query = gpdbPlayersFrom()
      .select(playerSelectList(), { count: "exact" });

    Object.entries(CURRENT_FILTERS).forEach(([col, value]) => {
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
        query = applyTextColumnFilter(query, col, value);
      }
    });

    for (const col of RANGE_FILTER_COLUMNS) {
      if (col === "market_value") {
        const bounds = RANGE_BOUNDS[col];
        const active = normalizedRangeActive(col);
        if (bounds && active && isRangeFilterActive(col)) {
          // Prefer numeric view column — text market_value compares lexicographically
          // ("39975000" incorrectly passes lte "4000000").
          if (gpdbUseEffectiveWageView && gpdbHasMarketValueN) {
            query = query.gte("market_value_n", active.min).lte("market_value_n", active.max);
          } else {
            query = query.gte("market_value", active.min).lte("market_value", active.max);
          }
        }
        continue;
      }
      if (col === "contract_wage") {
        const bounds = RANGE_BOUNDS[col];
        const active = normalizedRangeActive(col);
        if (bounds && active && isRangeFilterActive(col)) {
          query = applyContractWageFilter(query, active.min, active.max);
        }
        continue;
      }
      const inValues = getRangeFilterInValues(col);
      if (inValues?.length) {
        query = query.in(col, inValues);
      }
    }

    if (SCOUTED_ONLY && CURRENT_USER_CLUB_SHORT) {
      const scoutIds = Array.from(SCOUTING_TARGET_MAP.keys()).filter(Boolean);
      if (!scoutIds.length) {
        TOTAL_ROWS = 0;
        renderTable([]);
        renderPagination();
        updatePlayerCountDisplay();
        return;
      }
      query = query.in("Konami_ID", scoutIds);
    }

    if (CURRENT_SORT_COLUMN) {
      if (CURRENT_SORT_COLUMN === "Rating") {
        query = query
          .order("Rating", { ascending: false })
          .order("market_value", { ascending: false });
      } else if (CURRENT_SORT_COLUMN === "market_value") {
        query = query
          .order("market_value", { ascending: CURRENT_SORT_DIR === "asc" })
          .order("Rating", { ascending: false });
      } else if (
        CURRENT_SORT_COLUMN === "Position" ||
        INTL_STAT_COLUMNS.has(CURRENT_SORT_COLUMN)
      ) {
        // client-side sort (intl stats joined after fetch)
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

    query = query.range(from, to);

    let { data, error, count } = await query;

    if (error && gpdbUseEffectiveWageView && String(error.message || "").includes("effective_wage")) {
      console.warn("GPDB falling back from effective_wage view:", error);
      gpdbUseEffectiveWageView = false;
      gpdbHasMarketValueN = false;
      return loadPage(page);
    }

    if (
      error &&
      gpdbHasMarketValueN &&
      String(error.message || "").includes("market_value_n")
    ) {
      console.warn(
        "GPDB market_value_n filter failed — run gpdb_market_value_numeric_filter.sql",
        error
      );
      gpdbHasMarketValueN = false;
      return loadPage(page);
    }

    if (error && isMissingEconomicsColumnError(error) && useEconomicsDbColumns) {
      useEconomicsDbColumns = false;
      return loadPage(page);
    }

    if (
      error &&
      useNameSearchKey &&
      String(error.message || "").includes("name_search_key") &&
      Object.prototype.hasOwnProperty.call(CURRENT_FILTERS, "Name")
    ) {
      console.warn("GPDB name search: run supabase/sql/patches/gpdb_name_search.sql");
      useNameSearchKey = false;
      return loadPage(page);
    }

    if (error) {
      console.error(error);
      return;
    }

    let filtered = data || [];

    const mvBounds = RANGE_BOUNDS.market_value;
    const mvActive = normalizedRangeActive("market_value");
    if (mvBounds && mvActive && isRangeFilterActive("market_value")) {
      filtered = refinePlayersByMarketValue(filtered, mvActive.min, mvActive.max);
    }

    const wageBounds = RANGE_BOUNDS.contract_wage;
    const wageActive = normalizedRangeActive("contract_wage");
    if (
      wageBounds &&
      wageActive &&
      isRangeFilterActive("contract_wage") &&
      !gpdbUseEffectiveWageView
    ) {
      filtered = refinePlayersByContractWage(
        filtered,
        wageActive.min,
        wageActive.max
      );
    }

    const careerMap = await loadInternationalCareerMap(
      filtered.map((p) => p.Konami_ID)
    );
    filtered = attachIntlStats(filtered, careerMap);

    if (CURRENT_SORT_COLUMN === "Position") {
      filtered.sort((a, b) => {
        const ai = POSITION_ORDER.indexOf(a.Position);
        const bi = POSITION_ORDER.indexOf(b.Position);
        const aIdx = ai === -1 ? 999 : ai;
        const bIdx = bi === -1 ? 999 : bi;
        return CURRENT_SORT_DIR === "asc" ? aIdx - bIdx : bIdx - aIdx;
      });
    } else if (INTL_STAT_COLUMNS.has(CURRENT_SORT_COLUMN)) {
      const col = CURRENT_SORT_COLUMN;
      filtered.sort((a, b) => {
        const av = a[col] == null ? -Infinity : Number(a[col]);
        const bv = b[col] == null ? -Infinity : Number(b[col]);
        return CURRENT_SORT_DIR === "asc" ? av - bv : bv - av;
      });
    }

    TOTAL_ROWS = count ?? 0;

    renderTable(filtered);
    renderPagination();
    updatePlayerCountDisplay();
  }

  function formatHeader(col) {
    if (col === "market_value") return "Market Value";
    if (col === "contract_wage") return "Contract wage (per season)";
    if (col === "Maximum_Reserve_Price") return "Maximum Reserve Price";
    if (col === "Potential") return "Pot.";
    if (col === "Contracted_Team") return "Contracted Team";
    if (col === "intl_caps") return "Intl Apps";
    if (col === "intl_goals") return "Intl G";
    if (col === "intl_assists") return "Intl A";
    if (col === "intl_potm") return "Intl POTM";
    if (col === "intl_clean_sheets") return "Intl CS";
    if (col === "intl_avg_rating") return "Intl Avg";
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

  function normalizeDistinctColumnValues(col, rows) {
    const values = (rows || [])
      .map((row) => row[col])
      .filter((v) => v !== null && v !== undefined);

    if (col === "Season_Signed") {
      const nums = values.map((v) => Number(v)).filter((v) => !isNaN(v));
      const allNumeric = nums.length === values.length && values.length > 0;
      if (allNumeric) {
        return [...new Set(nums)].sort((a, b) => a - b).map(String);
      }
      return [...new Set(values.map((v) => String(v).trim()))]
        .filter((v) => v !== "")
        .sort((a, b) => a.localeCompare(b));
    }

    if (col === "market_value") {
      return [...new Set(values.map((v) => Number(v)))]
        .filter((v) => !isNaN(v))
        .sort((a, b) => a - b)
        .map(String);
    }

    if (
      col === "Age" ||
      col === "Rating" ||
      col === "contract_seasons_remaining" ||
      col === "contract_wage"
    ) {
      return [...new Set(values.map((v) => Number(v)))]
        .filter((v) => !isNaN(v))
        .sort((a, b) => a - b)
        .map(String);
    }

    return [...new Set(values.map((v) => String(v).trim()))]
      .filter((v) => v !== "")
      .sort((a, b) => a.localeCompare(b));
  }

  function setRangeBoundsFromValues(col, uniqueValues) {
    if (!uniqueValues.length) {
      RANGE_BOUNDS[col] = { type: "numeric", min: 0, max: 0 };
      RANGE_ACTIVE[col] = { min: 0, max: 0 };
      return;
    }

    if (
      col === "Age" ||
      col === "Rating" ||
      col === "market_value" ||
      col === "contract_seasons_remaining" ||
      col === "contract_wage"
    ) {
      const nums = uniqueValues.map(Number).filter((n) => !isNaN(n));
      const min = Math.min(...nums);
      const max = Math.max(...nums);
      RANGE_BOUNDS[col] = { type: "numeric", min, max };
      RANGE_ACTIVE[col] = { min, max };
      return;
    }

    const nums = uniqueValues.map((v) => Number(v));
    const allNumeric =
      nums.length === uniqueValues.length &&
      uniqueValues.every((v) => v !== "" && !isNaN(Number(v)));

    if (allNumeric) {
      const min = Math.min(...nums);
      const max = Math.max(...nums);
      RANGE_BOUNDS[col] = { type: "numeric", min, max };
      RANGE_ACTIVE[col] = { min, max };
      return;
    }

    RANGE_BOUNDS[col] = { type: "ordinal", values: uniqueValues };
    RANGE_ACTIVE[col] = { min: 0, max: uniqueValues.length - 1 };
  }

  async function loadRangeBounds() {
    setMarketValueBounds();

    for (const col of RANGE_FILTER_COLUMNS) {
      if (col === "market_value") continue;

      if (col === "contract_wage") {
        await loadContractWageBounds();
        continue;
      }

      const { data, error } = await supabase
        .from("Players")
        .select(col, { distinct: true });

      if (error || !data) {
        console.error(`Error loading range bounds for ${col}:`, error);
        setRangeBoundsFromValues(col, []);
        continue;
      }

      setRangeBoundsFromValues(col, normalizeDistinctColumnValues(col, data));
    }
  }

  function isRangeFilterActive(col) {
    const bounds = RANGE_BOUNDS[col];
    const active = normalizedRangeActive(col);
    if (!bounds || !active) return false;
    if (bounds.type === "numeric") {
      return active.min > bounds.min || active.max < bounds.max;
    }
    return active.min > 0 || active.max < bounds.values.length - 1;
  }

  function getRangeFilterInValues(col) {
    const bounds = RANGE_BOUNDS[col];
    const active = RANGE_ACTIVE[col];
    if (!bounds || !active || !isRangeFilterActive(col)) return null;

    if (bounds.type === "numeric") {
      const vals = [];
      for (let i = active.min; i <= active.max; i++) vals.push(String(i));
      return vals;
    }

    return bounds.values.slice(active.min, active.max + 1);
  }

  function formatRangeBracket(col) {
    const bounds = RANGE_BOUNDS[col];
    const active = RANGE_ACTIVE[col];
    if (!bounds || !active) return "(—)";

    const activeFilter = isRangeFilterActive(col);

    if (bounds.type === "numeric") {
      if (col === "market_value" || col === "contract_wage") {
        const { min: lo, max: hi } = normalizedRangeActive(col);
        if (!activeFilter) {
          return `(all · ${formatMoney(bounds.min)}–${formatMoney(bounds.max)})`;
        }
        return `(${formatMoney(lo)}-${formatMoney(hi)})`;
      }
      const { min: lo, max: hi } = normalizedRangeActive(col);
      if (!activeFilter) {
        return `(all · ${bounds.min}–${bounds.max})`;
      }
      return `(${lo}-${hi})`;
    }

    const lo = bounds.values[active.min] ?? "—";
    const hi = bounds.values[active.max] ?? "—";
    if (!activeFilter) {
      const bLo = bounds.values[0] ?? "—";
      const bHi = bounds.values[bounds.values.length - 1] ?? "—";
      return `(all · ${bLo}–${bHi})`;
    }
    return `(${lo}-${hi})`;
  }

  function updateRangeReadout(col) {
    const el = document.getElementById(`filter-${col}-range`);
    if (el) el.textContent = formatRangeBracket(col);
  }

  function updateRangeTrack(col) {
    const wrap = document.getElementById(`filter-${col}-sliders`);
    const bounds = RANGE_BOUNDS[col];
    const active = normalizedRangeActive(col);
    if (!wrap || !bounds || !active) return;

    let baseMin;
    let baseMax;
    if (bounds.type === "numeric") {
      baseMin = bounds.min;
      baseMax = bounds.max;
    } else {
      baseMin = 0;
      baseMax = Math.max(bounds.values.length - 1, 0);
    }

    const span = Math.max(baseMax - baseMin, 1);
    const minPct = ((active.min - baseMin) / span) * 100;
    const maxPct = ((active.max - baseMin) / span) * 100;
    wrap.style.setProperty("--range-min", `${minPct}%`);
    wrap.style.setProperty("--range-max", `${maxPct}%`);
  }

  function contractWageFilterHintHtml() {
    const pct = WAGE_FORECAST_SETTINGS.championship;
    const deployNote = gpdbUseEffectiveWageView
      ? ""
      : " · run gpdb_effective_wage_view.sql for full-database accuracy";
    return `<div class="range-filter-wage-hint">Per-season total wage. Free agents: forecast ${pct}% of market value${deployNote}</div>`;
  }

  function rangeFilterHtml(col) {
    const bounds = RANGE_BOUNDS[col];
    const label = formatHeader(col);
    if (!bounds) {
      return `
        <div class="range-filter" data-col="${col}">
          <div class="range-filter-label">${label} <span class="range-filter-range" id="filter-${col}-range">(—)</span></div>
        </div>
      `;
    }

    const active = normalizedRangeActive(col);
    let sliderMin = bounds.type === "numeric" ? bounds.min : 0;
    let sliderMax =
      bounds.type === "numeric" ? bounds.max : Math.max(bounds.values.length - 1, 0);
    let step = rangeFilterStep(col);
    let minVal = active.min;
    let maxVal = active.max;

    // Market value: UI in whole millions so min/step/max stay browser-valid.
    if (col === "market_value") {
      sliderMin = 0;
      sliderMax = MARKET_VALUE_SLIDER_MAX_M;
      step = 1;
      minVal = marketValueToSlider(active.min);
      maxVal = marketValueToSlider(active.max);
    }

    const disabled = sliderMax <= sliderMin ? "disabled" : "";

    const wageHint = col === "contract_wage" ? contractWageFilterHintHtml() : "";

    return `
      <div class="range-filter" data-col="${col}">
        <div class="range-filter-label">${label} <span class="range-filter-range" id="filter-${col}-range">${formatRangeBracket(col)}</span></div>
        <div class="range-filter-sliders" id="filter-${col}-sliders">
          <div class="range-filter-track"></div>
          <input type="range" class="range-filter-min" id="filter-${col}-min" min="${sliderMin}" max="${sliderMax}" value="${minVal}" step="${step}" aria-label="${label} minimum" ${disabled}>
          <input type="range" class="range-filter-max" id="filter-${col}-max" min="${sliderMin}" max="${sliderMax}" value="${maxVal}" step="${step}" aria-label="${label} maximum" ${disabled}>
        </div>
        ${wageHint}
      </div>
    `;
  }

  function resetRangeFilters() {
    for (const col of RANGE_FILTER_COLUMNS) {
      const bounds = RANGE_BOUNDS[col];
      if (!bounds) continue;
      if (bounds.type === "numeric") {
        RANGE_ACTIVE[col] = { min: bounds.min, max: bounds.max };
      } else {
        RANGE_ACTIVE[col] = { min: 0, max: Math.max(bounds.values.length - 1, 0) };
      }
      const minEl = document.getElementById(`filter-${col}-min`);
      const maxEl = document.getElementById(`filter-${col}-max`);
      if (col === "market_value") {
        if (minEl) minEl.value = String(marketValueToSlider(RANGE_ACTIVE[col].min));
        if (maxEl) maxEl.value = String(marketValueToSlider(RANGE_ACTIVE[col].max));
      } else {
        if (minEl) minEl.value = String(RANGE_ACTIVE[col].min);
        if (maxEl) maxEl.value = String(RANGE_ACTIVE[col].max);
      }
      updateRangeReadout(col);
      updateRangeTrack(col);
    }
  }

  function setupRangeFilters() {
    for (const col of RANGE_FILTER_COLUMNS) {
      const minEl = document.getElementById(`filter-${col}-min`);
      const maxEl = document.getElementById(`filter-${col}-max`);
      if (!minEl || !maxEl) continue;

      let debounceTimer = null;

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

      const readSliderPair = () => {
        let lo = Number(minEl.value);
        let hi = Number(maxEl.value);
        if (isNaN(lo)) lo = 0;
        if (isNaN(hi)) hi = lo;

        if (col === "market_value") {
          lo = marketValueFromSlider(lo);
          hi = marketValueFromSlider(hi);
        } else if (col === "contract_wage") {
          lo = snapContractWage(lo);
          hi = snapContractWage(hi);
        }

        return { lo, hi };
      };

      const writeSliderPair = (lo, hi) => {
        if (col === "market_value") {
          minEl.value = String(marketValueToSlider(lo));
          maxEl.value = String(marketValueToSlider(hi));
        } else {
          minEl.value = String(lo);
          maxEl.value = String(hi);
        }
      };

      const apply = () => {
        let { lo, hi } = readSliderPair();

        // Keep the thumb being dragged; only nudge the other if they cross.
        if (lo > hi) {
          if (document.activeElement === minEl) {
            hi = lo;
          } else if (document.activeElement === maxEl) {
            lo = hi;
          } else {
            [lo, hi] = [hi, lo];
          }
        }

        RANGE_ACTIVE[col] = { min: lo, max: hi };
        if (col === "market_value") normalizeMarketValueActive();
        if (col === "contract_wage") normalizeContractWageActive();
        const active = normalizedRangeActive(col);
        writeSliderPair(active.min, active.max);
        RANGE_ACTIVE[col] = { min: active.min, max: active.max };
        updateRangeReadout(col);
        updateRangeTrack(col);
        syncThumbZIndex();
        saveGpdbFilters();
        loadPage(1);
      };

      const scheduleApply = () => {
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(apply, 250);
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
      minEl.addEventListener("touchstart", syncThumbZIndex);
      maxEl.addEventListener("touchstart", syncThumbZIndex);
      syncThumbZIndex();
      updateRangeTrack(col);
    }
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

    if (col === "Name") {
      return playerNameLinkHtml(player.Konami_ID, value);
    }

    if (INTL_STAT_COLUMNS.has(col)) {
      if (col === "intl_avg_rating") {
        return value != null && Number.isFinite(Number(value))
          ? Number(value).toFixed(2)
          : "—";
      }
      return value != null ? value : 0;
    }

    return value ?? "";
  }

  function attachIntlStats(players, careerMap) {
    return (players || []).map((p) => {
      const st = careerMap.get(String(p.Konami_ID).trim()) || null;
      return {
        ...p,
        intl_caps: st?.caps ?? 0,
        intl_goals: st?.goals ?? 0,
        intl_assists: st?.assists ?? 0,
        intl_potm: st?.potm ?? 0,
        intl_clean_sheets: st?.clean_sheets ?? 0,
        intl_avg_rating: st?.avg_rating ?? null,
      };
    });
  }

  /* ============================================================
     MODULE F: Rendering (with Bid column)
     ============================================================ */

  async function refreshNationalSquadState() {
    MY_NATION = await loadMyNation(supabase);
    NATIONAL_CALLED_UP = new Set();
    NATIONAL_SQUAD_SUMMARY = null;

    const panel = document.getElementById("nationalSquadPanel");
    const myNationBtn = document.getElementById("myNationFilterBtn");
    const myClubNationBtn = document.getElementById("myClubNationFilterBtn");

    const clubNationLabel = CURRENT_USER_CLUB_SHORT
      ? CLUB_NATION_MAP[CURRENT_USER_CLUB_SHORT] || ""
      : "";
    MY_CLUB_NATION = clubNationLabel
      ? await resolveNationFromLabel(supabase, clubNationLabel)
      : null;

    if (myClubNationBtn) {
      if (MY_CLUB_NATION?.name) {
        myClubNationBtn.hidden = false;
        myClubNationBtn.innerHTML = `${renderNationFlag(MY_CLUB_NATION, "sm")} My Club Nation (${MY_CLUB_NATION.name})`;
      } else {
        myClubNationBtn.hidden = true;
      }
    }

    if (!MY_NATION?.code) {
      if (panel) panel.style.display = "none";
      if (myNationBtn) myNationBtn.hidden = true;
      return;
    }

    const squad = await loadNationalSquad(MY_NATION.code, supabase);
    NATIONAL_CALLED_UP = new Set(squad.map((s) => String(s.player_id)));
    NATIONAL_SQUAD_SUMMARY = summarizeNationalSquad(squad);

    if (myNationBtn) {
      myNationBtn.hidden = false;
      myNationBtn.innerHTML = `${renderNationFlag(MY_NATION, "sm")} My National Team (${MY_NATION.name})`;
    }

    if (panel) {
      const s = NATIONAL_SQUAD_SUMMARY;
      const gkNote = s.gkOk
        ? `${s.gkCount} GKs`
        : `<span style="color:#f88;">${s.gkCount} GKs (need ${s.minGk})</span>`;
      panel.style.display = "block";
      panel.innerHTML = `
        ${renderNationFlag(MY_NATION, "sm")}
        <b>${MY_NATION.name} squad:</b> ${s.total}/${s.max} · ${gkNote}
        · Call up or remove players below, or
        <a href="national_team.html?nation=${encodeURIComponent(MY_NATION.code)}" style="color:#ff9900;">view squad</a>
      `;
    }
  }

  function applyNationValuesToFilter(values, emptyAlert) {
    if (!values.length) {
      if (emptyAlert) alert(emptyAlert);
      return false;
    }

    CURRENT_FILTERS.Nation = values;
    const panel = document.getElementById("filter-Nation-panel");
    if (panel) {
      panel.querySelectorAll(".multi-filter-options input[type='checkbox']").forEach((cb) => {
        cb.checked = values.includes(cb.value);
      });
    }
    updateMultiFilterDisplay("Nation");
    saveGpdbFilters();
    loadPage(1);
    return true;
  }

  function buildGpdbCallUpCellHtml(player) {
    if (!MY_NATION?.code) return "";
    if (!playerBelongsToNation(player, MY_NATION)) return "";

    const id = String(player.Konami_ID).trim();
    if (isSeasonExcludedPlayer(player)) {
      return `<span class="locked-msg gpdb-excluded-msg" title="Admin season exclusion">Unavailable</span>`;
    }
    if (NATIONAL_CALLED_UP.has(id)) {
      return `<button type="button" class="button release-callup-btn" data-player-id="${id}">Remove</button>`;
    }
    if (NATIONAL_SQUAD_SUMMARY?.full) {
      return `<span class="locked-msg">Squad full (${NATIONAL_SQUAD_MAX})</span>`;
    }
    return `<button type="button" class="button call-up-btn" data-player-id="${id}">Call up</button>`;
  }

  async function handleCallUpClick(konamiId) {
    const res = await callUpPlayer(String(konamiId), supabase);
    if (res.error) {
      alert(res.error);
      return;
    }
    await refreshNationalSquadState();
    await loadPage(CURRENT_PAGE);
  }

  async function handleReleaseCallUpClick(konamiId) {
    const res = await releaseCallup(String(konamiId), supabase);
    if (res.error) {
      alert(res.error);
      return;
    }
    await refreshNationalSquadState();
    await loadPage(CURRENT_PAGE);
  }

  function applyGpdbNationFromUrl() {
    const raw = new URLSearchParams(window.location.search).get("nation");
    if (!raw?.trim()) return;

    const requested = raw
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    const options = FILTER_OPTION_CACHE.Nation || [];
    let values = requested;

    if (options.length) {
      const matched = [];
      for (const req of requested) {
        const reqNorm = req.toLowerCase();
        for (const opt of options) {
          const val = String(opt.value ?? "");
          const valNorm = val.toLowerCase();
          if (valNorm === reqNorm || valNorm.includes(reqNorm) || reqNorm.includes(valNorm)) {
            matched.push(val);
          }
        }
      }
      values = [...new Set(matched)];
      if (!values.length) values = requested;
    }

    CURRENT_FILTERS.Nation = values;
    const panel = document.getElementById("filter-Nation-panel");
    if (panel) {
      panel.querySelectorAll(".multi-filter-options input[type='checkbox']").forEach((cb) => {
        cb.checked = values.includes(cb.value);
      });
    }
    updateMultiFilterDisplay("Nation");
    saveGpdbFilters();
  }

  function applyMyNationFilter() {
    if (!MY_NATION?.code) return;
    const values = gpdbNationFilterValues(
      MY_NATION,
      FILTER_OPTION_CACHE.Nation || []
    );
    applyNationValuesToFilter(
      values,
      `No GPDB nation values match ${MY_NATION.name}. Try filtering Nation manually.`
    );
  }

  function applyMyClubNationFilter() {
    const label =
      MY_CLUB_NATION?.name ||
      (CURRENT_USER_CLUB_SHORT
        ? CLUB_NATION_MAP[CURRENT_USER_CLUB_SHORT]
        : "");
    if (!label) return;
    const values = clubNationFilterValues(
      label,
      FILTER_OPTION_CACHE.Nation || []
    );
    applyNationValuesToFilter(
      values,
      `No GPDB nation values match club nation ${label}. Try filtering Nation manually.`
    );
  }

  function toggleScoutedOnlyFilter() {
    if (!CURRENT_USER_CLUB_SHORT) return;
    SCOUTED_ONLY = !SCOUTED_ONLY;
    const btn = document.getElementById("myScoutedFilterBtn");
    if (btn) btn.classList.toggle("is-active", SCOUTED_ONLY);
    saveGpdbFilters();
    loadPage(1);
  }

  function renderTable(players) {
    const tableHead = document.getElementById("tableHead");
    const tableBody = document.getElementById("tableBody");

    if (!players || players.length === 0) {
      tableHead.innerHTML = "<tr><th>No data</th></tr>";
      tableBody.innerHTML = "";
      return;
    }

    const showCallUpCol = !!MY_NATION?.code;
    const showScoutCol = !!CURRENT_USER_CLUB_SHORT;

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
        ${showCallUpCol ? '<th class="gpdb-callup-col">Call up</th>' : ""}
        ${showScoutCol ? '<th class="gpdb-scout-col" title="Scouting shortlist">Scout</th>' : ""}
        <th>Bid</th>
      </tr>
    `;

    tableBody.innerHTML = players
      .map(player => {
        const hasClub = !!player.Contracted_Team;
        const seasonExcluded = isSeasonExcludedPlayer(player);
        const auctionExcluded = !seasonExcluded && isAuctionExcludedPlayer(player);

        let bidCell = `<span class="locked-msg">Loading…</span>`;
        const callUpCell = buildGpdbCallUpCellHtml(player);
        const scouted = SCOUTING_TARGET_MAP.has(String(player.Konami_ID));
        const scoutTier = SCOUTING_TARGET_MAP.get(String(player.Konami_ID));
        const scoutCell = showScoutCol
          ? seasonExcluded
            ? `<span class="locked-msg">—</span>`
            : `<button type="button" class="scout-btn${scouted ? " scout-on" : ""}" data-player-id="${player.Konami_ID}" title="${scouted ? `Scouting (tier ${scoutTier}) — click to remove` : "Add to scouting (top target)"}">${scoutingStarChar(scouted)}</button>`
          : "";

        if (seasonExcluded) {
          bidCell = seasonExcludedBidHtml();
        } else if (auctionExcluded) {
          bidCell = auctionExcludedBidHtml();
        } else if (GLOBAL_SETTINGS) {
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

            if (!CURRENT_USER_CLUB_SHORT) {
              bidCell = `<span class="locked-msg" title="Waiting-list members cannot bid until they own a club">Club required</span>`;
            } else if (inDraft) {
              bidCell = `<span class="locked-msg">In Draft Auction</span>`;
            } else if (GLOBAL_SETTINGS.draftAuctionEnabled) {
              const nowLocal = getUKNow();
              const draftStart = draftAuctionStartTime
                ? new Date(draftAuctionStartTime)
                : null;
              const phase = getDraftPhaseFromStart(nowLocal, draftStart);

              if (isGpdbFreeAgentOfferAllowed(nowLocal, draftStart)) {
                bidCell = `<button class="button draft-offer-btn" data-player-id="${player.Konami_ID}">Draft Offer</button>`;
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

        const suspRows = GPDB_SUSPENSIONS_BY_PLAYER.get(String(player.Konami_ID)) || [];
        const suspBadge = formatSuspensionBadgeHtml(suspRows);
        const nameCell = seasonExcluded
          ? `${formatCellValue("Name", player)} <span class="gpdb-excluded-badge" title="Admin season exclusion">Unavailable</span>`
          : `${formatCellValue("Name", player)}${suspBadge}`;

        const rowClasses = [
          seasonExcluded ? "gpdb-row-excluded" : "",
          auctionExcluded ? "gpdb-row-auction-reserved" : "",
          suspRows.length ? "gpdb-row-suspended" : "",
        ]
          .filter(Boolean)
          .join(" ");

        return `
          <tr class="${rowClasses}" data-konami-id="${player.Konami_ID}"
              data-rating="${player.Rating ?? ""}"
              data-playstyle="${player.Playstyle ?? ""}"
              data-market-value="${player.market_value ?? ""}"
              data-contracted-team="${player.Contracted_Team ?? ""}"
              data-season-signed="${player.Season_Signed ?? ""}"
              data-contract-seasons="${player.contract_seasons_remaining ?? ""}"
              data-nation="${player.Nation ?? ""}"
              data-age="${player.Age ?? ""}"
              data-season-excluded="${seasonExcluded ? "1" : "0"}"
              data-auction-excluded="${auctionExcluded ? "1" : "0"}">
            <td>${playerThumbLinkHtml(player.Konami_ID, {
              className: "gpdb-thumb",
              alt: player.Name,
            })}</td>
            ${TABLE_DISPLAY_COLUMNS.map((col) => {
              if (col === "Name") return `<td>${nameCell}</td>`;
              return `<td>${formatCellValue(col, player)}</td>`;
            }).join("")}
            ${showCallUpCol ? `<td class="gpdb-callup-col">${callUpCell || '<span class="locked-msg">—</span>'}</td>` : ""}
            ${showScoutCol ? `<td class="gpdb-scout-col">${scoutCell}</td>` : ""}
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
        saveGpdbFilters();
        loadPage(1);
      };
    });

    Array.from(tableBody.querySelectorAll("tr")).forEach(row => {
      row.style.cursor = "pointer";
      row.addEventListener("click", e => {
        if (e.target.closest(".make-offer-btn, .draft-offer-btn, .call-up-btn, .release-callup-btn, .scout-btn, a")) return;
        const konamiId = row.getAttribute("data-konami-id");
        if (konamiId) {
          window.open(pesdbPlayerUrl(konamiId), "_blank", "noopener");
        }
      });
    });

    document.querySelectorAll(".make-offer-btn, .draft-offer-btn").forEach(btn => {
      btn.addEventListener("click", () => openMakeOfferModal(btn.dataset.playerId));
    });

    document.querySelectorAll(".call-up-btn").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        handleCallUpClick(btn.dataset.playerId);
      });
    });

    document.querySelectorAll(".release-callup-btn").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        handleReleaseCallUpClick(btn.dataset.playerId);
      });
    });

    document.querySelectorAll(".scout-btn").forEach((btn) => {
      btn.addEventListener("click", async (e) => {
        e.stopPropagation();
        if (!CURRENT_USER_CLUB_SHORT) return;
        if (!isScoutingAvailable()) {
          alert("Scouting lists are not set up yet — ask admin to run club_scouting_targets.sql");
          return;
        }
        const pid = btn.dataset.playerId;
        try {
          const on = await toggleScoutingTarget(supabase, pid, 1);
          if (on) {
            SCOUTING_TARGET_MAP.set(String(pid), 1);
            btn.classList.add("scout-on");
            btn.textContent = scoutingStarChar(true);
            btn.title = "Scouting (tier 1) — click to remove";
          } else {
            SCOUTING_TARGET_MAP.delete(String(pid));
            btn.classList.remove("scout-on");
            btn.textContent = scoutingStarChar(false);
            btn.title = "Add to scouting (top target)";
          }
          if (SCOUTED_ONLY) await loadPage(CURRENT_PAGE);
        } catch (err) {
          alert(err?.message || "Could not update scouting list.");
        }
      });
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

    if (!CURRENT_USER_CLUB_SHORT) {
      alert("You need a GPSL club to make offers. Waiting-list members can browse GPDB but cannot bid until assigned a club.");
      return;
    }

    if (
      row.dataset.auctionExcluded === "1" ||
      AUCTION_EXCLUDED_PLAYER_IDS.has(String(konamiId).trim())
    ) {
      alert("This player is reserved for a special auction and cannot be bid on in the draft.");
      return;
    }

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
    const suspensionList = await loadActiveSuspensions(supabase, {});
    GPDB_SUSPENSIONS_BY_PLAYER = suspensionsByPlayerId(suspensionList);
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

  function updateMultiFilterDisplay(col, options = {}) {
    const { reload = true } = options;
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
      delete CURRENT_FILTERS[col];
    } else if (selected.length === 1) {
      display.textContent = labels[0];
    } else {
      display.textContent = `${labels[0]} +${selected.length - 1}`;
    }

    saveGpdbFilters();
    if (reload) loadPage(1);
  }

  async function populateDropdowns() {
    for (const col of DROPDOWN_COLUMNS) {
      const panel = document.getElementById(`filter-${col}-panel`);
      if (!panel) continue;

      let uniqueValues;

      if (col === "Contracted_Team") {
        // All league clubs — not only teams that currently have a player row.
        uniqueValues = Object.keys(CLUB_NAME_MAP)
          .filter((short) => short && short !== "FOREIGN")
          .sort((a, b) =>
            (CLUB_NAME_MAP[a] || a).localeCompare(CLUB_NAME_MAP[b] || b)
          );
        uniqueValues = ["FREE AGENT", ...uniqueValues];
      } else {
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

      if (col === "Season_Signed") {
        const nums = values.map((v) => Number(v)).filter((v) => !isNaN(v));
        const allNumeric = nums.length === values.length && values.length > 0;
        uniqueValues = allNumeric
          ? [...new Set(nums)].sort((a, b) => a - b)
          : [...new Set(values.map((v) => String(v).trim()))]
              .filter((v) => v !== "")
              .sort((a, b) => a.localeCompare(b));
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
    const buildFilterHtml = (col) => {
      const labelPlain =
        col === "Contracted_Team"
          ? "Contracted Team (DRAFT)"
          : formatHeader(col);
      const labelHtml = formatFilterLabel(col);
      if (RANGE_FILTER_COLUMNS.includes(col)) {
        return rangeFilterHtml(col);
      }
      if (DROPDOWN_COLUMNS.includes(col)) {
        const draftHint =
          col === "Contracted_Team" ? contractedTeamFilterHintHtml() : "";
        return `
          <div class="multi-filter" data-col="${col}">
            <div class="multi-filter-label">${labelHtml}</div>
            <div class="multi-filter-control" id="filter-${col}-display">All</div>
            ${draftHint}
            <div class="multi-filter-panel" id="filter-${col}-panel">
              <input type="text" class="multi-filter-search" autocomplete="off" aria-label="Search ${labelPlain}">
              <div class="multi-filter-options"></div>
            </div>
          </div>
        `;
      }
      const textLabel = formatHeader(col);
      return `
        <label class="text-filter">
          ${textLabel}
          <input type="text" id="filter-${col}" placeholder="Filter ${textLabel} (ignores accents, searches all players)">
        </label>
      `;
    };

    FILTER_LAYOUT_ROWS.forEach((row, idx) => {
      const rowEl = document.getElementById(`filters-row-${idx + 1}`);
      if (!rowEl) return;
      rowEl.innerHTML = row
        .filter((col) => !FILTER_EXCLUDE.includes(col))
        .map(buildFilterHtml)
        .join("");
    });
  }

  function setupTextFilters() {
    const textCols = COLUMNS.filter(
      (col) =>
        !FILTER_EXCLUDE.includes(col) &&
        !DROPDOWN_COLUMNS.includes(col) &&
        !RANGE_FILTER_COLUMNS.includes(col)
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
        saveGpdbFilters();
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

    document.getElementById("myNationFilterBtn")?.addEventListener("click", () => {
      applyMyNationFilter();
    });

    document.getElementById("myClubNationFilterBtn")?.addEventListener("click", () => {
      applyMyClubNationFilter();
    });

    document.getElementById("myScoutedFilterBtn")?.addEventListener("click", () => {
      toggleScoutedOnlyFilter();
    });

    document.getElementById("clearFiltersBtn").addEventListener("click", () => {
      CURRENT_FILTERS = {};
      SCOUTED_ONLY = false;
      clearGpdbFilterStorage();
      const scoutedBtn = document.getElementById("myScoutedFilterBtn");
      if (scoutedBtn) scoutedBtn.classList.remove("is-active");
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

      resetRangeFilters();

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
    mountClubBankBalance("clubBankBalance").catch((err) =>
      console.warn("club bank balance:", err)
    );

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
    await loadWageForecastSettings();
    await probeGpdbPlayersView();
    await loadSeasonExclusions();
    await loadAuctionExclusions();

    setupControls();
    await loadRangeBounds();
    applySavedGpdbFilterState(loadSavedGpdbFilters());
    setupFilters();
    setupRangeFilters();
    setupTextFilters();
    await populateDropdowns();
    restoreGpdbFilterUi();
    applyGpdbNationFromUrl();
    await loadTotalCount();
    await loadActiveDraftListings();
    await loadPendingDirectOfferPlayers();
    await loadDraftCreditsForOwner();
    await refreshNationalSquadState();
    loadPage(1);
  }

  init();

}); // end DOMContentLoaded
