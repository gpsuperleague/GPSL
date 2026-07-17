-- =============================================================================
-- Fix: competition_admin_end_gpsl_month_early statement timeout
--
-- Cause: lock + TOTM + GPSL Sport edition + scheduling fines all ran in ONE
-- transaction. Sport/TOTM can exceed the API statement_timeout, which rolls
-- back the calendar lock too.
--
-- Fix:
--  1) Early-end only locks the month (+ loans + optional pull-forward) — fast.
--  2) Month-lock jobs run in a separate admin RPC (own timeout budget).
--  3) When a locked month is passed, Sport/TOTM only process that month.
--
-- Run in Supabase SQL Editor, then retry End Month Early.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_run_month_lock_jobs(
  p_season_id bigint,
  p_force_scheduling boolean DEFAULT false,
  p_locked_gpsl_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_out jsonb := jsonb_build_object('ok', true, 'season_id', p_season_id);
  v_totm jsonb;
  v_sport jsonb;
  v_tv jsonb;
  v_response_track jsonb;
  v_sched_fines jsonb;
  v_response_fines jsonb;
  v_checkin_fines jsonb;
  v_last_scheduling timestamptz;
  v_run_scheduling boolean := false;
  v_month text := nullif(lower(btrim(coalesce(p_locked_gpsl_month, ''))), '');
  v_scope text;
  v_job_key text;
  v_res jsonb;
  v_id bigint;
  v_totm_results jsonb := '[]'::jsonb;
  v_sport_results jsonb := '[]'::jsonb;
BEGIN
  -- Heavy admin/cron work — allow up to 3 minutes for this transaction
  PERFORM set_config('statement_timeout', '180s', true);

  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  -- Team of the Month
  BEGIN
    IF v_month IS NOT NULL
       AND to_regprocedure('public.competition_compute_team_of_month(bigint,text,text)') IS NOT NULL THEN
      FOREACH v_scope IN ARRAY ARRAY['superleague', 'championship']::text[]
      LOOP
        v_job_key := 'team_of_month:' || v_scope || ':' || v_month;

        IF v_scope = 'superleague' AND EXISTS (
          SELECT 1 FROM public.competition_season_calendar_jobs j
          WHERE j.season_id = p_season_id
            AND j.job_key IN (v_job_key, 'team_of_month:' || v_month)
        ) THEN
          CONTINUE;
        ELSIF EXISTS (
          SELECT 1 FROM public.competition_season_calendar_jobs j
          WHERE j.season_id = p_season_id AND j.job_key = v_job_key
        ) THEN
          CONTINUE;
        END IF;

        v_res := public.competition_compute_team_of_month(p_season_id, v_month, v_scope);

        INSERT INTO public.competition_season_calendar_jobs (
          season_id, job_key, gpsl_month, result
        )
        VALUES (p_season_id, v_job_key, v_month, coalesce(v_res, '{}'::jsonb))
        ON CONFLICT (season_id, job_key) DO UPDATE
          SET result = excluded.result,
              gpsl_month = excluded.gpsl_month,
              ran_at = now();

        v_totm_results := v_totm_results || jsonb_build_array(
          jsonb_build_object(
            'gpsl_month', v_month,
            'division_scope', v_scope,
            'result', v_res
          )
        );
      END LOOP;
      v_totm := jsonb_build_object('ok', true, 'processed', v_totm_results, 'scoped', true);
    ELSIF to_regprocedure('public.competition_process_month_team_awards(bigint)') IS NOT NULL THEN
      v_totm := public.competition_process_month_team_awards(p_season_id);
    ELSE
      v_totm := jsonb_build_object('skipped', true, 'reason', 'totm_rpc_missing');
    END IF;
    v_out := v_out || jsonb_build_object('team_of_month', v_totm);
  EXCEPTION
    WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'team_of_month', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
  END;

  -- GPSL Sport edition
  BEGIN
    IF v_month IS NOT NULL
       AND to_regprocedure('public.gpsl_sport_generate_edition(bigint,text)') IS NOT NULL THEN
      v_job_key := 'gpsl_sport:' || v_month;
      IF NOT EXISTS (
        SELECT 1 FROM public.competition_season_calendar_jobs j
        WHERE j.season_id = p_season_id AND j.job_key = v_job_key
      ) THEN
        v_id := public.gpsl_sport_generate_edition(p_season_id, v_month);
        INSERT INTO public.competition_season_calendar_jobs (
          season_id, job_key, gpsl_month, result
        )
        VALUES (
          p_season_id, v_job_key, v_month,
          jsonb_build_object('edition_id', v_id, 'ok', v_id IS NOT NULL)
        )
        ON CONFLICT (season_id, job_key) DO UPDATE
          SET result = excluded.result,
              gpsl_month = excluded.gpsl_month,
              ran_at = now();
        v_sport_results := v_sport_results || jsonb_build_array(
          jsonb_build_object('gpsl_month', v_month, 'edition_id', v_id)
        );
      END IF;
      v_sport := jsonb_build_object('ok', true, 'processed', v_sport_results, 'scoped', true);
    ELSIF to_regprocedure('public.gpsl_sport_process_pending_editions(bigint)') IS NOT NULL THEN
      v_sport := public.gpsl_sport_process_pending_editions(p_season_id);
    ELSE
      v_sport := jsonb_build_object('skipped', true, 'reason', 'sport_rpc_missing');
    END IF;
    v_out := v_out || jsonb_build_object('gpsl_sport', v_sport);
  EXCEPTION
    WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'gpsl_sport', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
  END;

  -- TV selections
  BEGIN
    IF to_regprocedure('public.competition_tv_process_month_lock_selections(bigint,text)') IS NOT NULL THEN
      v_tv := public.competition_tv_process_month_lock_selections(p_season_id, p_locked_gpsl_month);
      v_out := v_out || jsonb_build_object('tv_selection', v_tv);
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'tv_selection', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
  END;

  IF p_force_scheduling THEN
    v_run_scheduling := true;
  ELSE
    SELECT j.ran_at
    INTO v_last_scheduling
    FROM public.competition_season_calendar_jobs j
    WHERE j.season_id = p_season_id
      AND j.job_key = 'scheduling_enforcement_throttle'
    LIMIT 1;

    v_run_scheduling :=
      v_last_scheduling IS NULL
      OR v_last_scheduling < now() - interval '5 minutes';
  END IF;

  IF v_run_scheduling THEN
    BEGIN
      IF to_regprocedure('public.competition_process_scheduling_response_deadlines(bigint)') IS NOT NULL THEN
        v_response_track := public.competition_process_scheduling_response_deadlines(p_season_id);
        v_out := v_out || jsonb_build_object('scheduling_response_deadlines', v_response_track);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'scheduling_response_deadlines', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;

    BEGIN
      IF to_regprocedure('public.competition_process_scheduling_arrangement_fines(bigint)') IS NOT NULL THEN
        v_sched_fines := public.competition_process_scheduling_arrangement_fines(p_season_id);
        v_out := v_out || jsonb_build_object('scheduling_arrangement_fines', v_sched_fines);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'scheduling_arrangement_fines', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;

    BEGIN
      IF to_regprocedure('public.competition_process_scheduling_response_fines(bigint)') IS NOT NULL THEN
        v_response_fines := public.competition_process_scheduling_response_fines(p_season_id);
        v_out := v_out || jsonb_build_object('scheduling_response_fines', v_response_fines);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'scheduling_response_fines', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;

    BEGIN
      IF to_regprocedure('public.competition_process_scheduling_checkin_fines(bigint)') IS NOT NULL THEN
        v_checkin_fines := public.competition_process_scheduling_checkin_fines(p_season_id);
        v_out := v_out || jsonb_build_object('scheduling_checkin_fines', v_checkin_fines);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'scheduling_checkin_fines', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      p_season_id,
      'scheduling_enforcement_throttle',
      coalesce(v_month, public.competition_active_gpsl_month(p_season_id, now()), 'none'),
      jsonb_build_object('ok', true, 'ran_at', now(), 'forced', p_force_scheduling)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();
  ELSE
    v_out := v_out || jsonb_build_object(
      'scheduling', jsonb_build_object('skipped', true, 'reason', 'throttled')
    );
  END IF;

  RETURN v_out;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_run_month_lock_jobs(
  p_season_id bigint DEFAULT NULL,
  p_gpsl_month text DEFAULT NULL,
  p_force_scheduling boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  RETURN public.competition_run_month_lock_jobs(
    v_season_id,
    coalesce(p_force_scheduling, true),
    p_gpsl_month
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_end_gpsl_month_early(
  p_confirm_phrase text,
  p_gpsl_month text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL,
  p_unlock_next_month boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_preview jsonb;
  v_season_id bigint;
  v_month text;
  v_cal record;
  v_prev_lock timestamptz;
  v_loans jsonb;
  v_pull jsonb;
  v_required_phrase text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Lock + calendar only (jobs run in a separate RPC so timeouts cannot undo the lock)
  PERFORM set_config('statement_timeout', '60s', true);

  v_required_phrase := CASE
    WHEN coalesce(p_unlock_next_month, false) THEN 'END MONTH OPEN NEXT'
    ELSE 'END GPSL MONTH'
  END;

  IF coalesce(btrim(p_confirm_phrase), '') <> v_required_phrase THEN
    RAISE EXCEPTION 'Confirmation phrase required — type exactly: %', v_required_phrase;
  END IF;

  v_preview := public.competition_admin_end_gpsl_month_preview(
    p_gpsl_month,
    p_season_id,
    p_unlock_next_month
  );

  IF coalesce((v_preview ->> 'ok')::boolean, false) IS NOT TRUE THEN
    RETURN v_preview;
  END IF;

  IF coalesce((v_preview ->> 'is_already_locked')::boolean, false) THEN
    RETURN v_preview || jsonb_build_object(
      'ended', false,
      'reason', 'already_locked'
    );
  END IF;

  IF coalesce((v_preview ->> 'is_live')::boolean, false) IS NOT TRUE THEN
    RETURN v_preview || jsonb_build_object(
      'ended', false,
      'reason', 'month_not_live'
    );
  END IF;

  v_season_id := (v_preview ->> 'season_id')::bigint;
  v_month := v_preview ->> 'gpsl_month';

  SELECT *
  INTO v_cal
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season_id
    AND c.gpsl_month = v_month
  FOR UPDATE;

  IF NOT FOUND OR now() < v_cal.unlock_at OR now() >= v_cal.lock_at THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_window_changed',
      'gpsl_month', v_month
    );
  END IF;

  v_prev_lock := v_cal.lock_at;

  BEGIN
    IF to_regprocedure('public.competition_admin_process_loan_installments(bigint,text)') IS NOT NULL THEN
      v_loans := public.competition_admin_process_loan_installments(v_season_id, v_month);
    ELSE
      v_loans := jsonb_build_object('skipped', true, 'reason', 'loan_rpc_missing');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      v_loans := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  UPDATE public.competition_season_calendar
  SET lock_at = now()
  WHERE season_id = v_season_id
    AND gpsl_month = v_month
    AND lock_at > now();

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'lock_update_failed',
      'gpsl_month', v_month
    );
  END IF;

  IF coalesce(p_unlock_next_month, false) THEN
    v_pull := public.competition_admin_pull_forward_calendar_months(v_season_id, v_month);
    IF coalesce((v_pull ->> 'ok')::boolean, false) IS NOT TRUE THEN
      RETURN v_preview || jsonb_build_object(
        'ended', true,
        'previous_lock_at', v_prev_lock,
        'new_lock_at', now(),
        'loan_installments', v_loans,
        'month_lock_jobs', NULL,
        'lock_jobs_deferred', true,
        'calendar_pull_forward', v_pull,
        'warning', 'month_locked_but_calendar_pull_failed'
      );
    END IF;
  ELSE
    v_pull := NULL;
  END IF;

  RETURN v_preview || jsonb_build_object(
    'ended', true,
    'previous_lock_at', v_prev_lock,
    'new_lock_at', now(),
    'loan_installments', v_loans,
    'month_lock_jobs', NULL,
    'lock_jobs_deferred', true,
    'calendar_pull_forward', v_pull,
    'active_gpsl_month_after', public.competition_active_gpsl_month(v_season_id, now())
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_run_month_lock_jobs(bigint, boolean, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_admin_run_month_lock_jobs(bigint, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_end_gpsl_month_early(text, text, bigint, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
