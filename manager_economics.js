/**
 * Manager market value — sum of playstyle tier contributions.
 * Tables: data/manager_value_tables.json
 */

let tablesCache = null;

export async function loadManagerValueTables() {
  if (tablesCache) return tablesCache;
  const res = await fetch(new URL("./data/manager_value_tables.json", import.meta.url));
  if (!res.ok) throw new Error("Failed to load manager_value_tables.json");
  tablesCache = await res.json();
  return tablesCache;
}

/** ₿ contributed by one playstyle proficiency rating. */
export function managerPlaystyleTierValue(rating, tables = tablesCache) {
  const r = Math.round(Number(rating));
  if (!Number.isFinite(r)) return 0;
  const tiers = tables?.playstyleTiers || [];
  for (const tier of tiers) {
    if (r >= tier.min && r <= tier.max) return Number(tier.value) || 0;
  }
  if (r > 90 && tiers.length) {
    return Number(tiers[tiers.length - 1].value) || 0;
  }
  return 0;
}

/** Sum all five playstyle columns → market value. */
export function managerMarketValueFromPlaystyles(manager, tables = tablesCache) {
  const styles = [
    manager?.possession,
    manager?.quick_counter,
    manager?.long_ball_counter,
    manager?.out_wide,
    manager?.long_ball,
  ];
  return styles.reduce(
    (sum, s) => sum + managerPlaystyleTierValue(s, tables),
    0
  );
}

/** Annual wage = 50% of MV by default; weekly = annual / 52. */
export function managerWeeklyWageFromMarketValue(marketValue, tables = tablesCache) {
  const mv = Number(marketValue) || 0;
  const pct = Number(tables?.annualWagePctOfMarketValue ?? 50);
  return Math.round((mv * pct) / 100 / 52);
}
