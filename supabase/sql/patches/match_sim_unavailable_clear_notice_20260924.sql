-- =============================================================================
-- Match sim: calm "player unavailable" notice (name + reason + Match Day tip)
-- Safe re-run. Rules unchanged — clearer message + fail-fast before long sim.
-- Apply AFTER match_sim_clear_stale_lock_fast_fail_20260924.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_player_unavailable_message(
  p_fixture_id bigint,
  p_player_id text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_block text;
  v_name text;
BEGIN
  v_block := public.competition_player_unavailable_for_fixture(p_fixture_id, p_player_id);
  IF v_block IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT nullif(btrim(p."Name"), '')
  INTO v_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = p_player_id
  LIMIT 1;

  RETURN format(
    'Player %s is unavailable for this match (%s). Open Match Day, replace them in the XI/bench, save, then simulate again.',
    coalesce(v_name, p_player_id),
    v_block
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.competition_player_unavailable_message(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_player_unavailable_message(bigint, text) TO anon;

CREATE OR REPLACE FUNCTION public.match_sim_assert_matchday_available(
  p_fixture_id bigint,
  p_club text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_club text := btrim(p_club);
  v_msg text;
  v_pid text;
  v_vacant boolean := false;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN;
  END IF;

  BEGIN
    v_vacant := public.match_sim_club_is_vacant(v_club);
  EXCEPTION WHEN OTHERS THEN
    v_vacant := false;
  END;
  IF v_vacant THEN
    RETURN;
  END IF;

  IF to_regclass('public.club_matchday_squad_player') IS NULL THEN
    RETURN;
  END IF;

  SELECT sp.player_id
  INTO v_pid
  FROM public.club_matchday_squad_player sp
  WHERE sp.club_short_name = v_club
    AND sp.slot_kind IN ('pitch', 'bench')
    AND public.competition_player_unavailable_for_fixture(p_fixture_id, sp.player_id) IS NOT NULL
  ORDER BY CASE sp.slot_kind WHEN 'pitch' THEN 0 ELSE 1 END, sp.sort_order NULLS LAST
  LIMIT 1;

  IF v_pid IS NULL THEN
    RETURN;
  END IF;

  v_msg := public.competition_player_unavailable_message(p_fixture_id, v_pid);
  RAISE EXCEPTION '%', coalesce(
    v_msg,
    'A selected Match Day player is unavailable for this match'
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.match_sim_assert_matchday_available(bigint, text) TO authenticated;

-- Public wrapper = clear_stale version + early unavailable assert
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

  -- Fail fast with a clear owner-facing message (no 10s wait)
  PERFORM public.match_sim_assert_matchday_available(p_fixture_id, v_home);
  PERFORM public.match_sim_assert_matchday_available(p_fixture_id, v_away);

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
      RAISE EXCEPTION '%', SQLERRM;
  END;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_simulate_fixture_result(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
