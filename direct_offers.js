// Pending direct offers (contracted players) — one active review per player

function isActiveBidStatus(status) {
  return String(status || "").toLowerCase() === "active";
}

/** Konami ID on a bid row (player_id column, legacy direct_bid_id fallback). */
export function getBidPlayerId(row) {
  if (!row) return null;
  const raw = row.player_id ?? row.direct_bid_id;
  if (raw == null || String(raw).trim() === "") return null;
  return String(raw).trim();
}

/** True pending direct offer = contracted, no listing yet, still awaiting seller review */
export function isPendingContractedDirectOffer(row) {
  if (row.is_direct !== true) return false;
  if (row.listing_id != null && row.listing_id !== "") return false;
  if (!row.seller_club_id || String(row.seller_club_id).trim() === "") return false;
  if (!isActiveBidStatus(row.status)) return false;
  if (!getBidPlayerId(row)) return false;
  return true;
}

/** All players with a pending direct offer (any seller). */
export async function loadPendingDirectOfferState(supabase) {
  const { data, error } = await supabase
    .from("Player_Transfer_Bids")
    .select("player_id, direct_bid_id, listing_id, seller_club_id, status, is_direct");

  if (error) {
    console.error("Failed to load pending direct offers:", error);
    return { allPlayerIds: new Set(), bySeller: new Map() };
  }

  const allPlayerIds = new Set();
  const bySeller = new Map();

  for (const row of data || []) {
    if (!isPendingContractedDirectOffer(row)) continue;
    const pid = getBidPlayerId(row);
    if (!pid) continue;
    allPlayerIds.add(pid);
    const seller = String(row.seller_club_id).trim();
    if (!seller) continue;
    if (!bySeller.has(seller)) bySeller.set(seller, new Set());
    bySeller.get(seller).add(pid);
  }

  return { allPlayerIds, bySeller };
}

export function sellerPendingPlayerIds(state, sellerShort) {
  const key = String(sellerShort || "").trim();
  if (!key || !state?.bySeller) return new Set();
  return state.bySeller.get(key) || new Set();
}

export async function loadPendingDirectOfferPlayerIds(supabase) {
  const state = await loadPendingDirectOfferState(supabase);
  return state.allPlayerIds;
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
