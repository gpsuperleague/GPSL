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
  v_buyer_balance numeric;
  v_season_id bigint;
  v_wage bigint;
  v_mgr_name text;
  v_meta jsonb;
BEGIN
  SELECT * INTO v_listing
  FROM public."Manager_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager draft listing % not found', p_listing_id;
  END IF;

  IF v_listing.listing_type IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'Manager listing % is not a draft listing', p_listing_id;
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
    RAISE EXCEPTION 'Manager % not found for draft listing %', v_listing.manager_id, p_listing_id;
  END IF;

  IF v_mgr.contracted_club IS NOT NULL AND btrim(v_mgr.contracted_club) <> '' THEN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = (upper(btrim(v_mgr.contracted_club)) = upper(btrim(v_buyer))),
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
    RAISE EXCEPTION 'Buyer % already has a manager — cannot settle draft listing %', v_buyer, p_listing_id;
  END IF;

  SELECT balance
  INTO v_buyer_balance
  FROM public."Club_Finances"
  WHERE club_name = v_buyer
  FOR UPDATE;

  IF v_buyer_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for % (listing %)', v_buyer, p_listing_id;
  END IF;

  v_mgr_name := coalesce(nullif(btrim(v_mgr.name), ''), 'Manager #' || v_listing.manager_id::text);

  v_meta := jsonb_build_object(
    'manager_draft', true,
    'listing_id', v_listing.id,
    'manager_id', v_listing.manager_id,
    'kind', 'manager'
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'contract_signing_offer'
      AND l.metadata->>'listing_id' = v_listing.id::text
      AND coalesce(l.metadata->>'manager_draft', '') IN ('true', 't', '1')
  ) THEN
    IF v_buyer_balance < v_amount THEN
      RAISE EXCEPTION 'Insufficient balance for % (need %, have %)', v_buyer, v_amount, v_buyer_balance;
    END IF;

    PERFORM public.post_club_ledger(
      v_buyer,
      'contract_signing_offer',
      -abs(v_amount),
      format('Manager draft signing — %s', v_mgr_name),
      v_meta,
      NULL,
      NULL,
      true,
      true
    );
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
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

  IF to_regprocedure(
    'public.manager_stint_open(bigint, text, numeric, text, bigint, timestamp with time zone)'
  ) IS NOT NULL THEN
    PERFORM public.manager_stint_open(
      v_listing.manager_id,
      v_buyer,
      v_amount,
      'draft',
      v_season_id,
      now()
    );
  END IF;
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
        RAISE WARNING 'Manager draft listing % failed: % (SQLSTATE %)',
          v_mgr_listing.id, SQLERRM, SQLSTATE;
    END;
  END LOOP;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_probe_manager_draft_settlement(p_limit int DEFAULT 5)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing record;
  v_limit int := greatest(coalesce(p_limit, 5), 1);
  v_results jsonb := '[]'::jsonb;
  v_closed boolean;
BEGIN
  FOR v_listing IN
    SELECT
      l.id,
      l.manager_id,
      m.name AS manager_name,
      l.current_highest_bidder,
      l.current_highest_bid,
      cf.balance AS buyer_balance
    FROM public."Manager_Transfer_Listings" l
    LEFT JOIN public."Managers" m ON m.id = l.manager_id
    LEFT JOIN public."Club_Finances" cf ON cf.club_name = l.current_highest_bidder
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
      AND l.current_highest_bidder IS NOT NULL
    ORDER BY l.id
    LIMIT v_limit
  LOOP
    BEGIN
      PERFORM public.transferengine_accept_manager_draft_sale(v_listing.id);

      SELECT EXISTS (
        SELECT 1
        FROM public."Manager_Transfer_Listings" l
        WHERE l.id = v_listing.id
          AND l.status = 'Closed'
          AND l.transfer_completed = true
      ) INTO v_closed;

      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'listing_id', v_listing.id,
        'manager_id', v_listing.manager_id,
        'manager_name', v_listing.manager_name,
        'buyer', v_listing.current_highest_bidder,
        'fee', v_listing.current_highest_bid,
        'buyer_balance_before', v_listing.buyer_balance,
        'ok', v_closed,
        'status_after', (
          SELECT l.status FROM public."Manager_Transfer_Listings" l WHERE l.id = v_listing.id
        ),
        'transfer_completed_after', (
          SELECT l.transfer_completed FROM public."Manager_Transfer_Listings" l WHERE l.id = v_listing.id
        ),
        'manager_contracted_club', (
          SELECT m.contracted_club FROM public."Managers" m WHERE m.id = v_listing.manager_id
        )
      ));
    EXCEPTION
      WHEN OTHERS THEN
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'listing_id', v_listing.id,
          'manager_id', v_listing.manager_id,
          'manager_name', v_listing.manager_name,
          'buyer', v_listing.current_highest_bidder,
          'fee', v_listing.current_highest_bid,
          'buyer_balance_before', v_listing.buyer_balance,
          'ok', false,
          'error', SQLERRM,
          'sqlstate', SQLSTATE
        ));
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'results', v_results
  );
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
  v_listing record;
  v_errors jsonb := '[]'::jsonb;
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

  FOR v_listing IN
    SELECT l.id
    FROM public."Manager_Transfer_Listings" l
    WHERE l.listing_type = 'draft' AND l.status = 'Active'
    ORDER BY l.id
  LOOP
    BEGIN
      PERFORM public.transferengine_accept_manager_draft_sale(v_listing.id);
    EXCEPTION
      WHEN OTHERS THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'listing_id', v_listing.id,
          'error', SQLERRM,
          'sqlstate', SQLSTATE
        ));
    END;
  END LOOP;

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
    'errors', v_errors,
    'still_active', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'listing_id', l.id,
        'manager_id', l.manager_id,
        'manager_name', m.name,
        'high_bid', l.current_highest_bid,
        'high_bidder', l.current_highest_bidder,
        'buyer_balance', cf.balance,
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
      LEFT JOIN public."Club_Finances" cf ON cf.club_name = l.current_highest_bidder
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_accept_manager_draft_sale(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_probe_manager_draft_settlement(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_probe_manager_draft_settlement(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_settle_manager_drafts_now() TO authenticated;

NOTIFY pgrst, 'reload schema';
