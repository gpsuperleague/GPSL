-- =============================================================================
-- Month-lock stadium + clinches — batch under API gateway (~60s)
--
-- Symptom: Retry May jobs soft-warns stadium/clinches timed out + HTTP 500.
-- Cause: all-clubs sync / all-division clinch scan exceed the API gateway.
--
-- Adds:
--   competition_stadium_sync_clubs_batch(season, limit, after_club)
--   competition_process_league_clinches_division(season, division)
-- Injects a CONTINUE filter into competition_process_league_clinches so the
-- division RPC only scans one division.
--
-- Admin UI (admin_test_end_month.js) loops these instead of one fat stage call.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_stadium_sync_clubs_batch(
  p_season_id bigint DEFAULT NULL,
  p_limit integer DEFAULT 8,
  p_after_club text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_limit int := greatest(1, least(coalesce(p_limit, 8), 20));
  v_after text := nullif(btrim(coalesce(p_after_club, '')), '');
  v_club text;
  v_synced int := 0;
  v_failed int := 0;
  v_last text := NULL;
  v_remaining int := 0;
BEGIN
  PERFORM set_config('statement_timeout', '90s', true);

  v_season_id := coalesce(
    p_season_id,
    (SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1)
  );

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.competition_stadium_sync_fill_state(text,bigint)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stadium_sync_missing');
  END IF;

  FOR v_club IN
    SELECT c."ShortName"
    FROM public."Clubs" c
    WHERE v_after IS NULL OR c."ShortName" > v_after
    ORDER BY c."ShortName"
    LIMIT v_limit
  LOOP
    BEGIN
      PERFORM public.competition_stadium_sync_fill_state(v_club, v_season_id);
      v_synced := v_synced + 1;
    EXCEPTION
      WHEN OTHERS THEN
        v_failed := v_failed + 1;
    END;
    v_last := v_club;
  END LOOP;

  IF v_last IS NULL THEN
    v_remaining := 0;
  ELSE
    SELECT count(*)::int
    INTO v_remaining
    FROM public."Clubs" c
    WHERE c."ShortName" > v_last;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'clubs_synced', v_synced,
    'clubs_failed', v_failed,
    'after_club', v_last,
    'remaining', coalesce(v_remaining, 0),
    'done', coalesce(v_remaining, 0) = 0
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_stadium_sync_clubs_batch(bigint, integer, text)
  TO authenticated, service_role;

-- Inject division filter into live clinch function (and impl if present)
DO $inject$
DECLARE
  v_reg text;
  v_def text;
  v_old text := 'v_div_label := public.competition_division_label(v_div);';
  v_new text :=
    E'IF nullif(current_setting(''gpsl.clinch_division_only'', true), '''') IS NOT NULL\n'
    || E'       AND current_setting(''gpsl.clinch_division_only'', true) IS DISTINCT FROM v_div THEN\n'
    || E'      CONTINUE;\n'
    || E'    END IF;\n'
    || E'    v_div_label := public.competition_division_label(v_div);';
BEGIN
  FOREACH v_reg IN ARRAY ARRAY[
    'public.competition_process_league_clinches(bigint)',
    'public.competition_process_league_clinches_impl(bigint)'
  ]
  LOOP
    BEGIN
      SELECT pg_get_functiondef(v_reg::regprocedure) INTO v_def;
    EXCEPTION
      WHEN undefined_function THEN
        CONTINUE;
    END;

    IF v_def IS NULL THEN
      CONTINUE;
    END IF;

    IF position('gpsl.clinch_division_only' IN v_def) > 0 THEN
      RAISE NOTICE '% already has division filter', v_reg;
      CONTINUE;
    END IF;

    IF position(v_old IN v_def) = 0 THEN
      RAISE NOTICE '%: marker not found — skip', v_reg;
      CONTINUE;
    END IF;

    v_def := replace(v_def, v_old, v_new);
    BEGIN
      EXECUTE v_def;
      RAISE NOTICE 'Injected division filter into %', v_reg;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'Inject failed for %: %', v_reg, SQLERRM;
    END;
  END LOOP;
END;
$inject$;

CREATE OR REPLACE FUNCTION public.competition_process_league_clinches_division(
  p_season_id bigint DEFAULT NULL,
  p_division text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_div text := lower(nullif(btrim(coalesce(p_division, '')), ''));
  v_out jsonb;
BEGIN
  PERFORM set_config('statement_timeout', '90s', true);

  IF v_div IS NULL OR v_div NOT IN ('superleague', 'championship_a', 'championship_b') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_division', 'division', p_division);
  END IF;

  v_season_id := coalesce(
    p_season_id,
    (SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1)
  );

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.competition_process_league_clinches(bigint)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'clinches_rpc_missing');
  END IF;

  PERFORM set_config('gpsl.clinch_division_only', v_div, true);

  BEGIN
    v_out := public.competition_process_league_clinches(v_season_id);
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM set_config('gpsl.clinch_division_only', '', true);
      RETURN jsonb_build_object('ok', false, 'division', v_div, 'error', SQLERRM);
  END;

  PERFORM set_config('gpsl.clinch_division_only', '', true);

  RETURN coalesce(v_out, '{}'::jsonb) || jsonb_build_object(
    'ok', coalesce((v_out->>'ok')::boolean, true),
    'division', v_div
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_process_league_clinches_division(bigint, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
