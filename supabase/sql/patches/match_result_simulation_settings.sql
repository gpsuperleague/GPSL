-- =============================================================================
-- Match simulation settings (admin Testing page)
-- UI: admin_match_sim.html
-- Stores adjustable sim rules on global_settings; simulate RPC reads them.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS match_result_simulation_settings jsonb
  NOT NULL DEFAULT jsonb_build_object(
    'yellow_per_month', 15,
    'red_per_month', 1,
    'cards_enabled', true,
    'injuries_enabled', true,
    'max_subs_on', 5
  );

COMMENT ON COLUMN public.global_settings.match_result_simulation_settings IS
  'Admin-tunable match result simulation rules (cards/month, injury roll, etc).';

-- Ensure defaults exist for older rows
UPDATE public.global_settings
SET match_result_simulation_settings =
  coalesce(match_result_simulation_settings, '{}'::jsonb)
  || jsonb_build_object(
    'yellow_per_month', coalesce((match_result_simulation_settings->>'yellow_per_month')::int, 15),
    'red_per_month', coalesce((match_result_simulation_settings->>'red_per_month')::int, 1),
    'cards_enabled', coalesce((match_result_simulation_settings->>'cards_enabled')::boolean, true),
    'injuries_enabled', coalesce((match_result_simulation_settings->>'injuries_enabled')::boolean, true),
    'max_subs_on', coalesce((match_result_simulation_settings->>'max_subs_on')::int, 5)
  )
WHERE id = 1;

CREATE OR REPLACE FUNCTION public.match_sim_settings()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'yellow_per_month', coalesce((s->>'yellow_per_month')::int, 15),
    'red_per_month', coalesce((s->>'red_per_month')::int, 1),
    'cards_enabled', coalesce((s->>'cards_enabled')::boolean, true),
    'injuries_enabled', coalesce((s->>'injuries_enabled')::boolean, true),
    'max_subs_on', greatest(0, least(5, coalesce((s->>'max_subs_on')::int, 5)))
  )
  FROM (
    SELECT coalesce(g.match_result_simulation_settings, '{}'::jsonb) AS s
    FROM public.global_settings g
    WHERE g.id = 1
  ) x;
$$;

CREATE OR REPLACE FUNCTION public.match_result_simulation_status()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'enabled', public.match_result_simulation_enabled(),
    'is_admin', public.is_gpsl_admin(),
    'settings', public.match_sim_settings()
  );
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
  v_red int;
  v_max_subs int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_yellow := greatest(0, least(200, coalesce((v_in->>'yellow_per_month')::int, 15)));
  v_red := greatest(0, least(50, coalesce((v_in->>'red_per_month')::int, 1)));
  v_max_subs := greatest(0, least(5, coalesce((v_in->>'max_subs_on')::int, 5)));

  v_out := jsonb_build_object(
    'yellow_per_month', v_yellow,
    'red_per_month', v_red,
    'cards_enabled', coalesce((v_in->>'cards_enabled')::boolean, true),
    'injuries_enabled', coalesce((v_in->>'injuries_enabled')::boolean, true),
    'max_subs_on', v_max_subs
  );

  UPDATE public.global_settings
  SET match_result_simulation_settings = v_out,
      updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'settings', v_out,
    'enabled', public.match_result_simulation_enabled()
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_result_simulation_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_match_sim_settings(jsonb) TO authenticated;

