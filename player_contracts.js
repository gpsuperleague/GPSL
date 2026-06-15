/**
 * Player contract helpers (3-year deals, final-year renew/expire).
 */

import { isHgContractProtected } from "./squad_rules.js";
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

/** Standard final-year players on hidden wage bid market (not HG ≤23). */
export function isOnExpiryWageMarket(player, clubNation) {
  if (isPesdbLegacyCard(player)) return false;
  return isContractFinalYear(player) && !isHgContractProtected(player, clubNation);
}

export function squadContractActionOptionsHtml(
  player,
  clubNation,
  voluntaryRelease = null
) {
  if (!isContractFinalYear(player)) return null;

  const hg = isHgContractProtected(player, clubNation);
  const legacy = isPesdbLegacyCard(player);
  const releaseOpt = voluntaryRelease?.optionHtml ?? "";

  const renewLabel = legacy
    ? (hg ? "Renew legacy card (1 season, same wage)" : "Renew legacy card (1 season)")
    : (hg ? "Renew (same wage, 3 Seasons)" : "Renew contract (3 Seasons)");

  return `
            <option value="renew">${renewLabel}</option>
            <option value="expire">Expire — release for MV</option>
            ${releaseOpt}`;
}
