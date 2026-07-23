-- =============================================================================
-- Month-lock: playoff brackets + Discord ONLY when locking May.
-- Stops "PLAYOFFS — brackets are live" on June/July/etc. End Month Early.
--
-- Run order:
--   1) This file (installs the May gate helper)
--   2) competition_admin_month_lock_jobs_staged.sql (wires the helper into jobs)
--   3) Optional: manager_of_the_month.sql if you use MotM on month lock
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_month_lock_try_generate_playoffs(
  p_season_id bigint,
  p_locked_gpsl_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := nullif(lower(btrim(coalesce(p_locked_gpsl_month, ''))), '');
BEGIN
  IF v_month IS DISTINCT FROM 'may' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'playoffs_only_on_may_lock',
      'gpsl_month', v_month
    );
  END IF;

  IF to_regprocedure('public.competition_generate_playoffs(bigint,boolean)') IS NOT NULL THEN
    RETURN public.competition_generate_playoffs(p_season_id, false);
  END IF;

  IF to_regprocedure('public.admin_competition_generate_playoffs(bigint,boolean)') IS NOT NULL THEN
    RETURN public.admin_competition_generate_playoffs(p_season_id, false);
  END IF;

  RETURN jsonb_build_object('skipped', true, 'reason', 'playoffs_rpc_missing');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_month_lock_try_generate_playoffs(bigint, text)
  TO authenticated, service_role;

-- Also gate the admin wrapper so an explicit playoffs stage on a non-May month
-- cannot bypass (even if an older competition_run_month_lock_jobs is still live).
CREATE OR REPLACE FUNCTION public.competition_admin_run_month_lock_jobs(
  p_season_id bigint DEFAULT NULL,
  p_gpsl_month text DEFAULT NULL,
  p_force_scheduling boolean DEFAULT true,
  p_stage text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_out jsonb;
  v_stage text := lower(nullif(btrim(coalesce(p_stage, '')), ''));
  v_month text := nullif(lower(btrim(coalesce(p_gpsl_month, ''))), '');
  v_stadium_clubs int;
  v_motm jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '240s', true);

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

  -- Explicit playoffs stage on non-May → skip (no Discord / no generate)
  IF v_stage = 'playoffs' AND v_month IS DISTINCT FROM 'may' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'stage', 'playoffs',
      'season_id', v_season_id,
      'playoffs', jsonb_build_object(
        'ok', true,
        'skipped', true,
        'reason', 'playoffs_only_on_may_lock',
        'gpsl_month', v_month
      )
    );
  END IF;

  -- Full 'all' run on non-May: run every stage except playoffs
  IF (v_stage IS NULL OR v_stage = 'all') AND v_month IS DISTINCT FROM 'may' THEN
    v_out := jsonb_build_object('ok', true, 'season_id', v_season_id, 'stage', coalesce(v_stage, 'all'));
    v_out := v_out || public.competition_run_month_lock_jobs(
      v_season_id, coalesce(p_force_scheduling, true), p_gpsl_month, 'totm'
    );
    v_out := v_out || public.competition_run_month_lock_jobs(
      v_season_id, coalesce(p_force_scheduling, true), p_gpsl_month, 'sport'
    );
    v_out := v_out || public.competition_run_month_lock_jobs(
      v_season_id, coalesce(p_force_scheduling, true), p_gpsl_month, 'tv'
    );
    v_out := v_out || public.competition_run_month_lock_jobs(
      v_season_id, coalesce(p_force_scheduling, true), p_gpsl_month, 'tables'
    );
    v_out := v_out || jsonb_build_object(
      'playoffs', jsonb_build_object(
        'ok', true,
        'skipped', true,
        'reason', 'playoffs_only_on_may_lock',
        'gpsl_month', v_month
      )
    );
    v_out := v_out || public.competition_run_month_lock_jobs(
      v_season_id, coalesce(p_force_scheduling, true), p_gpsl_month, 'clinches'
    );
    v_out := v_out || public.competition_run_month_lock_jobs(
      v_season_id, true, p_gpsl_month, 'scheduling'
    );
  ELSE
    v_out := public.competition_run_month_lock_jobs(
      v_season_id,
      coalesce(p_force_scheduling, true),
      p_gpsl_month,
      p_stage
    );
  END IF;

  -- Stadium fill (if staged runner did not already)
  IF NOT (v_out ? 'stadium_fill_sync')
     AND (
       v_stage IS NULL
       OR v_stage IN ('all', 'tables', 'league_tables', 'stadium', 'attendance')
     )
  THEN
    BEGIN
      IF to_regprocedure('public.competition_stadium_sync_all_clubs(bigint)') IS NOT NULL THEN
        v_stadium_clubs := public.competition_stadium_sync_all_clubs(v_season_id);
        v_out := v_out || jsonb_build_object(
          'stadium_fill_sync',
          jsonb_build_object('ok', true, 'clubs', v_stadium_clubs)
        );
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'stadium_fill_sync',
          jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;
  END IF;

  -- Manager of the Month after tables / full run (if MotM RPC exists)
  IF to_regprocedure('public.competition_compute_manager_of_month(bigint,text)') IS NOT NULL
     AND (
       v_stage IS NULL
       OR v_stage IN ('all', 'tables', 'league_tables', 'motm', 'manager_of_month')
     )
  THEN
    BEGIN
      IF v_month IS NULL THEN
        SELECT c.gpsl_month INTO v_month
        FROM public.competition_season_calendar c
        WHERE c.season_id = v_season_id
          AND c.gpsl_month IS NOT NULL
          AND c.gpsl_month <> 'playoffs'
          AND c.lock_at IS NOT NULL
          AND c.lock_at <= now()
        ORDER BY c.lock_at DESC
        LIMIT 1;
      END IF;

      IF v_month IS NOT NULL THEN
        v_motm := public.competition_compute_manager_of_month(v_season_id, v_month);
        v_out := v_out || jsonb_build_object('manager_of_month', v_motm);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'manager_of_month', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;
  END IF;

  RETURN v_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_run_month_lock_jobs(bigint, text, boolean, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
