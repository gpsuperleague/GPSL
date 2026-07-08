/**
 * New Owner Release — up to 3 in first season at a club.
 * Debit = purchase fee the club paid; player locked until next season.
 */

export const MAX_NEW_OWNER_RELEASES = 3;
export const NEW_OWNER_RELEASE_ACTION = "new-owner-release";

export function normalizeNewOwnerReleasesRemaining(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(MAX_NEW_OWNER_RELEASES, Math.trunc(n)));
}

export function newOwnerReleaseOptionLabel(remaining, fee, { availableNow = false, firstSeason = false } = {}) {
  if (!firstSeason) {
    return "New Owner release (first season only)";
  }
  if (remaining <= 0) {
    return "No New Owner releases left (0/3)";
  }
  if (!availableNow) {
    return `New Owner release (${remaining}/3) — pre-season / January only`;
  }
  const feeStr =
    fee != null && fee > 0
      ? ` — refund ₿ ${Number(fee).toLocaleString("en-GB")}`
      : fee === 0 || fee == null
        ? " — no purchase fee on record"
        : "";
  return `New Owner release (${remaining}/3 left${feeStr})`;
}
