-- =============================================================================
-- Vacant / season-absence walkovers — August batch catch-up (timeout-safe)
--
-- Also installs durable side_effects wiring (same as the full patch) without
-- processing every locked month in one statement.
--
-- Re-run until august_left = 0 (each run does up to 25 fixtures, 120s timeout).
-- =============================================================================

-- Raise timeout for this session
SET LOCAL statement_timeout = '120s';

-- ---------------------------------------------------------------------------
-- Durable processor (re-process pending; do not skip forever on job key)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_process_vacant_walkovers(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_cal record;
  v_fx record;
  v_job_key text;
  v_month_sort smallint;
  v_res jsonb;
  v_month_results jsonb;
  v_walkovers int;
  v_voids int;
  v_pending int;
  v_out jsonb := '[]'::jsonb;
BEGIN
  PERFORM set_config('statement_timeout', '120s', true);

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  IF to_regprocedure('public.competition_apply_vacant_fixture_result(bigint)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'apply_fn_missing');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'vacant_walkovers:' || v_cal.gpsl_month;
    v_month_sort := public.competition_gpsl_month_sort(v_cal.gpsl_month);

    SELECT count(*)::int INTO v_pending
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND f.status = 'scheduled'
      AND f.competition_type IN ('league', 'cup')
      AND f.gpsl_month IS NOT NULL
      AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_month_sort
      AND (
        public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
        OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
      );

    IF coalesce(v_pending, 0) = 0 THEN
      INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
      VALUES (
        v_season_id, v_job_key, v_cal.gpsl_month,
        jsonb_build_object('ok', true, 'walkovers', 0, 'voids', 0, 'pending', 0, 'note', 'nothing_pending')
      )
      ON CONFLICT (season_id, job_key) DO UPDATE
        SET result = excluded.result, gpsl_month = excluded.gpsl_month, ran_at = now();
      CONTINUE;
    END IF;

    v_month_results := '[]'::jsonb;
    v_walkovers := 0;
    v_voids := 0;

    FOR v_fx IN
      SELECT f.id
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND f.status = 'scheduled'
        AND f.competition_type IN ('league', 'cup')
        AND f.gpsl_month IS NOT NULL
        AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_month_sort
        AND (
          public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
          OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
        )
      ORDER BY public.competition_gpsl_month_sort(f.gpsl_month), f.matchday NULLS LAST, f.id
    LOOP
      v_res := public.competition_apply_vacant_fixture_result(v_fx.id);
      IF coalesce((v_res->>'ok')::boolean, false) THEN
        IF v_res->>'result' = 'void' THEN
          v_voids := v_voids + 1;
        ELSE
          v_walkovers := v_walkovers + 1;
        END IF;
        v_month_results := v_month_results || jsonb_build_array(v_res);
      END IF;
    END LOOP;

    INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
    VALUES (
      v_season_id, v_job_key, v_cal.gpsl_month,
      jsonb_build_object(
        'ok', true,
        'walkovers', v_walkovers,
        'voids', v_voids,
        'pending_before', v_pending,
        'fixtures', v_month_results
      )
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result, gpsl_month = excluded.gpsl_month, ran_at = now();

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'gpsl_month', v_cal.gpsl_month,
      'walkovers', v_walkovers,
      'voids', v_voids,
      'pending_before', v_pending
    ));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season_id, 'processed', v_out);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_process_vacant_walkovers(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_process_vacant_walkovers(bigint)
  TO service_role;

-- August-only batch: up to p_limit fixtures
CREATE OR REPLACE FUNCTION public.admin_vacant_walkovers_august_batch(
  p_limit int DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_fx record;
  v_res jsonb;
  v_done jsonb := '[]'::jsonb;
  v_n int := 0;
  v_walkovers int := 0;
  v_voids int := 0;
  v_limit int := greatest(1, least(coalesce(p_limit, 25), 50));
  v_left int;
BEGIN
  PERFORM set_config('statement_timeout', '120s', true);

  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_fx IN
    SELECT f.id
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND f.competition_type IN ('league', 'cup')
      AND lower(btrim(f.gpsl_month)) = 'august'
      AND (
        public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
        OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
      )
    ORDER BY f.matchday NULLS LAST, f.id
    LIMIT v_limit
  LOOP
    v_res := public.competition_apply_vacant_fixture_result(v_fx.id);
    v_n := v_n + 1;
    IF coalesce((v_res->>'ok')::boolean, false) THEN
      IF v_res->>'result' = 'void' THEN
        v_voids := v_voids + 1;
      ELSE
        v_walkovers := v_walkovers + 1;
      END IF;
      v_done := v_done || jsonb_build_array(v_res);
    ELSE
      v_done := v_done || jsonb_build_array(v_res);
    END IF;
  END LOOP;

  SELECT count(*)::int INTO v_left
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season
    AND f.status = 'scheduled'
    AND lower(btrim(f.gpsl_month)) = 'august'
    AND (
      public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
      OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
    );

  -- Stamp / refresh August job when drained
  IF coalesce(v_left, 0) = 0 THEN
    INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
    VALUES (
      v_season, 'vacant_walkovers:august', 'august',
      jsonb_build_object('ok', true, 'catchup', 'august_batch', 'walkovers', v_walkovers, 'voids', v_voids)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result, ran_at = now();
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'batch_attempted', v_n,
    'walkovers', v_walkovers,
    'voids', v_voids,
    'august_left', v_left,
    'fixtures', v_done
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_vacant_walkovers_august_batch(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_vacant_walkovers_august_batch(int) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_vacant_walkovers_run_now()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.competition_process_vacant_walkovers(NULL);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_vacant_walkovers_run_now() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_vacant_walkovers_run_now() TO authenticated;

CREATE OR REPLACE FUNCTION public.competition_vacant_walkovers_month_lock_side_effect(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN public.competition_process_vacant_walkovers(p_season_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_vacant_walkovers_month_lock_side_effect(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_vacant_walkovers_month_lock_side_effect(bigint, text)
  TO service_role;

INSERT INTO public.competition_month_lock_hooks (hook_key, sort_order, enabled, proc_name, notes)
VALUES (
  'vacant_walkovers',
  30,
  true,
  'competition_vacant_walkovers_month_lock_side_effect',
  'Owned vs vacant/absent 3–0; both inactive league → void (+1 MP)'
)
ON CONFLICT (hook_key) DO UPDATE
SET enabled = true,
    proc_name = EXCLUDED.proc_name,
    sort_order = EXCLUDED.sort_order,
    notes = EXCLUDED.notes;

-- Inject vacant_walkovers into side_effects if missing (string patch — avoid full replace)
DO $side$
DECLARE
  v_oid oid;
  v_def text;
  v_insert text;
BEGIN
  v_oid := to_regprocedure('public.competition_run_month_lock_side_effects(bigint,text,text)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'side_effects missing — run month_lock_side_effects_registry first';
    RETURN;
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('competition_process_vacant_walkovers' IN v_def) > 0
     OR position('''vacant_walkovers''' IN v_def) > 0 THEN
    RAISE NOTICE 'vacant walkovers already in side_effects';
    RETURN;
  END IF;

  v_insert :=
    E'\n    -- Vacant / season-absence walkovers\n'
    || E'    BEGIN\n'
    || E'      IF to_regprocedure(''public.competition_process_vacant_walkovers(bigint)'') IS NOT NULL THEN\n'
    || E'        v_res := public.competition_process_vacant_walkovers(p_season_id);\n'
    || E'        v_out := v_out || jsonb_build_object(''vacant_walkovers'', v_res);\n'
    || E'      END IF;\n'
    || E'    EXCEPTION WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''vacant_walkovers'', jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'    END;\n';

  -- Insert before registry hook loop if present
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
    RAISE EXCEPTION 'Could not inject vacant walkovers into side_effects';
  END IF;

  -- Avoid double-run via hooks table
  IF position('hook_key NOT IN' IN v_def) = 0
     AND position('AND hook_key NOT IN' IN v_def) = 0 THEN
    v_def := replace(
      v_def,
      E'WHERE enabled\n    ORDER BY sort_order, hook_key',
      E'WHERE enabled\n      AND hook_key NOT IN (''friendlies_prizes'', ''vacant_walkovers'')\n    ORDER BY sort_order, hook_key'
    );
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'Injected vacant walkovers into competition_run_month_lock_side_effects';
END;
$side$;

NOTIFY pgrst, 'reload schema';

-- One August batch (re-run this SELECT until august_left = 0)
SELECT public.admin_vacant_walkovers_august_batch(25) AS batch;
