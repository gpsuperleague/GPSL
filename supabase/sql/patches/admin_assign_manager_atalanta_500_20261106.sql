-- =============================================================================
-- Admin "Assign manager" 500 when replacing a club's current manager
-- =============================================================================
-- The page calls admin_testing_assign_manager. That releases the club's
-- manager, signs the new one, then sends a season-expectations inbox message.
-- A 500 with no row change means that whole step was rolled back.
--
-- Two live overloads make the call ambiguous (Postgres 42725), which PostgREST
-- returns as 500:
--   manager_release_from_club(bigint, text, numeric, text)
--     and the 6-arg version (last two args have defaults)
--   owner_inbox_send without schedule_proposal_id
--     and the longer version
--
-- This drops the shorter copies, and a failed expectations message no longer
-- undoes the signing.
--
-- Admin assign does not check the buying club's balance. Releasing a manager
-- credits that club the manager's full market value (contract_release_comp).
-- Owner sack is unchanged and still pays half market value.
-- Run once in the SQL editor, then press Assign again.
-- Tick "Release current manager at selected club".
-- =============================================================================

DROP FUNCTION IF EXISTS public.manager_release_from_club(bigint, text, numeric, text);

CREATE OR REPLACE FUNCTION public.manager_club_short_canonical(p_club text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c."ShortName"
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = upper(btrim(coalesce(p_club, '')))
  LIMIT 1;
$$;

DO $$
DECLARE
  r record;
  v_keep int;
BEGIN
  SELECT count(*) INTO v_keep
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'owner_inbox_send'
    AND pg_get_function_identity_arguments(p.oid) LIKE '%schedule_proposal_id%';

  IF v_keep > 0 THEN
    FOR r IN
      SELECT pg_get_function_identity_arguments(p.oid) AS args
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname = 'owner_inbox_send'
        AND pg_get_function_identity_arguments(p.oid) NOT LIKE '%schedule_proposal_id%'
    LOOP
      EXECUTE format('DROP FUNCTION IF EXISTS public.owner_inbox_send(%s)', r.args);
    END LOOP;
  END IF;
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
  v_skip_balance boolean;
BEGIN
  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  IF v_mgr.contracted_club IS NOT NULL AND btrim(v_mgr.contracted_club) <> '' THEN
    RAISE EXCEPTION 'Manager already contracted to %', v_mgr.contracted_club;
  END IF;

  IF to_regprocedure('public.manager_assert_not_sack_blocked(text, bigint)') IS NOT NULL
    AND NOT coalesce((p_ledger_metadata->>'skip_sack_block')::boolean, false)
    AND NOT (
      auth.uid() IS NOT NULL
      AND public.is_gpsl_admin()
    ) THEN
    PERFORM public.manager_assert_not_sack_blocked(p_club_short, p_manager_id);
  END IF;

  SELECT m.id INTO v_existing
  FROM public."Managers" m
  WHERE upper(btrim(m.contracted_club)) = upper(btrim(p_club_short))
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

  v_skip_balance := coalesce((p_ledger_metadata->>'skip_balance_check')::boolean, false);

  IF p_buyer_pays AND v_fee > 0 THEN
    IF NOT v_skip_balance THEN
      SELECT balance INTO v_balance
      FROM public."Club_Finances"
      WHERE upper(btrim(club_name)) = upper(btrim(p_club_short))
      FOR UPDATE;

      IF v_balance IS NULL THEN
        RAISE EXCEPTION 'Club finances not found for %', p_club_short;
      END IF;
      IF v_balance < v_fee THEN
        RAISE EXCEPTION 'Insufficient balance (need %, have %)', v_fee, v_balance;
      END IF;
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
    BEGIN
      PERFORM public.owner_inbox_notify_season_expectations(p_club_short);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'season expectations inbox skipped for %: %', p_club_short, SQLERRM;
    END;
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

DROP FUNCTION IF EXISTS public.manager_assign_to_club(bigint, text, smallint, numeric, boolean);

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
  v_club text;
  v_mgr public."Managers"%rowtype;
  v_club_mgr_id bigint;
  v_released_name text;
  v_released_mv numeric;
  v_other_club text;
  v_result jsonb;
  v_seasons smallint := greatest(coalesce(p_seasons, 2), 1::smallint);
  v_fee numeric;
  v_buyer_pays boolean := NOT coalesce(p_waive_fee, true);
  v_meta jsonb := jsonb_build_object('skip_balance_check', true, 'admin_assign', true);
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_club := public.manager_club_short_canonical(p_club_short);
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club not found: %', p_club_short;
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  IF upper(btrim(coalesce(v_mgr.contracted_club, ''))) = upper(v_club) THEN
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
  WHERE upper(btrim(m.contracted_club)) = upper(v_club)
  LIMIT 1;

  IF v_club_mgr_id IS NOT NULL AND v_club_mgr_id <> p_manager_id THEN
    IF NOT coalesce(p_release_club_manager, false) THEN
      RAISE EXCEPTION 'Club % already has manager % — enable release current club manager', v_club, v_club_mgr_id;
    END IF;
    SELECT m.name, m.market_value
    INTO v_released_name, v_released_mv
    FROM public."Managers" m
    WHERE m.id = v_club_mgr_id;
    -- NULL amount: release credits the club the manager's full market value.
    PERFORM public.manager_release_from_club(
      v_club_mgr_id,
      v_club,
      NULL::numeric,
      'contract_release_comp'::text,
      format('Manager release — %s (market value)', coalesce(v_released_name, 'manager')),
      jsonb_build_object('admin_replace', true)
    );
  END IF;

  IF v_mgr.contracted_club IS NOT NULL
     AND btrim(v_mgr.contracted_club) <> ''
     AND upper(btrim(v_mgr.contracted_club)) <> upper(v_club) THEN
    IF NOT coalesce(p_release_manager_contract, false) THEN
      RAISE EXCEPTION 'Manager is contracted to % — enable release from current club', v_mgr.contracted_club;
    END IF;
    v_other_club := coalesce(
      public.manager_club_short_canonical(v_mgr.contracted_club),
      btrim(v_mgr.contracted_club)
    );
    PERFORM public.manager_release_from_club(
      p_manager_id,
      v_other_club,
      NULL::numeric,
      'contract_release_comp'::text,
      format('Manager release — %s (market value)', v_mgr.name),
      jsonb_build_object('admin_replace', true)
    );
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
    'club', v_club,
    'released_manager', v_released_name,
    'release_payout', CASE
      WHEN v_released_name IS NULL THEN NULL
      ELSE greatest(coalesce(v_released_mv, 0), 0)
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_assign_to_club(bigint, text, smallint, numeric, boolean, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_testing_assign_manager(bigint, text, smallint, boolean, boolean, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
