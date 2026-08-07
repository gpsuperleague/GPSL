-- =============================================================================
-- HOTFIX: simulated matches — 15 yellow / 1 red per GPSL month + injury roll
-- Requires match_result_simulation.sql already deployed (rating fix ok too).
-- Safe re-run. Do not click Simulate while this runs.
-- =============================================================================

SET lock_timeout = '15s';
SET statement_timeout = '90s';

-- ---------------------------------------------------------------------------
-- Month card quota (same as admin_testing_seed_month_discipline):
-- 15 yellows + 1 red across league/cup fixtures in a GPSL calendar month.
-- Each remaining card independently lands on this fixture with p = 1/slots
-- (slots = this fixture + remaining scheduled). Last fixture gets the rest.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_sim_assign_month_cards(
  p_fixture_id bigint,
  p_yellow_target int DEFAULT 15,
  p_red_target int DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture record;
  v_existing_y int := 0;
  v_existing_r int := 0;
  v_need_y int;
  v_need_r int;
  v_remaining int := 0;
  v_slots numeric;
  v_y_here int := 0;
  v_r_here int := 0;
  v_i int;
  v_club text;
  v_player text;
  v_pair record;
  v_stats jsonb;
  v_assigned jsonb := '[]'::jsonb;
BEGIN
  SELECT
    f.id,
    f.season_id,
    f.gpsl_month,
    f.competition_type,
    f.status,
    f.home_club_short_name,
    f.away_club_short_name
  INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_found');
  END IF;

  IF v_fixture.status <> 'played' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_played');
  END IF;

  IF v_fixture.competition_type NOT IN ('league', 'cup') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'not_league_or_cup');
  END IF;

  IF v_fixture.gpsl_month IS NULL OR btrim(v_fixture.gpsl_month) = '' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'no_gpsl_month');
  END IF;

  SELECT
    count(*) FILTER (WHERE m.yellow_card)::int,
    count(*) FILTER (WHERE m.red_card)::int
  INTO v_existing_y, v_existing_r
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  WHERE f.season_id = v_fixture.season_id
    AND f.gpsl_month = v_fixture.gpsl_month
    AND f.status = 'played'
    AND f.competition_type IN ('league', 'cup');

  v_need_y := greatest(coalesce(p_yellow_target, 15) - coalesce(v_existing_y, 0), 0);
  v_need_r := greatest(coalesce(p_red_target, 1) - coalesce(v_existing_r, 0), 0);

  SELECT count(*)::int
  INTO v_remaining
  FROM public.competition_fixtures f
  WHERE f.season_id = v_fixture.season_id
    AND f.gpsl_month = v_fixture.gpsl_month
    AND f.status = 'scheduled'
    AND f.competition_type IN ('league', 'cup');

  -- This played fixture + remaining scheduled fixtures share the leftover quota.
  v_slots := greatest(v_remaining + 1, 1)::numeric;

  IF v_need_y = 0 AND v_need_r = 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'month_targets_met',
      'gpsl_month', v_fixture.gpsl_month,
      'yellows_existing', v_existing_y,
      'reds_existing', v_existing_r
    );
  END IF;

  FOR v_i IN 1..v_need_y LOOP
    IF random() < (1.0 / v_slots) THEN
      v_y_here := v_y_here + 1;
    END IF;
  END LOOP;

  FOR v_i IN 1..v_need_r LOOP
    IF random() < (1.0 / v_slots) THEN
      v_r_here := v_r_here + 1;
    END IF;
  END LOOP;

  FOR v_i IN 1..v_y_here LOOP
    SELECT m.club_short_name, m.player_id
    INTO v_club, v_player
    FROM public.competition_match_player_stats m
    WHERE m.fixture_id = p_fixture_id
      AND (
        coalesce(m.appeared, false)
        OR coalesce(m.started, false)
        OR coalesce(m.subbed_on, false)
      )
      AND NOT coalesce(m.yellow_card, false)
      AND NOT coalesce(m.red_card, false)
    ORDER BY random()
    LIMIT 1;

    EXIT WHEN v_player IS NULL;

    UPDATE public.competition_match_player_stats
    SET yellow_card = true
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_club
      AND player_id = v_player;

    v_assigned := v_assigned || jsonb_build_array(
      jsonb_build_object(
        'kind', 'yellow',
        'club_short_name', v_club,
        'player_id', v_player
      )
    );
  END LOOP;

  FOR v_i IN 1..v_r_here LOOP
    SELECT m.club_short_name, m.player_id
    INTO v_club, v_player
    FROM public.competition_match_player_stats m
    WHERE m.fixture_id = p_fixture_id
      AND (
        coalesce(m.appeared, false)
        OR coalesce(m.started, false)
        OR coalesce(m.subbed_on, false)
      )
      AND NOT coalesce(m.red_card, false)
    ORDER BY random()
    LIMIT 1;

    EXIT WHEN v_player IS NULL;

    UPDATE public.competition_match_player_stats
    SET red_card = true
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_club
      AND player_id = v_player;

    v_assigned := v_assigned || jsonb_build_array(
      jsonb_build_object(
        'kind', 'red',
        'club_short_name', v_club,
        'player_id', v_player
      )
    );
  END LOOP;

  -- Re-run discipline so suspensions / accumulators match live Matchday submit.
  FOR v_pair IN
    SELECT DISTINCT club_short_name
    FROM public.competition_match_player_stats
    WHERE fixture_id = p_fixture_id
      AND (coalesce(yellow_card, false) OR coalesce(red_card, false))
  LOOP
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'player_id', m.player_id,
          'started', coalesce(m.started, false),
          'subbed_on', coalesce(m.subbed_on, false),
          'appeared', coalesce(m.appeared, false),
          'goals', m.goals,
          'assists', m.assists,
          'rating', m.rating,
          'potm', coalesce(m.is_player_of_match, false),
          'yellow_card', coalesce(m.yellow_card, false),
          'red_card', coalesce(m.red_card, false)
        )
      ),
      '[]'::jsonb
    )
    INTO v_stats
    FROM public.competition_match_player_stats m
    WHERE m.fixture_id = p_fixture_id
      AND m.club_short_name = v_pair.club_short_name;

    IF to_regprocedure(
      'public.competition_process_match_discipline(bigint, bigint, text, jsonb)'
    ) IS NOT NULL THEN
      PERFORM public.competition_process_match_discipline(
        p_fixture_id,
        v_fixture.season_id,
        v_pair.club_short_name,
        v_stats
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'gpsl_month', v_fixture.gpsl_month,
    'yellow_target', p_yellow_target,
    'red_target', p_red_target,
    'yellows_existing_before', v_existing_y,
    'reds_existing_before', v_existing_r,
    'slots_including_this', v_slots,
    'yellows_assigned_here', (
      SELECT count(*)::int FROM jsonb_array_elements(v_assigned) e WHERE e->>'kind' = 'yellow'
    ),
    'reds_assigned_here', (
      SELECT count(*)::int FROM jsonb_array_elements(v_assigned) e WHERE e->>'kind' = 'red'
    ),
    'assignments', v_assigned
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_assign_month_cards(bigint, int, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- Main owner RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_simulate_fixture_result(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '60s'
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_fixture public.competition_fixtures;
  v_home jsonb;
  v_away jsonb;
  v_home_str numeric;
  v_away_str numeric;
  v_diff numeric;
  v_outcome text;
  v_score int[];
  v_hg int;
  v_ag int;
  v_home_stats jsonb;
  v_away_stats jsonb;
  v_home_won boolean;
  v_away_won boolean;
  v_draw boolean;
  v_motm_home boolean;
  v_home_star_def int;
  v_away_star_def int;
  v_home_star_create int;
  v_away_star_create int;
  v_home_star_fin int;
  v_away_star_fin int;
  v_home_name text;
  v_away_name text;
  v_cards jsonb;
  v_injuries jsonb;
BEGIN
  IF NOT public.match_result_simulation_enabled() THEN
    RAISE EXCEPTION 'Match result simulation is disabled';
  END IF;

  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for simulation (status=%)', v_fixture.status;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_result_submissions s
    WHERE s.fixture_id = p_fixture_id AND s.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A result is already awaiting confirmation for this fixture';
  END IF;

  -- Lock: if another club holds a fresh lock, block
  IF v_fixture.result_sim_lock_club IS NOT NULL
     AND v_fixture.result_sim_lock_club IS DISTINCT FROM v_club
     AND v_fixture.result_sim_lock_at IS NOT NULL
     AND v_fixture.result_sim_lock_at > now() - interval '30 seconds' THEN
    RAISE EXCEPTION
      'Opponent is already simulating this fixture — wait a moment or refresh';
  END IF;

  UPDATE public.competition_fixtures
  SET result_sim_lock_club = v_club,
      result_sim_lock_at = now()
  WHERE id = p_fixture_id;

  v_home := public.match_sim_load_club_side(v_fixture.home_club_short_name);
  v_away := public.match_sim_load_club_side(v_fixture.away_club_short_name);

  v_home_str := public.match_sim_side_strength(v_home);
  v_away_str := public.match_sim_side_strength(v_away);
  v_diff := v_home_str - v_away_str;

  SELECT
    count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND (e->>'role') IN ('gk', 'def', 'dmf')
        AND coalesce((e->>'started')::boolean, false)
    ),
    count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND (e->>'role') IN ('fb', 'mf')
        AND coalesce((e->>'started')::boolean, false)
    ),
    count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND (e->>'role') = 'fw'
        AND coalesce((e->>'started')::boolean, false)
    )
  INTO v_home_star_def, v_home_star_create, v_home_star_fin
  FROM jsonb_array_elements(v_home) e;

  SELECT
    count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND (e->>'role') IN ('gk', 'def', 'dmf')
        AND coalesce((e->>'started')::boolean, false)
    ),
    count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND (e->>'role') IN ('fb', 'mf')
        AND coalesce((e->>'started')::boolean, false)
    ),
    count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND (e->>'role') = 'fw'
        AND coalesce((e->>'started')::boolean, false)
    )
  INTO v_away_star_def, v_away_star_create, v_away_star_fin
  FROM jsonb_array_elements(v_away) e;

  v_outcome := public.match_sim_pick_outcome(v_home_str, v_away_str);
  v_score := public.match_sim_sample_goals(
    v_outcome,
    v_diff,
    public.match_sim_side_attack(v_home),
    public.match_sim_side_attack(v_away),
    public.match_sim_side_defence(v_home),
    public.match_sim_side_defence(v_away),
    v_home_star_def,
    v_away_star_def,
    v_home_star_create,
    v_away_star_create,
    v_home_star_fin,
    v_away_star_fin
  );
  v_hg := v_score[1];
  v_ag := v_score[2];

  v_home_won := v_hg > v_ag;
  v_away_won := v_ag > v_hg;
  v_draw := v_hg = v_ag;
  v_motm_home := CASE
    WHEN v_home_won THEN true
    WHEN v_away_won THEN false
    ELSE random() < 0.5
  END;

  v_home_stats := public.match_sim_build_club_stats(
    v_home, v_hg, v_ag, v_home_won, v_draw, v_motm_home
  );
  v_away_stats := public.match_sim_build_club_stats(
    v_away, v_ag, v_hg, v_away_won, v_draw, NOT v_motm_home
  );

  -- Cancel any stale pending inbox
  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by match simulation',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_inbox
  SET read_at = coalesce(read_at, now())
  WHERE fixture_id = p_fixture_id
    AND message_type = 'result_to_confirm';

  UPDATE public.competition_fixtures
  SET home_goals = v_hg::smallint,
      away_goals = v_ag::smallint,
      status = 'played',
      result_sim_lock_club = NULL,
      result_sim_lock_at = NULL
  WHERE id = p_fixture_id;

  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_fixture.home_club_short_name,
    v_home_stats,
    v_hg
  );
  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_fixture.away_club_short_name,
    v_away_stats,
    v_ag
  );

  -- Cards: same month quotas as deploy (15 yellow / 1 red across GPSL month)
  v_cards := public.match_sim_assign_month_cards(p_fixture_id, 15, 1);

  -- Injuries: same engine as live Matchday confirm / month deploy
  BEGIN
    IF to_regprocedure('public.competition_serve_injuries_for_fixture(bigint)') IS NOT NULL THEN
      PERFORM public.competition_serve_injuries_for_fixture(p_fixture_id);
      v_injuries := jsonb_build_object('ok', true, 'via', 'serve_injuries');
    ELSIF to_regprocedure('public.competition_injury_roll_for_fixture(bigint)') IS NOT NULL THEN
      v_injuries := public.competition_injury_roll_for_fixture(p_fixture_id);
    ELSE
      v_injuries := jsonb_build_object('ok', false, 'reason', 'injury_engine_missing');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_injuries := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  BEGIN
    PERFORM public.competition_settle_fixture_gates(p_fixture_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  IF v_fixture.competition_type = 'league' THEN
    BEGIN
      PERFORM public.competition_try_pay_league_division_prizes(
        v_fixture.season_id,
        v_fixture.division
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  ELSIF v_fixture.competition_type = 'cup' THEN
    BEGIN
      PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  SELECT "Club" INTO v_home_name FROM public."Clubs" WHERE "ShortName" = v_fixture.home_club_short_name;
  SELECT "Club" INTO v_away_name FROM public."Clubs" WHERE "ShortName" = v_fixture.away_club_short_name;

  -- Notify opponent
  PERFORM public.competition_inbox_notify(
    CASE
      WHEN v_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
      ELSE v_fixture.home_club_short_name
    END,
    'result_confirmed',
    p_fixture_id,
    NULL,
    format('Simulated result: %s vs %s', coalesce(v_home_name, 'Home'), coalesce(v_away_name, 'Away')),
    format(
      'Matchday %s — %s simulated the result %s–%s (XI strength %s vs %s).',
      v_fixture.matchday,
      v_club,
      v_hg,
      v_ag,
      round(v_home_str)::text,
      round(v_away_str)::text
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'home_club', v_fixture.home_club_short_name,
    'away_club', v_fixture.away_club_short_name,
    'home_goals', v_hg,
    'away_goals', v_ag,
    'outcome', v_outcome,
    'home_xi_strength', round(v_home_str, 1),
    'away_xi_strength', round(v_away_str, 1),
    'strength_diff', round(v_diff, 1),
    'simulated_by', v_club,
    'cards', v_cards,
    'injuries', v_injuries
  );
EXCEPTION
  WHEN OTHERS THEN
    UPDATE public.competition_fixtures
    SET result_sim_lock_club = NULL,
        result_sim_lock_at = NULL
    WHERE id = p_fixture_id
      AND result_sim_lock_club = v_club;
    RAISE;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_simulate_fixture_result(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_load_club_side(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_player_rating_num(text, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
