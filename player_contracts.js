/**
 * Player contract helpers (3-year deals, final-year renew/expire).
 */

import {
  isExpiryAuctionExempt,
  isExpiryAgeExempt,
  isOooOWageUpliftRenew,
} from "./squad_rules.js";
import { formatWage, oooRenewUpliftPct } from "./wages.js";

export const CONTRACT_YEARS_DEFAULT = 3;

export const FINAL_YEAR_TRANSFER_MESSAGE =
  "This player is in the final half-season of their contract and cannot be sold or listed. Renew (if eligible) or use the expiry wage market from your squad.";

export const SIGNING_LOCK_HALF_MESSAGE =
  "This player joined in the second half of last season and cannot be sold or listed until the GPSL January window (one full season after signing).";

/**
 * Contract half-season phase, shared across module copies (pages import this file
 * with different ?v= tags).
 */
const PHASE_KEY = "__gpslContractPhase";

function phaseState() {
  if (!globalThis[PHASE_KEY]) {
    globalThis[PHASE_KEY] = {
      loaded: false,
      secondHalf: false,
      currentLabel: "",
      previousLabel: "",
      promise: null,
    };
  }
  return globalThis[PHASE_KEY];
}

export function getContractPhase() {
  const s = phaseState();
  return {
    loaded: s.loaded,
    secondHalf: s.secondHalf,
    currentLabel: s.currentLabel,
    previousLabel: s.previousLabel,
  };
}

/** Loads gpsl_contract_phase() once per page (second half = from GPSL January unlock). */
export async function loadContractPhase(supabase, { force = false } = {}) {
  const s = phaseState();
  if (s.promise && !force) return s.promise;
  s.promise = (async () => {
    try {
      const { data, error } = await supabase.rpc("gpsl_contract_phase");
      if (!error && data && typeof data === "object") {
        s.loaded = true;
        s.secondHalf = data.second_half === true;
        s.currentLabel = String(data.current_label ?? "").trim();
        s.previousLabel = String(data.previous_label ?? "").trim();
      } else if (error) {
        console.warn("gpsl_contract_phase:", error.message);
      }
    } catch (e) {
      console.warn("gpsl_contract_phase:", e);
    }
    return getContractPhase();
  })();
  return s.promise;
}

export function contractEndWindow(player) {
  return String(player?.contract_end_window ?? "").trim().toLowerCase() === "january"
    ? "january"
    : "summer";
}

export function contractYearsLabel(seasonsRemaining, endWindow = "summer") {
  const n = Number(seasonsRemaining);
  if (!Number.isFinite(n) || seasonsRemaining == null) return "—";
  if (n <= 0) return "Expired";
  if (String(endWindow).toLowerCase() === "january") {
    if (n === 1) return "Final half (ends Jan)";
    return `${n - 1}½ Seasons`;
  }
  if (n === 1) return "Final year";
  return `${n} Seasons`;
}

export function isContractFinalYear(player) {
  const n = Number(player?.contract_seasons_remaining);
  return Number.isFinite(n) && n === 1;
}

/**
 * Final half-season of the deal: locked from sale, expiry wage bids open.
 * Summer contracts: final year from GPSL January. January contracts: whole last segment.
 */
export function isContractFinalHalf(player) {
  if (!isContractFinalYear(player)) return false;
  if (contractEndWindow(player) === "january") return true;
  const s = phaseState();
  return s.loaded ? s.secondHalf : true;
}

/** Expiry wage bids open in the final half-season only. */
export function isExpiryBiddingOpen(player) {
  return isContractFinalHalf(player);
}

/** Card removed from pesdb.net — legacy GPSL card (not sellable). */
export function isPesdbLegacyCard(player) {
  return !!player?.pesdb_unavailable;
}

/**
 * Mirrors SQL player_contract_sell_lock_reason (club players; free agents → null).
 * @returns {null|"legacy"|"signed_this_season"|"signed_last_season_half"|"contract_ended"|"final_half"}
 */
