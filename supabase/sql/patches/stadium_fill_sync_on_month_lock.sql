-- =============================================================================
-- Auto-sync stadium monthly fill drift when month-lock jobs run (tables stage).
--
-- Prefer re-running competition_admin_month_lock_jobs_staged.sql (includes this).
-- This smaller patch only wraps competition_admin_run_month_lock_jobs so End Month
-- / Retry jobs pick up fill sync without re-applying the full staged runner.
-- Safe re-run: drift steps are 0 when last_month already matches active month.
-- =============================================================================

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
  v_stadium_clubs int;
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

  v_out := public.competition_run_month_lock_jobs(
    v_season_id,
    coalesce(p_force_scheduling, true),
    p_gpsl_month,
    p_stage
  );

  -- If the staged runner already synced (has stadium_fill_sync key), do not double-call.
  IF v_out ? 'stadium_fill_sync' THEN
    RETURN v_out;
  END IF;

  -- Mirror staged behaviour: sync after tables / full run (and optional stadium stage).
  IF v_stage IS NULL
     OR v_stage IN ('all', 'tables', 'league_tables', 'stadium', 'attendance')
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

  RETURN v_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_run_month_lock_jobs(bigint, text, boolean, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
