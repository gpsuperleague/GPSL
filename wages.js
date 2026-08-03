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

/** Expiring-contract hidden wage offers must use this step. */
export function expiryWageBidStep() {
  return 250000;
}

/** Next valid offer: next ₿250k step strictly above current wage. */
export function minExpiryWageOffer(currentWage, step = expiryWageBidStep()) {
  const cur = Math.max(0, Number(currentWage) || 0);
  const s = Number(step) || expiryWageBidStep();
  return Math.floor(cur / s) * s + s;
}
