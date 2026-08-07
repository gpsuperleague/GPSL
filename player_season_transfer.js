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

/** @param {object} player — may include contract_seasons_remaining */
export {
  playerBlockedFromTransferMarket,
  FINAL_YEAR_TRANSFER_MESSAGE,
} from "./player_contracts.js";

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

  if (!error && row?.label) {
    return normalizeSeasonLabel(row.label);
  }

  // Preseason / summer break: newest setup shell (matches SQL fallback)
  const { data: pre, error: preErr } = await supabase
    .from("competition_seasons")
    .select("label")
    .in("status", ["preseason", "setup"])
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (preErr) {
    console.error("loadCurrentGpslSeasonLabel:", error || preErr);
    return "";
  }
  return normalizeSeasonLabel(pre?.label);
}

export async function loadCurrentGpslSeasonId(supabase) {
  const { data: rpcId, error: rpcErr } = await supabase.rpc(
    "current_gpsl_season_id"
  );
  if (!rpcErr && rpcId != null && Number.isFinite(Number(rpcId))) {
    return Number(rpcId);
  }

  const { data: row, error } = await supabase
    .from("competition_season_public")
    .select("id")
    .eq("is_current", true)
    .maybeSingle();

  if (!error && row?.id != null) {
    return Number(row.id);
  }

  const { data: pre, error: preErr } = await supabase
    .from("competition_seasons")
    .select("id")
    .in("status", ["preseason", "setup"])
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (preErr) {
    console.error("loadCurrentGpslSeasonId:", error || preErr);
    return null;
  }
  return pre?.id != null ? Number(pre.id) : null;
}
