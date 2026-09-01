-- =============================================================================
-- Deploy month results: also play unplayed internationals for that GPSL month
-- (needed for June/July WC / pre-season internationals with no club league slate).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_testing_deploy_month_international_preview(
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(trim(coalesce(p_gpsl_month, '')));
  v_ready int := 0;
  v_blocked int := 0;
  v_played int := 0;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_month = '' THEN
    RAISE EXCEPTION 'gpsl_month required';
  END IF;

  SELECT
    count(*) FILTER (
      WHERE f.played = false
        AND nullif(btrim(f.home_nation), '') IS NOT NULL
        AND nullif(btrim(f.away_nation), '') IS NOT NULL
    )::int,
    count(*) FILTER (
      WHERE f.played = false
        AND (
          nullif(btrim(f.home_nation), '') IS NULL
          OR nullif(btrim(f.away_nation), '') IS NULL
        )
    )::int,
    count(*) FILTER (WHERE f.played = true)::int
  INTO v_ready, v_blocked, v_played
  FROM public.international_fixtures f
  WHERE lower(trim(coalesce(f.gpsl_month, ''))) = v_month;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'fixture_id', x.id,
      'phase', x.phase,
      'home_nation', x.home_nation,
      'away_nation', x.away_nation,
      'match_no', x.match_no,
      'ready', x.ready,
      'block_reason', x.block_reason
    )
    ORDER BY
      CASE x.phase
        WHEN 'qualifying' THEN 1
        WHEN 'finals_group' THEN 2
        WHEN 'knockout' THEN 3
        ELSE 4
      END,
      x.match_no NULLS LAST,
      x.id
  ), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      f.id,
      f.phase,
      f.home_nation,
      f.away_nation,
      f.match_no,
      (
        f.played = false
        AND nullif(btrim(f.home_nation), '') IS NOT NULL
        AND nullif(btrim(f.away_nation), '') IS NOT NULL
      ) AS ready,
      CASE
        WHEN f.played THEN 'already played'
        WHEN nullif(btrim(f.home_nation), '') IS NULL
          OR nullif(btrim(f.away_nation), '') IS NULL
          THEN 'nations not set yet'
        ELSE NULL
      END AS block_reason
    FROM public.international_fixtures f
    WHERE lower(trim(coalesce(f.gpsl_month, ''))) = v_month
      AND f.played = false
    ORDER BY
      CASE f.phase
        WHEN 'qualifying' THEN 1
        WHEN 'finals_group' THEN 2
        WHEN 'knockout' THEN 3
        ELSE 4
      END,
      f.match_no NULLS LAST,
      f.id
    LIMIT 200
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'gpsl_month_label', public.competition_gpsl_month_label(v_month),
    'international_ready', coalesce(v_ready, 0),
    'international_blocked', coalesce(v_blocked, 0),
    'international_already_played', coalesce(v_played, 0),
    'fixtures', v_rows
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_testing_deploy_month_internationals(
  p_gpsl_month text,
  p_confirm_phrase text DEFAULT NULL,
  p_limit integer DEFAULT NULL,
  p_after_fixture_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(trim(coalesce(p_gpsl_month, '')));
  v_fix record;
  v_limit int := greatest(1, least(coalesce(p_limit, 10), 50));
  v_played int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_last_id bigint;
  v_has_more boolean := false;
  v_remaining int := 0;
  v_hg smallint;
  v_ag smallint;
  v_pass int;
  v_batch int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Admin only');
  END IF;

  IF v_month = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'gpsl_month required');
  END IF;

  IF p_after_fixture_id IS NULL
     AND coalesce(trim(p_confirm_phrase), '') <> 'DEPLOY TEST MONTH' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Confirmation phrase required — type exactly: DEPLOY TEST MONTH'
    );
  END IF;

  IF to_regprocedure(
    'public.international_apply_fixture_result(bigint,smallint,smallint,jsonb,smallint,smallint,smallint,smallint)'
  ) IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'international_apply_fixture_result missing'
    );
  END IF;

  BEGIN
    PERFORM set_config('statement_timeout', '180s', true);
  EXCEPTION
    WHEN OTHERS THEN
      NULL;
  END;

  -- Group / qual fixtures first (deterministic scores, draws OK)
  FOR v_fix IN
    SELECT f.id, f.phase, f.home_nation, f.away_nation
    FROM public.international_fixtures f
    WHERE lower(trim(coalesce(f.gpsl_month, ''))) = v_month
      AND f.played = false
      AND nullif(btrim(f.home_nation), '') IS NOT NULL
      AND nullif(btrim(f.away_nation), '') IS NOT NULL
      AND f.phase IN ('qualifying', 'finals_group')
      AND (p_after_fixture_id IS NULL OR f.id > p_after_fixture_id)
    ORDER BY
      CASE f.phase WHEN 'qualifying' THEN 1 ELSE 2 END,
      f.match_no NULLS LAST,
      f.id
    LIMIT v_limit
  LOOP
    BEGIN
      v_hg := (abs(hashtext(v_fix.id::text || ':h')) % 4)::smallint;
      v_ag := (abs(hashtext(v_fix.id::text || ':a')) % 4)::smallint;
      PERFORM public.international_apply_fixture_result(
        v_fix.id, v_hg, v_ag, '[]'::jsonb, NULL, NULL, NULL, NULL
      );
      v_played := v_played + 1;
      v_last_id := v_fix.id;
    EXCEPTION
      WHEN OTHERS THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'fixture_id', v_fix.id,
          'phase', v_fix.phase,
          'error', SQLERRM
        ));
        v_last_id := v_fix.id;
    END;
  END LOOP;

  -- Knockout: force a winner; later rounds may appear in the same month
  IF v_played < v_limit THEN
    FOR v_pass IN 1..12 LOOP
      EXIT WHEN v_played >= v_limit;
      v_batch := 0;
      FOR v_fix IN
        SELECT f.id, f.phase, f.home_nation, f.away_nation
        FROM public.international_fixtures f
        WHERE lower(trim(coalesce(f.gpsl_month, ''))) = v_month
          AND f.played = false
          AND nullif(btrim(f.home_nation), '') IS NOT NULL
          AND nullif(btrim(f.away_nation), '') IS NOT NULL
          AND f.phase = 'knockout'
          AND (p_after_fixture_id IS NULL OR f.id > coalesce(p_after_fixture_id, 0))
        ORDER BY f.match_no NULLS LAST, f.id
        LIMIT least(10, v_limit - v_played)
      LOOP
        BEGIN
          v_hg := (abs(hashtext(v_fix.id::text || ':h')) % 4)::smallint;
          v_ag := (abs(hashtext(v_fix.id::text || ':a')) % 4)::smallint;
          IF v_hg = v_ag THEN
            v_hg := v_hg + 1;
          END IF;
          PERFORM public.international_apply_fixture_result(
            v_fix.id, v_hg, v_ag, '[]'::jsonb, NULL, NULL, NULL, NULL
          );
          v_played := v_played + 1;
          v_batch := v_batch + 1;
          v_last_id := v_fix.id;
        EXCEPTION
          WHEN OTHERS THEN
            v_errors := v_errors || jsonb_build_array(jsonb_build_object(
              'fixture_id', v_fix.id,
              'phase', v_fix.phase,
              'error', SQLERRM
            ));
            v_last_id := v_fix.id;
        END;
        EXIT WHEN v_played >= v_limit;
      END LOOP;
      EXIT WHEN v_batch = 0;
    END LOOP;
  END IF;

  SELECT count(*)::int
  INTO v_remaining
  FROM public.international_fixtures f
  WHERE lower(trim(coalesce(f.gpsl_month, ''))) = v_month
    AND f.played = false
    AND nullif(btrim(f.home_nation), '') IS NOT NULL
    AND nullif(btrim(f.away_nation), '') IS NOT NULL;

  v_has_more := coalesce(v_remaining, 0) > 0;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'deployed_count', v_played,
    'international_deployed_count', v_played,
    'error_count', jsonb_array_length(v_errors),
    'errors', v_errors,
    'has_more', v_has_more,
    'remaining', coalesce(v_remaining, 0),
    'next_after_fixture_id', v_last_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_testing_deploy_month_international_preview(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_testing_deploy_month_internationals(text, text, integer, bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
