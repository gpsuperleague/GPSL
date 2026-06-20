-- =============================================================================
-- Draft settlement — fix accept_draft_sale leaving 1063 Active / draft_settled_count 0
--
-- Causes addressed:
--   • Winner on listing columns but no matching is_direct bid row
--   • Early RETURN leaves listing Active (finance missing, already contracted)
--   • 1000+ listings in one tick (timeout / no visible progress)
--
-- Run AFTER draft_settlement_resilience.sql
-- Then: SELECT transferengine_run_report();
-- =============================================================================

DROP FUNCTION IF EXISTS public.transferengine_settle_player_draft_listings();
DROP FUNCTION IF EXISTS public.transferengine_settle_player_draft_listings(int);

CREATE OR REPLACE FUNCTION public.transferengine_normalize_club_short_name(p_club text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_in text := nullif(btrim(p_club), '');
  v_out text;
BEGIN
  IF v_in IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT c."ShortName"
  INTO v_out
  FROM public."Clubs" c
  WHERE c."ShortName" = v_in
     OR c."Club" = v_in
  LIMIT 1;

  RETURN coalesce(v_out, v_in);
END;
$function$;

CREATE OR REPLACE FUNCTION public.transferengine_accept_draft_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_amount  numeric;
  v_buyer   text;
  v_player  public."Players"%rowtype;
  v_history_id bigint;
  v_draft_start timestamptz;
BEGIN
  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_listing.listing_type IS DISTINCT FROM 'draft' THEN
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RETURN;
  END IF;

  SELECT draft_auction_start_time INTO v_draft_start
  FROM public.global_settings WHERE id = 1;

  -- Listing leader (this auction) first — not all-time max bid on player_id
  v_buyer := public.transferengine_normalize_club_short_name(
    v_listing.current_highest_bidder::text
  );
  v_amount := v_listing.current_highest_bid;

  IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
    SELECT b.bid_amount, b.bidder_club_id
    INTO v_amount, v_buyer
    FROM public."Player_Transfer_Bids" b
    WHERE b.is_direct = true
      AND b.listing_id = v_listing.id
      AND (v_draft_start IS NULL OR b.bid_time >= v_draft_start)
    ORDER BY b.bid_amount DESC, b.bid_time ASC
    LIMIT 1;

    v_buyer := public.transferengine_normalize_club_short_name(v_buyer);
  END IF;

  IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false,
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_buyer,
      updated_at = now()
  WHERE id = v_listing.id;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = btrim(v_listing.player_id::text)
  FOR UPDATE;

  IF NOT FOUND THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false,
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF v_player."Contracted_Team" IS NOT NULL
     AND btrim(v_player."Contracted_Team"::text) <> '' THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = (btrim(v_player."Contracted_Team"::text) = v_buyer),
        winning_bid = CASE WHEN btrim(v_player."Contracted_Team"::text) = v_buyer THEN v_amount ELSE winning_bid END,
        winning_club = CASE WHEN btrim(v_player."Contracted_Team"::text) = v_buyer THEN v_buyer ELSE winning_club END,
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_buyer
  ) THEN
    RAISE EXCEPTION 'Club_Finances missing for buyer % (listing %)', v_buyer, p_listing_id;
  END IF;

  PERFORM public.assert_player_available_for_signing(btrim(v_listing.player_id::text));

  PERFORM public.player_assign_to_club(btrim(v_listing.player_id::text), v_buyer);

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id
  )
  VALUES (
    btrim(v_listing.player_id::text),
    NULL,
    v_buyer,
    v_amount,
    0,
    now(),
    v_listing.id
  )
  RETURNING id INTO v_history_id;

  PERFORM public.post_transfer_ledger_for_history(v_history_id);

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_amount,
      winning_club = v_buyer,
      updated_at = now()
  WHERE id = v_listing.id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_settle_player_draft_listings(
  p_batch_limit int DEFAULT 100
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_settled int := 0;
  v_limit int := greatest(coalesce(p_batch_limit, 100), 1);
BEGIN
  FOR v_listing IN
    SELECT *
    FROM public."Player_Transfer_Listings"
    WHERE listing_type = 'draft'
      AND status = 'Active'
    ORDER BY id
    LIMIT v_limit
  LOOP
    BEGIN
      PERFORM public.transferengine_accept_draft_sale(v_listing.id);
      IF EXISTS (
        SELECT 1
        FROM public."Player_Transfer_Listings" l
        WHERE l.id = v_listing.id
          AND l.status = 'Closed'
          AND l.transfer_completed = true
      ) THEN
        v_settled := v_settled + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'transferengine_accept_draft_sale listing % failed: %',
        v_listing.id, SQLERRM;
    END;
  END LOOP;

  RETURN v_settled;
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
  v_now timestamptz := now();
  v_mgr_active int;
  v_club_active int;
  v_player_draft_active int;
  v_should_settle_players boolean;
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
    AND (
      COALESCE(v_settings.draft_auction_enabled, false)
      OR v_now >= v_settings.draft_random_finish_time
    )
    AND NOT public.transferengine_standard_listings_block_draft_settlement(
      v_now,
      v_settings.draft_random_finish_time
    );

  IF v_should_settle_players THEN
    PERFORM public.transferengine_settle_player_draft_listings(100);
  END IF;

  PERFORM public.transferengine_settle_manager_draft_auctions_only();

  IF to_regprocedure('public.transferengine_settle_club_auctions_only()') IS NOT NULL THEN
    PERFORM public.transferengine_settle_club_auctions_only();
  END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_diagnose_draft_backlog()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_finish timestamptz;
BEGIN
  SELECT draft_random_finish_time INTO v_finish
  FROM public.global_settings WHERE id = 1;

  RETURN jsonb_build_object(
    'active_draft_listings', (
      SELECT count(*)::int FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
    ),
    'with_listing_leader', (
      SELECT count(*)::int FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
    ),
    'no_direct_bid_row', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public."Player_Transfer_Bids" b
          WHERE b.is_direct = true
            AND (
              b.listing_id = l.id
              OR btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = btrim(l.player_id::text)
            )
        )
    ),
    'player_already_signed_elsewhere', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND p."Contracted_Team" IS NOT NULL AND btrim(p."Contracted_Team"::text) <> ''
        AND btrim(p."Contracted_Team"::text) IS DISTINCT FROM btrim(l.current_highest_bidder::text)
    ),
    'buyer_missing_club_finances', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public."Club_Finances" f
          WHERE f.club_name = btrim(l.current_highest_bidder::text)
        )
    ),
    'ready_to_settle', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
        AND (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team"::text) = '')
        AND EXISTS (
          SELECT 1 FROM public."Club_Finances" f
          WHERE f.club_name = btrim(l.current_highest_bidder::text)
        )
    ),
    'draft_random_finish_time', v_finish
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_diagnose_draft_backlog() TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_diagnose_draft_backlog() TO service_role;

NOTIFY pgrst, 'reload schema';
