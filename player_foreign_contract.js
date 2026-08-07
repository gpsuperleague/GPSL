/**
 * Players sold to foreign clubs reappear in GPDB as free agents but are
 * unavailable for draft / transfer bids until the next competition season.
 *
 * Contract-expiry FAs (`expiry_fa`) are available to other clubs; only the
 * former club is blocked from re-signing.
 */

export function normalizeSeasonId(value) {
  if (value == null || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function lockKindRaw(player) {
  return String(player?.foreign_contract_lock_kind ?? "").trim();
}

/** `foreign` | `paid_up` | `expiry_fa` (default foreign when club set). */
export function playerForeignContractLockKind(player) {
  const kind = lockKindRaw(player);
  if (kind === "paid_up" || kind === "expiry_fa" || kind === "foreign") return kind;
  return "foreign";
}

/**
 * Globally locked (no club may draft/sign) while sold season is still current.
 * expiry_fa is intentionally excluded — other clubs may sign.
 */
export function playerForeignContractLocked(player, currentSeasonId) {
  const kind = playerForeignContractLockKind(player);
  if (kind === "expiry_fa") return false;

  const club = String(player?.foreign_contract_club ?? "").trim();
  const soldId = normalizeSeasonId(player?.foreign_contract_sold_season_id);
  const curId = normalizeSeasonId(currentSeasonId);
  if (!club || soldId == null || curId == null) return false;
  return soldId === curId;
}

/** Former club short name while player is an expiry free agent. */
export function playerExpiryFaFormerClub(player) {
  if (playerForeignContractLockKind(player) !== "expiry_fa") return null;
  const club = String(player?.foreign_contract_club ?? "").trim();
  return club || null;
}

/** True when this club is the former club of an expiry FA (cannot re-sign). */
export function playerExpiryFaBlockedForClub(player, clubShortName) {
  const former = playerExpiryFaFormerClub(player);
  const club = String(clubShortName ?? "").trim();
  if (!former || !club) return false;
  return former.toLowerCase() === club.toLowerCase();
}

export function playerForeignContractStatusLabel(player) {
  const club = String(player?.foreign_contract_club ?? "").trim();
  const until =
    String(player?.foreign_contract_unlock_season_label ?? "").trim() || "next season";
  const kind = playerForeignContractLockKind(player);

  if (kind === "paid_up") {
    const prevClub = club || "their previous club";
    return `Contract paid up by ${prevClub} — unavailable until ${until} (contractual small print)`;
  }

  if (kind === "expiry_fa") {
    const prevClub = club || "their previous club";
    return `Contract ended at ${prevClub} — free agent for other clubs only (former club cannot re-sign)`;
  }

  const buyer = club || "a foreign club";
  return `Unavailable until ${until} — contracted to ${buyer}`;
}
