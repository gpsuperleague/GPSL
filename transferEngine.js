const transferEngine = {};

// ===============================
//  EVALUATE EXPIRED LISTING
// ===============================
transferEngine.evaluateExpiredListing = async function (listing) {
  console.log("🔍 Checking expired listing:", listing.id);

  const now = new Date();
  const end = new Date(listing.end_time);

  // If expired and no bids → close
  if (!listing.current_highest_bid) {
    console.log("⚠️ No bids — closing listing", listing.id);

    const { error } = await supabase
      .from("Player_Transfer_Listings")
      .update({
        status: "Closed",
        transfer_completed: false
      })
      .eq("id", listing.id);

    if (error) console.error("❌ Failed to close listing:", error);
    else console.log("✅ Listing closed with no bids");

    return;
  }

  // If expired and reserve met → auto-complete sale
  if (listing.current_highest_bid >= listing.reserve_price) {
    console.log("🏁 Reserve met — auto‑completing sale for listing", listing.id);
    await transferEngine.acceptSale(listing.id);
    return;
  }

  // If expired and reserve NOT met → seller review
  console.log("📝 Reserve NOT met — sending to review:", listing.id);

  const reviewDeadline = new Date(now.getTime() + 24 * 60 * 60 * 1000);

  const { error } = await supabase
    .from("Player_Transfer_Listings")
    .update({
      status: "Review",
      review_deadline: reviewDeadline.toISOString()
    })
    .eq("id", listing.id);

  if (error) console.error("❌ Failed to set review status:", error);
  else console.log("✅ Listing moved to review");
};

// ===============================
//  ACCEPT SALE
// ===============================
transferEngine.acceptSale = async function (listingId) {
  console.log("🔍 acceptSale called for listing:", listingId);

  // Fetch listing
  const { data: listing, error: listingError } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("id", listingId)
    .single();

  if (listingError || !listing) {
    console.error("❌ Listing not found:", listingError);
    return;
  }

  console.log("📄 Listing data:", listing);

  const buyer = listing.current_highest_bidder;
  const seller = listing.seller_club_id;
  const amount = listing.current_highest_bid;

  // Move money: buyer → seller
  console.log("💰 Transferring funds:", { buyer, seller, amount });

  const { error: fundsError } = await supabase.rpc("transfer_funds", {
    from_club: buyer,
    to_club: seller,
    amount: amount
  });

  if (fundsError) console.error("❌ transfer_funds failed:", fundsError);
  else console.log("✅ Funds transferred successfully");

  // Transfer player to buyer
  console.log("🧩 Updating player club:", {
    player_id: listing.player_id,
    new_club: buyer
  });

  const { data: playerUpdate, error: playerError } = await supabase
    .from("Players")
    .update({ Contracted_Team: buyer })
    .eq("Konami_ID", listing.player_id);

  if (playerError) {
    console.error("❌ Player update failed:", playerError);
  } else {
    if (playerUpdate.length === 0) {
      console.warn("⚠️ Player update matched ZERO rows — check Konami_ID");
    } else {
      console.log("✅ Player updated:", playerUpdate);
    }
  }

  // Mark listing as completed
  console.log("🏁 Marking listing as completed:", listingId);

  const { error: listingUpdateError } = await supabase
    .from("Player_Transfer_Listings")
    .update({
      status: "Closed",
      transfer_completed: true
    })
    .eq("id", listingId);

  if (listingUpdateError) {
    console.error("❌ Failed to mark listing completed:", listingUpdateError);
  } else {
    console.log("🎉 Listing successfully completed");
  }
};

// ===============================
//  REJECT SALE
// ===============================
transferEngine.rejectSale = async function (listingId) {
  console.log("🚫 rejectSale called for listing:", listingId);

  const { error } = await supabase
    .from("Player_Transfer_Listings")
    .update({
      status: "Closed",
      transfer_completed: false
    })
    .eq("id", listingId);

  if (error) console.error("❌ Failed to reject sale:", error);
  else console.log("🛑 Listing rejected and closed");
};
