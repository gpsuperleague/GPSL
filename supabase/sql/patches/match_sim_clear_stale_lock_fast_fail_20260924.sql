-- =============================================================================
-- Match sim: clear stale locks + faster lock fail + surface SQLERRM
-- Fixes ~10s hang then HTTP 400 when a prior sim left result_sim_lock_* set
-- or when waiting on FOR UPDATE hit lock_timeout without a clear message.
-- Safe re-run.
-- =============================================================================

-- Drop stale simulate locks (older than 60s) so a crashed tab cannot block
UPDATE public.competition_fixtures f
SET
  result_sim_lock_club = NULL,
  result_sim_lock_at = NULL
WHERE f.result_sim_lock_at IS NOT NULL
  AND f.result_sim_lock_at < now() - interval '60 seconds';

-- Diagnose helper: quick preflight without running full sim
CREATE OR REPLACE FUNCTION public.competition_simulate_fixture_preflight(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_home text;
  v_away text;
  v_status text;
  v_lock_club text;
  v_lock_at timestamptz;
  v_enabled boolean := false;
  v_core boolean;
  v_home_n int := 0;
  v_away_n int := 0;
BEGIN
  BEGIN
    v_enabled := public.match_result_simulation_enabled();
  EXCEPTION WHEN OTHERS THEN
    v_enabled := false;
  END;

  v_core := to_regprocedure('public.competition_simulate_fixture_result_core(bigint)') IS NOT NULL;

  SELECT
    f.home_club_short_name,
    f.away_club_short_name,
    f.status,
    f.result_sim_lock_club,
    f.result_sim_lock_at
  INTO v_home, v_away, v_status, v_lock_club, v_lock_at
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Fixture not found');
  END IF;

  SELECT count(*)::int INTO v_home_n
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_home;

  SELECT count(*)::int INTO v_away_n
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_away;

  RETURN jsonb_build_object(
    'ok', true,
    'simulation_enabled', v_enabled,
    'core_function_exists', v_core,
    'my_club', v_club,
    'home', v_home,
    'away', v_away,
    'status', v_status,
    'lock_club', v_lock_club,
    'lock_at', v_lock_at,
    'lock_stale',
      v_lock_at IS NOT NULL AND v_lock_at < now() - interval '60 seconds',
    'home_contracted_players', v_home_n,
    'away_contracted_players', v_away_n,
    'in_fixture',
      v_club IS NOT NULL
      AND (v_club = v_home OR v_club = v_away)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_simulate_fixture_preflight(bigint) TO authenticated;

-- Faster lock timeout on the public wrapper (fail in ~3s with clear text)
CREATE OR REPLACE FUNCTION public.competition_simulate_fixture_result(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '60s'
SET lock_timeout = '3s'
AS $function$
DECLARE
  v_real_club text;
  v_home text;
  v_away text;
  v_home_owned boolean;
  v_away_owned boolean;
  v_staff boolean := false;
  v_result jsonb;
BEGIN
  IF NOT public.match_result_simulation_enabled() THEN
    RAISE EXCEPTION 'Match result simulation is disabled (Admin → Match sim)';
  END IF;

  IF to_regprocedure('public.competition_simulate_fixture_result_core(bigint)') IS NULL THEN
    RAISE EXCEPTION
      'competition_simulate_fixture_result_core is missing — re-apply match_result_simulation patches then match_sim_block_club_impersonation_20260902.sql';
  END IF;

  -- Clear any poisoned acting club + stale locks on this fixture
  IF to_regprocedure('public.gpsl_sim_set_acting_club(text)') IS NOT NULL THEN
    PERFORM public.gpsl_sim_set_acting_club(NULL);
  END IF;
  PERFORM set_config('gpsl.sim_acting_club', '', true);

  UPDATE public.competition_fixtures
  SET result_sim_lock_club = NULL, result_sim_lock_at = NULL
  WHERE id = p_fixture_id
    AND result_sim_lock_at IS NOT NULL
    AND result_sim_lock_at < now() - interval '60 seconds';

  SELECT f.home_club_short_name, f.away_club_short_name
  INTO v_home, v_away
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  SELECT c."ShortName"
  INTO v_real_club
  FROM public."Clubs" c
  WHERE c.owner_id = auth.uid()
  LIMIT 1;

  BEGIN
    v_staff := public.is_gpsl_admin_or_mod();
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      v_staff := public.is_gpsl_admin();
    EXCEPTION WHEN OTHERS THEN
      v_staff := false;
    END;
  END;

  SELECT coalesce(
    (SELECT c.owner_id IS NOT NULL FROM public."Clubs" c WHERE c."ShortName" = v_home),
    false
  )
  INTO v_home_owned;

  SELECT coalesce(
    (SELECT c.owner_id IS NOT NULL FROM public."Clubs" c WHERE c."ShortName" = v_away),
    false
  )
  INTO v_away_owned;

  BEGIN
    IF v_staff AND NOT v_home_owned AND NOT v_away_owned THEN
      IF to_regprocedure('public.gpsl_sim_set_acting_club(text)') IS NOT NULL THEN
        PERFORM public.gpsl_sim_set_acting_club(v_home);
      ELSE
        PERFORM set_config('gpsl.sim_acting_club', v_home, true);
      END IF;
      PERFORM public.competition_assert_fixture_month_unlocked(p_fixture_id, v_home);
      v_result := public.competition_simulate_fixture_result_core(p_fixture_id);
      IF to_regprocedure('public.gpsl_sim_set_acting_club(text)') IS NOT NULL THEN
        PERFORM public.gpsl_sim_set_acting_club(NULL);
      END IF;
      RETURN v_result;
    END IF;

    IF v_real_club IS NULL OR btrim(v_real_club) = '' THEN
      RAISE EXCEPTION 'No club linked to this account';
    END IF;

    IF v_real_club IS DISTINCT FROM v_home AND v_real_club IS DISTINCT FROM v_away THEN
      RAISE EXCEPTION 'Your club is not in this fixture (% vs %)', v_home, v_away;
    END IF;

    PERFORM public.competition_assert_fixture_month_unlocked(p_fixture_id, v_real_club);
    RETURN public.competition_simulate_fixture_result_core(p_fixture_id);
  EXCEPTION
    WHEN lock_not_available OR deadlock_detected THEN
      RAISE EXCEPTION
        'Simulation lock busy — another sim may be running on this fixture. Wait 30s and retry. (% )',
        SQLERRM;
    WHEN query_canceled THEN
      RAISE EXCEPTION
        'Simulation timed out or was canceled. Try Instant result, or check Admin match-sim settings. (% )',
        SQLERRM;
    WHEN OTHERS THEN
      -- Always surface the underlying message (PostgREST 400 body)
      RAISE EXCEPTION '%', SQLERRM;
  END;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_simulate_fixture_result(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
