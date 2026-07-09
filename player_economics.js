/**
 * Player economics — display + compute helpers (Excel G2/J2 + GPSL base extension).
 * Does not write to the database; use admin/import later for bulk updates.
 */

import {
  loadPlayerValueTables,
  calculateCalcPotential,
  calculateMarketValue,
  calculateMaximumReservePrice,
} from "./player_value_calcs.js";

export { loadPlayerValueTables };

/** PES max rating (F) — stored Potential, else fall back to current Rating. */
export function pesMaxFromPlayer(player) {
  const rating = Number(player?.Rating);
  const raw = player?.Potential ?? player?.potential;
  if (raw != null && raw !== "" && Number.isFinite(Number(raw))) {
    return Math.round(Number(raw));
  }
  if (Number.isFinite(rating)) return Math.round(rating);
  return null;
}

/** Calc Value (G) — stored Calc_Potential, or computed from rating / pes max / age. */
export function calcPotentialForPlayer(player) {
  const stored = player?.Calc_Potential ?? player?.calc_potential;
  if (stored != null && stored !== "" && Number.isFinite(Number(stored))) {
    return Math.round(Number(stored));
  }

  const rating = Number(player?.Rating);
  const age = Number(player?.Age);
  const pesMax = pesMaxFromPlayer(player);
  if (!Number.isFinite(rating) || !Number.isFinite(age) || pesMax == null) {
    return null;
  }

  return calculateCalcPotential(rating, pesMax, age);
}

/** e.g. "85 (95)" — current rating and calc potential. */
export function formatRatingWithPotential(player) {
  const rating = player?.Rating ?? "—";
  const pot = calcPotentialForPlayer(player);
  if (pot == null || pot === "" || String(rating) === String(pot)) {
    return String(rating);
  }
  return `${rating} (${pot})`;
}

/** What MV / max reserve would be if formulas ran today (does not change DB). */
export function computedEconomicsForPlayer(player, opts = {}) {
  const rating = Number(player?.Rating);
  const age = Number(player?.Age);
  const pos = player?.Position ?? "GK";
  const calc = calcPotentialForPlayer(player);

  if (!Number.isFinite(rating) || !Number.isFinite(age) || calc == null) {
    return null;
  }

  const market_value = calculateMarketValue(rating, calc, age, pos, {
    internationalBoost: !!opts.internationalBoost,
  });
  return {
    calcPotential: calc,
    market_value,
    Maximum_Reserve_Price: calculateMaximumReservePrice(market_value),
  };
}