export function playerSellLockReason(player, currentSeasonLabel) {
  if (isPesdbLegacyCard(player)) return "legacy";
  const s = phaseState();
  const signed = String(player?.Season_Signed ?? "").trim();
  const cur = String(currentSeasonLabel || s.currentLabel || "").trim();
  if (cur && signed && signed === cur) return "signed_this_season";
  if (
    player?.contract_join_second_half === true &&
    s.loaded &&
    !s.secondHalf &&
    signed &&
    s.previousLabel &&
    signed === s.previousLabel
  ) {
    return "signed_last_season_half";
  }
  const seasons = player?.contract_seasons_remaining;
  if (seasons == null || seasons === "") return null;
  const n = Number(seasons);
  if (!Number.isFinite(n)) return null;
  if (n <= 0) return "contract_ended";
  if (n === 1 && isContractFinalHalf(player)) return "final_half";
  return null;
}

export function sellLockMessage(reason, sameSeasonMessage) {
  switch (reason) {
    case "legacy":
      return "Legacy cards cannot be sold or listed.";
    case "signed_this_season":
      return (
        sameSeasonMessage ||
        "This player was signed in the current season and cannot be sold or listed until the next season."
      );
    case "signed_last_season_half":
      return SIGNING_LOCK_HALF_MESSAGE;
    case "contract_ended":
      return "This player's contract has ended.";
    case "final_half":
      return FINAL_YEAR_TRANSFER_MESSAGE;
    default:
      return "";
  }
}

/** Short squad-menu label for a sell lock. */
export function sellLockShortLabel(reason) {
  switch (reason) {
    case "final_half":
      return "Final half of contract — not sellable";
    case "signed_last_season_half":
      return "Signing lock — sellable from GPSL January";
    case "contract_ended":
      return "Contract ended";
    default:
      return "";
  }
}

export function playerCanListOrSell(player, currentSeasonLabel) {
  return playerSellLockReason(player, currentSeasonLabel) == null;
}

export function playerBlockedFromTransferMarket(player, currentSeasonLabel) {
  return !playerCanListOrSell(player, currentSeasonLabel);
}

export function formatSquadContractCell(player) {
  const years = contractYearsLabel(
    player?.contract_seasons_remaining,
    contractEndWindow(player)
  );
  const wage = formatWage(player?.contract_wage);
  if (years === "—" && wage === "—") return "—";
  return `<div class="squad-contract-stack">
    <span class="squad-contract-years">${years}</span>
    <span class="squad-contract-wage">${wage}</span>
  </div>`;
}

/** Final-year players on hidden wage bid market (not age-exempt / OooO). */
export function isOnExpiryWageMarket(player, clubNation, oooPlayerId = null) {
  if (isPesdbLegacyCard(player)) return false;
  return (
    isContractFinalYear(player) &&
    !isExpiryAuctionExempt(player, clubNation, oooPlayerId)
  );
}

