-- Cup proposal and reply penalties match the league.
-- No proposal at the round-month lock is a strike, then each later lock.
-- An away proposal stops further no-proposal strikes. Away may open once
-- the round month has locked. A missed reply is a strike. No ₿2.5m cup
-- no-proposal fine and no ₿1m late-arrangement fee.
-- Safe re-run.

DO $fines$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.competition_enforce_scheduling_arrangement_fines(bigint,text)'::regprocedure
  ), E'\r\n', E'\n');

  IF position('cup proposal strikes' IN v_def) > 0 THEN
    RAISE NOTICE 'arrangement fines already strike cups';
    RETURN;
  END IF;

  v_old := replace($old$       AND lower(coalesce(v_f.competition_type, 'league')) <> 'cup'
       AND NOT (
$old$, E'\r\n', E'\n');
  v_new := replace($new$       AND NOT (
$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'arrangement fines: cup strike exclusion not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := replace($old$      ELSIF v_deadline IS NOT NULL
        AND v_first_at >= v_deadline - interval '48 hours'
        AND v_first_at < v_deadline
      THEN
        v_tariff_code := 'match_late_arrangement';
$old$, E'\r\n', E'\n');
  v_new := replace($new$      ELSIF v_deadline IS NOT NULL
        AND lower(coalesce(v_f.competition_type, 'league')) <> 'cup' -- cup proposal strikes
        AND v_first_at >= v_deadline - interval '48 hours'
        AND v_first_at < v_deadline
      THEN
        v_tariff_code := 'match_late_arrangement';
$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'arrangement fines: late-fee branch not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
END;
$fines$;

CREATE OR REPLACE FUNCTION public.match_schedule_away_may_open_proposal(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_play int;
  v_lock timestamptz;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled' THEN
    RETURN false;
  END IF;
  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RETURN false;
  END IF;
  IF to_regprocedure('public.competition_fixture_involves_vacant_club(bigint)') IS NOT NULL
     AND public.competition_fixture_involves_vacant_club(p_fixture_id) THEN
    RETURN false;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.competition_fixture_schedule_proposal p
    WHERE p.fixture_id = p_fixture_id
      AND p.proposed_by_club_short_name = v_f.home_club_short_name
      AND p.status <> 'withdrawn'
  ) THEN
    RETURN false;
  END IF;

  v_play := public.competition_gpsl_month_sort(v_f.gpsl_month);

  IF lower(coalesce(v_f.competition_type, 'league')) = 'cup' THEN
    SELECT c.lock_at INTO v_lock
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_f.season_id
      AND public.competition_gpsl_month_sort(c.gpsl_month) = v_play
    ORDER BY c.lock_at
    LIMIT 1;
    RETURN v_lock IS NOT NULL AND v_lock <= now();
  END IF;

  SELECT c.lock_at INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_f.season_id
    AND public.competition_gpsl_month_sort(c.gpsl_month) = v_play - 1
  ORDER BY c.lock_at
  LIMIT 1;

  RETURN v_lock IS NOT NULL AND v_lock <= now();
END;
$function$;

DO $reply$
DECLARE
  v_def text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.match_schedule_reply_strike_tick()'::regprocedure
  ), E'\r\n', E'\n');
  IF position('cup reply strikes' IN v_def) = 0 THEN
    IF position('f.competition_type = ''league''' IN v_def) = 0 THEN
      RAISE EXCEPTION 'reply tick: league filter not found';
    END IF;
    v_def := replace(
      v_def,
      'f.competition_type = ''league''',
      'f.competition_type IN (''league'', ''cup'') -- cup reply strikes'
    );
    EXECUTE v_def;
  END IF;

  v_def := replace(pg_get_functiondef(
    'public.competition_enforce_scheduling_response_fines(bigint,text)'::regprocedure
  ), E'\r\n', E'\n');
  IF position('cup reply strikes' IN v_def) = 0 THEN
    IF position('fx.competition_type = ''league''' IN v_def) = 0 THEN
      RAISE EXCEPTION 'response fines: league filter not found';
    END IF;
    v_def := replace(
      v_def,
      'fx.competition_type = ''league''',
      'fx.competition_type IN (''league'', ''cup'') -- cup reply strikes'
    );
    EXECUTE v_def;
  END IF;
END;
$reply$;

SELECT jsonb_build_object(
  'cup_strike', position('<> ''cup''' IN replace(pg_get_functiondef(
    'public.competition_enforce_scheduling_arrangement_fines(bigint,text)'::regprocedure
  ), E'\r\n', E'\n')) > 0
    AND position('cup proposal strikes' IN replace(pg_get_functiondef(
      'public.competition_enforce_scheduling_arrangement_fines(bigint,text)'::regprocedure
    ), E'\r\n', E'\n')) > 0,
  'away_after_round', position('= v_play' IN replace(pg_get_functiondef(
    'public.match_schedule_away_may_open_proposal(bigint)'::regprocedure
  ), E'\r\n', E'\n')) > 0,
  'reply_tick', position('cup reply strikes' IN replace(pg_get_functiondef(
    'public.match_schedule_reply_strike_tick()'::regprocedure
  ), E'\r\n', E'\n')) > 0,
  'reply_lock', position('cup reply strikes' IN replace(pg_get_functiondef(
    'public.competition_enforce_scheduling_response_fines(bigint,text)'::regprocedure
  ), E'\r\n', E'\n')) > 0
);
