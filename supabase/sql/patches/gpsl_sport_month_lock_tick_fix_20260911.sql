-- =============================================================================
-- Fix: GPSL Sport not publishing at month lock / natural lock_at
--
-- Cause: later competition_calendar_month_tick rewrites (e.g. free_tier_cron_throttle)
-- dropped gpsl_sport_process_pending_editions(). Natural Friday locks therefore
-- never created August/September editions. End-Month-Early also defers lock jobs
-- so Sport only appears if the admin retries the sport stage / republishes.
--
-- Also: process_pending skipped any month with a gpsl_sport:<month> job row,
-- even when result was failed / missing edition_id.
--
-- This patch:
--   1) Hardens gpsl_sport_process_pending_editions (clear failed markers; create
--      if edition row missing)
--   2) Restores Sport on competition_calendar_month_tick AFTER team_of_month
--      (before early returns for squad-minimum / between-months)
--   3) Soft-wires a catch-up call into competition_run_month_lock_jobs RETURN
--
-- Safe re-run. After deploy, backfill with:
--   SELECT public.gpsl_sport_process_pending_editions(
--     (SELECT id FROM competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
--   );
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_process_pending_editions(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cal record;
  v_win record;
  v_job_key text;
  v_id bigint;
  v_results jsonb := '[]'::jsonb;
  v_capture jsonb;
  v_month text;
  v_has_win boolean := false;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_cal IN
    SELECT lower(btrim(c.gpsl_month)) AS gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.gpsl_month IS NOT NULL
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_month := v_cal.gpsl_month;
    v_job_key := 'gpsl_sport:' || v_month;
    v_capture := NULL;
    v_id := NULL;

    -- Clear failed / empty markers so we can retry
    DELETE FROM public.competition_season_calendar_jobs j
    WHERE j.season_id = p_season_id
      AND j.job_key = v_job_key
      AND (
        j.result IS NULL
        OR coalesce((j.result->>'ok')::boolean, false) IS NOT TRUE
        OR nullif(j.result->>'edition_id', '') IS NULL
      );

    SELECT e.id INTO v_id
    FROM public.gpsl_sport_editions e
    WHERE e.season_id = p_season_id
      AND lower(btrim(e.gpsl_month)) = v_month
    ORDER BY e.id DESC
    LIMIT 1;

    -- Successful edition + job already present
    IF v_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id
        AND j.job_key = v_job_key
        AND coalesce((j.result->>'ok')::boolean, false) IS TRUE
    ) THEN
      CONTINUE;
    END IF;

    IF v_id IS NULL THEN
      IF to_regprocedure('public.gpsl_sport_capture_owner_comments(bigint,text)') IS NOT NULL THEN
        BEGIN
          v_capture := public.gpsl_sport_capture_owner_comments(p_season_id, v_month);
        EXCEPTION WHEN OTHERS THEN
          v_capture := jsonb_build_object('ok', false, 'error', SQLERRM);
        END;
      END IF;

      IF to_regprocedure('public.gpsl_sport_generate_edition(bigint,text)') IS NULL THEN
        v_results := v_results || jsonb_build_array(
          jsonb_build_object('gpsl_month', v_month, 'ok', false, 'error', 'generate_rpc_missing')
        );
        CONTINUE;
      END IF;

      BEGIN
        v_id := public.gpsl_sport_generate_edition(p_season_id, v_month);
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO public.competition_season_calendar_jobs (
          season_id, job_key, gpsl_month, result
        ) VALUES (
          p_season_id, v_job_key, v_month,
          jsonb_build_object('ok', false, 'error', SQLERRM)
        )
        ON CONFLICT (season_id, job_key) DO UPDATE
          SET result = excluded.result, ran_at = now();
        v_results := v_results || jsonb_build_array(
          jsonb_build_object('gpsl_month', v_month, 'ok', false, 'error', SQLERRM)
        );
        CONTINUE;
      END;
    END IF;

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    ) VALUES (
      p_season_id, v_job_key, v_month,
      jsonb_build_object(
        'edition_id', v_id,
        'ok', v_id IS NOT NULL,
        'owner_comments', coalesce(v_capture, '{}'::jsonb)
      )
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();

    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'gpsl_month', v_month,
        'edition_id', v_id,
        'ok', v_id IS NOT NULL
      )
    );
  END LOOP;

  BEGIN
    SELECT * INTO v_win FROM public.gpsl_sport_preseason_window(p_season_id);
    v_has_win := FOUND;
  EXCEPTION WHEN OTHERS THEN
    v_has_win := false;
  END;

  IF v_has_win AND now() < v_win.august_start THEN
    FOREACH v_month IN ARRAY ARRAY['june', 'july']::text[]
    LOOP
      IF v_month = 'june'
         AND NOT (coalesce(v_win.include_june, false) AND now() >= v_win.publish_june_at)
      THEN
        CONTINUE;
      END IF;
      IF v_month = 'july'
         AND NOT (coalesce(v_win.include_july, false) AND now() >= v_win.publish_july_at)
      THEN
        CONTINUE;
      END IF;

      v_job_key := 'gpsl_sport:' || v_month;
      DELETE FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id
        AND j.job_key = v_job_key
        AND (
          j.result IS NULL
          OR coalesce((j.result->>'ok')::boolean, false) IS NOT TRUE
          OR nullif(j.result->>'edition_id', '') IS NULL
        );

      IF EXISTS (
        SELECT 1 FROM public.gpsl_sport_editions e
        WHERE e.season_id = p_season_id AND lower(btrim(e.gpsl_month)) = v_month
      ) THEN
        CONTINUE;
      END IF;

      BEGIN
        v_id := public.gpsl_sport_generate_edition(p_season_id, v_month);
      EXCEPTION WHEN OTHERS THEN
        v_id := NULL;
      END;

      INSERT INTO public.competition_season_calendar_jobs (
        season_id, job_key, gpsl_month, result
      ) VALUES (
        p_season_id, v_job_key, v_month,
        jsonb_build_object('edition_id', v_id, 'ok', v_id IS NOT NULL)
      )
      ON CONFLICT (season_id, job_key) DO UPDATE
        SET result = excluded.result, ran_at = now();

      v_results := v_results || jsonb_build_array(
        jsonb_build_object('gpsl_month', v_month, 'edition_id', v_id)
      );
    END LOOP;
  END IF;

  RETURN jsonb_build_object('ok', true, 'processed', v_results);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_process_pending_editions(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_process_pending_editions(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Restore Sport on the cron tick (full replace of free_tier body + Sport).
-- Sport runs AFTER team_of_month and BEFORE early returns for between-months /
-- squad-minimum — those early exits were why a final-RETURN soft-wire would miss.
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

  -- GPSL Sport: publish editions for any locked month still missing one
  BEGIN
    IF to_regprocedure('public.gpsl_sport_process_pending_editions(bigint)') IS NOT NULL THEN
      v_out := v_out || jsonb_build_object(
        'gpsl_sport',
        public.gpsl_sport_process_pending_editions(v_season_id)
      );
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'gpsl_sport',
        jsonb_build_object('ok', false, 'error', SQLERRM)
      );
  END;

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

-- Soft-wire catch-up into month-lock jobs (after staged work, before RETURN)
DO $wire_lock$
DECLARE
  v_def text;
  v_marker text := 'gpsl_sport_pending_catchup';
  v_old text := E'  RETURN v_out;\nEND;';
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') IS NULL THEN
    RAISE NOTICE 'competition_run_month_lock_jobs missing — Sport lock wire skipped';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) INTO v_def;

  IF v_def IS NULL THEN
    RETURN;
  END IF;

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Sport pending catch-up already wired into month-lock jobs';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'Could not locate RETURN v_out in month-lock jobs — Sport lock wire skipped';
    RETURN;
  END IF;

  v_new :=
    E'  -- GPSL Sport catch-up: ensure every locked month has an edition\n'
    || E'  BEGIN\n'
    || E'    IF to_regprocedure(''public.gpsl_sport_process_pending_editions(bigint)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''gpsl_sport_pending_catchup'',\n'
    || E'        public.gpsl_sport_process_pending_editions(p_season_id)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION\n'
    || E'    WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''gpsl_sport_pending_catchup'',\n'
    || E'        jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'  END;\n'
    || E'\n'
    || E'  RETURN v_out;\n'
    || E'END;';

  -- pg_get_functiondef already returns CREATE OR REPLACE FUNCTION ...
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'Wired Sport pending catch-up into competition_run_month_lock_jobs';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Sport lock wire failed: %', SQLERRM;
END;
$wire_lock$;

NOTIFY pgrst, 'reload schema';
