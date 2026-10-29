-- =============================================================================
-- Vacant / season-absence walkovers — auto at month lock (all months)
--
-- Replaces the August-only side-effect stub so future locks process every
-- locked month that still has pending inactive fixtures (fast apply + chunk).
-- Safe re-run. Finish August catch-up with the batch_run script first if needed.
-- =============================================================================

-- Process up to p_limit pending inactive fixtures across ALL locked months
CREATE OR REPLACE FUNCTION public.competition_process_vacant_walkovers_chunk(
  p_season_id bigint DEFAULT NULL,
  p_limit int DEFAULT 40
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '90s'
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_limit int := greatest(1, least(coalesce(p_limit, 40), 60));
  v_fx record;
  v_res jsonb;
  v_n int := 0;
  v_walkovers int := 0;
  v_voids int := 0;
  v_fail int := 0;
  v_left int;
  v_div text;
  v_divs text[] := ARRAY[]::text[];
  v_month text;
  v_months text[] := ARRAY[]::text[];
BEGIN
  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.competition_apply_vacant_fixture_result_fast(bigint)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fast_apply_missing — run august batch install first');
  END IF;

  FOR v_fx IN
    SELECT f.id, lower(btrim(f.gpsl_month)) AS gpsl_month
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND f.competition_type IN ('league', 'cup')
      AND cal.lock_at IS NOT NULL
      AND cal.lock_at <= now()
      AND (
        public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
        OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
      )
    ORDER BY public.competition_gpsl_month_sort(f.gpsl_month), f.id
    LIMIT v_limit
  LOOP
    BEGIN
      v_res := public.competition_apply_vacant_fixture_result_fast(v_fx.id);
    EXCEPTION WHEN OTHERS THEN
      v_fail := v_fail + 1;
      v_n := v_n + 1;
      CONTINUE;
    END;

    v_n := v_n + 1;
    IF coalesce((v_res->>'ok')::boolean, false) THEN
      IF v_res->>'result' = 'void' THEN
        v_voids := v_voids + 1;
      ELSE
        v_walkovers := v_walkovers + 1;
      END IF;
      v_div := nullif(btrim(coalesce(v_res->>'division', '')), '');
      IF v_div IS NOT NULL AND NOT (v_div = ANY (v_divs)) THEN
        v_divs := v_divs || v_div;
      END IF;
      v_month := v_fx.gpsl_month;
      IF v_month IS NOT NULL AND NOT (v_month = ANY (v_months)) THEN
        v_months := v_months || v_month;
      END IF;
    END IF;
  END LOOP;

  IF to_regprocedure('public.competition_try_pay_league_division_prizes(bigint,text)') IS NOT NULL THEN
    FOREACH v_div IN ARRAY v_divs
    LOOP
      BEGIN
        PERFORM public.competition_try_pay_league_division_prizes(v_season, v_div);
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END LOOP;
  END IF;

  -- Stamp job rows for months we touched / that are now clear
  FOREACH v_month IN ARRAY v_months
  LOOP
    INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
    VALUES (
      v_season,
      'vacant_walkovers:' || v_month,
      v_month,
      jsonb_build_object('ok', true, 'source', 'chunk', 'walkovers', v_walkovers, 'voids', v_voids)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result, ran_at = now();
  END LOOP;

  SELECT count(*)::int INTO v_left
  FROM public.competition_fixtures f
  JOIN public.competition_season_calendar cal
    ON cal.season_id = f.season_id
   AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
  WHERE f.season_id = v_season
    AND f.status = 'scheduled'
    AND f.competition_type IN ('league', 'cup')
    AND cal.lock_at IS NOT NULL
    AND cal.lock_at <= now()
    AND (
      public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
      OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
    );

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'batch_attempted', v_n,
    'walkovers', v_walkovers,
    'voids', v_voids,
    'failed', v_fail,
    'pending_left', v_left,
    'months_touched', to_jsonb(v_months),
    'divisions_settled', to_jsonb(v_divs)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_process_vacant_walkovers_chunk(bigint, int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_process_vacant_walkovers_chunk(bigint, int)
  TO service_role;

-- Full process = chunk large enough for a normal lock (still timeout-capped)
CREATE OR REPLACE FUNCTION public.competition_process_vacant_walkovers(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN public.competition_process_vacant_walkovers_chunk(p_season_id, 50);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_process_vacant_walkovers(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_process_vacant_walkovers(bigint)
  TO service_role;

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
  RETURN public.competition_process_vacant_walkovers_chunk(NULL, 50);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_vacant_walkovers_run_now() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_vacant_walkovers_run_now() TO authenticated;

-- Month-lock hook: ALL locked months, not August-only
CREATE OR REPLACE FUNCTION public.competition_vacant_walkovers_month_lock_side_effect(
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
  RETURN public.competition_process_vacant_walkovers_chunk(p_season_id, 50);
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
  'All locked months: owned vs vacant/absent 3–0; both inactive league → void'
)
ON CONFLICT (hook_key) DO UPDATE
SET enabled = true,
    proc_name = EXCLUDED.proc_name,
    notes = EXCLUDED.notes;

-- Hardcode into durable side_effects (idempotent inject)
DO $side$
DECLARE
  v_oid oid;
  v_def text;
  v_insert text;
BEGIN
  v_oid := to_regprocedure('public.competition_run_month_lock_side_effects(bigint,text,text)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'side_effects missing — hook table still registered';
    RETURN;
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('competition_process_vacant_walkovers' IN v_def) > 0 THEN
    RAISE NOTICE 'vacant walkovers already hardcoded in side_effects';
    RETURN;
  END IF;

  v_insert :=
    E'\n    BEGIN\n'
    || E'      IF to_regprocedure(''public.competition_process_vacant_walkovers_chunk(bigint,int)'') IS NOT NULL THEN\n'
    || E'        v_res := public.competition_process_vacant_walkovers_chunk(p_season_id, 50);\n'
    || E'        v_out := v_out || jsonb_build_object(''vacant_walkovers'', v_res);\n'
    || E'      ELSIF to_regprocedure(''public.competition_process_vacant_walkovers(bigint)'') IS NOT NULL THEN\n'
    || E'        v_res := public.competition_process_vacant_walkovers(p_season_id);\n'
    || E'        v_out := v_out || jsonb_build_object(''vacant_walkovers'', v_res);\n'
    || E'      END IF;\n'
    || E'    EXCEPTION WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''vacant_walkovers'', jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
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
    RAISE NOTICE 'Could not inject vacant into side_effects — hook row remains';
    RETURN;
  END IF;

  IF position('hook_key NOT IN' IN v_def) = 0 THEN
    v_def := replace(
      v_def,
      E'WHERE enabled\n    ORDER BY sort_order, hook_key',
      E'WHERE enabled\n      AND hook_key NOT IN (''friendlies_prizes'', ''vacant_walkovers'')\n    ORDER BY sort_order, hook_key'
    );
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'vacant walkovers hardcoded into side_effects';
END;
$side$;

NOTIFY pgrst, 'reload schema';

SELECT
  (position('competition_process_vacant_walkovers' IN pg_get_functiondef(
    'public.competition_run_month_lock_side_effects(bigint,text,text)'::regprocedure
  )) > 0) AS vacant_in_side_effects,
  (SELECT enabled FROM public.competition_month_lock_hooks WHERE hook_key = 'vacant_walkovers')
    AS hook_enabled,
  (to_regprocedure('public.competition_process_vacant_walkovers_chunk(bigint,int)') IS NOT NULL)
    AS chunk_fn;
