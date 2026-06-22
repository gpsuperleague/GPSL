-- =============================================================================
-- Transfer engine — reliable pg_cron schedule (primary automation)
-- =============================================================================
--
-- GitHub Actions schedule is best-effort; this runs inside Supabase Postgres.
--
-- BEFORE running this script:
--   Dashboard → Database → Extensions → enable "pg_cron"
--
-- AFTER running:
--   SELECT jobid, jobname, schedule, active FROM cron.job
--   WHERE jobname LIKE 'gpsl-transfer-engine%';
--
--   SELECT status, start_time, end_time, return_message
--   FROM cron.job_run_details
--   WHERE jobid IN (SELECT jobid FROM cron.job WHERE jobname LIKE 'gpsl-transfer-engine%')
--   ORDER BY start_time DESC LIMIT 10;
--
-- Manual tick (same as cron): SELECT public.gpsl_transferengine_cron_tick();
-- Full report JSON:          SELECT public.transferengine_run_report();
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

GRANT USAGE ON SCHEMA cron TO postgres;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA cron TO postgres;

-- Wrapper so cron failures show in Postgres logs / cron.job_run_details.
CREATE OR REPLACE FUNCTION public.gpsl_transferengine_cron_tick()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_report jsonb;
  v_lock_key bigint := 4242424242;
BEGIN
  IF NOT pg_try_advisory_lock(v_lock_key) THEN
    RAISE LOG 'gpsl_transferengine_cron_tick skipped — previous tick still running';
    RETURN;
  END IF;

  BEGIN
    v_report := public.transferengine_run_report();
    RAISE LOG 'gpsl_transferengine_cron_tick ok at % (draft_settled=% manager_settled=%)',
      now(),
      v_report->>'draft_settled_count',
      v_report->>'manager_draft_settled_count';
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'gpsl_transferengine_cron_tick failed: %', SQLERRM;
      PERFORM pg_advisory_unlock(v_lock_key);
      RAISE;
  END;

  PERFORM pg_advisory_unlock(v_lock_key);
EXCEPTION
  WHEN OTHERS THEN
    PERFORM pg_advisory_unlock(v_lock_key);
    RAISE;
END;
$function$;

COMMENT ON FUNCTION public.gpsl_transferengine_cron_tick IS
  'pg_cron entrypoint — runs transferengine_run_report() (special auction start, market + draft settlement).';

REVOKE ALL ON FUNCTION public.gpsl_transferengine_cron_tick() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_transferengine_cron_tick() TO postgres;

-- Idempotent re-deploy: drop previous GPSL transfer-engine cron jobs.
DO $do$
DECLARE
  v_job record;
BEGIN
  FOR v_job IN
    SELECT jobid, jobname
    FROM cron.job
    WHERE jobname LIKE 'gpsl-transfer-engine%'
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
  END LOOP;
END;
$do$;

-- Every 5 minutes, 24/7 (transfer list, draft backlog, calendar month tick).
SELECT cron.schedule(
  'gpsl-transfer-engine-5min',
  '*/5 * * * *',
  $$SELECT public.gpsl_transferengine_cron_tick();$$
);

-- UK evening window (UTC): every minute 17:00–21:59 covers
--   BST — draft random finish ~17:50 UTC, 7pm list ~18:00 UTC, extensions ~19–20 UTC
--   GMT — draft random finish ~18:50 UTC, 7pm list ~19:00 UTC, extensions ~20–21 UTC
SELECT cron.schedule(
  'gpsl-transfer-engine-evening-1min',
  '* 17-21 * * *',
  $$SELECT public.gpsl_transferengine_cron_tick();$$
);

-- Run once now so deploy does not wait for the next cron slot.
SELECT public.gpsl_transferengine_cron_tick();

NOTIFY pgrst, 'reload schema';
