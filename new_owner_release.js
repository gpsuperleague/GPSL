/**
 * New Owner first-season actions — up to 3 total (release OR transfer list).
 * Release: Central Bank refund of purchase fee. List: standard listing at MV; slot returns if unsold.
 */

export const MAX_NEW_OWNER_RELEASES = 3;
export const NEW_OWNER_RELEASE_ACTION = "new-owner-release";
export const NEW_OWNER_LIST_ACTION = "new-owner-list";

export function normalizeNewOwnerReleasesRemaining(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(MAX_NEW_OWNER_RELEASES, Math.trunc(n)));
}

export function newOwnerSlotBadgeText(remaining, { windowOpen = false } = {}) {
  const n = normalizeNewOwnerReleasesRemaining(remaining);
  if (n <= 0) {
    return {
      main: "No first-season slots left (0/3)",
      hint: " · Release or transfer list · max 3 total",
    };
  }
  const windowHint = windowOpen
    ? " · Pre-season / January open"
    : " · Pre-season / January only";
  return {
    main: `${n} first-season ${n === 1 ? "slot" : "slots"} left · max 3/season`,
    hint: `${windowHint} · Release (fee refund) or transfer list (slot returns if unsold)`,
  };
}

export function newOwnerReleaseOptionLabel(remaining, fee, { availableNow = false, firstSeason = false } = {}) {
  if (!firstSeason) {
    return "New Owner release (first season only)";
  }
  if (remaining <= 0) {
    return "No first-season slots left (0/3)";
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

export function newOwnerListOptionLabel(remaining, { availableNow = false, firstSeason = false, transferWindowOpen = false } = {}) {
  if (!firstSeason) {
    return "New Owner transfer list (first season only)";
  }
  if (remaining <= 0) {
    return "No first-season slots left (0/3)";
  }
  if (!availableNow) {
    return `New Owner transfer list (${remaining}/3) — pre-season / January only`;
  }
  if (!transferWindowOpen) {
    return `New Owner transfer list (${remaining}/3) — transfer window shut`;
  }
  return `New Owner transfer list (${remaining}/3) — at market value`;
}
