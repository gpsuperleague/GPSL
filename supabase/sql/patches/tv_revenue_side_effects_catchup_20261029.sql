-- =============================================================================
-- TV revenue select + settle → durable month-lock side effects + catch-up
-- 2026-10-29
--
-- Expected:
--   July lock  → select August TV picks (league + cup per Admin settings)
--   August lock → select September TV picks
--   Settle pays tv_revenue when selected fixtures are played
--
-- Why it missed (same class as friendlies / vacant walkovers):
--   Soft-wired into calendar tick / month-lock jobs → wiped
--   Job key tv_select_next:<month> skipped forever once stamped (even at 0)
--   Not in competition_run_month_lock_side_effects
--
-- Fix: re-select when needed, durable side_effects, catch up now.
-- Safe re-run.
-- =============================================================================

-- Ensure settle helper exists
CREATE OR REPLACE FUNCTION public.competition_tv_settle_unpaid_played(
  p_season_id bigint,
  p_gpsl_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '90s'
AS $function$
DECLARE
  v_month text := nullif(lower(btrim(coalesce(p_gpsl_month, ''))), '');
  v_fixture_id bigint;
  v_scanned int := 0;
  v_settled int := 0;
  v_before int;
  v_after int;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.competition_tv_settle_fixture(bigint)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'settle_missing');
  END IF;

  FOR v_fixture_id IN
    SELECT f.id
    FROM public.competition_tv_fixture_selection s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE s.season_id = p_season_id
      AND f.season_id = p_season_id
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND (v_month IS NULL OR lower(f.gpsl_month) = v_month)
      AND NOT EXISTS (
        SELECT 1
        FROM public.competition_finance_ledger l
        WHERE l.fixture_id = f.id
          AND l.entry_type = 'tv_revenue'
      )
    ORDER BY f.gpsl_month, f.id
    LIMIT 80
  LOOP
    v_scanned := v_scanned + 1;

    SELECT count(*)::int INTO v_before
    FROM public.competition_finance_ledger l
    WHERE l.fixture_id = v_fixture_id
      AND l.entry_type = 'tv_revenue';

    BEGIN
      PERFORM public.competition_tv_settle_fixture(v_fixture_id);
    EXCEPTION WHEN OTHERS THEN
      CONTINUE;
    END;

    SELECT count(*)::int INTO v_after
    FROM public.competition_finance_ledger l
    WHERE l.fixture_id = v_fixture_id
      AND l.entry_type = 'tv_revenue';

    IF v_after > v_before THEN
      v_settled := v_settled + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'gpsl_month', v_month,
    'fixtures_scanned', v_scanned,
    'fixtures_settled', v_settled
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_tv_settle_unpaid_played(bigint, text)
  TO authenticated, service_role;

-- Month-lock TV: always attempt select for next month (do not skip forever)
CREATE OR REPLACE FUNCTION public.competition_tv_process_month_lock_selections(
  p_season_id bigint,
  p_locked_gpsl_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '90s'
AS $function$
DECLARE
  v_locked text;
  v_next text;
  v_div text;
  v_n int;
  v_month_total int;
  v_existing int;
  v_results jsonb := '[]'::jsonb;
  v_job_key text;
  v_div_result jsonb;
  v_div_errors jsonb;
  v_settle jsonb;
  v_err text;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.competition_tv_select_division_month(bigint,text,text,boolean)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'select_fn_missing');
  END IF;

  FOR v_locked IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
      AND (
        p_locked_gpsl_month IS NULL
        OR lower(btrim(c.gpsl_month)) = lower(btrim(p_locked_gpsl_month))
      )
    ORDER BY c.sort_order
  LOOP
    v_job_key := 'tv_select_next:' || v_locked;

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
    v_existing := 0;

    IF v_next IS NOT NULL THEN
      SELECT count(*)::int INTO v_existing
      FROM public.competition_tv_fixture_selection s
      WHERE s.season_id = p_season_id
        AND lower(btrim(s.gpsl_month)) = lower(btrim(v_next));

      -- Always attempt select (p_replace=false is additive / respects quotas)
      FOREACH v_div IN ARRAY ARRAY['superleague', 'championship_a', 'championship_b']
      LOOP
        BEGIN
          v_n := public.competition_tv_select_division_month(
            p_season_id, v_div, v_next, false
          );
          v_div_result := v_div_result || jsonb_build_object(v_div, v_n);
          v_month_total := v_month_total + coalesce(v_n, 0);
        EXCEPTION WHEN OTHERS THEN
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
        'fixtures_selected_this_run', v_month_total,
        'existing_before', v_existing,
        'division_errors', v_div_errors
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
        'fixtures_selected_this_run', v_month_total,
        'existing_before', v_existing,
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

