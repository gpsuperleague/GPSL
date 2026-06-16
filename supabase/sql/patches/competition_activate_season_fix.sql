-- Fix Start season (go live): started_at column + preseason status + calendar check.
-- Run in Supabase SQL Editor if competition_activate_season returns 400.

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS league_phase text;

CREATE OR REPLACE FUNCTION public.competition_assert_setup_season(p_season_id bigint)
RETURNS public.competition_seasons
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE id = p_season_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Season not found';
  END IF;

  IF v_season.status NOT IN ('setup', 'preseason') THEN
    RAISE EXCEPTION 'Season is not in setup status';
  END IF;

  RETURN v_season;
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

  UPDATE public.global_settings
  SET league_phase = NULL, updated_at = now()
  WHERE id = 1;
END;
$function$;
