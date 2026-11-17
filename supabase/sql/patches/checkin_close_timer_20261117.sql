-- Record a missed check-in soon after the window closes.
-- The open-notice job only posts "check-in open". The strike, fine and
-- Discord miss were waiting for someone to open the fixture.

CREATE OR REPLACE FUNCTION public.match_schedule_process_closed_checkins()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_n int := 0;
  v_err int := 0;
BEGIN
  FOR v_id IN
    SELECT f.id
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
    WHERE f.status = 'scheduled'
      AND sch.status = 'agreed'
      AND sch.agreed_kickoff_at IS NOT NULL
      AND sch.agreed_kickoff_at
          + (public.match_schedule_checkin_minutes() || ' minutes')::interval
          <= now()
      AND sch.agreed_kickoff_at > now() - interval '24 hours'
      AND NOT (
        EXISTS (
          SELECT 1 FROM public.competition_fixture_checkin c
          WHERE c.fixture_id = f.id
            AND c.club_short_name = f.home_club_short_name
        )
        AND EXISTS (
          SELECT 1 FROM public.competition_fixture_checkin c
          WHERE c.fixture_id = f.id
            AND c.club_short_name = f.away_club_short_name
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_fixture_no_show_events e
        WHERE e.fixture_id = f.id
          AND e.kickoff_at = sch.agreed_kickoff_at
      )
    ORDER BY sch.agreed_kickoff_at
    LIMIT 20
  LOOP
    BEGIN
      PERFORM public.fixture_try_checkin_forfeit(v_id);
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      v_err := v_err + 1;
      RAISE WARNING 'closed check-in %: %', v_id, SQLERRM;
    END;
  END LOOP;

  IF v_n > 0 AND to_regprocedure('public.gpsl_discord_feed_request_flush()') IS NOT NULL THEN
    BEGIN
      PERFORM public.gpsl_discord_feed_request_flush();
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'closed check-in flush: %', SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object('ok', true, 'checked', v_n, 'errors', v_err);
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_process_closed_checkins() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_process_closed_checkins() TO postgres, service_role;

DO $do$
DECLARE
  v_job record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE WARNING 'pg_cron not enabled';
    RETURN;
  END IF;

  FOR v_job IN
    SELECT jobid FROM cron.job WHERE jobname = 'gpsl-checkin-close'
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
  END LOOP;

  PERFORM cron.schedule(
    'gpsl-checkin-close',
    '*/5 * * * *',
    $$SELECT public.match_schedule_process_closed_checkins();$$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule check-in close: %', SQLERRM;
END;
$do$;

SELECT public.match_schedule_process_closed_checkins() AS first_run;

SELECT jsonb_build_object(
  'job', EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-checkin-close' AND schedule = '*/5 * * * *'),
  'boca', coalesce((
    SELECT jsonb_build_object(
      'club', e.club_short_name,
      'action', e.action,
      'kickoff', e.kickoff_at
    )
    FROM public.competition_fixture_no_show_events e
    WHERE e.fixture_id = 9033
    ORDER BY e.kickoff_at DESC
    LIMIT 1
  ), '{}'::jsonb),
  'discord', coalesce((
    SELECT q.status
    FROM public.gpsl_discord_feed_queue q
    WHERE q.dedupe_key = 'scheduled:checkin_miss:9033:202611171230:home'
    ORDER BY q.id DESC
    LIMIT 1
  ), 'none')
) AS info;
