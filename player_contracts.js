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
  return `${n} yrs`;
}

export function isContractFinalYear(player) {
  const n = Number(player?.contract_seasons_remaining);
  return Number.isFinite(n) && n === 1;
}

export function playerCanListOrSell(player, currentSeasonLabel) {
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
  return `${years} · ${wage}`;
}

export function squadContractActionOptionsHtml(player, clubNation) {
  if (!isContractFinalYear(player)) return null;

  const hg = isHgContractProtected(player, clubNation);
  return `
            <option value="renew">${hg ? "Renew (same wage, 3 yrs)" : "Renew contract (3 yrs)"}</option>
            <option value="expire">Expire — release for MV</option>`;
}
