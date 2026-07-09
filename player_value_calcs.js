/**
 * Player Calc Potential + Market Value — Excel G2 / J2 with GPSL base-value extension.
 * Tables: data/player_value_tables.json
 */

let tablesCache = null;

export async function loadPlayerValueTables() {
  if (tablesCache) return tablesCache;
  const res = await fetch(new URL("./data/player_value_tables.json", import.meta.url));
  if (!res.ok) throw new Error("Failed to load player_value_tables.json");
  tablesCache = await res.json();
  return tablesCache;
}

function tables() {
  if (!tablesCache) {
    throw new Error("Call loadPlayerValueTables() before using player value calcs");
  }
  return tablesCache;
}

/** Sorted numeric keys from a string-keyed lookup map */
function sortedMapKeys(map) {
  return Object.keys(map)
    .map((k) => Number(k))
    .filter((n) => Number.isFinite(n))
    .sort((a, b) => a - b);
}

/**
 * GPSL base value by current rating — uses full 60-93 table; linear interpolation
 * between defined points for any other rating (clamp below 60 / above 93).
 */
export function getBaseValueByRating(rating) {
  const r = Math.round(Number(rating));
  if (!Number.isFinite(r)) return 0;

  const map = tables().baseValueByRating;
  const key = String(r);
  if (Object.prototype.hasOwnProperty.call(map, key)) {
    return Number(map[key]);
  }

  const keys = sortedMapKeys(map);
  if (!keys.length) return 0;

  if (r <= keys[0]) return Number(map[String(keys[0])]);
  if (r >= keys[keys.length - 1]) return Number(map[String(keys[keys.length - 1])]);

  for (let i = 0; i < keys.length - 1; i++) {
    const lo = keys[i];
    const hi = keys[i + 1];
    if (lo <= r && r <= hi) {
      const vLo = Number(map[String(lo)]);
      const vHi = Number(map[String(hi)]);
      const t = (r - lo) / (hi - lo);
      return Math.round(vLo + t * (vHi - vLo));
    }
  }

  return 0;
}

/** Excel LOOKUP(rating, keys, values) — keys ascending, largest <= rating */
export function ratingPotentialBonus(rating) {
  const t = tables();
  const keys = t.ratingBonus.keys;
  const values = t.ratingBonus.values;
  const r = Number(rating);
  if (!Number.isFinite(r)) return 0;

  let idx = 0;
  for (let i = 0; i < keys.length; i++) {
    if (r >= keys[i]) idx = i;
    else break;
  }
  return values[idx];
}

/**
 * Calc Value (col G) — unchanged from Excel.
 */
export function calculateCalcPotential(rating, pesMax, age) {
  const r = Math.round(Number(rating));
  const base = Math.round(Number(pesMax));
  const a = Math.round(Number(age));
  if (!Number.isFinite(r) || !Number.isFinite(base)) return base || r || 0;

  const bonus = ratingPotentialBonus(r);
  const ageBonus = a <= 19 ? 2 : 0;
  if (r === base) return base + bonus + ageBonus;
  return base;
}

function xlookupExact(map, key, defaultValue = 0) {
  const k = String(key);
  if (Object.prototype.hasOwnProperty.call(map, k)) {
    return Number(map[k]);
  }
  return defaultValue;
}

/**
 * Excel XLOOKUP exact match, or linear interpolation between bracket keys (GPSL).
 * Used for potential % when Calc Value is between table rows.
 */
function xlookupExactOrInterpolate(map, key, defaultValue = 0) {
  const k = Math.round(Number(key));
  if (!Number.isFinite(k)) return defaultValue;

  const exact = xlookupExact(map, k, NaN);
  if (!Number.isNaN(exact)) return exact;

  const keys = sortedMapKeys(map);
  if (!keys.length) return defaultValue;
  if (k <= keys[0]) return Number(map[String(keys[0])]);
  if (k >= keys[keys.length - 1]) return Number(map[String(keys[keys.length - 1])]);

  for (let i = 0; i < keys.length - 1; i++) {
    const lo = keys[i];
    const hi = keys[i + 1];
    if (lo <= k && k <= hi) {
      const vLo = Number(map[String(lo)]);
      const vHi = Number(map[String(hi)]);
      const t = (k - lo) / (hi - lo);
      return vLo + t * (vHi - vLo);
    }
  }

  return defaultValue;
}

/** +5% when in current national squad or previous WC-cycle squad (2 windows). */
export const INTERNATIONAL_SQUAD_MV_BOOST = 0.05;

/**
 * Market Value (col J) — uses GPSL extended base value; other lookups match Excel.
 * @param {object} [opts]
 * @param {boolean} [opts.internationalBoost] — apply 5% national-squad window boost
 */
export function calculateMarketValue(rating, calcPotential, age, position, opts = {}) {
  const r = Math.round(Number(rating));
  const calc = Math.round(Number(calcPotential));
  const a = Math.round(Number(age));
  const pos = String(position || "GK").trim().toUpperCase();
  const t = tables();

  const baseValue = getBaseValueByRating(r);
  if (baseValue <= 0) {
    return a < 30 ? t.mvFloorUnder30 : t.mvFloor30Plus;
  }

  let valueCalc = baseValue;
  valueCalc +=
    baseValue * xlookupExactOrInterpolate(t.potentialPctByCalcValue, calc, 0);
  valueCalc += baseValue * xlookupExact(t.agePctByAge, a, a >= 35 ? -1 : 0);

  if (Object.prototype.hasOwnProperty.call(t.youngStarPctByAge, String(a))) {
    valueCalc += baseValue * xlookupExact(t.youngStarPctByAge, a, 0);
  }

  valueCalc += baseValue * xlookupExact(t.positionPctByPosition, pos, 0);

  const floor = a < 30 ? t.mvFloorUnder30 : t.mvFloor30Plus;
  let mv = Math.max(floor, Math.round(valueCalc));
  if (opts.internationalBoost) {
    mv = Math.round(mv * (1 + INTERNATIONAL_SQUAD_MV_BOOST));
  }
  return mv;
}

export function calculateMaximumReservePrice(marketValue) {
  const mv = Number(marketValue) || 0;
  return Math.round(mv * (tables().maxReserveMultiplier ?? 1.5));
}

/**
 * Full recompute from scrape row.
 */
export function computePlayerEconomicsFromScrape(scrape, opts = {}) {
  const rating = Number(scrape.rating);
  const pesMax = Number(scrape.max_level_rating ?? scrape.potential ?? scrape.rating);
  const age = Number(scrape.age);
  const position = scrape.Position ?? scrape.position ?? "GK";

  const calcPotential = calculateCalcPotential(rating, pesMax, age);
  const pesPotential = Math.round(pesMax);

  const out = {
    Rating: rating,
    Age: age,
    Position: position,
    Potential: pesPotential,
    Calc_Potential: calcPotential,
  };

  if (opts.recalcMarketValue !== false) {
    out.market_value = calculateMarketValue(rating, calcPotential, age, position);
    out.Maximum_Reserve_Price = calculateMaximumReservePrice(out.market_value);
  }

  return out;
}
