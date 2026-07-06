-- =============================================================================
-- Admin: end the current GPSL month early (same lock jobs as cron month tick)
-- Run once in Supabase SQL Editor after calendar + scheduling + TOTM + sport patches.
-- =============================================================================

-- Shared month-lock job runner (idempotent; used by cron tick and admin early end)
CREATE OR REPLACE FUNCTION public.competition_run_month_lock_jobs(
  p_season_id bigint,
  p_force_scheduling boolean DEFAULT false
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
  v_response_track jsonb;
  v_sched_fines jsonb;
  v_response_fines jsonb;
  v_checkin_fines jsonb;
  v_last_scheduling timestamptz;
  v_run_scheduling boolean := false;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.competition_process_month_team_awards(bigint)') IS NOT NULL THEN
    v_totm := public.competition_process_month_team_awards(p_season_id);
    v_out := v_out || jsonb_build_object('team_of_month', v_totm);
  END IF;

  IF to_regprocedure('public.gpsl_sport_process_pending_editions(bigint)') IS NOT NULL THEN
    v_sport := public.gpsl_sport_process_pending_editions(p_season_id);
    v_out := v_out || jsonb_build_object('gpsl_sport', v_sport);
  END IF;

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
    IF to_regprocedure('public.competition_process_scheduling_response_deadlines(bigint)') IS NOT NULL THEN
      v_response_track := public.competition_process_scheduling_response_deadlines(p_season_id);
      v_out := v_out || jsonb_build_object('scheduling_response_deadlines', v_response_track);
    END IF;

    IF to_regprocedure('public.competition_process_scheduling_arrangement_fines(bigint)') IS NOT NULL THEN
      v_sched_fines := public.competition_process_scheduling_arrangement_fines(p_season_id);
      v_out := v_out || jsonb_build_object('scheduling_arrangement_fines', v_sched_fines);
    END IF;

    IF to_regprocedure('public.competition_process_scheduling_response_fines(bigint)') IS NOT NULL THEN
      v_response_fines := public.competition_process_scheduling_response_fines(p_season_id);
      v_out := v_out || jsonb_build_object('scheduling_response_fines', v_response_fines);
    END IF;

    IF to_regprocedure('public.competition_process_scheduling_checkin_fines(bigint)') IS NOT NULL THEN
      v_checkin_fines := public.competition_process_scheduling_checkin_fines(p_season_id);
      v_out := v_out || jsonb_build_object('scheduling_checkin_fines', v_checkin_fines);
    END IF;

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      p_season_id,
      'scheduling_enforcement_throttle',
      coalesce(public.competition_active_gpsl_month(p_season_id, now()), 'none'),
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

CREATE OR REPLACE FUNCTION public.competition_admin_end_gpsl_month_preview(
  p_gpsl_month text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_cal record;
  v_unplayed_league int := 0;
  v_unplayed_cup int := 0;
  v_pending_submissions int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

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

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_season_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_calendar', 'season_id', v_season_id);
  END IF;

  v_month := nullif(lower(btrim(coalesce(p_gpsl_month, ''))), '');
  IF v_month IS NULL THEN
    v_month := public.competition_active_gpsl_month(v_season_id, now());
  END IF;

  IF v_month IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_active_month',
      'season_id', v_season_id,
      'confirm_phrase', 'END GPSL MONTH'
    );
  END IF;

  SELECT *
  INTO v_cal
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season_id
    AND c.gpsl_month = v_month;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_not_on_calendar',
      'gpsl_month', v_month
    );
  END IF;

  SELECT count(*)::int
  INTO v_unplayed_league
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season_id
    AND f.gpsl_month = v_month
    AND f.competition_type = 'league'
    AND f.status <> 'played';

  SELECT count(*)::int
  INTO v_unplayed_cup
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season_id
    AND f.gpsl_month = v_month
    AND f.competition_type = 'cup'
    AND f.status <> 'played';

  SELECT count(*)::int
  INTO v_pending_submissions
  FROM public.competition_result_submissions s
  JOIN public.competition_fixtures f ON f.id = s.fixture_id
  WHERE f.season_id = v_season_id
    AND f.gpsl_month = v_month
    AND s.status = 'pending';

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'gpsl_month_label', public.competition_gpsl_month_label(v_month),
    'unlock_at', v_cal.unlock_at,
    'lock_at', v_cal.lock_at,
    'is_live', (now() >= v_cal.unlock_at AND now() < v_cal.lock_at),
    'is_already_locked', (now() >= v_cal.lock_at),
    'unplayed_league', v_unplayed_league,
    'unplayed_cup', v_unplayed_cup,
    'pending_submissions', v_pending_submissions,
    'confirm_phrase', 'END GPSL MONTH',
    'jobs', jsonb_build_array(
      'calendar_lock',
      'loan_installments_due',
      'team_of_month',
      'gpsl_sport_edition',
      'scheduling_response_deadlines',
      'scheduling_arrangement_fines',
      'scheduling_response_fines',
      'scheduling_checkin_no_show_forfeits'
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_end_gpsl_month_early(
  p_confirm_phrase text,
  p_gpsl_month text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
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
  v_jobs jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF coalesce(btrim(p_confirm_phrase), '') <> 'END GPSL MONTH' THEN
    RAISE EXCEPTION 'Confirmation phrase required — type exactly: END GPSL MONTH';
  END IF;

  v_preview := public.competition_admin_end_gpsl_month_preview(p_gpsl_month, p_season_id);

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

  IF to_regprocedure('public.competition_admin_process_loan_installments(bigint,text)') IS NOT NULL THEN
    v_loans := public.competition_admin_process_loan_installments(v_season_id, v_month);
  ELSE
    v_loans := jsonb_build_object('skipped', true, 'reason', 'loan_rpc_missing');
  END IF;

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

  v_jobs := public.competition_run_month_lock_jobs(v_season_id, true);

  RETURN v_preview || jsonb_build_object(
    'ended', true,
    'previous_lock_at', v_prev_lock,
    'new_lock_at', now(),
    'loan_installments', v_loans,
    'month_lock_jobs', v_jobs
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_run_month_lock_jobs(bigint, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_admin_end_gpsl_month_preview(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_end_gpsl_month_early(text, text, bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
