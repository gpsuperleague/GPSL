-- Manager signing fees → Staff (contract_signing_offer). Free-agent fees also credit
-- GPSL Central Bank — see manager_signing_central_bank.sql.

CREATE OR REPLACE FUNCTION public.manager_assign_to_club(
  p_manager_id bigint,
  p_club_short text,
  p_seasons smallint DEFAULT 2,
  p_fee numeric DEFAULT NULL,
  p_buyer_pays boolean DEFAULT true
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

    PERFORM public.post_club_ledger(
      p_club_short,
      'contract_signing_offer',
      -abs(v_fee),
      format('Manager signing — %s', v_mgr.name),
      jsonb_build_object('manager_id', p_manager_id, 'kind', 'manager'),
      v_season_id,
      NULL,
      false,
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

CREATE OR REPLACE FUNCTION public.manager_settle_listing(p_listing_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Manager_Transfer_Listings"%rowtype;
  v_seller text;
  v_buyer text;
  v_fee numeric;
  v_mgr_id bigint;
  v_season_id bigint;
BEGIN
  SELECT * INTO v_listing
  FROM public."Manager_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND OR v_listing.status <> 'Active' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_active');
  END IF;

  v_buyer := v_listing.current_highest_bidder;
  v_fee := v_listing.current_highest_bid;
  v_seller := v_listing.seller_club_id;
  v_mgr_id := v_listing.manager_id;

  IF v_buyer IS NULL OR v_fee IS NULL THEN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed', transfer_completed = false, updated_at = now()
    WHERE id = p_listing_id;
    RETURN jsonb_build_object('ok', true, 'sold', false);
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  LIMIT 1;

  PERFORM public.manager_release_from_club(v_mgr_id, NULL, NULL, 'transfer_sale');

  IF v_fee > 0 THEN
    PERFORM public.post_club_ledger(
      v_buyer,
      'contract_signing_offer',
      -abs(v_fee),
      format('Manager purchase — listing %s', p_listing_id),
      jsonb_build_object('manager_id', v_mgr_id, 'seller', v_seller, 'kind', 'manager'),
      v_season_id,
      NULL,
      false,
      true
    );

    IF v_seller IS NOT NULL THEN
      PERFORM public.post_club_ledger(
        v_seller,
        'transfer_sale',
        abs(v_fee),
        format('Manager sale — listing %s', p_listing_id),
        jsonb_build_object('manager_id', v_mgr_id, 'buyer', v_buyer, 'kind', 'manager'),
        v_season_id,
        NULL,
        false,
        true
      );
    END IF;
  END IF;

  PERFORM public.manager_assign_to_club(v_mgr_id, v_buyer, 2, 0, false);

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Closed', transfer_completed = true, updated_at = now()
  WHERE id = p_listing_id;

  RETURN jsonb_build_object('ok', true, 'sold', true, 'buyer', v_buyer, 'fee', v_fee);
END;
$function$;

-- Reclassify any manager signing lines already posted as transfer_purchase.
UPDATE public.competition_finance_ledger l
SET entry_type = 'contract_signing_offer'
WHERE l.entry_type = 'transfer_purchase'
  AND (
    coalesce(l.metadata->>'kind', '') = 'manager'
    OR coalesce(l.metadata->>'manager_draft', '') = 'true'
    OR l.description ILIKE 'Manager %'
  );

NOTIFY pgrst, 'reload schema';
