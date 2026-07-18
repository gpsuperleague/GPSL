-- =============================================================================
-- Reset per-season club quotas on Start season (activate)
--
-- Bug: voluntary_contract_release.sql hooked club_reset_voluntary_contract_releases()
-- into competition_activate_season, but later activate patches (calendar / stadium /
-- prestige) replaced that function and dropped the reset.
--
-- Foreign interest often still looked "fresh" (unused slots / reseeded tracking);
-- voluntary release counts did not reset.
--
-- This patch:
--   1) Restores voluntary reset (3/club)
--   2) Resets foreign interest (3/club) + re-picks tracking teams
--   3) Hooks both into competition_activate_season for every future Start season
--   4) Runs a catch-up reset once for the already-live season
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_reset_voluntary_contract_releases()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public."Clubs" c
  SET voluntary_contract_releases_remaining = 3
  WHERE c."ShortName" <> 'FOREIGN';
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_reset_foreign_interest_season()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  r record;
BEGIN
  UPDATE public."Clubs" c
  SET foreign_interest_remaining = 3
  WHERE c."ShortName" <> 'FOREIGN';

  UPDATE public."Clubs" c
  SET foreign_interest_remaining = 0
  WHERE c."ShortName" = 'FOREIGN';

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Clubs'
      AND column_name = 'foreign_tracking_teams'
  ) THEN
    UPDATE public."Clubs" c
    SET foreign_tracking_teams = '{}'::text[]
    WHERE c."ShortName" <> 'FOREIGN';

    IF to_regprocedure('public.sync_club_foreign_tracking(text)') IS NOT NULL THEN
      FOR r IN
        SELECT c."ShortName"
        FROM public."Clubs" c
        WHERE c."ShortName" <> 'FOREIGN'
          AND coalesce(c.foreign_interest_remaining, 0) > 0
      LOOP
        PERFORM public.sync_club_foreign_tracking(r."ShortName");
      END LOOP;
    END IF;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_reset_club_season_quotas()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_voluntary int;
  v_foreign int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM public.club_reset_voluntary_contract_releases();
  PERFORM public.club_reset_foreign_interest_season();

  SELECT count(*)::int
  INTO v_voluntary
  FROM public."Clubs" c
  WHERE c."ShortName" <> 'FOREIGN'
    AND coalesce(c.voluntary_contract_releases_remaining, 0) = 3;

  SELECT count(*)::int
  INTO v_foreign
  FROM public."Clubs" c
  WHERE c."ShortName" <> 'FOREIGN'
    AND coalesce(c.foreign_interest_remaining, 0) = 3;

  RETURN jsonb_build_object(
    'ok', true,
    'clubs_voluntary_at_3', v_voluntary,
    'clubs_foreign_interest_at_3', v_foreign
  );
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

  -- Per-season club quotas (voluntary releases + foreign interest)
  PERFORM public.competition_reset_club_season_quotas();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_activate_season(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_reset_club_season_quotas() TO authenticated;

-- Catch-up for the already-live season (Season 2). Safe to re-run.
SELECT public.competition_reset_club_season_quotas();

NOTIFY pgrst, 'reload schema';
