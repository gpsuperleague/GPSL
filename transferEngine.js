/* ============================================================
   MODULE: Transfer Engine
   ============================================================ */

const transferEngine = {};

// Extension config
const MAIN_LATE_WINDOW_HOURS = 2;      // last 2h of main auction
const MAIN_EXTENSION_HOURS   = 1;      // +1h extension
const MICRO_WINDOW_MINUTES   = 5;      // last 5m of any extension
const MICRO_EXTENSION_MINUTES = 5;     // +5m micro extension

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

  const buyer = listing.current_highest_bidder;
  const seller = listing.seller_club_id;
  const amount = listing.current_highest_bid;

  /* --------------------------------------------
     1. Validate listing state
     -------------------------------------------- */
  if (listing.status !== "Active" && listing.status !== "Review") {
    console.error("❌ Listing already processed");
    return;
  }

  /* --------------------------------------------
     2. Load finances (no affordability check anymore)
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
     3. Load player + validate ownership
     -------------------------------------------- */
  const { data: player } = await supabase
    .from("Players")
    .select("*")
    .eq("Konami_ID", listing.player_id)
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
     4. Perform updates (balances can go negative)
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

    await supabase
      .from("Club_Finances")
      .update({ balance: buyerBalance })
      .eq("club_name", buyer);

    return;
  }

  console.log("🧩 Updating player club…");

  const { error: playerError } = await supabase
    .from("Players")
    .update({ Contracted_Team: buyer })
    .eq("Konami_ID", listing.player_id);

  if (playerError) {
    console.error("❌ Player update failed:", playerError);

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
      .eq("Konami_ID", listing.player_id);

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
   MODULE D: Handle Expiry vs Extension
   ============================================================ */
transferEngine.handleExpiryOrExtension = async function (listing) {
  const now = new Date();
  const end = new Date(listing.end_time);

  console.log("⏱ Handling expiry/extension for listing:", listing.id);

  // Get latest bid for this listing
  const { data: bids, error: bidsError } = await supabase
    .from("Player_Transfer_Bids")
    .select("*")
    .eq("listing_id", listing.id)
    .order("bid_time", { ascending: false })
    .limit(1);

  if (bidsError) {
    console.error("❌ Failed to fetch bids for extension:", bidsError);
    // If we can't see bids, just evaluate as expired
    await transferEngine.evaluateExpiredListing(listing);
    return;
  }

  const latestBid = bids && bids.length > 0 ? bids[0] : null;

  // No bids at all → normal expiry
  if (!latestBid) {
    await transferEngine.evaluateExpiredListing(listing);
    return;
  }

  const bidTime = new Date(latestBid.bid_time);

  // If listing has never been extended → check 2h late window for +1h extension
  if (!listing.was_extended) {
    const lateWindowStart = new Date(end.getTime() - MAIN_LATE_WINDOW_HOURS * 60 * 60 * 1000);

    if (bidTime >= lateWindowStart && bidTime <= end) {
      const newEnd = new Date(end.getTime() + MAIN_EXTENSION_HOURS * 60 * 60 * 1000);

      console.log("⏫ Applying 1h extension for listing:", listing.id);

      const { error: extError } = await supabase
        .from("Player_Transfer_Listings")
        .update({
          end_time: newEnd.toISOString(),
          was_extended: true,
          extension_type: "1h",
          extension_count: (listing.extension_count || 0) + 1
        })
        .eq("id", listing.id);

      if (extError) {
        console.error("❌ Failed to apply 1h extension:", extError);
        await transferEngine.evaluateExpiredListing(listing);
      }

      return;
    }

    // No late bid in last 2h → normal expiry
    await transferEngine.evaluateExpiredListing(listing);
    return;
  }

  // Already extended → check micro‑extension (5m window)
  const microWindowStart = new Date(end.getTime() - MICRO_WINDOW_MINUTES * 60 * 1000);

  if (bidTime >= microWindowStart && bidTime <= end) {
    const newEnd = new Date(end.getTime() + MICRO_EXTENSION_MINUTES * 60 * 1000);

    console.log("⏫ Applying 5m micro‑extension for listing:", listing.id);

    const { error: microError } = await supabase
      .from("Player_Transfer_Listings")
      .update({
        end_time: newEnd.toISOString(),
        was_extended: true,
        extension_type: "5m",
        extension_count: (listing.extension_count || 0) + 1
      })
      .eq("id", listing.id);

    if (microError) {
      console.error("❌ Failed to apply 5m extension:", microError);
      await transferEngine.evaluateExpiredListing(listing);
    }

    return;
  }

  // No bid in last 5 minutes of extension → final expiry
  await transferEngine.evaluateExpiredListing(listing);
};

/* ============================================================
   MODULE E: RUN ENGINE
   ============================================================ */
transferEngine.run = async function () {
  console.log("🔄 Transfer Engine: Running expiry check…");

  const now = new Date();

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
      console.log("⏳ Listing reached end_time → handling:", listing.id);
      await transferEngine.handleExpiryOrExtension(listing);
    }
  }

  console.log("✅ Transfer Engine cycle complete");
};

window.transferEngine = transferEngine;

/* ============================================================
   TEST FUNCTION — FIXED
   ============================================================ */
async function updatePlayerTeam(testKonamiId, newTeam) {
  console.log("🔧 TEST: Updating player manually…");

  const { data, error } = await supabase
    .from("Players")
    .update({ Contracted_Team: newTeam })
    .eq("Konami_ID", testKonamiId)
    .select();

  if (error) {
    console.error("❌ TEST update failed:", error);
  } else {
    console.log("✅ TEST update success:", data);
  }
}
