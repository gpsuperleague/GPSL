-- =============================================================================
-- Forward fix: pay TV revenue on Deploy Month + automatic month-end tick
--
-- Gaps:
--   1) admin_testing_deploy_scheduled_fixture / deploy_fixture_result settle
--      gates + cup prizes but never call competition_tv_settle_fixture
--   2) Month lock only SELECTS next-month TV picks — does not settle unpaid
--   3) competition_calendar_month_tick (cron / transferengine) often never
--      runs TV selection or settle
--
-- This patch:
--   • competition_tv_settle_unpaid_played — idempotent settle of selected+played
--   • competition_tv_process_month_lock_selections — still selects next month,
--     then settles unpaid for the locked month(s) + season backlog
--   • Injects settle into live deploy fixture RPCs
--   • Injects TV select+settle into live competition_calendar_month_tick
--
-- Safe re-run. Does NOT backfill Season 2 history — use
-- season2_tv_revenue_backfill.sql (or Admin → TV Revenue → Backfill) for that.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_tv_settle_unpaid_played(
  p_season_id bigint,
  p_gpsl_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
  LOOP
    v_scanned := v_scanned + 1;

    SELECT count(*)::int INTO v_before
    FROM public.competition_finance_ledger l
    WHERE l.fixture_id = v_fixture_id
      AND l.entry_type = 'tv_revenue';

    BEGIN
      PERFORM public.competition_tv_settle_fixture(v_fixture_id);
    EXCEPTION
      WHEN OTHERS THEN
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

-- Select next month (unchanged) + settle unpaid for locked month + season backlog
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
  v_settle jsonb;
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
    v_month_total := 0;

    IF v_next IS NOT NULL THEN
      FOREACH v_div IN ARRAY ARRAY['superleague', 'championship_a', 'championship_b']
      LOOP
        v_n := public.competition_tv_select_division_month(p_season_id, v_div, v_next, false);
        v_div_result := v_div_result || jsonb_build_object(v_div, v_n);
        v_month_total := v_month_total + v_n;
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
        'fixtures_selected', v_month_total
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
        'selected_by_division', v_div_result
      )
    );
  END LOOP;

  -- Safety net: pay any selected+played fixtures still missing tv_revenue
  -- (Deploy Month misses, late selection, confirm-path gaps). Idempotent.
  v_settle := public.competition_tv_settle_unpaid_played(p_season_id, NULL);

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'processed', v_results,
    'tv_settle', v_settle
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_tv_process_month_lock_selections(bigint, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Inject TV settle into Deploy Month fixture RPCs (live definitions)
-- ---------------------------------------------------------------------------
DO $inject_deploy$
DECLARE
  v_reg regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  FOREACH v_reg IN ARRAY ARRAY[
    'public.admin_testing_deploy_scheduled_fixture(bigint)'::regprocedure,
    'public.admin_testing_deploy_fixture_result(bigint,smallint,smallint)'::regprocedure
  ]
  LOOP
    BEGIN
      SELECT pg_get_functiondef(v_reg) INTO v_def;
    EXCEPTION
      WHEN undefined_function THEN
        CONTINUE;
    END;

    IF v_def IS NULL THEN
      CONTINUE;
    END IF;

    IF position('competition_tv_settle_fixture' IN v_def) > 0 THEN
      RAISE NOTICE '% already settles TV — skip', v_reg;
      CONTINUE;
    END IF;

    IF position('competition_settle_fixture_gates(p_fixture_id)' IN v_def) = 0 THEN
      RAISE NOTICE '% has no gate settle — skip TV inject', v_reg;
      CONTINUE;
    END IF;

    v_old := 'PERFORM public.competition_settle_fixture_gates(p_fixture_id);';
    v_new :=
      'PERFORM public.competition_settle_fixture_gates(p_fixture_id);'
      || E'\n    PERFORM public.competition_tv_settle_fixture(p_fixture_id);';

    -- Prefer soft-fail TV inside existing BEGIN/EXCEPTION gate block when present
    IF position('BEGIN' IN v_def) > 0
       AND position('v_gate_err' IN v_def) > 0 THEN
      v_new :=
        'PERFORM public.competition_settle_fixture_gates(p_fixture_id);'
        || E'\n    BEGIN'
        || E'\n      PERFORM public.competition_tv_settle_fixture(p_fixture_id);'
        || E'\n    EXCEPTION'
        || E'\n      WHEN OTHERS THEN'
        || E'\n        NULL;'
        || E'\n    END;';
    END IF;

    v_def := replace(v_def, v_old, v_new);

    IF position('competition_tv_settle_fixture' IN v_def) = 0 THEN
      RAISE NOTICE 'Could not inject TV settle into %', v_reg;
      CONTINUE;
    END IF;

    EXECUTE v_def;
    RAISE NOTICE 'Injected TV settle into %', v_reg;
  END LOOP;
END;
$inject_deploy$;

-- ---------------------------------------------------------------------------
-- Inject TV select + unpaid settle into live calendar month tick (auto cron)
-- ---------------------------------------------------------------------------
DO $inject_tick$
DECLARE
  v_def text;
  v_needle text;
  v_insert text;
BEGIN
  BEGIN
    SELECT pg_get_functiondef('public.competition_calendar_month_tick()'::regprocedure)
    INTO v_def;
  EXCEPTION
    WHEN undefined_function THEN
      RAISE NOTICE 'competition_calendar_month_tick missing — skip';
      RETURN;
  END;

  IF v_def IS NULL THEN
    RETURN;
  END IF;

  IF position('competition_tv_settle_unpaid_played' IN v_def) > 0
     OR position('tv_revenue_tick' IN v_def) > 0 THEN
    RAISE NOTICE 'calendar_month_tick already has TV settle — skip';
    RETURN;
  END IF;

  -- Insert after initial v_out payload (works across tick variants)
  v_needle :=
    '''calendar_phase'', CASE'
    || E'\n      WHEN v_month IS NULL THEN ''between_months'''
    || E'\n      ELSE ''in_month'''
    || E'\n    END'
    || E'\n  );';

  IF position(v_needle IN v_def) = 0 THEN
    -- Looser fallback
    v_needle := 'END' || E'\n  );';
    IF position('''calendar_phase''' IN v_def) = 0 THEN
      RAISE NOTICE 'Could not locate calendar_phase block — skip tick inject';
      RETURN;
    END IF;
  END IF;

  v_insert :=
    v_needle
    || E'\n\n  -- TV: select next month on lock + settle unpaid selected fixtures'
    || E'\n  BEGIN'
    || E'\n    IF to_regprocedure(''public.competition_tv_process_month_lock_selections(bigint,text)'') IS NOT NULL THEN'
    || E'\n      v_out := v_out || jsonb_build_object('
    || E'\n        ''tv_selection'','
    || E'\n        public.competition_tv_process_month_lock_selections(v_season_id, NULL)'
    || E'\n      );'
    || E'\n    ELSIF to_regprocedure(''public.competition_tv_settle_unpaid_played(bigint,text)'') IS NOT NULL THEN'
    || E'\n      v_out := v_out || jsonb_build_object('
    || E'\n        ''tv_revenue_tick'','
    || E'\n        public.competition_tv_settle_unpaid_played(v_season_id, NULL)'
    || E'\n      );'
    || E'\n    END IF;'
    || E'\n  EXCEPTION'
    || E'\n    WHEN OTHERS THEN'
    || E'\n      v_out := v_out || jsonb_build_object('
    || E'\n        ''tv_revenue_tick'','
    || E'\n        jsonb_build_object(''ok'', false, ''error'', SQLERRM)'
    || E'\n      );'
    || E'\n  END;';

  IF position(v_needle IN v_def) > 0 THEN
    v_def := replace(v_def, v_needle, v_insert);
  ELSE
    -- Fallback: inject after first team_of_month block if present
    IF position('team_of_month' IN v_def) > 0
       AND position('competition_process_month_team_awards' IN v_def) > 0 THEN
      v_def := regexp_replace(
        v_def,
        'v_out := v_out \|\| jsonb_build_object\(\s*''team_of_month'', v_totm\s*\);',
        E'v_out := v_out || jsonb_build_object(''team_of_month'', v_totm);\n\n  BEGIN\n    IF to_regprocedure(''public.competition_tv_process_month_lock_selections(bigint,text)'') IS NOT NULL THEN\n      v_out := v_out || jsonb_build_object(\n        ''tv_selection'',\n        public.competition_tv_process_month_lock_selections(v_season_id, NULL)\n      );\n    END IF;\n  EXCEPTION\n    WHEN OTHERS THEN\n      v_out := v_out || jsonb_build_object(\n        ''tv_revenue_tick'',\n        jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n      );\n  END;',
        'n'
      );
    ELSE
      RAISE NOTICE 'calendar_month_tick inject failed — pattern not found';
      RETURN;
    END IF;
  END IF;

  IF position('competition_tv_process_month_lock_selections' IN v_def) = 0
     AND position('competition_tv_settle_unpaid_played' IN v_def) = 0 THEN
    RAISE NOTICE 'calendar_month_tick inject produced no TV call — abort';
    RETURN;
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'Injected TV select/settle into competition_calendar_month_tick';
END;
$inject_tick$;

NOTIFY pgrst, 'reload schema';

-- Verify (optional):
-- SELECT proname FROM pg_proc
-- WHERE proname IN (
--   'competition_tv_settle_unpaid_played',
--   'competition_tv_process_month_lock_selections'
-- );
-- SELECT public.competition_tv_settle_unpaid_played(
--   (SELECT id FROM competition_seasons WHERE is_current LIMIT 1), NULL
-- );
