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
  "This player is in the final year of their contract and cannot be sold or listed. Renew or expire from your squad.";

export function contractYearsLabel(seasonsRemaining) {
  const n = Number(seasonsRemaining);
  if (!Number.isFinite(n) || seasonsRemaining == null) return "—";
  if (n <= 0) return "Expired";
  if (n === 1) return "Final year";
  return `${n} Seasons`;
}

export function isContractFinalYear(player) {
  const n = Number(player?.contract_seasons_remaining);
  return Number.isFinite(n) && n === 1;
}

/** Card removed from pesdb.net — legacy GPSL card (not sellable). */
export function isPesdbLegacyCard(player) {
  return !!player?.pesdb_unavailable;
}

export function playerCanListOrSell(player, currentSeasonLabel) {
  if (isPesdbLegacyCard(player)) return false;
  if (isContractFinalYear(player)) return false;
  const signed = String(player?.Season_Signed ?? "").trim();
  const cur = String(currentSeasonLabel ?? "").trim();
  if (cur && signed && signed === cur) return false;
  const seasons = player?.contract_seasons_remaining;
  if (seasons == null || seasons === "") return true;
  return Number(seasons) >= 2;
}

export function playerBlockedFromTransferMarket(player, currentSeasonLabel) {
  return !playerCanListOrSell(player, currentSeasonLabel);
}

export function formatSquadContractCell(player) {
  const years = contractYearsLabel(player?.contract_seasons_remaining);
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

  // Contested: wage auction only (no mid-season unilateral renew).
  if (!exempt && !legacy) {
    if (hasWageBid) {
      return `
            <option value="noop:wage_bid_locked">Wage bid locked — Pending EOS</option>
            ${releaseOpt}`;
    }
    return `
            <option value="expiry_bid">Offer wage bid (competes at season end)</option>
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
            ${releaseOpt}`;
}

/**
 * Contract outlook for Squad registration panel.
 * - Mid-deal (remaining=2): season 2 of a standard 3-season deal — Dec/Jan sell window notice.
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
  const midDealSellWindow = month === "december" || month === "january";

  const midDeal = list.filter((p) => Number(p?.contract_seasons_remaining) === 2);
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
