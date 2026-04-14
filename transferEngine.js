/* ============================================================
   MODULE: Transfer Engine
   Purpose:
   - Evaluate expired listings
   - Auto-complete sales
   - Handle seller review
   - Transfer funds
   - Move players between clubs
   - Log transfer history
   ============================================================ */

const transferEngine = {};


/* ============================================================
   MODULE A: Evaluate Expired Listing
   ============================================================ */
transferEngine.evaluateExpiredListing = async function (listing) {
  console.log("🔍 Checking expired listing:", listing.id);

  const now = new Date();
  const end = new Date(listing.end_time);

  // 1. No bids → close listing
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

  // 2. Reserve met → auto-complete sale
  if (listing.current_highest_bid >= listing.reserve_price) {
    console.log("🏁 Reserve met — auto‑completing sale for listing", listing.id);
    await transferEngine.acceptSale(listing.id);
    return;
  }

  // 3. Reserve NOT met → seller review
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


/* ============================================================
   MODULE B: Accept Sale (Full Financial Logic)
   ============================================================ */
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

  /* --------------------------------------------
     1. Validate buyer can afford the transfer
     -------------------------------------------- */
  const { data: buyerFinance } = await supabase
    .from("Club_Finances")
    .select("balance")
    .eq("club_name", buyer)
    .single();

  if (!buyerFinance) {
    console.error("❌ Buyer finance lookup failed");
    return;
  }

  if (buyerFinance.balance < amount) {
    console.error("❌ Buyer cannot afford this transfer — rejecting sale automatically");

    await supabase
      .from("Player_Transfer_Listings")
      .update({
        status: "Closed",
        transfer_completed: false,
        final_bid: null
      })
      .eq("id", listingId);

    return;
  }

  /* --------------------------------------------
     2. Transfer funds (buyer → seller)
     -------------------------------------------- */
  console.log("💰 Transferring funds:", { buyer, seller, amount });

  const { error: fundsError } = await supabase.rpc("transfer_funds", {
    from_club: buyer,
    to_club: seller,
    amount: amount
  });

  if (fundsError) {
    console.error("❌ transfer_funds failed:", fundsError);
    return;
  }

  console.log("✅ Funds transferred successfully");

  /* --------------------------------------------
     3. Move player to buyer
     -------------------------------------------- */
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
    console.log("✅ Player updated:", playerUpdate);
  }

  /* --------------------------------------------
     4. Log transfer history
     -------------------------------------------- */
  await supabase.from("Transfer_History").insert({
    player_id: listing.player_id,
    seller_club_id: seller,
    buyer_club_id: buyer,
    fee: amount,
    transfer_time: new Date().toISOString(),
    listing_id: listing.id
  });

  console.log("📜 Transfer logged in history");

  /* --------------------------------------------
     5. Mark listing as completed
     -------------------------------------------- */
  console.log("🏁 Marking listing as completed:", listingId);

  const { error: listingUpdateError } = await supabase
    .from("Player_Transfer_Listings")
    .update({
      status: "Closed",
      transfer_completed: true,
      final_bid: amount,
      winner: buyer
    })
    .eq("id", listingId);

  if (listingUpdateError) {
    console.error("❌ Failed to mark listing completed:", listingUpdateError);
  } else {
    console.log("🎉 Listing successfully completed");
  }
};


/* ============================================================
   MODULE C: Reject Sale
   ============================================================ */
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
