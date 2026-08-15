-- =============================================================================
-- Manager list: same mid-spell tenure as sack
--
-- Cannot list a manager immediately after signing — first chance mid first spell:
--   summer signing → January; January signing → next June–July/January
-- Calendar window still required (June/July/January / pre-season).
-- Archived managers still cannot be listed.
--
-- Depends on: manager_sack_tenure_eligible() (manager_sack_tenure_ui_fix_20260815.sql
-- or manager_list_sack_no_august.sql / manager_window_fa_market.sql).
-- Safe re-run.
-- =============================================================================

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
  v_now timestamptz := now();
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

  IF coalesce(v_mgr.archived, false) THEN
    RAISE EXCEPTION
      'This manager is no longer in the game catalog — they cannot be listed. You may only sack them; when the contract ends you receive full market value.';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, v_now), ''));

  IF NOT public.manager_sack_tenure_eligible(
    v_mgr.signed_season_id, v_mgr.signed_gpsl_month, v_season_id, v_month
  ) THEN
    RAISE EXCEPTION
      'Cannot list yet — managers must reach mid-season in their first spell (summer signings: January; January signings: next June–July)';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Manager_Transfer_Listings"
    WHERE manager_id = p_manager_id AND status = 'Active'
  ) THEN
    RAISE EXCEPTION 'Manager already listed';
  END IF;

  IF to_regprocedure('public.compute_standard_listing_end_time(timestamptz)') IS NOT NULL THEN
    v_end := public.compute_standard_listing_end_time(v_now);
  ELSE
    v_end := coalesce(
      public.manager_gpsl_month_lock_at(v_season_id, v_month),
      v_now + interval '7 days'
    );
  END IF;

  INSERT INTO public."Manager_Transfer_Listings" (
    manager_id, seller_club_id, listing_type, status, end_time, market_value, metadata
  )
  VALUES (
    p_manager_id, v_club, 'standard', 'Active', v_end, v_mgr.market_value,
    jsonb_build_object(
      'gpsl_month', v_month,
      'season_id', v_season_id,
      'end_rule', 'standard_24h_7pm_uk'
    )
  )
  RETURNING id INTO v_listing_id;

  RETURN jsonb_build_object(
    'ok', true,
    'listing_id', v_listing_id,
    'end_time', v_end
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_list_for_transfer(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
