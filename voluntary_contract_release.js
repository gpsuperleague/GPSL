/**
 * Voluntary contract release (squad action) — max 3 per club per season.
 */

export const MAX_VOLUNTARY_CONTRACT_RELEASES = 3;
export const VOLUNTARY_RELEASE_ACTION = "release-contract";

export function normalizeVoluntaryReleasesRemaining(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return MAX_VOLUNTARY_CONTRACT_RELEASES;
  return Math.max(0, Math.min(MAX_VOLUNTARY_CONTRACT_RELEASES, Math.trunc(n)));
}

/** Buy-out = wage × seasons remaining on contract. */
export function calculateVoluntaryReleaseCost(contractWage, seasonsRemaining) {
  const wage = Number(contractWage) || 0;
  const seasons = Number(seasonsRemaining) || 0;
  if (wage <= 0 || seasons <= 0) return 0;
  return Math.round(wage * seasons);
}

export function voluntaryReleaseOptionLabel(remaining, cost) {
  if (remaining <= 0) {
    return "No voluntary releases left (0/3)";
  }
  const costStr =
    cost > 0
      ? ` — pay ₿ ${cost.toLocaleString("en-GB")}`
      : "";
  return `Release from contract (${remaining}/3 left${costStr})`;
}
