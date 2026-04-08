transferEngine.placeBid = async function (listingId, bidderClubId, bidAmount) {
  console.log("Placing bid:", listingId, bidderClubId, bidAmount);

  // Fetch listing
  const { data: listingData, error: listingError } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("id", listingId)
    .single();

  if (listingError || !listingData) {
    console.error("Listing not found", listingError);
    return { success: false, message: "Listing not found" };
  }

  const listing = listingData;
  const now = new Date();
  const end = new Date(listing.end_time);

  // Prevent bidding after expiry
  if (now > end) {
    return { success: false, message: "Listing has already expired" };
  }

  // Prevent low bids
  if (bidAmount <= (listing.current_highest_bid || 0)) {
    return { success: false, message: "Bid must be higher than current highest bid" };
  }

  // Insert bid record
  await supabase.from("Transfer_Bids").insert({
    listing_id: listingId,
    bidder_club_id: bidderClubId,
    bid_amount: bidAmount,
    bid_time: now.toISOString()
  });

  // Update listing with new highest bid
  await supabase
    .from("Player_Transfer_Listings")
    .update({
      current_highest_bid: bidAmount,
      current_highest_bidder: bidderClubId
    })
    .eq("id", listingId);

  // ============================
  //  EXTENSION LOGIC
  // ============================

  const timeRemaining = end - now;

  // If inside final 2 minutes → extend by 2 minutes
  if (timeRemaining <= 2 * 60 * 1000) {
    const newEnd = new Date(end.getTime() + 2 * 60 * 1000);
    await supabase
      .from("Player_Transfer_Listings")
      .update({ end_time: newEnd.toISOString() })
      .eq("id", listingId);

    return { success: true, message: "Bid placed. Listing extended by 2 minutes." };
  }

  // If inside final hour → extend by 1 hour
  if (timeRemaining <= 60 * 60 * 1000) {
    const newEnd = new Date(end.getTime() + 60 * 60 * 1000);
    await supabase
      .from("Player_Transfer_Listings")
      .update({ end_time: newEnd.toISOString() })
      .eq("id", listingId);

    return { success: true, message: "Bid placed. Listing extended by 1 hour." };
  }

  return { success: true, message: "Bid placed successfully." };
};
