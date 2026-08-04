// Wage helpers — % of market value from global_settings (division tier)

export async function loadWagePercentages(supabase) {
  const { data, error } = await supabase
    .from("global_settings_public")
    .select("wage_pct_superleague, wage_pct_championship")
    .eq("id", 1)
    .maybeSingle();

  if (error) {
    console.error("loadWagePercentages:", error);
    return { superleague: 5, championship: 4 };
  }

  return {
    superleague: Number(data?.wage_pct_superleague ?? 5),
    championship: Number(data?.wage_pct_championship ?? 4),
  };
}

/** @param {'superleague'|'championship'|string} divisionTier */
export function wageFromMarketValue(marketValue, divisionTier, settings) {
  const mv = Number(marketValue) || 0;
  const pct =
    divisionTier === "superleague"
      ? Number(settings?.superleague ?? 5)
      : Number(settings?.championship ?? 4);
  return Math.round((mv * pct) / 100);
}

export function formatWage(amount) {
  const n = Number(amount);
  if (!Number.isFinite(n)) return "—";
  return `₿ ${n.toLocaleString("en-GB", { maximumFractionDigits: 0 })}`;
}

/** Minimum uplift above current wage for expiring-contract bids (%). */
export function expiryWageMinUpliftPct() {
  return 10;
}

/** @deprecated Step removed — use expiryWageMinUpliftPct / minExpiryWageOffer. */
export function expiryWageBidStep() {
  return 1;
}

/** Minimum expiry wage offer: current wage + uplift % (ceil), strictly above current. */
export function minExpiryWageOffer(
  currentWage,
  upliftPct = expiryWageMinUpliftPct()
) {
  const cur = Math.max(0, Number(currentWage) || 0);
  const pct = Number(upliftPct);
  const usePct = Number.isFinite(pct) && pct > 0 ? pct : expiryWageMinUpliftPct();

  if (cur <= 0) return 10000;

  let min = Math.ceil(cur * (1 + usePct / 100));
  if (min <= cur) min = cur + 1;
  return min;
}
