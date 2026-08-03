-- =============================================================================
-- Deploy Test Month — harden against statement / API timeouts (Nov etc.)
--
-- Problem: admin_testing_deploy_month_discipline.sql reintroduced a 120s
-- timeout and an expensive remaining_ready count (per-fixture squad checks).
-- Batches of 5 then roll back entirely on timeout → mid-month stuck.
--
-- This patch restores the timeout-fix behaviour AND keeps discipline seeding:
--   • statement_timeout 180s
--   • skip clinch during batch; one clinch pass at end (if any league deployed)
--   • cheap scheduled_left count (no availability scans)
--   • default / max batch size = 2 (UI should send 1)
-- Safe re-run. Prefer this over re-running the older timeout_fix alone.
-- =============================================================================

-- Clinch skip wrapper (idempotent)
DO $$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.competition_process_league_clinches(bigint)') IS NULL THEN
    RAISE NOTICE 'competition_process_league_clinches missing — skip wrap';
    RETURN;
  END IF;

  SELECT pg_get_functiondef('public.competition_process_league_clinches(bigint)'::regprocedure)
  INTO v_def;

  IF v_def LIKE '%competition_process_league_clinches_impl%' THEN
    RETURN;
  END IF;

  IF v_def LIKE '%gpsl.skip_clinch_scan%' THEN
    RETURN;
  END IF;

  IF to_regprocedure('public.competition_process_league_clinches_impl(bigint)') IS NOT NULL THEN
    DROP FUNCTION public.competition_process_league_clinches_impl(bigint);
  END IF;

  ALTER FUNCTION public.competition_process_league_clinches(bigint)
    RENAME TO competition_process_league_clinches_impl;

  EXECUTE $wrap$
    CREATE OR REPLACE FUNCTION public.competition_process_league_clinches(
      p_season_id bigint DEFAULT NULL
    )
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public
    AS $function$
    BEGIN
      IF current_setting('gpsl.skip_clinch_scan', true) = 'on' THEN
        RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'bulk_deploy');
      END IF;

      RETURN public.competition_process_league_clinches_impl(p_season_id);
    END;
    $function$;
  $wrap$;

  GRANT EXECUTE ON FUNCTION public.competition_process_league_clinches(bigint)
    TO authenticated, service_role;
END $$;

CREATE OR REPLACE FUNCTION public.admin_testing_deploy_month_results(
  p_gpsl_month text,
  p_confirm_phrase text DEFAULT NULL,
  p_limit integer DEFAULT NULL,
  p_after_fixture_id bigint DEFAULT NULL,
  p_include_details boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(trim(p_gpsl_month));
  v_season_id bigint;
  v_fixture record;
  v_deployed jsonb := '[]'::jsonb;
  v_errors jsonb := '[]'::jsonb;
  v_error_summary jsonb := '{}'::jsonb;
  v_result jsonb;
  v_league_deployed int := 0;
  v_cup_deployed int := 0;
  v_batch_count int := 0;
  v_last_fixture_id bigint;
  v_has_more boolean := false;
  v_remaining int := 0;
  v_scheduled_left int := 0;
  v_discipline jsonb := NULL;
  v_clinches jsonb := NULL;
  -- Cap hard at 2 — larger batches time out and roll back the whole RPC
  v_limit int := greatest(1, least(coalesce(p_limit, 1), 2));
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_after_fixture_id IS NULL
     AND coalesce(trim(p_confirm_phrase), '') <> 'DEPLOY TEST MONTH' THEN
    RAISE EXCEPTION 'Confirmation phrase required — type exactly: DEPLOY TEST MONTH';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);
  PERFORM set_config('gpsl.skip_clinch_scan', 'on', true);

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season';
  END IF;

  FOR v_fixture IN
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND f.gpsl_month = v_month
      AND f.status = 'scheduled'
      AND f.competition_type IN ('league', 'cup')
      AND (p_after_fixture_id IS NULL OR f.id > p_after_fixture_id)
    ORDER BY
      CASE f.competition_type WHEN 'league' THEN 0 ELSE 1 END,
      f.cup_code NULLS FIRST,
      f.cup_round NULLS FIRST,
      f.cup_match NULLS FIRST,
      f.matchday,
      f.division,
      f.id
    LIMIT v_limit
  LOOP
    v_batch_count := v_batch_count + 1;
    v_last_fixture_id := v_fixture.id;

    BEGIN
      v_result := public.admin_testing_deploy_scheduled_fixture(v_fixture.id);
      IF coalesce(p_include_details, false) THEN
        v_deployed := v_deployed || jsonb_build_array(v_result);
      END IF;
      IF v_fixture.competition_type = 'cup' THEN
        v_cup_deployed := v_cup_deployed + 1;
      ELSE
        v_league_deployed := v_league_deployed + 1;
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'fixture_id', v_fixture.id,
          'competition_type', v_fixture.competition_type,
          'cup_code', v_fixture.cup_code,
          'error', SQLERRM
        ));
    END;
  END LOOP;

  -- One clinch scan for the whole batch (not per fixture)
  PERFORM set_config('gpsl.skip_clinch_scan', 'off', true);
  IF v_league_deployed > 0
     AND to_regprocedure('public.competition_process_league_clinches(bigint)') IS NOT NULL THEN
    BEGIN
      v_clinches := public.competition_process_league_clinches(v_season_id);
    EXCEPTION WHEN OTHERS THEN
      v_clinches := jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  IF v_last_fixture_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND f.gpsl_month = v_month
        AND f.status = 'scheduled'
        AND f.competition_type IN ('league', 'cup')
        AND f.id > v_last_fixture_id
    )
    INTO v_has_more;
  END IF;

  -- Cheap remaining count (do NOT call admin_testing_fixture_squads_ready here)
  SELECT count(*)::int
  INTO v_scheduled_left
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season_id
    AND f.gpsl_month = v_month
    AND f.status = 'scheduled'
    AND f.competition_type IN ('league', 'cup');

  v_remaining := v_scheduled_left;

  IF coalesce(v_scheduled_left, 0) = 0
     AND to_regprocedure('public.admin_testing_seed_month_discipline(bigint,text,int,int)') IS NOT NULL THEN
    BEGIN
      v_discipline := public.admin_testing_seed_month_discipline(
        v_season_id, v_month, 15, 1
      );
    EXCEPTION
      WHEN OTHERS THEN
        v_discipline := jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  SELECT coalesce(jsonb_object_agg(err, cnt), '{}'::jsonb)
  INTO v_error_summary
  FROM (
    SELECT elem ->> 'error' AS err, count(*)::int AS cnt
    FROM jsonb_array_elements(v_errors) elem
    GROUP BY 1
  ) s;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'gpsl_month_label', public.competition_gpsl_month_label(v_month),
    'season_id', v_season_id,
    'deployed_count', v_league_deployed + v_cup_deployed,
    'league_deployed_count', v_league_deployed,
    'cup_deployed_count', v_cup_deployed,
    'error_count', jsonb_array_length(v_errors),
    'error_summary', v_error_summary,
    'batch_count', v_batch_count,
    'batch_limit', v_limit,
    'has_more', coalesce(v_has_more, false),
    'next_after_fixture_id', v_last_fixture_id,
    'remaining_ready', v_remaining,
    'scheduled_left', v_scheduled_left,
    'discipline', v_discipline,
    'clinches', v_clinches,
    'deployed', CASE WHEN coalesce(p_include_details, false) THEN v_deployed ELSE NULL END,
    'errors', v_errors
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_testing_deploy_month_results(text, text, integer, bigint, boolean)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
