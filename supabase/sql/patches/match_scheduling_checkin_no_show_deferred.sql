-- =============================================================================
-- Match scheduling — deferred check-in no-show fines
-- =============================================================================
-- Run after: match_scheduling_month_lock_fines_and_replay.sql
--
-- Rules:
--   • Both miss check-in → no record, no fine
--   • One checks in, one misses → record no-show (no instant 3–0 / fine)
--   • Match later played normally (result confirmed, not forfeit) → clear record, no fine
--   • Replay reset → clear record
--   • Play month lock, still unplayed with recorded no-show → 3–0 forfeit + fine
-- =============================================================================

ALTER TABLE public.competition_fixture_schedule
  ADD COLUMN IF NOT EXISTS no_show_club_short_name text
    REFERENCES public."Clubs" ("ShortName"),
  ADD COLUMN IF NOT EXISTS no_show_kickoff_at timestamptz;

CREATE OR REPLACE FUNCTION public.match_schedule_clear_no_show(p_fixture_id bigint)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.competition_fixture_schedule
  SET
    no_show_club_short_name = NULL,
    no_show_kickoff_at = NULL,
    updated_at = now()
  WHERE fixture_id = p_fixture_id;
$$;

CREATE OR REPLACE FUNCTION public.match_schedule_clear_no_show_if_played(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.id = p_fixture_id
      AND f.status = 'played'
      AND f.is_forfeit = false
  ) THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
  END IF;
END;
$function$;

