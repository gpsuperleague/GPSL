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

/**
 * Buyer bid still live in Transfer Centre “Active Bids”.
 * Bid rows often stay status=active after listing closes or user is outbid.
 */
export function isBuyerBidStillLive(bid, listing, buyerClubShort, options = {}) {
  if (!bid || !isActiveBidStatus(bid.status)) return false;

  const now = options.now instanceof Date ? options.now : new Date();
  const draftEnded = options.draftAuctionEnded === true;
  const club = String(buyerClubShort || "").trim();

  if (bid.is_first_draft_bid || bid.is_draft_join) {
    if (draftEnded) return false;
    if (!listing || String(listing.listing_type || "").toLowerCase() !== "draft") {
      return false;
    }
    return String(listing.status || "") === "Active";
  }

  if (isPendingContractedDirectOffer(bid)) return true;

  if (bid.listing_id == null || !listing) return false;

  const st = String(listing.status || "");
  if (st === "Closed") return false;

  const lt = String(listing.listing_type || "").toLowerCase();
  if (lt === "draft") {
    if (draftEnded) return false;
    return st === "Active";
  }

  const leading =
    listing.current_highest_bidder &&
    String(listing.current_highest_bidder) === club;

  if (st === "Active") {
    const end = listing.end_time ? new Date(listing.end_time) : null;
    if (!end || end <= now) return false;
    return leading;
  }

  if (st === "Review" || st === "Seller Review") {
    return leading;
  }

  return false;
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

/** Players with an active standard (transfer list) listing still open */
export async function loadActiveListedPlayerIds(supabase) {
  const nowIso = new Date().toISOString();
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("player_id, listing_type, status, end_time")
    .eq("status", "Active")
    .gt("end_time", nowIso);

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
