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

  const buyer = listing.current_highest_bidder;   // ShortName
  const seller = listing.seller_club_id;          // ShortName
  const amount = listing.current_highest_bid;

  /* --------------------------------------------
     1. Validate buyer can afford the transfer
     -------------------------------------------- */
  const { data: buyerFinance, error: buyerFinanceError } = await supabase
    .from("Club_Finances")
    .select("balance")
    .eq("club_name", buyer) // ShortName now
    .single();

  if (buyerFinanceError || !buyerFinance) {
    console.error("❌ Buyer finance lookup failed:", buyerFinanceError);
    return;
  }

  if (buyerFinance.balance < amount) {
    console.error("❌ Buyer cannot afford this transfer — rejecting sale automatically");

    await supabase
      .from("Player_Transfer_Listings")
      .update({
        status: "Closed",
        transfer_completed: false,
        winning_bid: null,
        winning_club: null
      })
      .eq("id", listingId);

    return;
  }

  /* --------------------------------------------
     2. Transfer funds (buyer → seller)
     -------------------------------------------- */
  console.log("💰 Transferring funds:", { buyer, seller, amount });

  const { error: fundsError } = await supabase.rpc("transfer_funds", {
    from_club: buyer,   // ShortName
    to_club: seller,    // ShortName
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
    .update({ Contracted_Team: buyer }) // ShortName
    .eq('"Konami_ID"', listing.player_id);

  if (playerError) {
    console.error("❌ Player update failed:", playerError);
  } else {
    console.log("✅ Player updated:", playerUpdate);
  }

  /* --------------------------------------------
     4. Log transfer history
     -------------------------------------------- */
  const { error: historyError } = await supabase
    .from("Transfer_History")
    .insert({
      player_id: listing.player_id,
      seller_club_id: seller, // ShortName
      buyer_club_id: buyer,   // ShortName
      fee: amount,
      transfer_time: new Date().toISOString(),
      listing_id: listing.id
    });

  if (historyError) {
    console.error("❌ Failed to log transfer history:", historyError);
  } else {
    console.log("📜 Transfer logged in history");
  }

  /* --------------------------------------------
     5. Mark listing as completed
     -------------------------------------------- */
  console.log("🏁 Marking listing as completed:", listingId);

  const { error: listingUpdateError } = await supabase
    .from("Player_Transfer_Listings")
    .update({
      status: "Closed",
      transfer_completed: true,
      winning_bid: amount,
      winning_club: buyer
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
      transfer_completed: false,
      winning_bid: null,
      winning_club: null
    })
    .eq("id", listingId);

  if (error) console.error("❌ Failed to reject sale:", error);
  else console.log("🛑 Listing rejected and closed");
};


/* ============================================================
   MODULE D: RUN ENGINE (process expired listings)
   ============================================================ */
transferEngine.run = async function () {
  console.log("🔄 Transfer Engine: Running expiry check…");

  const now = new Date();

  // Fetch all ACTIVE listings
  const { data: listings, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("*")
    .eq("status", "Active");

  if (error) {
    console.error("❌ Failed to fetch listings:", error);
    return;
  }

  if (!listings || listings.length === 0) {
    console.log("📭 No active listings to evaluate");
    return;
  }

  console.log(`📦 Active listings found: ${listings.length}`);

  for (const listing of listings) {
    const end = new Date(listing.end_time);

    if (now >= end) {
      console.log("⏳ Listing expired → evaluating:", listing.id);
      await transferEngine.evaluateExpiredListing(listing);
    }
  }

  console.log("✅ Transfer Engine cycle complete");
};

window.transferEngine = transferEngine;
