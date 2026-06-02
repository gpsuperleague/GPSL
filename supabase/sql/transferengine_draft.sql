-- =============================================================================
-- GPSL — draft (free agents) + standard (contracted) transfer engine
-- Apply in Supabase SQL Editor (project omyyogfumrjoaweuawjn), once.
--
-- CONTRACTED PLAYERS: list / direct bid → existing transferengine_handle_* 
--   + transferengine_accept_sale (seller_club_id set).
-- FREE AGENTS: draft only (listing_type = 'draft') → settle here at random finish.
-- =============================================================================

-- Free-agent draft win: debit buyer only, assign player, close listing
CREATE OR REPLACE FUNCTION public.transferengine_accept_draft_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_listing        "Player_Transfer_Listings"%rowtype;
  v_buyer_balance  numeric;
  v_amount         numeric;
  v_buyer          text;
  v_player         "Players"%rowtype;
BEGIN
  SELECT *
  INTO v_listing
  FROM "Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Draft listing % not found', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.listing_type IS DISTINCT FROM 'draft' THEN
    RAISE NOTICE 'Listing % is not draft', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RAISE NOTICE 'Draft listing % already processed', p_listing_id;
    RETURN;
  END IF;

  SELECT b.bid_amount, b.bidder_club_id
  INTO v_amount, v_buyer
  FROM "Player_Transfer_Bids" b
  WHERE b.is_direct = true
    AND (
      b.listing_id = v_listing.id
      OR b.direct_bid_id::text = v_listing.player_id
    )
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_buyer IS NULL OR v_amount IS NULL THEN
    UPDATE "Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  UPDATE "Player_Transfer_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_buyer
  WHERE id = v_listing.id;

  SELECT balance
  INTO v_buyer_balance
  FROM "Club_Finances"
  WHERE club_name = v_buyer
  FOR UPDATE;

  IF v_buyer_balance IS NULL THEN
    RAISE NOTICE 'Buyer finance missing for draft listing %', p_listing_id;
    RETURN;
  END IF;

  SELECT *
  INTO v_player
  FROM "Players"
  WHERE "Konami_ID"::text = v_listing.player_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Player not found for draft listing %', p_listing_id;
    RETURN;
  END IF;

  IF v_player."Contracted_Team" IS NOT NULL
     AND btrim(v_player."Contracted_Team") <> '' THEN
    RAISE NOTICE 'Player already contracted for draft listing %', p_listing_id;
    RETURN;
  END IF;

  UPDATE "Club_Finances"
  SET balance = v_buyer_balance - v_amount
  WHERE club_name = v_buyer;

  UPDATE "Players"
  SET "Contracted_Team" = v_buyer
  WHERE "Konami_ID"::text = v_listing.player_id;

  INSERT INTO "Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id
  )
  VALUES (
    v_listing.player_id,
    NULL,
    v_buyer,
    v_amount,
    0,
    now(),
    v_listing.id
  );

  UPDATE "Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_amount,
      winning_club = v_buyer
  WHERE id = v_listing.id;
END;
$function$;


-- When draft_random_finish_time is reached, settle all active draft listings
CREATE OR REPLACE FUNCTION public.transferengine_settle_draft_auctions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_settings record;
  v_listing  "Player_Transfer_Listings"%rowtype;
BEGIN
  SELECT
    draft_auction_enabled,
    draft_random_finish_time
  INTO v_settings
  FROM global_settings
  WHERE id = 1;

  IF NOT COALESCE(v_settings.draft_auction_enabled, false) THEN
    RETURN;
  END IF;

  IF v_settings.draft_random_finish_time IS NULL THEN
    RETURN;
  END IF;

  IF now() < v_settings.draft_random_finish_time THEN
    RETURN;
  END IF;

  FOR v_listing IN
    SELECT *
    FROM "Player_Transfer_Listings"
    WHERE listing_type = 'draft'
      AND status = 'Active'
  LOOP
    PERFORM transferengine_accept_draft_sale(v_listing.id);
  END LOOP;
END;
$function$;


-- Standard listings only; draft uses random finish settlement above
CREATE OR REPLACE FUNCTION public.transferengine_run()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_listing "Player_Transfer_Listings"%rowtype;
  v_now     timestamptz := now();
BEGIN
  PERFORM transferengine_settle_draft_auctions();

  FOR v_listing IN
    SELECT *
    FROM "Player_Transfer_Listings"
    WHERE status = 'Active'
      AND listing_type IS DISTINCT FROM 'draft'
  LOOP
    IF v_now >= v_listing.end_time THEN
      PERFORM transferengine_handle_expiry_or_extension(v_listing.id);
    END IF;
  END LOOP;
END;
$function$;
