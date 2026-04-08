const transferEngine = {};

// ===============================
//  EVALUATE EXPIRED LISTING
// ===============================
transferEngine.evaluateExpiredListing = async function (listing) {
  const now = new Date();
  const end = new Date(listing.end_time);

  // If expired and no bids → close
  if (!listing.current_highest_bid) {
    await supabase
      .from("Player_Transfer_Listings")
      .update({
        status: "Closed",
        transfer_completed: false
      })
      .eq("id", listing.id);

    return;
  }

  // If expired and reserve met → auto-complete sale
  if (listing.current_highest_bid >= listing.reserve_price) {
    await transferEngine.acceptSale(listing.id);
    return;
  }

  // If expired and reserve NOT met → seller review
  const reviewDeadline = new Date(now.getTime() + 24 * 60 * 60 * 1000);

  await supabase
    .from("Player_Transfer_Listings")
    .update({
      status: "Review",
      review_deadline: reviewDeadline.toISOString()
    })
    .eq("id", listing.id);
};



// ===============================
//  ACCEPT SALE
// ===============================
transferEngine.acceptSale = async function (listingId) {
  // Fetch listing
  const { data: listing, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("id", listingId)
    .single();

  if (error || !listing) {
    console.error("Listing not found for acceptSale");
    return;
  }

  const buyer = listing.current_highest_bidder;
  const seller = listing.seller_club_id;
  const amount = listing.current_highest_bid;

  // Move money: buyer → seller
  await supabase.rpc("transfer_funds", {
    from_club: buyer,
    to_club: seller,
    amount: amount
  });

  // Transfer player to buyer
  await supabase
    .from("Players")
    .update({ club_id: buyer })
    .eq("id", listing.player_id);

  // Mark listing as completed
  await supabase
    .from("Player_Transfer_Listings")
    .update({
      status: "Closed",
      transfer_completed: true
    })
    .eq("id", listingId);
};



// ===============================
//  REJECT SALE
// ===============================
transferEngine.rejectSale = async function (listingId) {
  await supabase
    .from("Player_Transfer_Listings")
    .update({
      status: "Closed",
      transfer_completed: false
    })
    .eq("id", listingId);
};