-- Side-effect wrapper (season, locked_month)
CREATE OR REPLACE FUNCTION public.competition_tv_month_lock_side_effect(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '90s'
AS $function$
BEGIN
  RETURN public.competition_tv_process_month_lock_selections(p_season_id, p_gpsl_month);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_tv_month_lock_side_effect(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_tv_month_lock_side_effect(bigint, text)
  TO service_role;

INSERT INTO public.competition_month_lock_hooks (hook_key, sort_order, enabled, proc_name, notes)
VALUES (
  'tv_revenue',
  20,
  true,
  'competition_tv_month_lock_side_effect',
  'Select next-month TV (league+cup quotas) + settle unpaid played picks'
)
ON CONFLICT (hook_key) DO UPDATE
SET enabled = true,
    proc_name = EXCLUDED.proc_name,
    notes = EXCLUDED.notes;

-- Inject into durable side_effects
DO $side$
DECLARE
  v_oid oid;
  v_def text;
  v_insert text;
BEGIN
  v_oid := to_regprocedure('public.competition_run_month_lock_side_effects(bigint,text,text)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'side_effects missing — TV hook registered only';
    RETURN;
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('competition_tv_process_month_lock_selections' IN v_def) > 0
     OR position('competition_tv_month_lock_side_effect' IN v_def) > 0 THEN
    RAISE NOTICE 'TV already in side_effects';
    RETURN;
  END IF;

  v_insert :=
    E'\n    BEGIN\n'
    || E'      IF to_regprocedure(''public.competition_tv_month_lock_side_effect(bigint,text)'') IS NOT NULL THEN\n'
    || E'        v_res := public.competition_tv_month_lock_side_effect(p_season_id, v_month);\n'
    || E'        v_out := v_out || jsonb_build_object(''tv_revenue'', v_res);\n'
    || E'      ELSIF to_regprocedure(''public.competition_tv_process_month_lock_selections(bigint,text)'') IS NOT NULL THEN\n'
    || E'        v_res := public.competition_tv_process_month_lock_selections(p_season_id, v_month);\n'
    || E'        v_out := v_out || jsonb_build_object(''tv_revenue'', v_res);\n'
    || E'      END IF;\n'
    || E'    EXCEPTION WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''tv_revenue'', jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'    END;\n';

  IF position(E'FOR r IN\n    SELECT hook_key, proc_name\n    FROM public.competition_month_lock_hooks' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      E'FOR r IN\n    SELECT hook_key, proc_name\n    FROM public.competition_month_lock_hooks',
      v_insert || E'\n  FOR r IN\n    SELECT hook_key, proc_name\n    FROM public.competition_month_lock_hooks'
    );
  ELSIF position(E'v_out := v_out || jsonb_build_object(''stage'', v_stage);' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      E'v_out := v_out || jsonb_build_object(''stage'', v_stage);',
      v_insert || E'\n  v_out := v_out || jsonb_build_object(''stage'', v_stage);'
    );
  ELSE
    RAISE NOTICE 'Could not inject TV into side_effects body — hook remains';
    RETURN;
  END IF;

  IF position('''tv_revenue''' IN v_def) > 0
     AND position('hook_key NOT IN' IN v_def) > 0
     AND position('''tv_revenue''' IN substring(v_def from position('hook_key NOT IN' in v_def) for 200)) = 0 THEN
    v_def := replace(
      v_def,
      E'AND hook_key NOT IN (''friendlies_prizes'', ''vacant_walkovers'')',
      E'AND hook_key NOT IN (''friendlies_prizes'', ''vacant_walkovers'', ''tv_revenue'')'
    );
  ELSIF position('hook_key NOT IN' IN v_def) = 0 THEN
    v_def := replace(
      v_def,
      E'WHERE enabled\n    ORDER BY sort_order, hook_key',
      E'WHERE enabled\n      AND hook_key NOT IN (''friendlies_prizes'', ''vacant_walkovers'', ''tv_revenue'')\n    ORDER BY sort_order, hook_key'
    );
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'TV hardcoded into competition_run_month_lock_side_effects';
END;
$side$;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Diagnose (before catch-up)
-- ---------------------------------------------------------------------------
SELECT
  lower(btrim(s.gpsl_month)) AS gpsl_month,
  count(*) AS tv_picks,
  count(*) FILTER (WHERE f.status = 'played') AS played,
  count(*) FILTER (
    WHERE f.status = 'played'
      AND EXISTS (
        SELECT 1 FROM public.competition_finance_ledger l
        WHERE l.fixture_id = f.id AND l.entry_type = 'tv_revenue'
      )
  ) AS paid_tv
FROM public.competition_tv_fixture_selection s
JOIN public.competition_fixtures f ON f.id = s.fixture_id
WHERE s.season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
)
  AND lower(btrim(s.gpsl_month)) IN ('june','july','august','september','october')
GROUP BY 1
ORDER BY 1;

SELECT job_key, gpsl_month, ran_at,
       result->>'target_month' AS target_month,
       result->>'fixtures_selected' AS fixtures_selected,
       result->>'fixtures_selected_this_run' AS selected_this_run
FROM public.competition_season_calendar_jobs
WHERE season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
)
  AND job_key LIKE 'tv_select_next:%'
ORDER BY ran_at;

-- Catch up now (select missing months + settle unpaid)
SELECT public.competition_tv_process_month_lock_selections(
  (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1),
  NULL
) AS tv_catchup;

-- After
SELECT
  lower(btrim(s.gpsl_month)) AS gpsl_month,
  count(*) AS tv_picks,
  count(*) FILTER (WHERE f.status = 'played') AS played,
  count(*) FILTER (
    WHERE f.status = 'played'
      AND EXISTS (
        SELECT 1 FROM public.competition_finance_ledger l
        WHERE l.fixture_id = f.id AND l.entry_type = 'tv_revenue'
      )
  ) AS paid_tv
FROM public.competition_tv_fixture_selection s
JOIN public.competition_fixtures f ON f.id = s.fixture_id
WHERE s.season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
)
  AND lower(btrim(s.gpsl_month)) IN ('june','july','august','september','october')
GROUP BY 1
ORDER BY 1;

SELECT
  (position('tv_revenue' IN pg_get_functiondef(
    'public.competition_run_month_lock_side_effects(bigint,text,text)'::regprocedure
  )) > 0
  OR position('competition_tv_' IN pg_get_functiondef(
    'public.competition_run_month_lock_side_effects(bigint,text,text)'::regprocedure
  )) > 0) AS tv_in_side_effects,
  (SELECT enabled FROM public.competition_month_lock_hooks WHERE hook_key = 'tv_revenue')
    AS hook_enabled;
