-- =============================================================================
-- Free tier — reduce background DB load (Nano RAM / burst disk IO)
-- =============================================================================
-- Run in Supabase SQL Editor when the project is Healthy.
--
-- Support confirmed overload from cron workloads on Free compute. This patch:
--   1. Removes the extra every-minute evening pg_cron job (keeps 5-minute job).
--   2. Throttles scheduling enforcement (response deadlines + arrangement fines)
--      to at most once per 5 minutes inside competition_calendar_month_tick.
--
-- ALSO do manually (no SQL):
--   • GitHub → Actions → Transfer Engine Runner → ⋮ → Disable workflow
--     (pg_cron already runs the same engine; duplicate runs double disk IO.)
--   • Avoid clicking Admin → “Run transfer engine” repeatedly while testing.
--
-- Draft / 7pm UK timing: 5-minute cron is still sufficient (≤5 min delay).
-- Re-enable the evening 1-minute job only on Pro compute if needed later.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1 — Remove every-minute evening cron (largest win on Free tier)
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_job record;
BEGIN
  FOR v_job IN
    SELECT jobid, jobname
    FROM cron.job
    WHERE jobname = 'gpsl-transfer-engine-evening-1min'
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
    RAISE NOTICE 'Unscheduled cron job % (jobid %)', v_job.jobname, v_job.jobid;
  END LOOP;
END;
$do$;

-- ---------------------------------------------------------------------------
-- 2 — Throttle scheduling enforcement inside calendar month tick
-- ---------------------------------------------------------------------------
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
  v_response_fines jsonb;
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
    v_response_fines := public.competition_process_scheduling_response_deadlines(v_season_id);
    v_out := v_out || jsonb_build_object('scheduling_response_deadlines', v_response_fines);

    v_sched_fines := public.competition_process_scheduling_arrangement_fines(v_season_id);
    v_out := v_out || jsonb_build_object('scheduling_arrangement_fines', v_sched_fines);

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
      'scheduling_arrangement_fines', jsonb_build_object('skipped', true, 'reason', 'throttled')
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

-- ---------------------------------------------------------------------------
-- Verify
-- ---------------------------------------------------------------------------
-- SELECT jobname, schedule, active FROM cron.job WHERE jobname LIKE 'gpsl-transfer-engine%';
-- Expected: only gpsl-transfer-engine-5min (*/5 * * * *)
--
-- SELECT public.competition_calendar_month_tick();
-- SELECT public.transferengine_run_report();

NOTIFY pgrst, 'reload schema';
