-- Admin season lifecycle: preseason, summer break, end season, create uses preseason.
-- Run after competition_phase0.sql and competition_real_world_calendar.sql.

ALTER TABLE public.competition_seasons
  DROP CONSTRAINT IF EXISTS competition_seasons_status_check;

ALTER TABLE public.competition_seasons
  ADD CONSTRAINT competition_seasons_status_check
  CHECK (status IN ('setup', 'preseason', 'active', 'complete', 'summer_break'));

-- Treat legacy setup like preseason
UPDATE public.competition_seasons
SET status = 'preseason'
WHERE status = 'setup';

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
    RAISE EXCEPTION 'Season % is not in setup (status=%)', p_season_id, v_season.status;
  END IF;

  RETURN v_season;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_create_season(p_label text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_label text := trim(p_label);
  v_season_id bigint;
  v_club_count bigint;
  v_prev bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_label IS NULL OR v_label = '' THEN
    RAISE EXCEPTION 'Season label is required';
  END IF;

  INSERT INTO public.competition_seasons (label, status, is_current)
  VALUES (v_label, 'preseason', false)
  RETURNING id INTO v_season_id;

  INSERT INTO public.competition_club_seasons (season_id, club_short_name, division)
  SELECT v_season_id, c."ShortName", 'unassigned'
  FROM public."Clubs" c
  WHERE c."ShortName" <> 'FOREIGN'
  ORDER BY c."ShortName";

  GET DIAGNOSTICS v_club_count = ROW_COUNT;

  IF v_club_count <> 60 THEN
    RAISE EXCEPTION 'Expected 60 clubs, found %', v_club_count;
  END IF;

  SELECT s.id INTO v_prev
  FROM public.competition_seasons s
  WHERE s.id < v_season_id
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_prev IS NOT NULL THEN
    -- Carry GPDB exclusions forward when the previous season had any.
    IF to_regprocedure('public.admin_gpdb_copy_season_exclusions(bigint, bigint)') IS NOT NULL
       AND (
         EXISTS (
           SELECT 1 FROM public.gpdb_season_excluded_players ep WHERE ep.season_id = v_prev
         )
         OR EXISTS (
           SELECT 1 FROM public.gpdb_season_excluded_nations en WHERE en.season_id = v_prev
         )
       )
    THEN
      PERFORM public.admin_gpdb_copy_season_exclusions(v_prev, v_season_id);
    END IF;

    IF to_regprocedure('public.competition_admin_copy_cup_prizes(bigint, bigint)') IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM public.competition_cup_prize_config c WHERE c.season_id = v_prev
       )
    THEN
      PERFORM public.competition_admin_copy_cup_prizes(v_prev, v_season_id);
    END IF;

    IF to_regprocedure('public.competition_admin_copy_league_prizes(bigint, bigint)') IS NOT NULL
       AND to_regclass('public.competition_league_prize_config') IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM public.competition_league_prize_config c WHERE c.season_id = v_prev
       )
    THEN
      PERFORM public.competition_admin_copy_league_prizes(v_prev, v_season_id);
    END IF;

    -- Season N → N+1: decrement contracts even when prior year is already complete
    -- (Summer Break / no is_current). Inaugural season (no v_prev) skips this.
    IF to_regprocedure('public.contract_tick_season_rollover()') IS NOT NULL THEN
      PERFORM public.contract_tick_season_rollover();
    END IF;
  END IF;

  RETURN v_season_id;
END;
$function$;

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS league_phase text;

COMMENT ON COLUMN public.global_settings.league_phase IS
  'Optional league-wide phase label, e.g. summer_break when no active GPSL month.';

CREATE OR REPLACE FUNCTION public.competition_end_season()
RETURNS jsonb
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
  WHERE is_current = true
    AND status = 'active'
  LIMIT 1;

  IF NOT FOUND THEN
    SELECT * INTO v_season
    FROM public.competition_seasons
    WHERE status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active current season to end';
  END IF;

  UPDATE public.competition_seasons
  SET status = 'complete', is_current = false, ended_at = coalesce(ended_at, now())
  WHERE id = v_season.id;

  UPDATE public.global_settings
  SET league_phase = 'summer_break', updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'season_id', v_season.id,
    'label', v_season.label,
    'league_phase', 'summer_break'
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
  SET status = 'active', is_current = true, started_at = coalesce(started_at, now())
  WHERE id = p_season_id;

  UPDATE public.global_settings
  SET league_phase = NULL, updated_at = now()
  WHERE id = 1;

  IF to_regprocedure('public.competition_stadium_snapshot_season_start(bigint)') IS NOT NULL THEN
    PERFORM public.competition_stadium_snapshot_season_start(p_season_id);
  END IF;

  IF to_regprocedure('public.competition_club_prestige_lock_season(bigint)') IS NOT NULL THEN
    PERFORM public.competition_club_prestige_lock_season(p_season_id);
  END IF;

  -- Per-season club quotas (voluntary / foreign / manager sacks)
  IF to_regprocedure('public.competition_reset_club_season_quotas()') IS NOT NULL THEN
    PERFORM public.competition_reset_club_season_quotas();
  ELSE
    IF to_regprocedure('public.club_reset_voluntary_contract_releases()') IS NOT NULL THEN
      PERFORM public.club_reset_voluntary_contract_releases();
    END IF;
    IF to_regprocedure('public.manager_reset_season_quotas()') IS NOT NULL THEN
      PERFORM public.manager_reset_season_quotas();
    END IF;
  END IF;

  -- Weekly match availability carries forward across seasons
  IF to_regprocedure('public.club_owner_availability_carry_forward(bigint)') IS NOT NULL THEN
    PERFORM public.club_owner_availability_carry_forward(p_season_id);
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_end_season() TO authenticated;

DROP VIEW IF EXISTS public.global_settings_public;
CREATE VIEW public.global_settings_public
WITH (security_invoker = false)
AS
SELECT
  id,
  transfer_window_open,
  draft_auction_enabled,
  draft_auction_start_time,
  updated_at,
  league_phase,
  (
    COALESCE(draft_auction_enabled, false)
    AND draft_auction_start_time IS NOT NULL
    AND draft_random_finish_time IS NOT NULL
    AND now() >= draft_auction_start_time
    AND now() < draft_random_finish_time
  ) AS draft_bidding_open
FROM public.global_settings;

GRANT SELECT ON public.global_settings_public TO authenticated;
GRANT SELECT ON public.global_settings_public TO anon;

CREATE OR REPLACE VIEW public.competition_season_public
WITH (security_invoker = false)
AS
SELECT
  id,
  label,
  status,
  is_current,
  championship_drawn_at,
  started_at,
  ended_at,
  created_at
FROM public.competition_seasons
WHERE status IN ('setup', 'preseason', 'active')
ORDER BY is_current DESC, created_at DESC;

GRANT SELECT ON public.competition_season_public TO authenticated;
GRANT SELECT ON public.competition_season_public TO anon;

-- RLS: admins may see preseason seasons
DROP POLICY IF EXISTS competition_seasons_select ON public.competition_seasons;
CREATE POLICY competition_seasons_select ON public.competition_seasons
  FOR SELECT TO authenticated
  USING (status IN ('active', 'setup', 'preseason'));

DROP POLICY IF EXISTS competition_club_seasons_select ON public.competition_club_seasons;
CREATE POLICY competition_club_seasons_select ON public.competition_club_seasons
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.competition_seasons s
      WHERE s.id = season_id
        AND s.status IN ('active', 'setup', 'preseason')
    )
  );
