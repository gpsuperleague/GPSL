-- =============================================================================
-- Install ONLY: fast August vacant-walkover batch (skips per-fixture prize spam)
-- Then repeatedly run: vacant_walkovers_august_batch_run_20261029.sql
-- =============================================================================

-- Lean apply: mark result + cup advance; defer league prize / gate / TV / inbox
CREATE OR REPLACE FUNCTION public.competition_apply_vacant_fixture_result_fast(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_home_inactive boolean;
  v_away_inactive boolean;
  v_loser text;
  v_winner text;
  v_low text;
  v_high text;
BEGIN
  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled'
     OR v_f.competition_type NOT IN ('league', 'cup') THEN
    RETURN jsonb_build_object('ok', false, 'fixture_id', p_fixture_id, 'reason', 'not_applicable');
  END IF;

  v_home_inactive := public.competition_club_is_fixture_inactive(v_f.home_club_short_name, v_f.season_id);
  v_away_inactive := public.competition_club_is_fixture_inactive(v_f.away_club_short_name, v_f.season_id);

  IF NOT v_home_inactive AND NOT v_away_inactive THEN
    RETURN jsonb_build_object('ok', false, 'fixture_id', p_fixture_id, 'reason', 'both_active');
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by vacant/absence walkover',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  -- League both inactive → void (+1 MP, no score)
  IF v_home_inactive AND v_away_inactive AND v_f.competition_type = 'league' THEN
    UPDATE public.competition_fixtures
    SET status = 'played',
        is_void = true,
        home_goals = NULL,
        away_goals = NULL
    WHERE id = p_fixture_id;

    RETURN jsonb_build_object(
      'ok', true, 'fixture_id', p_fixture_id, 'result', 'void',
      'division', v_f.division, 'season_id', v_f.season_id
    );
  END IF;

  IF v_home_inactive AND v_away_inactive THEN
    v_low := least(v_f.home_club_short_name, v_f.away_club_short_name);
    v_high := greatest(v_f.home_club_short_name, v_f.away_club_short_name);
    v_loser := CASE
      WHEN substr(md5(concat_ws(':', v_f.season_id, v_f.cup_code, v_low, v_high)), 1, 1) < '8'
      THEN v_low ELSE v_high
    END;
  ELSIF v_home_inactive THEN
    v_loser := v_f.home_club_short_name;
  ELSE
    v_loser := v_f.away_club_short_name;
  END IF;

  v_winner := CASE
    WHEN v_loser = v_f.home_club_short_name THEN v_f.away_club_short_name
    ELSE v_f.home_club_short_name
  END;

  UPDATE public.competition_fixtures
  SET home_goals = CASE WHEN v_winner = v_f.home_club_short_name THEN 3 ELSE 0 END,
      away_goals = CASE WHEN v_winner = v_f.away_club_short_name THEN 3 ELSE 0 END,
      status = 'played',
      is_forfeit = true,
      forfeit_loser_club = v_loser
  WHERE id = p_fixture_id;

  IF v_f.competition_type = 'cup'
     AND to_regprocedure('public.competition_cup_on_fixture_played(bigint)') IS NOT NULL THEN
    BEGIN
      PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object(
        'ok', false, 'fixture_id', p_fixture_id, 'reason', 'cup_advance_failed',
        'error', SQLERRM, 'winner', v_winner, 'loser', v_loser
      );
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'fixture_id', p_fixture_id, 'result', 'walkover',
    'winner', v_winner, 'loser', v_loser,
    'division', v_f.division, 'season_id', v_f.season_id,
    'competition_type', v_f.competition_type
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_apply_vacant_fixture_result_fast(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_apply_vacant_fixture_result_fast(bigint)
  TO service_role;

CREATE OR REPLACE FUNCTION public.admin_vacant_walkovers_august_batch(
  p_limit int DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '60s'
AS $function$
DECLARE
  v_season bigint;
  v_fx record;
  v_res jsonb;
  v_done jsonb := '[]'::jsonb;
  v_n int := 0;
  v_walkovers int := 0;
  v_voids int := 0;
  v_fail int := 0;
  v_limit int := greatest(1, least(coalesce(p_limit, 5), 10));
  v_left int;
  v_div text;
  v_divs text[] := ARRAY[]::text[];
BEGIN
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
    ORDER BY f.id
    LIMIT v_limit
  LOOP
    BEGIN
      v_res := public.competition_apply_vacant_fixture_result_fast(v_fx.id);
    EXCEPTION WHEN OTHERS THEN
      v_fail := v_fail + 1;
      v_n := v_n + 1;
      v_done := v_done || jsonb_build_array(jsonb_build_object(
        'ok', false, 'fixture_id', v_fx.id, 'error', SQLERRM
      ));
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
    END IF;
    -- Keep payload small (ids only) to avoid huge jsonb timeout/UI lag
    v_done := v_done || jsonb_build_array(jsonb_build_object(
      'ok', v_res->>'ok',
      'fixture_id', v_res->>'fixture_id',
      'result', v_res->>'result',
      'winner', v_res->>'winner',
      'loser', v_res->>'loser'
    ));
  END LOOP;

  -- One prize settle per touched division (not per fixture)
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

  SELECT count(*)::int INTO v_left
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season
    AND f.status = 'scheduled'
    AND lower(btrim(f.gpsl_month)) = 'august'
    AND (
      public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
      OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
    );

  IF coalesce(v_left, 0) = 0 THEN
    INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
    VALUES (
      v_season, 'vacant_walkovers:august', 'august',
      jsonb_build_object('ok', true, 'catchup', 'august_batch_done')
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result, ran_at = now();
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'batch_attempted', v_n,
    'walkovers', v_walkovers,
    'voids', v_voids,
    'failed', v_fail,
    'august_left', v_left,
    'divisions_settled', to_jsonb(v_divs),
    'fixtures', v_done
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_vacant_walkovers_august_batch(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_vacant_walkovers_august_batch(int)
  TO authenticated, service_role;

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
  -- Drain a chunk; next locks / re-runs finish the rest
  RETURN public.admin_vacant_walkovers_august_batch(10);
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
    notes = EXCLUDED.notes;

NOTIFY pgrst, 'reload schema';

SELECT 'install_ok' AS status;
