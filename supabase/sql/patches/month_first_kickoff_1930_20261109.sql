-- =============================================================================
-- First kick-off in a GPSL month is 19:30 UK
--
-- Months still open at 19:00 UK. The first bookable slot was that same instant,
-- so check-in opened at 18:50, before the month. 19:30 UK is the first slot
-- (19:20 check-in, after the 19:00 open). Later the same evening is unchanged.
-- Owners see that instant in their own timezone.
--
-- Also: Ajax vs Arsenal, November, 12 Nov. Clear check-in (and the result if
-- they already played) and set the kick-off to 19:30 UK the same evening.
--
-- Run once in the Supabase SQL editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_month_first_kickoff(p_unlock timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_1930 timestamptz;
BEGIN
  IF p_unlock IS NULL THEN
    RETURN NULL;
  END IF;

  v_1930 := (
    date_trunc('day', p_unlock AT TIME ZONE 'Europe/London') + time '19:30'
  ) AT TIME ZONE 'Europe/London';

  IF v_1930 >= p_unlock THEN
    RETURN v_1930;
  END IF;

  RETURN p_unlock;
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_month_first_kickoff(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_schedule_month_first_kickoff(timestamptz)
  TO authenticated, service_role;

-- Push every proposal window's start up to that 19:30, without moving the lock.
CREATE OR REPLACE FUNCTION public.match_schedule_proposal_kickoff_window(
  p_fixture_id bigint
)
RETURNS TABLE (
  unlock_at timestamptz,
  lock_at timestamptz,
  gpsl_month text,
  is_catch_up boolean,
  is_holiday_early boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_active text;
  v_row record;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF to_regprocedure('public.match_schedule_holiday_corridor_window(bigint)') IS NOT NULL THEN
    SELECT c.unlock_at, c.lock_at, c.gpsl_month, c.is_catch_up, c.is_holiday_early
    INTO v_row
    FROM public.match_schedule_holiday_corridor_window(p_fixture_id) c
    LIMIT 1;

    IF FOUND AND v_row.unlock_at IS NOT NULL THEN
      unlock_at := public.match_schedule_month_first_kickoff(v_row.unlock_at);
      lock_at := v_row.lock_at;
      gpsl_month := v_row.gpsl_month;
      is_catch_up := coalesce(v_row.is_catch_up, false);
      is_holiday_early := coalesce(v_row.is_holiday_early, false);
      RETURN NEXT;
      RETURN;
    END IF;
  END IF;

  IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());
    IF v_active IS NULL THEN
      RETURN;
    END IF;

    RETURN QUERY
    SELECT
      public.match_schedule_month_first_kickoff(cal.unlock_at),
      cal.lock_at,
      cal.gpsl_month,
      true,
      false
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_fixture.season_id
      AND lower(btrim(cal.gpsl_month)) = lower(btrim(v_active));
    RETURN;
  END IF;

  IF to_regprocedure('public.match_schedule_fixture_is_holiday_early(bigint)') IS NOT NULL
     AND public.match_schedule_fixture_is_holiday_early(p_fixture_id)
  THEN
    v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());
    IF v_active IS NULL THEN
      RETURN;
    END IF;

    RETURN QUERY
    SELECT
      public.match_schedule_month_first_kickoff(cal.unlock_at),
      cal.lock_at,
      cal.gpsl_month,
      false,
      true
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_fixture.season_id
      AND lower(btrim(cal.gpsl_month)) = lower(btrim(v_active));
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    public.match_schedule_month_first_kickoff(w.unlock_at),
    w.lock_at,
    w.gpsl_month,
    false,
    false
  FROM public.match_schedule_fixture_month_window(p_fixture_id) w;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_proposal_kickoff_window(bigint)
  TO authenticated, service_role;

-- Ajax vs Arsenal, November: clear the early check-in and move KO to 19:30 UK.
DO $ajax$
DECLARE
  v_fid bigint;
  v_n int;
  v_ko timestamptz;
  v_new timestamptz;
  v_status text;
  v_home text;
  v_away text;
  v_month text;
  v_season bigint;
  v_type text;
  v_played boolean;
  v_checkins int := 0;
  v_stats int := 0;
  v_subs int := 0;
BEGIN
  SELECT f.id
  INTO v_fid
  FROM public.competition_fixtures f
  JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
  WHERE lower(btrim(f.gpsl_month)) = 'november'
    AND (
      (upper(f.home_club_short_name) = 'AJX' AND upper(f.away_club_short_name) = 'ARS')
      OR (upper(f.home_club_short_name) = 'ARS' AND upper(f.away_club_short_name) = 'AJX')
    )
    AND sch.agreed_kickoff_at IS NOT NULL
    AND (sch.agreed_kickoff_at AT TIME ZONE 'Europe/London')::date = DATE '2026-11-12'
  ORDER BY f.id
  LIMIT 1;

  IF v_fid IS NULL THEN
    SELECT count(*)::int
    INTO v_n
    FROM public.competition_fixtures f
    WHERE lower(btrim(f.gpsl_month)) = 'november'
      AND (
        (upper(f.home_club_short_name) = 'AJX' AND upper(f.away_club_short_name) = 'ARS')
        OR (upper(f.home_club_short_name) = 'ARS' AND upper(f.away_club_short_name) = 'AJX')
      );

    IF v_n = 1 THEN
      SELECT f.id
      INTO v_fid
      FROM public.competition_fixtures f
      WHERE lower(btrim(f.gpsl_month)) = 'november'
        AND (
          (upper(f.home_club_short_name) = 'AJX' AND upper(f.away_club_short_name) = 'ARS')
          OR (upper(f.home_club_short_name) = 'ARS' AND upper(f.away_club_short_name) = 'AJX')
        );
    ELSE
      RAISE EXCEPTION
        'Could not find one November AJX vs ARS fixture for 12 Nov 2026 (found % November meetings)',
        v_n;
    END IF;
  END IF;

  SELECT
    f.status,
    f.home_club_short_name,
    f.away_club_short_name,
    f.gpsl_month,
    f.season_id,
    f.competition_type,
    sch.agreed_kickoff_at
  INTO v_status, v_home, v_away, v_month, v_season, v_type, v_ko
  FROM public.competition_fixtures f
  JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
  WHERE f.id = v_fid;

  v_new := (
    date_trunc('day', coalesce(v_ko, timestamptz '2026-11-12 19:00:00+00') AT TIME ZONE 'Europe/London')
    + time '19:30'
  ) AT TIME ZONE 'Europe/London';

  v_played := v_status IN ('played', 'completed')
    OR EXISTS (
      SELECT 1 FROM public.competition_fixtures f
      WHERE f.id = v_fid AND f.home_goals IS NOT NULL
    );

  DELETE FROM public.competition_fixture_checkin WHERE fixture_id = v_fid;
  GET DIAGNOSTICS v_checkins = ROW_COUNT;

  IF to_regclass('public.competition_fixture_play_now_session') IS NOT NULL THEN
    DELETE FROM public.competition_fixture_play_now_session WHERE fixture_id = v_fid;
  END IF;

  IF v_played THEN
    IF to_regprocedure('public.competition_cup_retract_advancement_for_fixture(bigint)') IS NOT NULL THEN
      PERFORM public.competition_cup_retract_advancement_for_fixture(v_fid);
    END IF;

    IF to_regclass('public.competition_match_player_stats') IS NOT NULL THEN
      DELETE FROM public.competition_match_player_stats WHERE fixture_id = v_fid;
      GET DIAGNOSTICS v_stats = ROW_COUNT;
    END IF;

    IF to_regclass('public.competition_result_submissions') IS NOT NULL THEN
      DELETE FROM public.competition_result_submissions WHERE fixture_id = v_fid;
      GET DIAGNOSTICS v_subs = ROW_COUNT;
    END IF;

    IF to_regclass('public.competition_fixture_match_fitness_tick') IS NOT NULL THEN
      DELETE FROM public.competition_fixture_match_fitness_tick WHERE fixture_id = v_fid;
    END IF;

    UPDATE public.competition_fixtures
    SET
      status = 'scheduled',
      home_goals = NULL,
      away_goals = NULL,
      is_forfeit = false,
      is_void = false
    WHERE id = v_fid;

    BEGIN
      UPDATE public.competition_fixtures
      SET
        result_auto_closed = false,
        home_stats_edit_used_at = NULL,
        away_stats_edit_used_at = NULL
      WHERE id = v_fid;
    EXCEPTION WHEN undefined_column THEN
      NULL;
    END;

    BEGIN
      UPDATE public.competition_fixtures
      SET cup_pen_winner_club_short_name = NULL
      WHERE id = v_fid;
    EXCEPTION WHEN undefined_column THEN
      NULL;
    END;

    IF to_regprocedure('public.admin_match_fitness_rebuild_streaks(bigint, text)') IS NOT NULL THEN
      PERFORM public.admin_match_fitness_rebuild_streaks(v_season, v_home);
      PERFORM public.admin_match_fitness_rebuild_streaks(v_season, v_away);
    END IF;
  END IF;

  UPDATE public.competition_fixture_schedule
  SET
    status = 'agreed',
    agreed_kickoff_at = v_new,
    updated_at = now()
  WHERE fixture_id = v_fid;

  RAISE NOTICE
    'Fixture % % vs % (%) kick-off % → % UK. Check-ins removed: %. Result cleared: % (stats %, submissions %).',
    v_fid, v_home, v_away, v_month,
    to_char(v_ko AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    to_char(v_new AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    v_checkins, v_played, v_stats, v_subs;
END;
$ajax$;

NOTIFY pgrst, 'reload schema';

SELECT
  f.id,
  f.status,
  f.home_club_short_name,
  f.away_club_short_name,
  f.gpsl_month,
  f.home_goals,
  f.away_goals,
  sch.status AS schedule_status,
  to_char(sch.agreed_kickoff_at AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI') AS kickoff_uk,
  (SELECT count(*) FROM public.competition_fixture_checkin c WHERE c.fixture_id = f.id) AS checkins
FROM public.competition_fixtures f
JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
WHERE lower(btrim(f.gpsl_month)) = 'november'
  AND (
    (upper(f.home_club_short_name) = 'AJX' AND upper(f.away_club_short_name) = 'ARS')
    OR (upper(f.home_club_short_name) = 'ARS' AND upper(f.away_club_short_name) = 'AJX')
  );
