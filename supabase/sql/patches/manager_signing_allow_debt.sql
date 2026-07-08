-- =============================================================================
-- Manager signings — allow debt (FFP / debt rules apply elsewhere)
-- Run after manager_career_history.sql and manager_sack_rehire_block.sql
-- =============================================================================

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
  v_kind text := 'assign';
BEGIN
  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  IF v_mgr.contracted_club IS NOT NULL AND btrim(v_mgr.contracted_club) <> '' THEN
    RAISE EXCEPTION 'Manager already contracted to %', v_mgr.contracted_club;
  END IF;

  IF NOT coalesce((p_ledger_metadata->>'skip_sack_block')::boolean, false)
    AND NOT (
      auth.uid() IS NOT NULL
      AND public.is_gpsl_admin()
    ) THEN
    PERFORM public.manager_assert_not_sack_blocked(p_club_short, p_manager_id);
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

  IF coalesce((p_ledger_metadata->>'manager_draft')::boolean, false)
    OR coalesce(p_ledger_metadata->>'manager_draft', '') IN ('true', 't', '1') THEN
    v_kind := 'draft';
  ELSIF coalesce(p_ledger_metadata->>'source', '') = 'market' THEN
    v_kind := 'market';
  ELSIF coalesce(p_ledger_metadata->>'source', '') = 'admin' THEN
    v_kind := 'admin';
  END IF;

  IF to_regprocedure(
    'public.manager_stint_open(bigint, text, numeric, text, bigint, timestamp with time zone)'
  ) IS NOT NULL THEN
    PERFORM public.manager_stint_open(
      p_manager_id,
      p_club_short,
      v_fee,
      v_kind,
      v_season_id,
      now()
    );
  END IF;

  IF to_regprocedure('public.owner_inbox_notify_season_expectations(text)') IS NOT NULL THEN
    PERFORM public.owner_inbox_notify_season_expectations(p_club_short);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'manager_id', p_manager_id,
    'club', p_club_short,
    'fee', v_fee,
    'seasons', greatest(coalesce(p_seasons, 2), 1),
    'weekly_wage', v_wage
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.manager_place_bid(
  p_listing_id bigint,
  p_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_listing public."Manager_Transfer_Listings"%rowtype;
  v_mgr public."Managers"%rowtype;
  v_min numeric;
  v_high numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_listing
  FROM public."Manager_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND OR v_listing.status <> 'Active' THEN
    RAISE EXCEPTION 'Listing not active';
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = v_listing.manager_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  PERFORM public.manager_assert_not_sack_blocked(v_club, v_listing.manager_id);

  IF EXISTS (
    SELECT 1 FROM public."Managers" m WHERE m.contracted_club = v_club
  ) THEN
    RAISE EXCEPTION 'Your club already has a manager';
  END IF;

  v_high := coalesce(v_listing.current_highest_bid, 0);
  v_min := greatest(v_listing.market_value::numeric, v_high + 500000);

  IF p_amount < v_min THEN
    RAISE EXCEPTION 'Bid must be at least %', v_min;
  END IF;

  INSERT INTO public."Manager_Transfer_Bids" (
    listing_id, manager_id, bidder_club_id, bid_amount, is_direct
  )
  VALUES (p_listing_id, v_listing.manager_id, v_club, p_amount, true);

  UPDATE public."Manager_Transfer_Listings"
  SET current_highest_bid = p_amount,
      current_highest_bidder = v_club,
      updated_at = now()
  WHERE id = p_listing_id;

  RETURN jsonb_build_object('ok', true, 'bid', p_amount, 'listing_id', p_listing_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_assign_to_club(
  bigint, text, smallint, numeric, boolean, jsonb
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_place_bid(bigint, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
