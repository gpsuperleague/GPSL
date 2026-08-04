/**
 * Player contract helpers (3-year deals, final-year renew/expire).
 */

import { isExpiryAuctionExempt } from "./squad_rules.js";
import { formatWage } from "./wages.js";

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

/** Final-year players on hidden wage bid market (not uncontested brackets). */
export function isOnExpiryWageMarket(player, clubNation) {
  if (isPesdbLegacyCard(player)) return false;
  return isContractFinalYear(player) && !isExpiryAuctionExempt(player, clubNation);
}

export function squadContractActionOptionsHtml(
  player,
  clubNation,
  voluntaryRelease = null
) {
  if (!isContractFinalYear(player)) return null;

  const exempt = isExpiryAuctionExempt(player, clubNation);
  const legacy = isPesdbLegacyCard(player);
  const releaseOpt = voluntaryRelease?.optionHtml ?? "";

  const renewLabel = legacy
    ? (exempt
        ? "Renew legacy card now (1 season, same wage)"
        : "Renew legacy card now (1 season — choose wage)")
    : (exempt
        ? "Renew now at same wage (3 seasons)"
        : "Renew now — choose wage (3 seasons)");

  // Contested final-year: also point owners at the hidden wage auction.
  const bidOpt =
    !exempt && !legacy
      ? `<option value="expiry_bid">Offer wage bid (competes at season end)</option>`
      : "";

  return `
            <option value="renew">${renewLabel}</option>
            ${bidOpt}
            <option value="expire">Expire now — release for MV</option>
            ${releaseOpt}`;
}