-- Simulate uses stored settings for cards / injuries
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
  v_yellow_target int := 15;
  v_red_target int := 1;
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
  v_yellow_target := coalesce((v_settings->>'yellow_per_month')::int, 15);
  v_red_target := coalesce((v_settings->>'red_per_month')::int, 1);
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
    v_cards := public.match_sim_assign_month_cards(
      p_fixture_id, v_yellow_target, v_red_target
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

-- Bench sub count follows settings.max_subs_on
CREATE OR REPLACE FUNCTION public.match_sim_load_club_side(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club);
  v_rows jsonb;
  v_n int;
  v_max_subs int := 5;
BEGIN
  BEGIN
    v_max_subs := greatest(
      0,
      least(5, coalesce((public.match_sim_settings()->>'max_subs_on')::int, 5))
    );
  EXCEPTION WHEN OTHERS THEN
    v_max_subs := 5;
  END;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id', sp.player_id,
        'name', p."Name",
        'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
        'role', public.match_sim_role_from_slot(sp.pitch_slot, p."Position"),
        'pitch_slot', sp.pitch_slot,
        'started', true,
        'subbed_on', false,
        'is_star', public.match_sim_is_star(
          public.match_sim_player_rating_num(p."Rating"::text, 70)
        )
      )
      ORDER BY sp.sort_order NULLS LAST, sp.pitch_slot, p."Name"
    ),
    '[]'::jsonb
  )
  INTO v_rows
  FROM public.club_matchday_squad_player sp
  JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
  WHERE sp.club_short_name = v_club
    AND sp.slot_kind = 'pitch'
    AND p."Contracted_Team" = v_club;

  v_n := jsonb_array_length(v_rows);

  IF v_n < 11 THEN
    SELECT coalesce(
      jsonb_agg(x.obj ORDER BY x.ord),
      '[]'::jsonb
    )
    INTO v_rows
    FROM (
      SELECT
        jsonb_build_object(
          'player_id', p."Konami_ID"::text,
          'name', p."Name",
          'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
          'role', public.match_sim_role_from_slot(NULL, p."Position"),
          'pitch_slot', NULL,
          'started', true,
          'subbed_on', false,
          'is_star', public.match_sim_is_star(
            public.match_sim_player_rating_num(p."Rating"::text, 70)
          )
        ) AS obj,
        row_number() OVER (
          ORDER BY public.match_sim_player_rating_num(p."Rating"::text, 0) DESC, p."Name"
        ) AS ord
      FROM public."Players" p
      WHERE p."Contracted_Team" = v_club
      LIMIT 11
    ) x;
    v_n := jsonb_array_length(v_rows);
  END IF;

  IF v_n < 11 THEN
    RAISE EXCEPTION 'Club % needs at least 11 contracted players to simulate (have %)', v_club, v_n;
  END IF;

  IF v_max_subs <= 0 THEN
    RETURN v_rows;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.club_matchday_squad_player sp
    WHERE sp.club_short_name = v_club AND sp.slot_kind = 'bench'
  ) THEN
    SELECT v_rows || coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'player_id', b.player_id,
            'name', b.name,
            'rating', b.rating,
            'role', b.role,
            'pitch_slot', NULL,
            'started', false,
            'subbed_on', true,
            'is_star', b.is_star
          )
          ORDER BY b.ord
        )
        FROM (
          SELECT
            sp.player_id,
            p."Name" AS name,
            public.match_sim_player_rating_num(p."Rating"::text, 70) AS rating,
            public.match_sim_role_from_slot(NULL, p."Position") AS role,
            public.match_sim_is_star(
              public.match_sim_player_rating_num(p."Rating"::text, 70)
            ) AS is_star,
            row_number() OVER (
              ORDER BY sp.sort_order NULLS LAST, p."Name"
            ) AS ord
          FROM public.club_matchday_squad_player sp
          JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
          WHERE sp.club_short_name = v_club
            AND sp.slot_kind = 'bench'
            AND p."Contracted_Team" = v_club
        ) b
        WHERE b.ord <= v_max_subs
      ),
      '[]'::jsonb
    )
    INTO v_rows;
  ELSE
    SELECT v_rows || coalesce(
      (
        SELECT jsonb_agg(y.obj ORDER BY y.ord)
        FROM (
          SELECT
            jsonb_build_object(
              'player_id', p."Konami_ID"::text,
              'name', p."Name",
              'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
              'role', public.match_sim_role_from_slot(NULL, p."Position"),
              'pitch_slot', NULL,
              'started', false,
              'subbed_on', true,
              'is_star', public.match_sim_is_star(
                public.match_sim_player_rating_num(p."Rating"::text, 70)
              )
            ) AS obj,
            row_number() OVER (
              ORDER BY public.match_sim_player_rating_num(p."Rating"::text, 0) DESC, p."Name"
            ) AS ord
          FROM public."Players" p
          WHERE p."Contracted_Team" = v_club
            AND NOT EXISTS (
              SELECT 1
              FROM jsonb_array_elements(v_rows) e
              WHERE e->>'player_id' = p."Konami_ID"::text
            )
        ) y
        WHERE y.ord <= v_max_subs
      ),
      '[]'::jsonb
    )
    INTO v_rows;
  END IF;

  RETURN v_rows;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_load_club_side(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
