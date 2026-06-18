-- =============================================================================
-- Manager draft — auto-settle after random finish (one deploy fixes current + future)
-- Run once when settlement fails or listings stay Active after auction ends.
--
-- Fixes:
--   1. manager_assign_to_club missing (settlement calls 6-arg version)
--   2. integer vs smallint on seasons literal (2::smallint)
--   3. settlement skipped when manager_draft_auction_enabled turned off in Admin
--   4. transferengine_settle_draft_auctions early-exit before manager residue
--
-- Auto-run: GitHub Actions (every minute) → Edge Function transferengine_run
--           → transferengine_run_report() → transferengine_run()
--           → transferengine_settle_draft_auctions()
--           → transferengine_settle_manager_draft_auctions_only()
--           (after draft_random_finish_time)
--
-- Requires: post_club_ledger (central_bank_model_a_flows or manager_signing patch)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Canonical manager_assign_to_club (6 args, smallint seasons)
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'manager_assign_to_club'
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.manager_assign_to_club(
  p_manager_id bigint,
  p_club_short text,
  p_seasons smallint DEFAULT 2,
  p_fee numeric DEFAULT NULL,
  p_buyer_pays boolean DEFAULT true,
  p_ledger_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mgr public."Managers"%rowtype;
  v_existing bigint;
  v_balance numeric;
  v_fee numeric;
  v_season_id bigint;
  v_wage bigint;
  v_meta jsonb;
BEGIN
  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  IF v_mgr.contracted_club IS NOT NULL AND btrim(v_mgr.contracted_club) <> '' THEN
    RAISE EXCEPTION 'Manager already contracted to %', v_mgr.contracted_club;
  END IF;

  SELECT m.id INTO v_existing
  FROM public."Managers" m
  WHERE m.contracted_club = p_club_short
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RAISE EXCEPTION 'Club already has a manager signed';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = p_club_short AND c.manager_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Club already has a manager signed';
  END IF;

  v_fee := coalesce(p_fee, v_mgr.market_value::numeric);

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF p_buyer_pays AND v_fee > 0 THEN
    SELECT balance INTO v_balance
    FROM public."Club_Finances"
    WHERE club_name = p_club_short
    FOR UPDATE;

    IF v_balance IS NULL THEN
      RAISE EXCEPTION 'Club finances not found for %', p_club_short;
    END IF;
    IF v_balance < v_fee THEN
      RAISE EXCEPTION 'Insufficient balance (need %, have %)', v_fee, v_balance;
    END IF;

    v_meta := coalesce(p_ledger_metadata, '{}'::jsonb)
      || jsonb_build_object('manager_id', p_manager_id, 'kind', 'manager');

    PERFORM public.post_club_ledger(
      p_club_short,
      'contract_signing_offer',
      -abs(v_fee),
      format('Manager signing — %s', v_mgr.name),
      v_meta,
      v_season_id,
      NULL,
      true,
      true
    );
  END IF;

  v_wage := public.manager_weekly_wage_for(v_mgr.market_value);

  UPDATE public."Managers"
  SET contracted_club = p_club_short,
      contract_seasons_remaining = greatest(coalesce(p_seasons, 2), 1),
      weekly_wage = v_wage,
      signed_season_id = v_season_id,
      updated_at = now()
  WHERE id = p_manager_id;

  PERFORM public.manager_sync_club_rating(p_club_short);

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      updated_at = now()
  WHERE manager_id = p_manager_id
    AND listing_type = 'draft'
    AND status = 'Active';

  IF to_regprocedure('public.owner_inbox_notify_season_expectations(text)') IS NOT NULL THEN
    PERFORM public.owner_inbox_notify_season_expectations(p_club_short);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'manager_id', p_manager_id,
    'club', p_club_short,
    'fee', v_fee,
    'seasons', p_seasons,
    'weekly_wage', v_wage
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_assign_to_club(
  bigint, text, smallint, numeric, boolean, jsonb
) TO authenticated;

-- ---------------------------------------------------------------------------
-- Draft win → manager_assign_to_club (explicit smallint cast)
-- ---------------------------------------------------------------------------

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

  IF v_buyer IS NULL OR v_amount IS NULL THEN
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
    RETURN;
  END IF;

  IF v_mgr.contracted_club IS NOT NULL AND btrim(v_mgr.contracted_club) <> '' THEN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed', transfer_completed = false, updated_at = now()
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
    RETURN;
  END IF;

  v_meta := jsonb_build_object(
    'manager_draft', true,
    'listing_id', v_listing.id,
    'kind', 'manager'
  );

  IF EXISTS (
    SELECT 1 FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'contract_signing_offer'
      AND l.metadata->>'listing_id' = v_listing.id::text
      AND coalesce(l.metadata->>'manager_draft', '') = 'true'
  ) THEN
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

GRANT EXECUTE ON FUNCTION public.transferengine_accept_manager_draft_sale(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Settle all Active manager draft listings after secret finish (ignore enabled flag)
-- ---------------------------------------------------------------------------

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
  FROM public.global_settings WHERE id = 1;

  IF v_finish IS NULL OR v_now < v_finish THEN
    RETURN;
  END IF;

  FOR v_mgr_listing IN
    SELECT * FROM public."Manager_Transfer_Listings"
    WHERE listing_type = 'draft' AND status = 'Active'
  LOOP
    BEGIN
      PERFORM public.transferengine_accept_manager_draft_sale(v_mgr_listing.id);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Manager draft listing % failed: %', v_mgr_listing.id, SQLERRM;
    END;
  END LOOP;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Draft settlement orchestrator — still run for leftover manager/club listings
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.transferengine_settle_draft_auctions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_now timestamptz := now();
  v_mgr_active int;
  v_club_active int;
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

  IF NOT COALESCE(v_settings.draft_auction_enabled, false)
     AND NOT COALESCE(v_settings.manager_draft_auction_enabled, false)
     AND NOT COALESCE(v_settings.club_auction_enabled, false) THEN
    IF NOT (
      v_settings.draft_random_finish_time IS NOT NULL
      AND v_now >= v_settings.draft_random_finish_time
      AND (v_mgr_active > 0 OR v_club_active > 0)
    ) THEN
      RETURN;
    END IF;
  END IF;

  IF v_settings.draft_random_finish_time IS NULL OR v_now < v_settings.draft_random_finish_time THEN
    RETURN;
  END IF;

  PERFORM public.transferengine_process_standard_listings(v_now);

  IF COALESCE(v_settings.draft_auction_enabled, false)
     AND NOT public.transferengine_standard_listings_block_draft_settlement(
       v_now, v_settings.draft_random_finish_time
     ) THEN
    FOR v_listing IN
      SELECT * FROM public."Player_Transfer_Listings"
      WHERE listing_type = 'draft' AND status = 'Active'
    LOOP
      PERFORM public.transferengine_accept_draft_sale(v_listing.id);
    END LOOP;
  END IF;

  PERFORM public.transferengine_settle_manager_draft_auctions_only();

  IF to_regprocedure('public.transferengine_settle_club_auctions_only()') IS NOT NULL THEN
    PERFORM public.transferengine_settle_club_auctions_only();
  END IF;
END;
$function$;

NOTIFY pgrst, 'reload schema';
