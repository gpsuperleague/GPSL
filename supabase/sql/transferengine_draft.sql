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
      OR btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = btrim(v_listing.player_id)
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

  PERFORM public.player_assign_to_club(v_listing.player_id, v_buyer);

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


-- UK calendar date for transfer-list scheduling (7pm / extensions)
CREATE OR REPLACE FUNCTION public.gpsl_timestamptz_uk_date(p_ts timestamptz)
RETURNS date
LANGUAGE sql
STABLE
AS $$
  SELECT (p_ts AT TIME ZONE 'Europe/London')::date;
$$;


-- Block draft settlement while a transfer-LIST auction (Active only) from the same UK
-- evening as draft_random_finish_time is still running — incl. anti-snipe extensions past 7pm.
-- Does NOT look at seller review, direct offers, or listings scheduled on a later UK day.
CREATE OR REPLACE FUNCTION public.transferengine_standard_listings_block_draft_settlement(
  p_now timestamptz,
  p_draft_finish timestamptz
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT
    p_draft_finish IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM "Player_Transfer_Listings" l
      WHERE l.status = 'Active'
        AND l.listing_type IS DISTINCT FROM 'draft'
        AND l.end_time > p_now
        AND public.gpsl_timestamptz_uk_date(
              COALESCE(l.initial_end_time, l.end_time)
            ) = public.gpsl_timestamptz_uk_date(p_draft_finish)
        AND (
          COALESCE(l.was_extended, false)
          OR EXTRACT(
                HOUR FROM (
                  COALESCE(l.initial_end_time, l.end_time)
                    AT TIME ZONE 'Europe/London'
                )
              )::int = 19
        )
    );
$$;


-- Process due standard transfer-list listings (7pm batch + extensions)
CREATE OR REPLACE FUNCTION public.transferengine_process_standard_listings(
  p_now timestamptz DEFAULT now()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_listing "Player_Transfer_Listings"%rowtype;
BEGIN
  FOR v_listing IN
    SELECT *
    FROM "Player_Transfer_Listings"
    WHERE status = 'Active'
      AND listing_type IS DISTINCT FROM 'draft'
  LOOP
    IF p_now >= v_listing.end_time THEN
      PERFORM transferengine_handle_expiry_or_extension(v_listing.id);
    END IF;
  END LOOP;
END;
$function$;


-- Settle one manager draft listing (requires managers_system.sql)
CREATE OR REPLACE FUNCTION public.transferengine_accept_manager_draft_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Manager_Transfer_Listings"%rowtype;
  v_amount  numeric;
  v_buyer   text;
  v_mgr     public."Managers"%rowtype;
BEGIN
  SELECT * INTO v_listing
  FROM public."Manager_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND OR v_listing.listing_type IS DISTINCT FROM 'draft' THEN
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RETURN;
  END IF;

  SELECT b.bid_amount, b.bidder_club_id
  INTO v_amount, v_buyer
  FROM public."Manager_Transfer_Bids" b
  WHERE b.listing_id = v_listing.id
     OR b.manager_id = v_listing.manager_id
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_buyer IS NULL OR v_amount IS NULL THEN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed', transfer_completed = false, updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = v_listing.manager_id FOR UPDATE;

  IF NOT FOUND OR (v_mgr.contracted_club IS NOT NULL AND btrim(v_mgr.contracted_club) <> '') THEN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed', transfer_completed = false, updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  UPDATE public."Manager_Transfer_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_buyer,
      updated_at = now()
  WHERE id = v_listing.id;

  BEGIN
    PERFORM public.manager_assign_to_club(v_listing.manager_id, v_buyer, 2, v_amount, true);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Manager draft listing % assign failed: %', p_listing_id, SQLERRM;
    RETURN;
  END;

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Closed', transfer_completed = true, updated_at = now()
  WHERE id = v_listing.id;
END;
$function$;


-- After random finish AND today's transfer-list evening is clear
CREATE OR REPLACE FUNCTION public.transferengine_settle_draft_auctions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_listing  public."Player_Transfer_Listings"%rowtype;
  v_mgr_listing public."Manager_Transfer_Listings"%rowtype;
  v_now      timestamptz := now();
BEGIN
  SELECT
    draft_auction_enabled,
    manager_draft_auction_enabled,
    draft_random_finish_time
  INTO v_settings
  FROM public.global_settings
  WHERE id = 1;

  IF NOT COALESCE(v_settings.draft_auction_enabled, false)
     AND NOT COALESCE(v_settings.manager_draft_auction_enabled, false) THEN
    RETURN;
  END IF;

  IF v_settings.draft_random_finish_time IS NULL THEN
    RETURN;
  END IF;

  IF v_now < v_settings.draft_random_finish_time THEN
    RETURN;
  END IF;

  PERFORM public.transferengine_process_standard_listings(v_now);

  IF public.transferengine_standard_listings_block_draft_settlement(
    v_now,
    v_settings.draft_random_finish_time
  ) THEN
    RETURN;
  END IF;

  IF COALESCE(v_settings.draft_auction_enabled, false) THEN
    FOR v_listing IN
      SELECT *
      FROM public."Player_Transfer_Listings"
      WHERE listing_type = 'draft' AND status = 'Active'
    LOOP
      PERFORM public.transferengine_accept_draft_sale(v_listing.id);
    END LOOP;
  END IF;

  IF COALESCE(v_settings.manager_draft_auction_enabled, false) THEN
    FOR v_mgr_listing IN
      SELECT *
      FROM public."Manager_Transfer_Listings"
      WHERE listing_type = 'draft' AND status = 'Active'
    LOOP
      PERFORM public.transferengine_accept_manager_draft_sale(v_mgr_listing.id);
    END LOOP;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_accept_manager_draft_sale(bigint) TO authenticated;


-- Each cron tick: transfer list first; draft only after random finish (e.g. 6:57pm)
-- AND no Active transfer-list auction still running that was scheduled for 7pm UK
-- on the draft-finish evening (incl. extensions to 9pm). Later days' listings ignored.
CREATE OR REPLACE FUNCTION public.transferengine_run()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
  PERFORM transferengine_process_standard_listings(now());
  PERFORM transferengine_settle_draft_auctions();
END;
$function$;
