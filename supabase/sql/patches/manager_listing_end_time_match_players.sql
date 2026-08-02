-- =============================================================================
-- Manager Transfer Market listings: same end-time rule as player market
--   ≥ 24 hours from list time, completing at the next 19:00 Europe/London
--
-- Replaces previous manager_list_for_transfer end_time logic
-- (GPSL month lock / now+7 days).
--
-- Safe re-run. Requires manager_list_sack_window_open() (manager window patches).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.compute_standard_listing_end_time(p_start timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $function$
DECLARE
  v_min_end   timestamptz;
  v_uk_local  timestamp;
  v_uk_date   date;
  v_uk_time   time;
  v_next19    timestamptz;
  v_add_day   int;
BEGIN
  IF p_start IS NULL THEN
    RETURN NULL;
  END IF;

  v_min_end := p_start + interval '24 hours';
  v_uk_local := v_min_end AT TIME ZONE 'Europe/London';
  v_uk_date := v_uk_local::date;
  v_uk_time := v_uk_local::time;

  IF EXTRACT(HOUR FROM v_uk_time) > 19
     OR (
       EXTRACT(HOUR FROM v_uk_time) = 19
       AND (
         EXTRACT(MINUTE FROM v_uk_time) > 0
         OR EXTRACT(SECOND FROM v_uk_time) > 0
       )
     )
  THEN
    v_add_day := 1;
  ELSE
    v_add_day := 0;
  END IF;

  v_next19 :=
    ((v_uk_date + v_add_day)::timestamp + time '19:00:00')
    AT TIME ZONE 'Europe/London';

  IF v_min_end > v_next19 THEN
    RETURN v_min_end;
  END IF;
  RETURN v_next19;
END;
$function$;

COMMENT ON FUNCTION public.compute_standard_listing_end_time(timestamptz) IS
  'Standard transfer list end: at least 24h from start, then next 19:00 Europe/London (player + manager market).';

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
      'Manager listing is only available in June, July, August, or the January transfer window';
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

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, v_now), ''));

  -- Same rule as Player_Transfer_Listings standard market
  v_end := public.compute_standard_listing_end_time(v_now);

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

GRANT EXECUTE ON FUNCTION public.compute_standard_listing_end_time(timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_list_for_transfer(bigint) TO authenticated;

-- Align any currently Active club-listed managers to the same rule
-- (do not shorten listings that already end later — e.g. month-lock leftovers).
UPDATE public."Manager_Transfer_Listings" l
SET
  end_time = GREATEST(
    l.end_time,
    public.compute_standard_listing_end_time(coalesce(l.created_at, now()))
  ),
  metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object(
    'end_rule', 'standard_24h_7pm_uk',
    'end_time_recalculated_at', now()
  )
WHERE l.status = 'Active'
  AND coalesce(l.listing_type, 'standard') = 'standard'
  AND l.end_time IS NOT NULL
  AND l.end_time > now()
  AND l.end_time IS DISTINCT FROM
    public.compute_standard_listing_end_time(coalesce(l.created_at, now()));

NOTIFY pgrst, 'reload schema';
