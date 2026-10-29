-- =============================================================================
-- Month-lock scheduling effects → durable side_effects (2026-10-29)
--
-- Live check: arrangement fines / window awards / deadline warnings were NOT
-- in competition_run_month_lock_jobs (soft-wires wiped again). Response
-- deadlines alone were still present.
--
-- Put scheduling into competition_run_month_lock_side_effects so admin/complete
-- entry points always run them. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_month_lock_scheduling_effects(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_out jsonb := jsonb_build_object('ok', true, 'gpsl_month', nullif(v_month, ''));
  v_res jsonb;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'season_id required');
  END IF;

  -- Arrangement fines (no proposal / late proposal) for the locked month
  IF v_month <> ''
     AND to_regprocedure('public.competition_enforce_scheduling_arrangement_fines(bigint,text)') IS NOT NULL THEN
    BEGIN
      v_res := public.competition_enforce_scheduling_arrangement_fines(p_season_id, v_month);
      v_out := v_out || jsonb_build_object('arrangement_fines', v_res);
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'arrangement_fines', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;
  END IF;

  -- Response overdue warn → fine
  IF to_regprocedure('public.competition_process_scheduling_response_deadlines(bigint)') IS NOT NULL THEN
    BEGIN
      v_res := public.competition_process_scheduling_response_deadlines(p_season_id);
      v_out := v_out || jsonb_build_object('response_deadlines', v_res);
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'response_deadlines', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;
  END IF;

  -- Window awards (activity / unplayed at lock)
  IF to_regprocedure('public.competition_process_scheduling_window_awards(bigint)') IS NOT NULL THEN
    BEGIN
      v_res := public.competition_process_scheduling_window_awards(p_season_id);
      v_out := v_out || jsonb_build_object('window_awards', v_res);
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'window_awards', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;
  END IF;

  -- Upcoming deadline warnings (inbox) — copy may still be stale; run anyway
  IF to_regprocedure('public.competition_notify_scheduling_deadline_warnings(bigint)') IS NOT NULL THEN
    BEGIN
      v_res := public.competition_notify_scheduling_deadline_warnings(p_season_id);
      v_out := v_out || jsonb_build_object('deadline_warnings', v_res);
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'deadline_warnings', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;
  END IF;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_month_lock_scheduling_effects(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_month_lock_scheduling_effects(bigint, text)
  TO service_role;

-- Extend durable side_effects with scheduling (keep finance block intact)
CREATE OR REPLACE FUNCTION public.competition_run_month_lock_side_effects(
  p_season_id bigint,
  p_gpsl_month text,
  p_stage text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_stage text := lower(btrim(coalesce(p_stage, 'all')));
  v_out jsonb := jsonb_build_object('ok', true, 'gpsl_month', nullif(v_month, ''));
  v_res jsonb;
  r record;
  v_reg text;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'season_id required');
  END IF;

  IF v_month = '' THEN
    BEGIN
      v_month := lower(coalesce(
        public.competition_active_gpsl_month(p_season_id, now()), ''
      ));
    EXCEPTION WHEN OTHERS THEN
      v_month := '';
    END;
  END IF;
  v_out := v_out || jsonb_build_object('gpsl_month', nullif(v_month, ''));

  IF v_month <> '' THEN
    BEGIN
      IF to_regprocedure('public.club_balance_snapshot_gpsl_month(bigint,text)') IS NOT NULL THEN
        v_res := public.club_balance_snapshot_gpsl_month(p_season_id, v_month);
        v_out := v_out || jsonb_build_object('balance_snapshot', v_res);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'balance_snapshot', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;

    BEGIN
      IF to_regprocedure('public.competition_post_monthly_interest(bigint,text)') IS NOT NULL THEN
        v_res := public.competition_post_monthly_interest(p_season_id, v_month);
        v_out := v_out || jsonb_build_object('monthly_interest', v_res);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'monthly_interest', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;

    BEGIN
      IF to_regprocedure('public.club_credit_probation_tick(bigint)') IS NOT NULL THEN
        PERFORM public.club_credit_probation_tick(p_season_id);
        v_out := v_out || jsonb_build_object('credit_probation', jsonb_build_object('ok', true));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'credit_probation', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;

    -- Scheduling (arrange fines / response / window awards / warnings)
    BEGIN
      IF to_regprocedure('public.competition_month_lock_scheduling_effects(bigint,text)') IS NOT NULL THEN
        v_res := public.competition_month_lock_scheduling_effects(p_season_id, v_month);
        v_out := v_out || jsonb_build_object('scheduling', v_res);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'scheduling', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;
  END IF;

  FOR r IN
    SELECT hook_key, proc_name
    FROM public.competition_month_lock_hooks
    WHERE enabled
    ORDER BY sort_order, hook_key
  LOOP
    BEGIN
      v_reg := format('public.%I(bigint,text)', r.proc_name);
      IF to_regprocedure(v_reg) IS NULL OR v_month = '' THEN
        CONTINUE;
      END IF;
      EXECUTE format('SELECT public.%I($1, $2)', r.proc_name)
        INTO v_res
        USING p_season_id, v_month;
      v_out := v_out || jsonb_build_object(r.hook_key, v_res);
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        r.hook_key, jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;
  END LOOP;

  v_out := v_out || jsonb_build_object('stage', v_stage);
  RETURN v_out;
END;
$function$;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.competition_month_lock_scheduling_effects(bigint,text)') IS NOT NULL
    AS scheduling_effects_fn,
  (position('competition_month_lock_scheduling_effects' IN pg_get_functiondef(
    'public.competition_run_month_lock_side_effects(bigint,text,text)'::regprocedure
  )) > 0) AS scheduling_in_side_effects;
