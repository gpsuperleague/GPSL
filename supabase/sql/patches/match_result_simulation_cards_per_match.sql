-- =============================================================================
-- Match sim cards: per-match yellows + % chance of one red
-- Defaults: 3 yellows / match, 5% chance of a single red
-- UI: admin_match_sim.html
-- Run after match_result_simulation_outcome_bands.sql
-- =============================================================================

SET lock_timeout = '15s';
SET statement_timeout = '90s';

-- Seed / migrate settings keys
UPDATE public.global_settings
SET match_result_simulation_settings =
  coalesce(match_result_simulation_settings, '{}'::jsonb)
  || jsonb_build_object(
    'yellow_per_match', coalesce(
      (match_result_simulation_settings->>'yellow_per_match')::int,
      3
    ),
    'red_chance_pct', coalesce(
      (match_result_simulation_settings->>'red_chance_pct')::numeric,
      5
    )
  )
WHERE id = 1;

-- ---------------------------------------------------------------------------
-- Assign N yellows this match; with p_red_chance_pct% chance assign one red.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_sim_assign_match_cards(
  p_fixture_id bigint,
  p_yellow_count int DEFAULT 3,
  p_red_chance_pct numeric DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture record;
  v_y_here int := greatest(0, least(22, coalesce(p_yellow_count, 3)));
  v_r_here int := 0;
  v_i int;
  v_club text;
  v_player text;
  v_pair record;
  v_stats jsonb;
  v_assigned jsonb := '[]'::jsonb;
  v_chance numeric := greatest(0, least(100, coalesce(p_red_chance_pct, 5)));
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

  -- Exactly one red with the configured chance (e.g. 5% → at most one red).
  IF random() * 100.0 < v_chance THEN
    v_r_here := 1;
  END IF;

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
    'mode', 'per_match',
    'yellow_per_match', v_y_here,
    'red_chance_pct', v_chance,
    'yellows_assigned', (
      SELECT count(*)::int FROM jsonb_array_elements(v_assigned) e WHERE e->>'kind' = 'yellow'
    ),
    'reds_assigned', (
      SELECT count(*)::int FROM jsonb_array_elements(v_assigned) e WHERE e->>'kind' = 'red'
    ),
    'assignments', v_assigned
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_assign_match_cards(bigint, int, numeric) TO authenticated;

-- Settings getter / setter (keeps outcome_bands)
CREATE OR REPLACE FUNCTION public.match_sim_settings()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'yellow_per_match', coalesce((s->>'yellow_per_match')::int, 3),
    'red_chance_pct', coalesce((s->>'red_chance_pct')::numeric, 5),
    'cards_enabled', coalesce((s->>'cards_enabled')::boolean, true),
    'injuries_enabled', coalesce((s->>'injuries_enabled')::boolean, true),
    'max_subs_on', greatest(0, least(5, coalesce((s->>'max_subs_on')::int, 5))),
    'outcome_bands', public.match_sim_normalize_outcome_bands(s->'outcome_bands')
  )
  FROM (
    SELECT coalesce(g.match_result_simulation_settings, '{}'::jsonb) AS s
    FROM public.global_settings g
    WHERE g.id = 1
  ) x;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_match_sim_settings(p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_in jsonb := coalesce(p_settings, '{}'::jsonb);
  v_out jsonb;
  v_yellow int;
  v_red_chance numeric;
  v_max_subs int;
  v_bands jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_yellow := greatest(0, least(22, coalesce((v_in->>'yellow_per_match')::int, 3)));
  v_red_chance := greatest(0, least(100, coalesce((v_in->>'red_chance_pct')::numeric, 5)));
  v_max_subs := greatest(0, least(5, coalesce((v_in->>'max_subs_on')::int, 5)));
  v_bands := public.match_sim_normalize_outcome_bands(v_in->'outcome_bands');

  v_out := jsonb_build_object(
    'yellow_per_match', v_yellow,
    'red_chance_pct', v_red_chance,
    'cards_enabled', coalesce((v_in->>'cards_enabled')::boolean, true),
    'injuries_enabled', coalesce((v_in->>'injuries_enabled')::boolean, true),
    'max_subs_on', v_max_subs,
    'outcome_bands', v_bands
  );

  UPDATE public.global_settings
  SET match_result_simulation_settings = v_out,
      updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'settings', public.match_sim_settings(),
    'enabled', public.match_result_simulation_enabled()
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_match_sim_settings(jsonb) TO authenticated;


-- Wire simulate to per-match card rules
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
  v_settings jsonb;
  v_yellow_per_match int := 3;
  v_red_chance_pct numeric := 5;
  v_cards_enabled boolean := true;
  v_injuries_enabled boolean := true;
BEGIN
  IF NOT public.match_result_simulation_enabled() THEN
    RAISE EXCEPTION 'Match result simulation is disabled';
  END IF;

  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_settings := public.match_sim_settings();
  v_yellow_per_match := coalesce((v_settings->>'yellow_per_match')::int, 3);
  v_red_chance_pct := coalesce((v_settings->>'red_chance_pct')::numeric, 5);
  v_cards_enabled := coalesce((v_settings->>'cards_enabled')::boolean, true);
  v_injuries_enabled := coalesce((v_settings->>'injuries_enabled')::boolean, true);

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

  IF v_fixture.result_sim_lock_club IS NOT NULL
     AND v_fixture.result_sim_lock_club IS DISTINCT FROM v_club
     AND v_fixture.result_sim_lock_at IS NOT NULL
     AND v_fixture.result_sim_lock_at > now() - interval '30 seconds' THEN
    RAISE EXCEPTION
      'Opponent is already simulating this fixture 窶・wait a moment or refresh';
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

  IF v_cards_enabled THEN
    v_cards := public.match_sim_assign_match_cards(
      p_fixture_id, v_yellow_per_match, v_red_chance_pct
    );
  ELSE
    v_cards := jsonb_build_object('ok', true, 'skipped', true, 'reason', 'cards_disabled');
  END IF;

  IF v_injuries_enabled THEN
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
  ELSE
    v_injuries := jsonb_build_object('ok', true, 'skipped', true, 'reason', 'injuries_disabled');
  END IF;

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
      'Matchday %s 窶・%s simulated the result %s窶・s (XI strength %s vs %s).',
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
    'settings', v_settings,
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

NOTIFY pgrst, 'reload schema';