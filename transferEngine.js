/* ============================================================
   MODULE: Transfer Engine
   Purpose:
   - Evaluate expired listings
   - Auto-complete sales
   - Handle seller review
   - Transfer funds safely
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
   MODULE B: Accept Sale (SAFE, ATOMIC LOGIC)
   ============================================================ */
transferEngine.acceptSale = async function (listingId) {
  console.log("🔍 acceptSale called for listing:", listingId);

  /* --------------------------------------------
     0. Fetch listing
     -------------------------------------------- */
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
     1. Validate listing state
     -------------------------------------------- */
  if (listing.status !== "Active" && listing.status !== "Review") {
    console.error("❌ Listing already processed");
    return;
  }

  /* --------------------------------------------
     2. Load finances for buyer + seller
     -------------------------------------------- */
  const { data: buyerFinance } = await supabase
    .from("Club_Finances")
    .select("balance")
    .eq("club_name", buyer)
    .single();

  const { data: sellerFinance } = await supabase
    .from("Club_Finances")
    .select("balance")
    .eq("club_name", seller)
    .single();

  if (!buyerFinance || !sellerFinance) {
    console.error("❌ Finance lookup failed");
    return;
  }

  const buyerBalance = buyerFinance.balance;
  const sellerBalance = sellerFinance.balance;

  /* --------------------------------------------
     3. Affordability check (NO MONEY MOVES YET)
     -------------------------------------------- */
  if (buyerBalance < amount) {
    console.error("❌ Buyer cannot afford — auto‑rejecting");

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
     4. Load player + validate ownership
     -------------------------------------------- */
  const { data: player } = await supabase
    .from("Players")
    .select("*")
    .eq("Konami_ID", Number(listing.player_id))   // FIXED
    .single();

  if (!player) {
    console.error("❌ Player not found");
    return;
  }

  if (player.Contracted_Team !== seller) {
    console.error("❌ Player no longer at selling club");
    return;
  }

  /* --------------------------------------------
     5. ALL VALIDATIONS PASSED → Perform updates
     -------------------------------------------- */

  console.log("💰 Deducting funds from buyer…");
  const { error: buyerUpdateError } = await supabase
    .from("Club_Finances")
    .update({ balance: buyerBalance - amount })
    .eq("club_name", buyer);

  if (buyerUpdateError) {
    console.error("❌ Failed to deduct from buyer:", buyerUpdateError);
    return;
  }

  console.log("💰 Crediting seller…");
  const { error: sellerUpdateError } = await supabase
    .from("Club_Finances")
    .update({ balance: sellerBalance + amount })
    .eq("club_name", seller);

  if (sellerUpdateError) {
    console.error("❌ Failed to credit seller:", sellerUpdateError);

    // rollback buyer deduction
    await supabase
      .from("Club_Finances")
      .update({ balance: buyerBalance })
      .eq("club_name", buyer);

    return;
  }

  console.log("🧩 Updating player club…");

  // DEBUG: show what ID the engine is using
  console.log("DEBUG listing.player_id:", listing.player_id, typeof listing.player_id);

  // DEBUG: show whether the DB can find that player
  const debugLookup = await supabase
    .from("Players")
    .select("Konami_ID, Contracted_Team")
    .eq("Konami_ID", Number(listing.player_id));

  console.log("DEBUG player lookup:", debugLookup);

  const { error: playerError } = await supabase
    .from("Players")
    .update({ Contracted_Team: buyer })
    .eq("Konami_ID", Number(listing.player_id));   // FIXED

  if (playerError) {
    console.error("❌ Player update failed:", playerError);

    // rollback finances
    await supabase
      .from("Club_Finances")
      .update({ balance: buyerBalance })
      .eq("club_name", buyer);

    await supabase
      .from("Club_Finances")
      .update({ balance: sellerBalance })
      .eq("club_name", seller);

    return;
  }

  console.log("📜 Logging transfer history…");
  const { error: historyError } = await supabase
    .from("Transfer_History")
    .insert({
      player_id: listing.player_id,
      seller_club_id: seller,
      buyer_club_id: buyer,
      fee: amount,
      agent_fee: 0,
      transfer_time: new Date().toISOString(),
      listing_id: listing.id
    });

  if (historyError) {
    console.error("❌ Failed to log history:", historyError);

    // rollback finances + player
    await supabase
      .from("Club_Finances")
      .update({ balance: buyerBalance })
      .eq("club_name", buyer);

    await supabase
      .from("Club_Finances")
      .update({ balance: sellerBalance })
      .eq("club_name", seller);

    await supabase
      .from("Players")
      .update({ Contracted_Team: seller })
      .eq("Konami_ID", Number(listing.player_id));   // FIXED

    return;
  }

  console.log("🏁 Marking listing completed…");
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
    console.error("❌ Failed to close listing:", listingUpdateError);
    return;
  }

  console.log("🎉 Transfer completed successfully");
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

async function updatePlayerTeam(testKonamiId, newTeam) {
  console.log("🔧 TEST: Updating player manually…");

  const { data, error } = await supabase
    .from("Players")
    .update({ Contracted_Team: newTeam })
    .eq("Konami_ID", Number(testKonamiId))
    .select();

  if (error) {
    console.error("❌ TEST update failed:", error);
  } else {
    console.log("✅ TEST update success:", data);
  }
}

