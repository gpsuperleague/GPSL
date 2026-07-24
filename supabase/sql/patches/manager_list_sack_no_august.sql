-- =============================================================================
-- Manager list/sack window: June, July, January only (not August)
--
-- Fixtures have started by August — owners may still use the FA board month,
-- but cannot list or sack their signed manager in August.
--
-- Safe re-run. Updates window + error messages + tenure month set.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.manager_list_sack_window_open()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_status text;
  v_month text;
  v_tw boolean;
BEGIN
  SELECT s.id, s.status
  INTO v_season_id, v_status
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN false;
  END IF;

  -- Pre-season / create-season window (before August fixtures)
  IF lower(coalesce(v_status, '')) = 'preseason' THEN
    RETURN true;
  END IF;

  SELECT transfer_window_open INTO v_tw
  FROM public.global_settings WHERE id = 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));

  IF v_month = '' AND coalesce(v_tw, false) THEN
    RETURN true;
  END IF;

  -- Summer list/sack: June & July only (not August — fixtures underway)
  IF v_month IN ('june', 'july') THEN
    RETURN true;
  END IF;

  -- January requires transfer window flag
  IF v_month = 'january' AND coalesce(v_tw, false) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_sack_window_open()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.manager_list_sack_window_open();
$$;

CREATE OR REPLACE FUNCTION public.manager_sack_tenure_eligible(
  p_signed_season_id bigint,
  p_signed_gpsl_month text,
  p_current_season_id bigint DEFAULT NULL,
  p_current_month text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_current_season_id;
  v_month text := lower(btrim(coalesce(p_current_month, '')));
  v_cohort text := public.manager_signed_cohort(p_signed_gpsl_month);
BEGIN
  IF p_signed_season_id IS NULL THEN
    RETURN true; -- legacy spells with no stamp
  END IF;

  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_month = '' THEN
    v_month := lower(coalesce(public.competition_active_gpsl_month(v_season, now()), ''));
  END IF;

  IF v_cohort = 'summer' THEN
    -- Signed June/July/August → first chance January same season, then any later season
    RETURN (v_season > p_signed_season_id)
        OR (v_season = p_signed_season_id AND v_month = 'january');
  END IF;

  -- Signed January → first chance next season's June/July/January (not August)
  RETURN v_season > p_signed_season_id
    AND (
      v_month IN ('june', 'july', 'january')
      OR v_season > p_signed_season_id + 1
    );
END;
$function$;

-- Refresh exception copy on list / sack (function bodies otherwise unchanged)
CREATE OR REPLACE FUNCTION public.manager_list_for_transfer(p_manager_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_mgr public."Managers"%rowtype;
  v_end timestamptz;
  v_listing_id bigint;
  v_season_id bigint;
  v_month text;
  v_lock timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.manager_list_sack_window_open() THEN
    RAISE EXCEPTION
      'Manager listing is only available in June, July, or the January transfer window';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND OR v_mgr.contracted_club IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Manager not at your club';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Manager_Transfer_Listings"
    WHERE manager_id = p_manager_id AND status = 'Active'
  ) THEN
    RAISE EXCEPTION 'Manager already listed';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));
  v_lock := public.manager_gpsl_month_lock_at(v_season_id, v_month);
  v_end := coalesce(v_lock, now() + interval '7 days');

  INSERT INTO public."Manager_Transfer_Listings" (
    manager_id, seller_club_id, listing_type, status, end_time, market_value, metadata
  )
  VALUES (
    p_manager_id, v_club, 'standard', 'Active', v_end, v_mgr.market_value,
    jsonb_build_object('gpsl_month', v_month, 'season_id', v_season_id)
  )
  RETURNING id INTO v_listing_id;

  RETURN jsonb_build_object('ok', true, 'listing_id', v_listing_id, 'end_time', v_end);
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_sack()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_mgr public."Managers"%rowtype;
  v_payout numeric;
  v_sacks smallint;
  v_season_id bigint;
  v_result jsonb;
  v_month text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.manager_list_sack_window_open() THEN
    RAISE EXCEPTION
      'Manager sack is only available in June, July, or the January transfer window';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT manager_sacks_remaining INTO v_sacks
  FROM public."Clubs"
  WHERE "ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_sacks, 0) < 1 THEN
    RAISE EXCEPTION 'Manager sack already used this season';
  END IF;

  SELECT * INTO v_mgr
  FROM public."Managers"
  WHERE contracted_club = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No manager signed at your club';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));

  IF NOT public.manager_sack_tenure_eligible(
    v_mgr.signed_season_id, v_mgr.signed_gpsl_month, v_season_id, v_month
  ) THEN
    RAISE EXCEPTION
      'Cannot sack yet — managers must reach mid-season in their first spell (summer signings: January; January signings: next June–July)';
  END IF;

  v_payout := round(greatest(v_mgr.market_value, 0)::numeric / 2.0, 0);

  UPDATE public."Clubs"
  SET manager_sacks_remaining = 0
  WHERE "ShortName" = v_club;

  v_result := public.manager_release_from_club(
    v_mgr.id,
    v_club,
    v_payout,
    'contract_release_comp',
    format('Manager sack — %s (half MV)', v_mgr.name),
    jsonb_build_object(
      'manager_sack', true,
      'gpsl_month', nullif(v_month, '')
    )
  );

  IF to_regprocedure('public.manager_club_sack_block_record(text, bigint, bigint)') IS NOT NULL THEN
    PERFORM public.manager_club_sack_block_record(v_club, v_mgr.id, v_season_id);
  END IF;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_list_sack_window_open() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_sack_window_open() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_sack_tenure_eligible(bigint, text, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_list_for_transfer(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_sack() TO authenticated;

NOTIFY pgrst, 'reload schema';
