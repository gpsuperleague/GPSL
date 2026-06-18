-- Manager free-agent signings → club ledger + GPSL Central Bank (Model A).
-- Fixes: admin assign / manager_assign_to_club with bank_leg=false, and draft settlement
-- paths that debited Club_Finances without competition_finance_ledger or bank_ledger.
-- Drops all manager_assign_to_club overloads first (5-arg + 6-arg both match 5-arg calls).

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

-- Draft auction win: ledger + bank via manager_assign_to_club (no raw balance tweak).
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

  v_meta := jsonb_build_object(
    'manager_draft', true,
    'listing_id', v_listing.id,
    'kind', 'manager'
  );

  IF EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'contract_signing_offer'
      AND l.metadata->>'listing_id' = v_listing.id::text
      AND coalesce(l.metadata->>'manager_draft', '') = 'true'
  ) THEN
    RAISE NOTICE 'Manager draft listing % already ledgered', p_listing_id;
    RETURN;
  END IF;

  PERFORM public.manager_assign_to_club(
    v_listing.manager_id,
    v_buyer,
    2,
    v_amount,
    true,
    v_meta
  );

  RAISE NOTICE 'Manager draft listing % settled — manager % to % for %',
    p_listing_id, v_listing.manager_id, v_buyer, v_amount;
END;
$function$;

-- Mirror missing central-bank legs for past manager free-agent signings.
DO $$
DECLARE
  v_row record;
BEGIN
  FOR v_row IN
    SELECT l.*
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'contract_signing_offer'
      AND coalesce(l.metadata->>'kind', '') = 'manager'
      AND coalesce(l.metadata->>'seller', '') = ''
      AND NOT EXISTS (
        SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = l.id
      )
    ORDER BY l.id
  LOOP
    UPDATE public.gpsl_bank_account
    SET reserves = reserves - v_row.amount,
        updated_at = now()
    WHERE id = 1;

    INSERT INTO public.bank_ledger (
      entry_type,
      amount,
      description,
      club_short_name,
      club_ledger_id,
      metadata
    )
    VALUES (
      v_row.entry_type,
      -v_row.amount,
      coalesce(nullif(btrim(v_row.description), ''), v_row.entry_type),
      v_row.club_short_name,
      v_row.id,
      coalesce(v_row.metadata, '{}'::jsonb)
    );
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