-- Record one-sided no-show after check-in window; never instant forfeit
CREATE OR REPLACE FUNCTION public.fixture_try_checkin_forfeit(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_window_end timestamptz;
  v_home_in boolean;
  v_away_in boolean;
  v_loser text;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RETURN false;
  END IF;

  PERFORM public.match_schedule_clear_no_show_if_played(p_fixture_id);

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  v_window_end := v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;
  IF now() < v_window_end THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  IF NOT v_home_in AND NOT v_away_in THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  IF v_home_in AND NOT v_away_in THEN
    v_loser := v_fixture.away_club_short_name;
  ELSE
    v_loser := v_fixture.home_club_short_name;
  END IF;

  UPDATE public.competition_fixture_schedule
  SET
    no_show_club_short_name = v_loser,
    no_show_kickoff_at = v_kickoff,
    updated_at = now()
  WHERE fixture_id = p_fixture_id;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_reset_to_unscheduled(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public.competition_fixture_schedule
  SET
    status = 'unscheduled',
    agreed_kickoff_at = NULL,
    pending_proposal_id = NULL,
    response_due_at = NULL,
    response_required_club_short_name = NULL,
    response_miss_count = 0,
    no_show_club_short_name = NULL,
    no_show_kickoff_at = NULL,
    updated_at = now()
  WHERE fixture_id = p_fixture_id;

  DELETE FROM public.competition_fixture_checkin
  WHERE fixture_id = p_fixture_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.fixture_check_in(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_window_end timestamptz;
  v_home_in boolean;
  v_away_in boolean;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for check-in';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'Kick-off time is not agreed yet';
  END IF;

  v_window_end := v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;

  IF now() < v_kickoff THEN
    RAISE EXCEPTION 'Check-in opens at %', public.match_schedule_format_kickoff_uk(v_kickoff);
  END IF;

  IF now() >= v_window_end THEN
    PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
    RAISE EXCEPTION 'Check-in window has closed';
  END IF;

  INSERT INTO public.competition_fixture_checkin (fixture_id, club_short_name)
  VALUES (p_fixture_id, v_club)
  ON CONFLICT (fixture_id, club_short_name) DO NOTHING;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
  END IF;

  RETURN jsonb_build_object('ok', true, 'checked_in_at', now());
END;
$function$;

-- Clear no-show when a normal result is confirmed
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_played_clear_no_show_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status = 'played'
     AND NEW.is_forfeit = false
     AND (OLD.status IS DISTINCT FROM 'played' OR OLD.is_forfeit = true)
  THEN
    PERFORM public.match_schedule_clear_no_show(NEW.id);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS match_schedule_fixture_played_clear_no_show_trg
  ON public.competition_fixtures;

CREATE TRIGGER match_schedule_fixture_played_clear_no_show_trg
  AFTER UPDATE OF status, is_forfeit ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.match_schedule_fixture_played_clear_no_show_trg();

-- Month lock: forfeit + fine if still unplayed with recorded no-show
CREATE OR REPLACE FUNCTION public.competition_enforce_scheduling_checkin_fines(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_lock timestamptz;
  v_results jsonb := '[]'::jsonb;
  v_count int := 0;
  v_skipped int := 0;
BEGIN
  SELECT c.lock_at
  INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = p_closed_gpsl_month;

  IF v_lock IS NULL OR v_lock > now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_not_closed',
      'closed_gpsl_month', p_closed_gpsl_month
    );
  END IF;

  FOR v_row IN
    SELECT
      f.id AS fixture_id,
      s.no_show_club_short_name AS loser,
      f.matchday,
      f.gpsl_month
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'scheduled'
      AND f.gpsl_month = p_closed_gpsl_month
      AND s.no_show_club_short_name IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = s.no_show_club_short_name
          AND c.owner_id IS NOT NULL
      )
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.competition_fine_applied fa
      WHERE fa.fixture_id = v_row.fixture_id
        AND fa.tariff_code = 'match_agreed_no_show'
        AND fa.note LIKE format('sched_checkin_lock:%s:%', p_closed_gpsl_month, v_row.fixture_id) || '%'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    PERFORM public.fixture_apply_forfeit(
      v_row.fixture_id,
      v_row.loser,
      'match_agreed_no_show',
      format(
        'sched_checkin_lock:%s:%s|No check-in at agreed kick-off · %s MD%s · assessed at month lock',
        p_closed_gpsl_month,
        v_row.fixture_id,
        public.competition_gpsl_month_label(v_row.gpsl_month),
        v_row.matchday
      )
    );

    v_count := v_count + 1;
    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_row.fixture_id,
        'loser', v_row.loser
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'forfeits_applied', v_count,
    'skipped', v_skipped,
    'forfeited', v_results
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_process_scheduling_checkin_fines(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cal record;
  v_job_key text;
  v_res jsonb;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = p_season_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_calendar');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month, c.lock_at
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'scheduling_checkin_fines:' || v_cal.gpsl_month;

    IF EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id
        AND j.job_key = v_job_key
    ) THEN
      CONTINUE;
    END IF;

    v_res := public.competition_enforce_scheduling_checkin_fines(
      p_season_id,
      v_cal.gpsl_month
    );

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      p_season_id,
      v_job_key,
      v_cal.gpsl_month,
      coalesce(v_res, '{}'::jsonb)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();

    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'gpsl_month', v_cal.gpsl_month,
        'result', v_res
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'processed', v_results
  );
END;
$function$;

-- Patch calendar tick to include check-in fines at month lock
CREATE OR REPLACE FUNCTION public.competition_calendar_month_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_month_sort smallint;
  v_august_sort constant smallint := public.competition_gpsl_month_sort('august');
  v_job_id bigint;
  v_enforcement jsonb;
  v_totm jsonb;
  v_sched_fines jsonb;
  v_response_track jsonb;
  v_response_fines jsonb;
  v_checkin_fines jsonb;
  v_out jsonb;
  v_last_scheduling timestamptz;
  v_run_scheduling boolean := false;
BEGIN
  SELECT id
  INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
    AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_season_id
  ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_calendar',
      'season_id', v_season_id
    );
  END IF;

  v_month := public.competition_active_gpsl_month(v_season_id, now());
  v_month_sort := public.competition_gpsl_month_sort(v_month);

  v_out := jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'calendar_phase', CASE
      WHEN v_month IS NULL THEN 'between_months'
      ELSE 'in_month'
    END
  );

  IF to_regprocedure('public.competition_process_month_team_awards(bigint)') IS NOT NULL THEN
    v_totm := public.competition_process_month_team_awards(v_season_id);
    v_out := v_out || jsonb_build_object('team_of_month', v_totm);
  END IF;

  SELECT j.ran_at
  INTO v_last_scheduling
  FROM public.competition_season_calendar_jobs j
  WHERE j.season_id = v_season_id
    AND j.job_key = 'scheduling_enforcement_throttle'
  LIMIT 1;

  v_run_scheduling :=
    v_last_scheduling IS NULL
    OR v_last_scheduling < now() - interval '5 minutes';

  IF v_run_scheduling THEN
    v_response_track := public.competition_process_scheduling_response_deadlines(v_season_id);
    v_out := v_out || jsonb_build_object('scheduling_response_deadlines', v_response_track);

    v_sched_fines := public.competition_process_scheduling_arrangement_fines(v_season_id);
    v_out := v_out || jsonb_build_object('scheduling_arrangement_fines', v_sched_fines);

    v_response_fines := public.competition_process_scheduling_response_fines(v_season_id);
    v_out := v_out || jsonb_build_object('scheduling_response_fines', v_response_fines);

    v_checkin_fines := public.competition_process_scheduling_checkin_fines(v_season_id);
    v_out := v_out || jsonb_build_object('scheduling_checkin_fines', v_checkin_fines);

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      v_season_id,
      'scheduling_enforcement_throttle',
      coalesce(v_month, 'none'),
      jsonb_build_object('ok', true, 'ran_at', now())
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();
  ELSE
    v_out := v_out || jsonb_build_object(
      'scheduling_response_deadlines', jsonb_build_object('skipped', true, 'reason', 'throttled'),
      'scheduling_arrangement_fines', jsonb_build_object('skipped', true, 'reason', 'throttled'),
      'scheduling_response_fines', jsonb_build_object('skipped', true, 'reason', 'throttled'),
      'scheduling_checkin_fines', jsonb_build_object('skipped', true, 'reason', 'throttled')
    );
  END IF;

  IF v_month IS NULL OR v_month_sort IS NULL OR v_month_sort < v_august_sort THEN
    RETURN v_out || jsonb_build_object(
      'squad_minimum_august', jsonb_build_object('skipped', true, 'reason', 'before_august')
    );
  END IF;

  INSERT INTO public.competition_season_calendar_jobs (
    season_id, job_key, gpsl_month, result
  )
  VALUES (
    v_season_id,
    'squad_minimum_august',
    v_month,
    jsonb_build_object('status', 'running')
  )
  ON CONFLICT (season_id, job_key) DO NOTHING
  RETURNING id INTO v_job_id;

  IF v_job_id IS NULL THEN
    RETURN v_out || jsonb_build_object(
      'squad_minimum_august', jsonb_build_object('skipped', true, 'reason', 'already_ran')
    );
  END IF;

  v_enforcement := public.competition_enforce_squad_minimum_august(v_season_id);

  UPDATE public.competition_season_calendar_jobs
  SET result = v_enforcement,
      gpsl_month = v_month,
      ran_at = now()
  WHERE id = v_job_id;

  RETURN v_out || jsonb_build_object('squad_minimum_august', v_enforcement);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_enforce_scheduling_checkin_fines(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_process_scheduling_checkin_fines(bigint) TO service_role;

NOTIFY pgrst, 'reload schema';
