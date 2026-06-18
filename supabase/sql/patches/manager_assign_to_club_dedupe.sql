-- Drop duplicate manager_assign_to_club overloads (causes "function is not unique").
-- Keep ONE version: (bigint, text, smallint, numeric, boolean, jsonb).
-- Re-run after manager_signing_central_bank.sql if assign RPC fails again.

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
    'seasons', greatest(coalesce(p_seasons, 2), 1),
    'weekly_wage', v_wage
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_testing_assign_manager(
  p_manager_id bigint,
  p_club_short text,
  p_seasons smallint DEFAULT 2,
  p_release_club_manager boolean DEFAULT true,
  p_release_manager_contract boolean DEFAULT false,
  p_waive_fee boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := trim(p_club_short);
  v_mgr public."Managers"%rowtype;
  v_club_mgr_id bigint;
  v_result jsonb;
  v_seasons smallint := greatest(coalesce(p_seasons, 2), 1::smallint);
  v_fee numeric;
  v_buyer_pays boolean := NOT coalesce(p_waive_fee, true);
  v_meta jsonb := '{}'::jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club) THEN
    RAISE EXCEPTION 'Club not found: %', v_club;
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  IF v_mgr.contracted_club = v_club THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_assigned', true,
      'manager_id', p_manager_id,
      'manager_name', v_mgr.name,
      'club', v_club
    );
  END IF;

  SELECT m.id INTO v_club_mgr_id
  FROM public."Managers" m
  WHERE m.contracted_club = v_club
  LIMIT 1;

  IF v_club_mgr_id IS NOT NULL AND v_club_mgr_id <> p_manager_id THEN
    IF NOT coalesce(p_release_club_manager, false) THEN
      RAISE EXCEPTION 'Club % already has manager % — enable release current club manager', v_club, v_club_mgr_id;
    END IF;
    PERFORM public.manager_release_from_club(v_club_mgr_id, NULL, 0, 'admin_testing');
  END IF;

  IF v_mgr.contracted_club IS NOT NULL
     AND btrim(v_mgr.contracted_club) <> ''
     AND v_mgr.contracted_club <> v_club THEN
    IF NOT coalesce(p_release_manager_contract, false) THEN
      RAISE EXCEPTION 'Manager is contracted to % — enable release from current club', v_mgr.contracted_club;
    END IF;
    PERFORM public.manager_release_from_club(p_manager_id, NULL, 0, 'admin_testing');
  END IF;

  IF coalesce(p_waive_fee, true) THEN
    v_fee := 0;
  ELSE
    v_fee := NULL;
  END IF;

  v_result := public.manager_assign_to_club(
    p_manager_id,
    v_club,
    v_seasons,
    v_fee,
    v_buyer_pays,
    v_meta
  );

  RETURN v_result || jsonb_build_object(
    'manager_name', v_mgr.name,
    'club', v_club
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_testing_assign_manager(
  bigint, text, smallint, boolean, boolean, boolean
) TO authenticated;

NOTIFY pgrst, 'reload schema';
