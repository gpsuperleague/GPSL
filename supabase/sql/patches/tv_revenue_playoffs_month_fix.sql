-- =============================================================================
-- Fix: May lock → TV select for Playoffs violates gpsl_month check
--
-- Symptom (End May early):
--   Warnings: new row for relation "competition_tv_fixture_selection"
--   violates check constraint "competition_tv_fixture_selection_gpsl_month_check"
--   Retry month-lock jobs → 500 on competition_admin_run_month_lock_jobs
--
-- Cause: calendar next month after May is `playoffs`, but TV selection table
-- still only allows august–may. Cup-final TV inserts in playoffs week would
-- hit the same wall.
--
-- Fix:
--   1) Allow `playoffs` on competition_tv_fixture_selection.gpsl_month
--   2) Harden competition_tv_process_month_lock_selections:
--        • per-division try/catch (one division fail ≠ abort May lock jobs)
--        • always record tv_select_next:<locked> job (even if 0 selected)
--        • still settle unpaid TV after
-- Safe re-run. Then Retry May month-lock jobs (TV stage).
-- =============================================================================

ALTER TABLE public.competition_tv_fixture_selection
  DROP CONSTRAINT IF EXISTS competition_tv_fixture_selection_gpsl_month_check;

ALTER TABLE public.competition_tv_fixture_selection
  ADD CONSTRAINT competition_tv_fixture_selection_gpsl_month_check
  CHECK (
    gpsl_month IN (
      'august', 'september', 'october', 'november', 'december',
      'january', 'february', 'march', 'april', 'may', 'playoffs'
    )
  );

CREATE OR REPLACE FUNCTION public.competition_tv_process_month_lock_selections(
  p_season_id bigint,
  p_locked_gpsl_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_locked text;
  v_next text;
  v_div text;
  v_n int;
  v_month_total int;
  v_results jsonb := '[]'::jsonb;
  v_job_key text;
  v_div_result jsonb;
  v_div_errors jsonb := '{}'::jsonb;
  v_settle jsonb;
  v_err text;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_locked IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
      AND (p_locked_gpsl_month IS NULL OR c.gpsl_month = p_locked_gpsl_month)
    ORDER BY c.sort_order
  LOOP
    v_job_key := 'tv_select_next:' || v_locked;

    IF EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id
        AND j.job_key = v_job_key
    ) THEN
      CONTINUE;
    END IF;

    SELECT c2.gpsl_month
    INTO v_next
    FROM public.competition_season_calendar c2
    WHERE c2.season_id = p_season_id
      AND c2.sort_order > (
        SELECT c0.sort_order
        FROM public.competition_season_calendar c0
        WHERE c0.season_id = p_season_id
          AND c0.gpsl_month = v_locked
      )
    ORDER BY c2.sort_order
    LIMIT 1;

    v_div_result := '{}'::jsonb;
    v_div_errors := '{}'::jsonb;
    v_month_total := 0;

    IF v_next IS NOT NULL THEN
      FOREACH v_div IN ARRAY ARRAY['superleague', 'championship_a', 'championship_b']
      LOOP
        BEGIN
          v_n := public.competition_tv_select_division_month(
            p_season_id, v_div, v_next, false
          );
          v_div_result := v_div_result || jsonb_build_object(v_div, v_n);
          v_month_total := v_month_total + coalesce(v_n, 0);
        EXCEPTION
          WHEN OTHERS THEN
            v_err := SQLERRM;
            v_div_result := v_div_result || jsonb_build_object(v_div, 0);
            v_div_errors := v_div_errors || jsonb_build_object(v_div, v_err);
        END;
      END LOOP;
    END IF;

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      p_season_id,
      v_job_key,
      v_locked,
      jsonb_build_object(
        'ok', true,
        'locked_month', v_locked,
        'target_month', v_next,
        'selected_by_division', v_div_result,
        'fixtures_selected', v_month_total,
        'division_errors', v_div_errors,
        'note', CASE
          WHEN v_next = 'playoffs' THEN
            'Playoffs week: league TV quota usually 0; cup/playoff ties may still be selected'
          ELSE NULL
        END
      )
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();

    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'locked_month', v_locked,
        'target_month', v_next,
        'selected_by_division', v_div_result,
        'fixtures_selected', v_month_total,
        'division_errors', v_div_errors
      )
    );
  END LOOP;

  IF to_regprocedure('public.competition_tv_settle_unpaid_played(bigint,text)') IS NOT NULL THEN
    v_settle := public.competition_tv_settle_unpaid_played(p_season_id, NULL);
  ELSE
    v_settle := jsonb_build_object('skipped', true, 'reason', 'settle_unpaid_missing');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'processed', v_results,
    'tv_settle', v_settle
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_tv_process_month_lock_selections(bigint, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- After running: Admin → End Month → Retry May month-lock jobs
-- Or: SELECT public.competition_tv_process_month_lock_selections(
--        (SELECT id FROM competition_seasons WHERE is_current LIMIT 1), 'may');
