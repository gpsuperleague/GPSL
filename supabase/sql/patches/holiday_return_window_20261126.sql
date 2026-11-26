-- A holiday that overlaps the ordinary play window and ends after that lock
-- keeps the fixture open through the GPSL month the club returns into.
-- At that later lock, a still-unscheduled match whose home club never
-- proposed, with level strikes, is forfeited by home. That check sits ahead
-- of "on holiday for the scheduled month", so the waiting club is not the loser.
-- A vacant club is not extended: the vacant walkover still applies.
-- Shield 9960 is Slovan Bratislava (SLB, owned) vs Dortmund, not vacant Benfica (BEN).
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_holiday_return_through_sort(
  p_fixture_id bigint
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_play integer;
  v_grace integer;
  v_end integer;
  v_max integer;
  v_lock timestamptz;
  v_return timestamptz;
  v_sort integer;
BEGIN
  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled' THEN
    RETURN NULL;
  END IF;

  IF lower(coalesce(v_f.competition_type, 'league')) NOT IN ('league', 'cup') THEN
    RETURN NULL;
  END IF;

  IF public.competition_club_is_vacant(v_f.home_club_short_name)
     OR public.competition_club_is_vacant(v_f.away_club_short_name) THEN
    RETURN NULL;
  END IF;

  v_play := public.competition_gpsl_month_sort(v_f.gpsl_month);
  v_grace := public.match_schedule_play_grace_months(v_f.competition_type, v_f.gpsl_month);
  IF v_play IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT max(public.competition_gpsl_month_sort(cal.gpsl_month))
  INTO v_max
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_f.season_id;

  v_end := least(v_play + coalesce(v_grace, 0), coalesce(v_max, v_play));

  SELECT cal.lock_at
  INTO v_lock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_f.season_id
    AND public.competition_gpsl_month_sort(cal.gpsl_month) = v_end
  ORDER BY cal.sort_order DESC
  LIMIT 1;

  IF v_lock IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT max(h.ends_at)
  INTO v_return
  FROM public.club_owner_holidays h
  WHERE h.season_id = v_f.season_id
    AND h.club_short_name IN (v_f.home_club_short_name, v_f.away_club_short_name)
    AND public.club_holiday_is_effective(h.id)
    AND h.ends_at > v_lock
    AND EXISTS (
      SELECT 1
      FROM public.competition_season_calendar cal
      WHERE cal.season_id = v_f.season_id
        AND public.competition_gpsl_month_sort(cal.gpsl_month) BETWEEN v_play AND v_end
        AND h.starts_at < cal.lock_at
        AND h.ends_at > cal.unlock_at
    );

  IF v_return IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT public.competition_gpsl_month_sort(cal.gpsl_month)
  INTO v_sort
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_f.season_id
    AND cal.unlock_at <= v_return
    AND cal.lock_at > v_return
  ORDER BY cal.sort_order DESC
  LIMIT 1;

  IF v_sort IS NULL OR v_sort <= v_end THEN
    RETURN NULL;
  END IF;

  RETURN least(v_sort, coalesce(v_max, v_sort));
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_fixture_holiday_return_through_sort(bigint)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_holiday_return_through_sort(bigint)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.match_schedule_fixture_holiday_return_through_sort(bigint) IS
  'GPSL month sort a fixture stays open through when a holiday overlapping the ordinary window ends after that lock. Null when no extension, or when either club is vacant.';

DO $window$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_schedule_fixture_within_play_window(bigint,timestamptz)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('holiday_return_through_sort' IN v_def) = 0 THEN
    v_old := replace($old$
  IF lower(coalesce(v_f.competition_type, 'league')) <> 'cup' THEN
    v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
    IF v_owner_through IS NOT NULL AND v_active_sort <= v_owner_through THEN
      RETURN true;
    END IF;
  END IF;

  RETURN false;$old$, E'\r\n', E'\n');
    v_new := replace($new$
  IF lower(coalesce(v_f.competition_type, 'league')) <> 'cup' THEN
    v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
    IF v_owner_through IS NOT NULL AND v_active_sort <= v_owner_through THEN
      RETURN true;
    END IF;
  END IF;

  IF public.match_schedule_fixture_holiday_return_through_sort(p_fixture_id) IS NOT NULL
     AND v_active_sort <= public.match_schedule_fixture_holiday_return_through_sort(p_fixture_id) THEN
    RETURN true;
  END IF;

  RETURN false;$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'within_play_window: owner block not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  v_def := replace(
    pg_get_functiondef('public.match_schedule_fixture_play_window_expired(bigint,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('holiday_return_through_sort' IN v_def) = 0 THEN
    v_old := replace($old$
  IF lower(coalesce(v_f.competition_type, 'league')) <> 'cup' THEN
    v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
    IF v_owner_through IS NOT NULL AND v_closed_sort <= v_owner_through THEN
      RETURN false;
    END IF;
  END IF;

  RETURN true;$old$, E'\r\n', E'\n');
    v_new := replace($new$
  IF lower(coalesce(v_f.competition_type, 'league')) <> 'cup' THEN
    v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
    IF v_owner_through IS NOT NULL AND v_closed_sort <= v_owner_through THEN
      RETURN false;
    END IF;
  END IF;

  IF public.match_schedule_fixture_holiday_return_through_sort(p_fixture_id) IS NOT NULL
     AND v_closed_sort <= public.match_schedule_fixture_holiday_return_through_sort(p_fixture_id) THEN
    RETURN false;
  END IF;

  RETURN true;$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'play_window_expired: owner block not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$window$;

DO $loser$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_schedule_pick_window_loser(bigint,bigint,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('home never proposed' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := replace($old$  v_home_h := public.match_schedule_club_on_holiday_for_month($old$, E'\r\n', E'\n');
  v_new := replace($new$  -- home never proposed: home loses when the match is still unscheduled and strikes are level
  IF coalesce((
        SELECT s.status
        FROM public.competition_fixture_schedule s
        WHERE s.fixture_id = v_f.id
      ), 'unscheduled') = 'unscheduled'
     AND NOT EXISTS (
        SELECT 1
        FROM public.competition_fixture_schedule_proposal p
        WHERE p.fixture_id = v_f.id
          AND p.proposed_by_club_short_name = v_f.home_club_short_name
          AND p.status <> 'withdrawn'
      )
     AND public.match_schedule_fixture_strike_count(v_f.id, v_f.home_club_short_name)
         IS NOT DISTINCT FROM public.match_schedule_fixture_strike_count(v_f.id, v_f.away_club_short_name)
  THEN
    RETURN v_f.home_club_short_name;
  END IF;

  v_home_h := public.match_schedule_club_on_holiday_for_month($new$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'window loser: holiday check not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$loser$;

-- Guard: Dortmund vs Wolves only, if a window-expiry forfeit already named Wolves.
UPDATE public.competition_fixtures
SET
  status = 'scheduled',
  home_goals = NULL,
  away_goals = NULL,
  is_forfeit = false,
  forfeit_loser_club = NULL
WHERE id = 9061
  AND upper(home_club_short_name) = 'DOR'
  AND upper(away_club_short_name) = 'WOL'
  AND status = 'played'
  AND coalesce(is_forfeit, false)
  AND upper(forfeit_loser_club) = 'WOL'
  AND home_goals = 3
  AND away_goals = 0;
