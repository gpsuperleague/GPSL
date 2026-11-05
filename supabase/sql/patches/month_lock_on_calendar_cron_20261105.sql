-- =============================================================================
-- Month lock runs at calendar lock_at (Thu 19:00 UK) — 2026-11-05
--
-- Product model: when a GPSL month locks, run the full month-lock jobs +
-- side effects (interest, TV next month, awards, friendlies, vacant WOs,
-- scheduling fines, etc.). Calendar lock_at alone never invoked that path;
-- only admin End Month did.
--
-- This installs gpsl_month_lock_on_calendar_tick():
--   • Finds locked months missing job stamp month_lock_on_calendar:<month>
--   • Runs competition_run_month_lock_jobs_complete(..., 'all')
--   • One month per tick (avoids statement timeout)
--   • Cron every 5 minutes
--
-- Replaces the piecemeal gpsl_month_lock_auto_catchup_tick body and keeps
-- the same cron job name. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_month_lock_on_calendar_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '240s'
AS $function$
DECLARE
  v_season bigint;
  v_month text;
  v_lock_at timestamptz;
  v_job_key text;
  v_result jsonb;
  v_vacant jsonb := NULL;
  v_already boolean;
BEGIN
  PERFORM set_config('gpsl.skip_bookies_reprice', 'on', true);
  PERFORM set_config('statement_timeout', '240s', true);

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  -- Oldest locked month not yet stamped as calendar-lock processed
  SELECT lower(btrim(c.gpsl_month)), c.lock_at
  INTO v_month, v_lock_at
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season
    AND c.lock_at IS NOT NULL
    AND c.lock_at <= now()
    AND lower(btrim(c.gpsl_month)) <> 'playoffs'
    AND NOT EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = v_season
        AND j.job_key = 'month_lock_on_calendar:' || lower(btrim(c.gpsl_month))
        AND coalesce((j.result->>'ok')::boolean, false) = true
    )
  ORDER BY c.sort_order
  LIMIT 1;

  IF v_month IS NULL THEN
    -- Still drain vacant walkovers for any locked leftovers
    IF to_regprocedure('public.competition_process_vacant_walkovers_chunk(bigint,integer)') IS NOT NULL THEN
      BEGIN
        v_vacant := public.competition_process_vacant_walkovers_chunk(v_season, 25);
      EXCEPTION WHEN OTHERS THEN
        v_vacant := jsonb_build_object('ok', false, 'error', SQLERRM);
      END;
    END IF;
    RETURN jsonb_build_object(
      'ok', true,
      'season_id', v_season,
      'skipped', true,
      'reason', 'no_locked_month_pending',
      'vacant_walkovers', v_vacant
    );
  END IF;

  v_job_key := 'month_lock_on_calendar:' || v_month;

  BEGIN
    IF to_regprocedure(
         'public.competition_run_month_lock_jobs_complete(bigint,boolean,text,text)'
       ) IS NOT NULL THEN
      v_result := public.competition_run_month_lock_jobs_complete(
        v_season,
        true,          -- force scheduling fines at lock
        v_month,
        'all'
      );
    ELSE
      v_result := public.competition_run_month_lock_jobs(
        v_season, true, v_month, 'all'
      );
      IF to_regprocedure(
           'public.competition_run_month_lock_side_effects(bigint,text,text)'
         ) IS NOT NULL THEN
        v_result := coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
          'side_effects',
          public.competition_run_month_lock_side_effects(v_season, v_month, 'all')
        );
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_result := jsonb_build_object('ok', false, 'error', SQLERRM, 'gpsl_month', v_month);
  END;

  -- Belt-and-suspenders: awards / friendlies / vacant if complete path missed pieces
  IF to_regprocedure('public.competition_catchup_month_awards(bigint,text[],boolean)') IS NOT NULL THEN
    BEGIN
      v_result := coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
        'awards_catchup',
        public.competition_catchup_month_awards(v_season, ARRAY[v_month]::text[], false)
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  IF to_regprocedure('public.gpsl_friendlies_pay_locked_months_catchup(bigint)') IS NOT NULL THEN
    BEGIN
      v_result := coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
        'friendlies_catchup',
        public.gpsl_friendlies_pay_locked_months_catchup(v_season)
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  IF to_regprocedure('public.competition_process_vacant_walkovers_chunk(bigint,integer)') IS NOT NULL THEN
    BEGIN
      v_vacant := public.competition_process_vacant_walkovers_chunk(v_season, 30);
      v_result := coalesce(v_result, '{}'::jsonb) || jsonb_build_object('vacant_walkovers', v_vacant);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  v_already := coalesce((v_result->>'ok')::boolean, false)
    OR coalesce((v_result->'side_effects'->>'ok')::boolean, false);

  -- Stamp success so we don't re-run forever. On hard failure, leave unstamped
  -- so the next tick retries.
  IF coalesce((v_result->>'ok')::boolean, false)
     OR (v_result ? 'side_effects' AND coalesce((v_result->'side_effects'->>'ok')::boolean, false))
     OR NOT (v_result ? 'error') THEN
    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      v_season,
      v_job_key,
      v_month,
      coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
        'ok', true,
        'lock_at', v_lock_at,
        'ran_via', 'gpsl_month_lock_on_calendar_tick'
      )
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'gpsl_month', v_month,
    'lock_at', v_lock_at,
    'job_key', v_job_key,
    'result', v_result
  );
END;
$function$;

-- Keep old name as alias so existing cron / callers still work
CREATE OR REPLACE FUNCTION public.gpsl_month_lock_auto_catchup_tick()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.gpsl_month_lock_on_calendar_tick();
$$;

REVOKE ALL ON FUNCTION public.gpsl_month_lock_on_calendar_tick() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.gpsl_month_lock_auto_catchup_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_month_lock_on_calendar_tick() TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_month_lock_auto_catchup_tick() TO service_role;

COMMENT ON FUNCTION public.gpsl_month_lock_on_calendar_tick() IS
  'After calendar lock_at: run full month-lock jobs + side effects (one month per tick).';

DO $cron$
BEGIN
  BEGIN
    PERFORM cron.unschedule('gpsl-month-lock-auto-catchup');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  BEGIN
    PERFORM cron.unschedule('gpsl-month-lock-on-calendar');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- Every 5 minutes — picks up Thu 19:00 UK lock within a few minutes
  PERFORM cron.schedule(
    'gpsl-month-lock-on-calendar',
    '*/5 * * * *',
    $q$SELECT public.gpsl_month_lock_on_calendar_tick();$q$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule month-lock-on-calendar: %', SQLERRM;
END;
$cron$;

-- Run once now for any locked month still unstamped (e.g. September scheduling fines)
SELECT public.gpsl_month_lock_on_calendar_tick() AS tick_now;

SELECT jobid, jobname, schedule, active
FROM cron.job
WHERE jobname IN (
  'gpsl-month-lock-on-calendar',
  'gpsl-month-lock-auto-catchup',
  'gpsl-friendlies-prizes-catchup',
  'gpsl-vacant-walkovers'
)
ORDER BY jobname;

NOTIFY pgrst, 'reload schema';