export function squadContractActionOptionsHtml(
  player,
  clubNation,
  voluntaryRelease = null,
  oooPlayerId = null
) {
  if (!isContractFinalYear(player)) return null;

  const exempt = isExpiryAuctionExempt(player, clubNation, oooPlayerId);
  const legacy = isPesdbLegacyCard(player);
  const oooUplift = isOooOWageUpliftRenew(player, clubNation, oooPlayerId);
  const uplift = oooRenewUpliftPct();
  const releaseOpt = voluntaryRelease?.optionHtml ?? "";
  const hasWageBid = !!voluntaryRelease?.hasWageBid;
  const finalHalf = isContractFinalHalf(player);
  const sellOpts =
    !finalHalf && !legacy ? voluntaryRelease?.sellOptionsHtml ?? "" : "";
  const endsAt =
    contractEndWindow(player) === "january" ? "GPSL January" : "season end";

  // Contested: wage auction only (no mid-season unilateral renew).
  if (!exempt && !legacy) {
    if (hasWageBid) {
      return `
            <option value="noop:wage_bid_locked">Wage bid locked — resolves at ${endsAt}</option>
            ${releaseOpt}`;
    }
    if (!finalHalf) {
      return `
            ${sellOpts}
            <option value="noop:expiry_bids_jan" disabled>Wage bids open at GPSL January</option>
            ${releaseOpt}`;
    }
    return `
            <option value="expiry_bid">Offer wage bid (competes at ${endsAt})</option>
            ${releaseOpt}`;
  }

  let renewLabel;
  if (legacy) {
    renewLabel = "Renew legacy card now (1 season, same wage)";
  } else if (oooUplift) {
    renewLabel = `Renew One of our Own now (+${uplift}% wage, 3 seasons)`;
  } else {
    renewLabel = "Renew now at same wage (3 seasons)";
  }

  return `
            <option value="renew">${renewLabel}</option>
            ${sellOpts}
            ${releaseOpt}`;
}

/**
 * Contract outlook for Squad registration panel.
 * - Last chance (midDeal kept as alias): sellable now, but the next half-season is the locked final half.
 * - Final year (remaining=1): potential leavers + re-signable (age brackets / OooO / legacy).
 *
 * @param {object[]} players
 * @param {string|null|undefined} clubNation
 * @param {string|null|undefined} activeGpslMonth
 * @param {string|null|undefined} oooPlayerId
 */
export function analyseSquadContractOutlook(
  players,
  clubNation,
  activeGpslMonth,
  oooPlayerId = null
) {
  const list = Array.isArray(players) ? players : [];
  const month = String(activeGpslMonth || "")
    .trim()
    .toLowerCase();
  const phase = getContractPhase();
  const secondHalf = phase.loaded
    ? phase.secondHalf
    : ["january", "february", "march", "april", "may"].includes(month);

  // Last sale window before the final half locks: summer deals in the first half of
  // their final year (lock at GPSL January); January deals in the second half with
  // two segments left (lock at the summer rollover).
  const lastChance = list.filter((p) => {
    if (isPesdbLegacyCard(p)) return false;
    const n = Number(p?.contract_seasons_remaining);
    if (contractEndWindow(p) === "january") return n === 2 && secondHalf;
    return n === 1 && !secondHalf;
  });
  const lastChanceLocksAtJanuary = lastChance.some(
    (p) => contractEndWindow(p) === "summer"
  );

  const midDealSellWindow = lastChance.length > 0;
  const midDeal = lastChance;
  const finalYear = list.filter((p) => Number(p?.contract_seasons_remaining) === 1);

  const reSignable = [];
  const contested = [];
  for (const p of finalYear) {
    if (
      isPesdbLegacyCard(p) ||
      isExpiryAuctionExempt(p, clubNation, oooPlayerId)
    ) {
      reSignable.push(p);
    } else {
      contested.push(p);
    }
  }

  const reSignableAgeExempt = reSignable.filter(
    (p) => !isPesdbLegacyCard(p) && isExpiryAgeExempt(p, clubNation)
  );
  const reSignableOoo = reSignable.filter(
    (p) =>
      !isPesdbLegacyCard(p) && isOooOWageUpliftRenew(p, clubNation, oooPlayerId)
  );

  return {
    activeGpslMonth: month || null,
    midDealSellWindow,
    midDeal,
    midDealCount: midDeal.length,
    lastChance,
    lastChanceCount: lastChance.length,
    lastChanceLocksAtJanuary,
    secondHalf,
    finalYear,
    finalYearCount: finalYear.length,
    reSignable,
    reSignableCount: reSignable.length,
    reSignableExemptCount: reSignableAgeExempt.length,
    reSignableOooCount: reSignableOoo.length,
    contested,
    contestedCount: contested.length,
  };
}
