-- =============================================================================
-- Manager draft settlement hotfix — residue after random finish
-- Run when player drafts settled but manager drafts stayed Active.
--
-- Root cause: transferengine_settle_manager_draft_auctions_only() skipped when
-- manager_draft_auction_enabled was false, while player draft already settles
-- active listings after finish (draft_settlement_overload_fix / resilience).
--
-- After deploy:
--   SELECT public.admin_settle_manager_drafts_now();
-- Or Admin → Settle manager drafts now
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
  v_meta    jsonb;
  v_ledger_posted boolean := false;
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
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RETURN;
  END IF;

  SELECT b.bid_amount, b.bidder_club_id
  INTO v_amount, v_buyer
  FROM public."Manager_Transfer_Bids" b
  WHERE b.is_direct = true
    AND (b.listing_id = v_listing.id OR b.manager_id = v_listing.manager_id)
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_buyer IS NULL OR v_amount IS NULL THEN
    v_buyer := nullif(btrim(v_listing.current_highest_bidder), '');
    v_amount := v_listing.current_highest_bid;
  END IF;

  IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
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

  SELECT * INTO v_mgr
  FROM public."Managers"
  WHERE id = v_listing.manager_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE WARNING 'Manager draft listing % — manager % not found', p_listing_id, v_listing.manager_id;
    RETURN;
  END IF;

  IF v_mgr.contracted_club IS NOT NULL AND btrim(v_mgr.contracted_club) <> '' THEN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = (v_mgr.contracted_club = v_buyer),
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Managers" m WHERE m.contracted_club = v_buyer
  ) OR EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_buyer AND c.manager_id IS NOT NULL
  ) THEN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed', transfer_completed = false, updated_at = now()
    WHERE id = v_listing.id;
    RAISE WARNING 'Manager draft listing % — buyer % already has a manager', p_listing_id, v_buyer;
    RETURN;
  END IF;

  v_meta := jsonb_build_object(
    'manager_draft', true,
    'listing_id', v_listing.id,
    'kind', 'manager'
  );

  SELECT EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'contract_signing_offer'
      AND l.metadata->>'listing_id' = v_listing.id::text
      AND coalesce(l.metadata->>'manager_draft', '') IN ('true', 't', '1')
  ) INTO v_ledger_posted;

  IF v_ledger_posted THEN
    PERFORM public.manager_assign_to_club(
      v_listing.manager_id,
      v_buyer,
      2::smallint,
      v_amount,
      false,
      v_meta
    );
    RETURN;
  END IF;

  PERFORM public.manager_assign_to_club(
    v_listing.manager_id,
    v_buyer,
    2::smallint,
    v_amount,
    true,
    v_meta
  );
END;
$function$;


-- Settle Active manager draft threads after secret finish (ignore enabled toggle).
CREATE OR REPLACE FUNCTION public.transferengine_settle_manager_draft_auctions_only()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_finish timestamptz;
  v_mgr_listing public."Manager_Transfer_Listings"%rowtype;
  v_now timestamptz := now();
BEGIN
  SELECT draft_random_finish_time INTO v_finish
  FROM public.global_settings
  WHERE id = 1;

  IF v_finish IS NULL OR v_now < v_finish THEN
    RETURN;
  END IF;

  FOR v_mgr_listing IN
    SELECT *
    FROM public."Manager_Transfer_Listings"
    WHERE listing_type = 'draft' AND status = 'Active'
    ORDER BY id
  LOOP
    BEGIN
      PERFORM public.transferengine_accept_manager_draft_sale(v_mgr_listing.id);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE WARNING 'Manager draft listing % failed: %', v_mgr_listing.id, SQLERRM;
    END;
  END LOOP;
END;
$function$;


-- Keep player + manager residue settlement in sync.
CREATE OR REPLACE FUNCTION public.transferengine_settle_draft_auctions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_now timestamptz := now();
  v_mgr_active int;
  v_club_active int;
  v_player_draft_active int;
  v_should_settle_players boolean;
  v_should_settle_managers boolean;
BEGIN
  SELECT
    draft_auction_enabled,
    manager_draft_auction_enabled,
    club_auction_enabled,
    draft_random_finish_time
  INTO v_settings
  FROM public.global_settings
  WHERE id = 1;

  SELECT count(*)::int INTO v_mgr_active
  FROM public."Manager_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  SELECT count(*)::int INTO v_club_active
  FROM public."Club_Auction_Listings"
  WHERE status = 'Active';

  SELECT count(*)::int INTO v_player_draft_active
  FROM public."Player_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  IF v_settings.draft_random_finish_time IS NULL
     OR v_now < v_settings.draft_random_finish_time THEN
    RETURN;
  END IF;

  IF NOT COALESCE(v_settings.draft_auction_enabled, false)
     AND NOT COALESCE(v_settings.manager_draft_auction_enabled, false)
     AND NOT COALESCE(v_settings.club_auction_enabled, false)
     AND v_player_draft_active = 0
     AND v_mgr_active = 0
     AND v_club_active = 0 THEN
    RETURN;
  END IF;

  PERFORM public.transferengine_process_standard_listings(v_now);

  v_should_settle_players :=
    v_player_draft_active > 0
    AND NOT public.transferengine_standard_listings_block_draft_settlement(
      v_now,
      v_settings.draft_random_finish_time
    );

  IF v_should_settle_players THEN
    PERFORM public.transferengine_settle_player_draft_listings(100);
  END IF;

  v_should_settle_managers := v_mgr_active > 0;

  IF v_should_settle_managers THEN
    PERFORM public.transferengine_settle_manager_draft_auctions_only();
  END IF;

  IF to_regprocedure('public.transferengine_settle_club_auctions_only()') IS NOT NULL THEN
    PERFORM public.transferengine_settle_club_auctions_only();
  END IF;
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
    'note',
      CASE
        WHEN NOT coalesce(v_enabled, false) AND v_before > 0
          THEN 'Settlement ignores manager_draft_auction_enabled when Active listings remain after random finish'
        ELSE NULL
      END,
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
          ),
        'manager_already_contracted', nullif(btrim(m.contracted_club), '')
      ) ORDER BY l.id), '[]'::jsonb)
      FROM public."Manager_Transfer_Listings" l
      LEFT JOIN public."Managers" m ON m.id = l.manager_id
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_accept_manager_draft_sale(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_settle_manager_drafts_now() TO authenticated;

NOTIFY pgrst, 'reload schema';
