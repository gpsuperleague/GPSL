-- =============================================================================
-- Month-lock-on-calendar: only auto-run recently locked months
--
-- First tick walked oldest→newest and started re-processing July. Historical
-- months already had interest/awards from earlier catch-ups; re-running full
-- scheduling fines would be harmful.
--
-- Fix:
--   1) Backfill stamps for locked months older than 48h (no job re-run)
--   2) Full month-lock jobs only for months locked within the last 48 hours
--      (and still unstamped)
-- Safe re-run.
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
  v_backfilled int := 0;
  r record;
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

  -- Stamp old locked months so we never re-run full lock jobs on them
  FOR r IN
    SELECT lower(btrim(c.gpsl_month)) AS gpsl_month, c.lock_at
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now() - interval '48 hours'
      AND lower(btrim(c.gpsl_month)) <> 'playoffs'
      AND NOT EXISTS (
        SELECT 1
        FROM public.competition_season_calendar_jobs j
        WHERE j.season_id = v_season
          AND j.job_key = 'month_lock_on_calendar:' || lower(btrim(c.gpsl_month))
          AND coalesce((j.result->>'ok')::boolean, false) = true
      )
  LOOP
    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      v_season,
      'month_lock_on_calendar:' || r.gpsl_month,
      r.gpsl_month,
      jsonb_build_object(
        'ok', true,
        'backfilled', true,
        'reason', 'locked_over_48h_skip_rerun',
        'lock_at', r.lock_at
      )
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();
    v_backfilled := v_backfilled + 1;
  END LOOP;

  -- Newest recently locked month still needing a real run
  SELECT lower(btrim(c.gpsl_month)), c.lock_at
  INTO v_month, v_lock_at
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season
    AND c.lock_at IS NOT NULL
    AND c.lock_at <= now()
    AND c.lock_at > now() - interval '48 hours'
    AND lower(btrim(c.gpsl_month)) <> 'playoffs'
    AND NOT EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = v_season
        AND j.job_key = 'month_lock_on_calendar:' || lower(btrim(c.gpsl_month))
        AND coalesce((j.result->>'ok')::boolean, false) = true
        AND coalesce((j.result->>'backfilled')::boolean, false) = false
    )
  ORDER BY c.lock_at DESC
  LIMIT 1;

  IF v_month IS NULL THEN
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
      'reason', 'no_recent_locked_month_pending',
      'backfilled_stamps', v_backfilled,
      'vacant_walkovers', v_vacant
    );
  END IF;

  v_job_key := 'month_lock_on_calendar:' || v_month;

  BEGIN
    IF to_regprocedure(
         'public.competition_run_month_lock_jobs_complete(bigint,boolean,text,text)'
       ) IS NOT NULL THEN
      v_result := public.competition_run_month_lock_jobs_complete(
        v_season, true, v_month, 'all'
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

  IF NOT (v_result ? 'error')
     OR coalesce((v_result->>'ok')::boolean, false)
     OR coalesce((v_result->'side_effects'->>'ok')::boolean, false) THEN
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
    'backfilled_stamps', v_backfilled,
    'result', v_result
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_month_lock_auto_catchup_tick()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.gpsl_month_lock_on_calendar_tick();
$$;

-- Immediate: stamp old months + process September if still needed
SELECT public.gpsl_month_lock_on_calendar_tick() AS tick_now;

SELECT job_key, gpsl_month, ran_at,
       result->>'backfilled' AS backfilled,
       result->>'ran_via' AS ran_via
FROM public.competition_season_calendar_jobs
WHERE season_id = (SELECT id FROM competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
  AND job_key LIKE 'month_lock_on_calendar:%'
ORDER BY ran_at DESC NULLS LAST;
