/**
 * Same-season transfer lock: players signed in the current GPSL season
 * cannot be listed, sold abroad, or receive transfer-market activity until next season.
 */

export const SAME_SEASON_TRANSFER_MESSAGE =
  "This player was signed in the current season and cannot be sold or listed until the next season.";

export function normalizeSeasonLabel(value) {
  if (value == null) return "";
  return String(value).trim();
}

/** True when Season_Signed matches the active competition season label. */
export function playerSignedCurrentSeason(player, currentSeasonLabel) {
  const signed = normalizeSeasonLabel(player?.Season_Signed);
  const cur = normalizeSeasonLabel(currentSeasonLabel);
  if (!cur || !signed) return false;
  return signed === cur;
}

export function playerBlockedSameSeasonTransfer(player, currentSeasonLabel) {
  return playerSignedCurrentSeason(player, currentSeasonLabel);
}

export async function loadCurrentGpslSeasonLabel(supabase) {
  const { data: rpcLabel, error: rpcErr } = await supabase.rpc(
    "current_gpsl_season_label"
  );
  if (!rpcErr && rpcLabel != null && String(rpcLabel).trim() !== "") {
    return normalizeSeasonLabel(rpcLabel);
  }

  const { data: row, error } = await supabase
    .from("competition_season_public")
    .select("label")
    .eq("is_current", true)
    .maybeSingle();

  if (error) {
    console.error("loadCurrentGpslSeasonLabel:", error);
    return "";
  }
  return normalizeSeasonLabel(row?.label);
}
