-- =============================================================================
-- CONTRACTED-PLAYER transfer helpers — bigint listing id (matches table)
-- Run AFTER transferengine_draft.sql if Step 5 still errors on integer/bigint
-- =============================================================================

CREATE OR REPLACE FUNCTION public.transferengine_accept_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_listing          "Player_Transfer_Listings"%rowtype;
  v_buyer_balance    numeric;
  v_seller_balance   numeric;
  v_player           "Players"%rowtype;
BEGIN
  SELECT *
  INTO v_listing
  FROM "Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Listing % not found', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RAISE NOTICE 'Listing % already processed', p_listing_id;
    RETURN;
  END IF;

  SELECT balance
  INTO v_buyer_balance
  FROM "Club_Finances"
  WHERE club_name = v_listing.current_highest_bidder
  FOR UPDATE;

  SELECT balance
  INTO v_seller_balance
  FROM "Club_Finances"
  WHERE club_name = v_listing.seller_club_id
  FOR UPDATE;

  IF v_buyer_balance IS NULL OR v_seller_balance IS NULL THEN
    RAISE NOTICE 'Finance lookup failed for listing %', p_listing_id;
    RETURN;
  END IF;

  SELECT *
  INTO v_player
  FROM "Players"
  WHERE "Konami_ID"::text = v_listing.player_id::text
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Player not found for listing %', p_listing_id;
    RETURN;
  END IF;

  IF v_player."Contracted_Team" IS DISTINCT FROM v_listing.seller_club_id THEN
    RAISE NOTICE 'Player no longer at selling club for listing %', p_listing_id;
    RETURN;
  END IF;

  IF public.player_signed_this_season(v_player."Season_Signed") THEN
    RAISE NOTICE 'Player signed this season — sale blocked for listing %', p_listing_id;
    RETURN;
  END IF;

  UPDATE "Club_Finances"
  SET balance = v_buyer_balance - v_listing.current_highest_bid
  WHERE club_name = v_listing.current_highest_bidder;

  UPDATE "Club_Finances"
  SET balance = v_seller_balance + v_listing.current_highest_bid
  WHERE club_name = v_listing.seller_club_id;

  PERFORM public.player_assign_to_club(
    v_listing.player_id::text,
    v_listing.current_highest_bidder
  );

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
    v_listing.seller_club_id,
    v_listing.current_highest_bidder,
    v_listing.current_highest_bid,
    0,
    now(),
    v_listing.id
  );

  UPDATE "Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_listing.current_highest_bid,
      winning_club = v_listing.current_highest_bidder
  WHERE id = v_listing.id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_evaluate_expired_listing(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_listing "Player_Transfer_Listings"%rowtype;
  v_now     timestamptz := now();
BEGIN
  SELECT *
  INTO v_listing
  FROM "Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Listing % not found in evaluate_expired_listing', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.current_highest_bid IS NULL THEN
    UPDATE "Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF v_listing.current_highest_bid >= v_listing.reserve_price THEN
    PERFORM transferengine_accept_sale(v_listing.id);
    RETURN;
  END IF;

  UPDATE "Player_Transfer_Listings"
  SET status = 'Review',
      seller_review_deadline = v_now + interval '24 hours'
  WHERE id = v_listing.id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_handle_expiry_or_extension(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_listing            "Player_Transfer_Listings"%rowtype;
  v_latest_bid         "Player_Transfer_Bids"%rowtype;
  v_now                timestamptz := now();
  v_late_window        interval := interval '2 hours';
  v_main_extension     interval := interval '1 hour';
  v_micro_window       interval := interval '5 minutes';
  v_micro_ext          interval := interval '5 minutes';
  v_late_window_start  timestamptz;
  v_micro_window_start timestamptz;
BEGIN
  SELECT *
  INTO v_listing
  FROM "Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Listing % not found in handle_expiry_or_extension', p_listing_id;
    RETURN;
  END IF;

  SELECT *
  INTO v_latest_bid
  FROM "Player_Transfer_Bids"
  WHERE listing_id = v_listing.id
  ORDER BY bid_time DESC
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM transferengine_evaluate_expired_listing(v_listing.id);
    RETURN;
  END IF;

  IF NOT v_listing.was_extended THEN
    v_late_window_start := v_listing.end_time - v_late_window;

    IF v_latest_bid.bid_time >= v_late_window_start
       AND v_latest_bid.bid_time <= v_listing.end_time THEN

      UPDATE "Player_Transfer_Listings"
      SET end_time = v_listing.end_time + v_main_extension,
          was_extended = true,
          extension_type = '1h',
          extension_count = coalesce(extension_count, 0) + 1
      WHERE id = v_listing.id;

      RETURN;
    END IF;

    PERFORM transferengine_evaluate_expired_listing(v_listing.id);
    RETURN;
  END IF;

  v_micro_window_start := v_listing.end_time - v_micro_window;

  IF v_latest_bid.bid_time >= v_micro_window_start
     AND v_latest_bid.bid_time <= v_listing.end_time THEN

    UPDATE "Player_Transfer_Listings"
    SET end_time = v_listing.end_time + v_micro_ext,
        was_extended = true,
        extension_type = '5m',
        extension_count = coalesce(extension_count, 0) + 1
    WHERE id = v_listing.id;

    RETURN;
  END IF;

  PERFORM transferengine_evaluate_expired_listing(v_listing.id);
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_reject_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
  UPDATE "Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE id = p_listing_id;
END;
$function$;


-- Drop integer overloads so Postgres does not pick the wrong signature
DROP FUNCTION IF EXISTS public.transferengine_handle_expiry_or_extension(integer);
DROP FUNCTION IF EXISTS public.transferengine_evaluate_expired_listing(integer);
DROP FUNCTION IF EXISTS public.transferengine_accept_sale(integer);
DROP FUNCTION IF EXISTS public.transferengine_reject_sale(integer);


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
