-- =============================================================================
-- Manager draft settlement — mirrors player draft (transferengine_draft.sql)
-- Run once, then: SELECT public.admin_settle_manager_drafts_now();
-- =============================================================================
-- Player draft: highest bid → debit Club_Finances → player_assign_to_club → close listing
-- Manager draft: highest bid → debit Club_Finances → Managers.contracted_club
--                 → manager_sync_club_rating (sets Clubs.manager_id for Club Details)
-- =============================================================================

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
  v_buyer_balance numeric;
  v_season_id bigint;
  v_wage bigint;
BEGIN
  SELECT * INTO v_listing
  FROM public."Manager_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Manager draft listing % not found', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.listing_type IS DISTINCT FROM 'draft' THEN
    RAISE NOTICE 'Manager listing % is not draft', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RAISE NOTICE 'Manager draft listing % already processed', p_listing_id;
    RETURN;
  END IF;

  SELECT b.bid_amount, b.bidder_club_id
  INTO v_amount, v_buyer
  FROM public."Manager_Transfer_Bids" b
  WHERE b.is_direct = true
    AND (
      b.listing_id = v_listing.id
      OR b.manager_id = v_listing.manager_id
    )
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_buyer IS NULL OR v_amount IS NULL THEN
    v_buyer := nullif(btrim(v_listing.current_highest_bidder), '');
    v_amount := v_listing.current_highest_bid;
  END IF;

  IF v_buyer IS NULL OR v_amount IS NULL THEN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false,
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  UPDATE public."Manager_Transfer_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_buyer,
      updated_at = now()
  WHERE id = v_listing.id;

  SELECT balance
  INTO v_buyer_balance
  FROM public."Club_Finances"
  WHERE club_name = v_buyer
  FOR UPDATE;

  IF v_buyer_balance IS NULL THEN
    RAISE NOTICE 'Buyer finance missing for manager draft listing %', p_listing_id;
    RETURN;
  END IF;

  SELECT * INTO v_mgr
  FROM public."Managers"
  WHERE id = v_listing.manager_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Manager not found for draft listing %', p_listing_id;
    RETURN;
  END IF;

  IF v_mgr.contracted_club IS NOT NULL AND btrim(v_mgr.contracted_club) <> '' THEN
    RAISE NOTICE 'Manager already contracted for draft listing %', p_listing_id;
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed', transfer_completed = false, updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Managers" m
    WHERE m.contracted_club = v_buyer
  ) OR EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_buyer AND c.manager_id IS NOT NULL
  ) THEN
    RAISE NOTICE 'Buyer % already has a manager — cannot settle draft listing %',
      v_buyer, p_listing_id;
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed', transfer_completed = false, updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  UPDATE public."Club_Finances"
  SET balance = v_buyer_balance - v_amount
  WHERE club_name = v_buyer;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  LIMIT 1;

  v_wage := public.manager_weekly_wage_for(v_mgr.market_value);

  UPDATE public."Managers"
  SET contracted_club = v_buyer,
      contract_seasons_remaining = 2,
      weekly_wage = v_wage,
      signed_season_id = v_season_id,
      updated_at = now()
  WHERE id = v_listing.manager_id;

  PERFORM public.manager_sync_club_rating(v_buyer);

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      updated_at = now()
  WHERE id = v_listing.id;

  RAISE NOTICE 'Manager draft listing % settled — manager % to % for %',
    p_listing_id, v_listing.manager_id, v_buyer, v_amount;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_settle_manager_draft_auctions_only()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_mgr_listing public."Manager_Transfer_Listings"%rowtype;
  v_now timestamptz := now();
BEGIN
  SELECT manager_draft_auction_enabled, draft_random_finish_time
  INTO v_settings
  FROM public.global_settings
  WHERE id = 1;

  IF NOT COALESCE(v_settings.manager_draft_auction_enabled, false) THEN
    RETURN;
  END IF;

  IF v_settings.draft_random_finish_time IS NULL THEN
    RETURN;
  END IF;

  IF v_now < v_settings.draft_random_finish_time THEN
    RETURN;
  END IF;

  FOR v_mgr_listing IN
    SELECT *
    FROM public."Manager_Transfer_Listings"
    WHERE listing_type = 'draft' AND status = 'Active'
  LOOP
    PERFORM public.transferengine_accept_manager_draft_sale(v_mgr_listing.id);
  END LOOP;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_settle_draft_auctions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_listing  public."Player_Transfer_Listings"%rowtype;
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

  IF COALESCE(v_settings.draft_auction_enabled, false)
     AND NOT public.transferengine_standard_listings_block_draft_settlement(
       v_now,
       v_settings.draft_random_finish_time
     ) THEN
    FOR v_listing IN
      SELECT *
      FROM public."Player_Transfer_Listings"
      WHERE listing_type = 'draft' AND status = 'Active'
    LOOP
      PERFORM public.transferengine_accept_draft_sale(v_listing.id);
    END LOOP;
  END IF;

  PERFORM public.transferengine_settle_manager_draft_auctions_only();
END;
$function$;


CREATE OR REPLACE FUNCTION public.admin_settle_manager_drafts_now()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_before int;
  v_after int;
  v_finish timestamptz;
  v_enabled boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT manager_draft_auction_enabled, draft_random_finish_time
  INTO v_enabled, v_finish
  FROM public.global_settings
  WHERE id = 1;

  SELECT count(*)::int INTO v_before
  FROM public."Manager_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  PERFORM public.transferengine_settle_manager_draft_auctions_only();

  SELECT count(*)::int INTO v_after
  FROM public."Manager_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  RETURN jsonb_build_object(
    'ok', true,
    'ran_at', now(),
    'manager_draft_auction_enabled', coalesce(v_enabled, false),
    'draft_random_finish_time', v_finish,
    'secret_finish_passed', v_finish IS NOT NULL AND now() >= v_finish,
    'active_manager_draft_before', v_before,
    'active_manager_draft_after', v_after,
    'manager_draft_settled_count', v_before - v_after,
    'still_active', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'listing_id', l.id,
        'manager_id', l.manager_id,
        'manager_name', m.name,
        'high_bid', l.current_highest_bid,
        'high_bidder', l.current_highest_bidder,
        'buyer_already_has_manager',
          EXISTS (
            SELECT 1 FROM public."Managers" mx
            WHERE mx.contracted_club = l.current_highest_bidder
          )
          OR EXISTS (
            SELECT 1 FROM public."Clubs" cx
            WHERE cx."ShortName" = l.current_highest_bidder
              AND cx.manager_id IS NOT NULL
          )
      ) ORDER BY l.id), '[]'::jsonb)
      FROM public."Manager_Transfer_Listings" l
      LEFT JOIN public."Managers" m ON m.id = l.manager_id
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
    ),
    'recently_completed', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'listing_id', l.id,
        'manager_id', l.manager_id,
        'manager_name', m.name,
        'transfer_completed', l.transfer_completed,
        'high_bidder', l.current_highest_bidder,
        'managers_contracted_club', m.contracted_club,
        'clubs_manager_id', c.manager_id
      ) ORDER BY l.updated_at DESC), '[]'::jsonb)
      FROM public."Manager_Transfer_Listings" l
      LEFT JOIN public."Managers" m ON m.id = l.manager_id
      LEFT JOIN public."Clubs" c ON c."ShortName" = l.current_highest_bidder
      WHERE l.listing_type = 'draft'
        AND l.status = 'Closed'
        AND l.updated_at > now() - interval '4 hours'
      LIMIT 30
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_accept_manager_draft_sale(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_settle_manager_drafts_now() TO authenticated;

NOTIFY pgrst, 'reload schema';
