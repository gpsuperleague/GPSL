/**
 * Players sold to foreign clubs reappear in GPDB as free agents but are
 * unavailable for draft / transfer bids until the next competition season.
 */

export function normalizeSeasonId(value) {
  if (value == null || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

/** Locked while current competition season is still the season they were sold in. */
export function playerForeignContractLocked(player, currentSeasonId) {
  const club = String(player?.foreign_contract_club ?? "").trim();
  const soldId = normalizeSeasonId(player?.foreign_contract_sold_season_id);
  const curId = normalizeSeasonId(currentSeasonId);
  if (!club || soldId == null || curId == null) return false;
  return soldId === curId;
}

export function playerForeignContractStatusLabel(player) {
  const club = String(player?.foreign_contract_club ?? "").trim() || "a foreign club";
  const until =
    String(player?.foreign_contract_unlock_season_label ?? "").trim() || "next season";
  return `Unavailable until ${until} — contracted to ${club}`;
}
