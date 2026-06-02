// Pending direct offers (contracted players) — one active review per player

function isActiveBidStatus(status) {
  return String(status || "").toLowerCase() === "active";
}

/** True pending direct offer = contracted, no listing yet, still awaiting seller review */
function isPendingContractedDirectOffer(row) {
  if (row.is_direct !== true) return false;
  if (row.listing_id != null && row.listing_id !== "") return false;
  if (!row.seller_club_id || String(row.seller_club_id).trim() === "") return false;
  if (!isActiveBidStatus(row.status)) return false;
  if (row.direct_bid_id == null || String(row.direct_bid_id).trim() === "") {
    return false;
  }
  return true;
}

export async function loadPendingDirectOfferPlayerIds(supabase) {
  const { data, error } = await supabase
    .from("Player_Transfer_Bids")
    .select("direct_bid_id, listing_id, seller_club_id, status, is_direct");

  if (error) {
    console.error("Failed to load pending direct offers:", error);
    return new Set();
  }

  const ids = new Set();
  for (const row of data || []) {
    if (!isPendingContractedDirectOffer(row)) continue;
    ids.add(String(row.direct_bid_id).trim());
  }
  return ids;
}

/** Players with an active standard (transfer list) listing */
export async function loadActiveListedPlayerIds(supabase) {
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("player_id, listing_type, status")
    .eq("status", "Active");

  if (error) {
    console.error("Failed to load active listings:", error);
    return new Set();
  }

  const ids = new Set();
  for (const row of data || []) {
    const lt = String(row.listing_type || "").toLowerCase();
    if (lt === "draft") continue;
    if (row.player_id == null) continue;
    ids.add(String(row.player_id).trim());
  }
  return ids;
}

export function playerHasPendingDirectOffer(pendingSet, konamiId) {
  if (!pendingSet || konamiId == null) return false;
  const key = String(konamiId).trim();
  if (!key) return false;
  return pendingSet.has(key);
}

export function playerHasActiveListing(listedSet, konamiId) {
  if (!listedSet || konamiId == null) return false;
  const key = String(konamiId).trim();
  if (!key) return false;
  return listedSet.has(key);
}
