// Pending direct offers (contracted players) — one active review per player

export async function loadPendingDirectOfferPlayerIds(supabase) {
  const { data, error } = await supabase
    .from("Player_Transfer_Bids")
    .select("direct_bid_id")
    .eq("is_direct", true)
    .is("listing_id", null)
    .eq("status", "active");

  if (error) {
    console.error("Failed to load pending direct offers:", error);
    return new Set();
  }

  const ids = new Set();
  for (const row of data || []) {
    if (row.direct_bid_id != null && String(row.direct_bid_id).trim() !== "") {
      ids.add(String(row.direct_bid_id).trim());
    }
  }
  return ids;
}

export function playerHasPendingDirectOffer(pendingSet, konamiId) {
  if (!pendingSet || konamiId == null) return false;
  return pendingSet.has(String(konamiId).trim());
}
