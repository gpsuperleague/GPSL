-- =============================================================================
-- Owner weekly match availability — carry forward across seasons
--
-- Weekly slots live in club_owner_availability_slot keyed by season_id.
-- Start season never copied them, so Club Details looked empty after Season 2.
--
-- This patch:
--   1) Copies prior-season weekly slots onto the newly activated season
--      (per club, only when that club has no slots yet for the new season)
--   2) Hooks into competition_activate_season
--   3) Catch-up copy for the already-live season
--
-- Does NOT copy one-off "unavailable" windows or holidays (date/season-specific).
-- owner_timezone on Clubs already persists. Prelaunch wipe deletes seasons
-- (CASCADE) — that full reset is intentional and out of scope here.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_owner_availability_copy_season(
  p_from_season_id bigint,
  p_to_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_inserted int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_from_season_id IS NULL OR p_to_season_id IS NULL THEN
    RAISE EXCEPTION 'from/to season ids required';
  END IF;

  IF p_from_season_id = p_to_season_id THEN
    RETURN jsonb_build_object('ok', true, 'slots_copied', 0, 'skipped', 'same_season');
  END IF;

  IF to_regclass('public.club_owner_availability_slot') IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'slots_copied', 0, 'skipped', 'no_table');
  END IF;

  INSERT INTO public.club_owner_availability_slot (
    season_id, club_short_name, owner_id, iso_dow, slot_minute
  )
  SELECT
    p_to_season_id,
    s.club_short_name,
    coalesce(c.owner_id, s.owner_id),
    s.iso_dow,
    s.slot_minute
  FROM public.club_owner_availability_slot s
  JOIN public."Clubs" c ON c."ShortName" = s.club_short_name
  WHERE s.season_id = p_from_season_id
    AND c."ShortName" <> 'FOREIGN'
    AND coalesce(c.owner_id, s.owner_id) IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.club_owner_availability_slot d
      WHERE d.season_id = p_to_season_id
        AND d.club_short_name = s.club_short_name
    )
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'from_season_id', p_from_season_id,
    'to_season_id', p_to_season_id,
    'slots_copied', v_inserted
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_owner_availability_carry_forward(
  p_to_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_from bigint;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_to_season_id IS NULL THEN
    RAISE EXCEPTION 'to season id required';
  END IF;

  SELECT s.season_id
  INTO v_from
  FROM public.club_owner_availability_slot s
  WHERE s.season_id < p_to_season_id
  GROUP BY s.season_id
  ORDER BY s.season_id DESC
  LIMIT 1;

  IF v_from IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'to_season_id', p_to_season_id,
      'slots_copied', 0,
      'skipped', 'no_prior_slots'
    );
  END IF;

  RETURN public.club_owner_availability_copy_season(v_from, p_to_season_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_activate_season(p_season_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sl bigint;
  v_a bigint;
  v_b bigint;
  v_bad bigint;
  v_has_calendar boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM public.competition_assert_setup_season(p_season_id);

  SELECT count(*) INTO v_sl
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id AND division = 'superleague';

  SELECT count(*) INTO v_a
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id AND division = 'championship_a';

  SELECT count(*) INTO v_b
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id AND division = 'championship_b';

  SELECT count(*) INTO v_bad
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id
    AND division NOT IN ('superleague', 'championship_a', 'championship_b');

  IF v_sl <> 20 OR v_a <> 20 OR v_b <> 20 OR v_bad > 0 THEN
    RAISE EXCEPTION 'Need 20 SL + 20 CH A + 20 CH B (bad rows: %)', v_bad;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config WHERE season_id = p_season_id
  ) INTO v_has_calendar;

  IF NOT v_has_calendar THEN
    RAISE EXCEPTION 'Set the real-world season calendar (first Friday 19:00 UK) before starting the season';
  END IF;

  UPDATE public.competition_seasons
  SET is_current = false
  WHERE is_current = true;

  UPDATE public.competition_seasons
  SET status = 'active',
      is_current = true,
      started_at = coalesce(started_at, now())
  WHERE id = p_season_id;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'competition_seasons'
      AND column_name = 'activated_at'
  ) THEN
    EXECUTE
      'UPDATE public.competition_seasons
       SET activated_at = coalesce(activated_at, now())
       WHERE id = $1'
    USING p_season_id;
  END IF;

  UPDATE public.global_settings
  SET league_phase = NULL, updated_at = now()
  WHERE id = 1;

  IF to_regprocedure('public.competition_stadium_snapshot_season_start(bigint)') IS NOT NULL THEN
    PERFORM public.competition_stadium_snapshot_season_start(p_season_id);
  END IF;

  IF to_regprocedure('public.competition_club_prestige_lock_season(bigint)') IS NOT NULL THEN
    PERFORM public.competition_club_prestige_lock_season(p_season_id);
  END IF;

  IF to_regprocedure('public.competition_reset_club_season_quotas()') IS NOT NULL THEN
    PERFORM public.competition_reset_club_season_quotas();
  END IF;

  -- Weekly match availability carries forward (not wiped on season change)
  PERFORM public.club_owner_availability_carry_forward(p_season_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_owner_availability_copy_season(bigint, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_owner_availability_carry_forward(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_activate_season(bigint) TO authenticated;

-- Catch-up for the already-live season
DO $$
DECLARE
  v_sid bigint;
  v_result jsonb;
BEGIN
  SELECT s.id INTO v_sid
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_sid IS NOT NULL THEN
    v_result := public.club_owner_availability_carry_forward(v_sid);
    RAISE NOTICE 'owner availability carry-forward: %', v_result;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
