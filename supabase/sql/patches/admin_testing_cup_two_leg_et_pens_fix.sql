-- =============================================================================
-- Fix: Deploy Month / admin testing must honour two-leg aggregate ET + pens
-- (Bowl / Super8 QF second legs).
--
-- Bug: admin_testing_roll_cup_open_play treated every cup fixture as single-leg.
-- When leg2 finished with a decisive score but AGGREGATE still level (e.g. L1 2-1,
-- L2 1-0 → 2-2), no pens were stored → competition_cup_on_fixture_played could
-- not set a winner → SF "Awaiting opponent" → no November Bowl fixtures.
--
-- Also repairs already-stuck two-leg ties (level agg, no pen winner).
--
-- Requires: competition_cup_two_leg_et_pens.sql (+ pen_advance / two_leg repair).
-- Safe re-run.
--
-- After apply (stuck Bowl now):
--   SELECT public.competition_cup_repair_stuck_two_leg_pens(NULL, 'bowl');
--   -- or Admin → Setup Cups → Bowl → Force fill bracket
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Fixture-aware cup score roll
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_testing_roll_cup_for_fixture(
  p_fixture public.competition_fixtures
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_h90 smallint := floor(random() * 5)::smallint;
  v_a90 smallint := floor(random() * 5)::smallint;
  v_home_open smallint;
  v_away_open smallint;
  v_pen text := NULL;
BEGIN
  -- Two-leg first leg: draws allowed; never ET/pens
  IF to_regprocedure('public.competition_cup_is_two_leg_first(public.competition_fixtures)') IS NOT NULL
     AND public.competition_cup_is_two_leg_first(p_fixture) THEN
    RETURN jsonb_build_object(
      'home_90', v_h90,
      'away_90', v_a90,
      'home_open', v_h90,
      'away_open', v_a90,
      'pen_slot', NULL
    );
  END IF;

  -- Two-leg second leg: ET/pens only when aggregate is level after 90
  IF to_regprocedure('public.competition_cup_is_two_leg_second(public.competition_fixtures)') IS NOT NULL
     AND public.competition_cup_is_two_leg_second(p_fixture)
     AND to_regprocedure(
           'public.competition_cup_two_leg_needs_decider(public.competition_fixtures,integer,integer)'
         ) IS NOT NULL THEN
    v_home_open := v_h90;
    v_away_open := v_a90;

    IF public.competition_cup_two_leg_needs_decider(p_fixture, v_h90::int, v_a90::int) THEN
      -- Spec: extra time, then pens if still level. Simulate either ET winner or ET 0-0 + pens.
      IF random() < 0.55 THEN
        -- One side scores in ET → breaks aggregate (no pens)
        IF random() < 0.5 THEN
          v_home_open := (v_h90 + 1 + floor(random() * 2)::int)::smallint;
        ELSE
          v_away_open := (v_a90 + 1 + floor(random() * 2)::int)::smallint;
        END IF;
        v_pen := NULL;
      ELSE
        -- ET goalless (open play stays at 90') → pens decide
        v_home_open := v_h90;
        v_away_open := v_a90;
        v_pen := CASE WHEN random() < 0.5 THEN 'home' ELSE 'away' END;
      END IF;
    ELSE
      v_pen := NULL;
    END IF;

    RETURN jsonb_build_object(
      'home_90', v_h90,
      'away_90', v_a90,
      'home_open', v_home_open,
      'away_open', v_away_open,
      'pen_slot', v_pen
    );
  END IF;

  -- Single-leg cups (Shield / Plate / League Cup / Bowl SF-Final): ET/pens on draw
  IF v_h90 > v_a90 THEN
    v_home_open := v_h90;
    v_away_open := v_a90;
    v_pen := NULL;
  ELSIF v_a90 > v_h90 THEN
    v_home_open := v_h90;
    v_away_open := v_a90;
    v_pen := NULL;
  ELSIF random() < 0.45 THEN
    v_home_open := v_h90;
    v_away_open := v_a90;
    IF random() < 0.5 THEN
      v_home_open := (v_h90 + 1 + floor(random() * 2)::int)::smallint;
    ELSE
      v_away_open := (v_a90 + 1 + floor(random() * 2)::int)::smallint;
    END IF;
    IF v_home_open = v_away_open THEN
      v_home_open := v_home_open + 1;
    END IF;
    v_pen := NULL;
  ELSE
    v_home_open := v_h90;
    v_away_open := v_a90;
    v_pen := CASE WHEN random() < 0.5 THEN 'home' ELSE 'away' END;
  END IF;

  RETURN jsonb_build_object(
    'home_90', v_h90,
    'away_90', v_a90,
    'home_open', v_home_open,
    'away_open', v_away_open,
    'pen_slot', v_pen
  );
END;
$function$;

-- Keep old name for callers that ignore fixture context (legacy); single-leg behaviour
CREATE OR REPLACE FUNCTION public.admin_testing_roll_cup_open_play()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $function$
DECLARE
  v_dummy public.competition_fixtures;
BEGIN
  -- Empty row → falls through to single-leg path in roll_cup_for_fixture
  RETURN public.admin_testing_roll_cup_for_fixture(v_dummy);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Deploy one fixture (availability-aware) using fixture-aware cup roll
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_testing_deploy_scheduled_fixture(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home_stats jsonb;
  v_away_stats jsonb;
  v_home_goals smallint;
  v_away_goals smallint;
  v_pen_winner text;
  v_cup_roll jsonb;
  v_gate_err text;
  v_prize_err text;
  v_score_label text;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture % is not scheduled (status=%)', p_fixture_id, v_fixture.status;
  END IF;

  IF v_fixture.competition_type NOT IN ('league', 'cup') THEN
    RAISE EXCEPTION 'Unsupported competition_type=%', v_fixture.competition_type;
  END IF;

  IF NOT public.admin_testing_fixture_squads_ready(
    v_fixture.home_club_short_name,
    v_fixture.away_club_short_name,
    p_fixture_id
  ) THEN
    RAISE EXCEPTION 'Not enough available players — % (% avail) vs % (% avail)',
      v_fixture.home_club_short_name,
      public.admin_testing_club_available_count(v_fixture.home_club_short_name, p_fixture_id),
      v_fixture.away_club_short_name,
      public.admin_testing_club_available_count(v_fixture.away_club_short_name, p_fixture_id);
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by admin testing month deploy',
      responded_by_club = NULL,
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_inbox
  SET read_at = coalesce(read_at, now())
  WHERE fixture_id = p_fixture_id
    AND message_type = 'result_to_confirm';

  IF v_fixture.competition_type = 'league' THEN
    v_home_goals := floor(random() * 5)::smallint;
    v_away_goals := floor(random() * 5)::smallint;
    v_pen_winner := NULL;
    v_score_label := format('%s-%s', v_home_goals, v_away_goals);
  ELSE
    v_cup_roll := public.admin_testing_roll_cup_for_fixture(v_fixture);
    v_home_goals := (v_cup_roll->>'home_open')::smallint;
    v_away_goals := (v_cup_roll->>'away_open')::smallint;
    IF v_cup_roll->>'pen_slot' = 'home' THEN
      v_pen_winner := v_fixture.home_club_short_name;
      v_score_label := format(
        '%s-%s aet pens (%s)',
        v_cup_roll->>'home_90',
        v_cup_roll->>'away_90',
        v_fixture.home_club_short_name
      );
    ELSIF v_cup_roll->>'pen_slot' = 'away' THEN
      v_pen_winner := v_fixture.away_club_short_name;
      v_score_label := format(
        '%s-%s aet pens (%s)',
        v_cup_roll->>'home_90',
        v_cup_roll->>'away_90',
        v_fixture.away_club_short_name
      );
    ELSIF (v_cup_roll->>'home_open')::int <> (v_cup_roll->>'home_90')::int
       OR (v_cup_roll->>'away_open')::int <> (v_cup_roll->>'away_90')::int THEN
      v_pen_winner := NULL;
      v_score_label := format(
        '%s-%s (%s-%s aet)',
        v_cup_roll->>'home_90',
        v_cup_roll->>'away_90',
        v_home_goals,
        v_away_goals
      );
    ELSE
      v_pen_winner := NULL;
      v_score_label := format('%s-%s', v_home_goals, v_away_goals);
    END IF;
  END IF;

  v_home_stats := public.admin_testing_build_club_match_stats(
    v_fixture.home_club_short_name,
    CASE
      WHEN v_fixture.competition_type = 'cup' AND v_pen_winner IS NOT NULL
        THEN (v_cup_roll->>'home_90')::int
      ELSE v_home_goals::int
    END,
    p_fixture_id
  );
  v_away_stats := public.admin_testing_build_club_match_stats(
    v_fixture.away_club_short_name,
    CASE
      WHEN v_fixture.competition_type = 'cup' AND v_pen_winner IS NOT NULL
        THEN (v_cup_roll->>'away_90')::int
      ELSE v_away_goals::int
    END,
    p_fixture_id
  );

  UPDATE public.competition_fixtures
  SET home_goals = v_home_goals,
      away_goals = v_away_goals,
      cup_pen_winner_club_short_name = v_pen_winner,
      status = 'played'
  WHERE id = p_fixture_id;

  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_fixture.home_club_short_name,
    v_home_stats,
    CASE
      WHEN v_fixture.competition_type = 'cup' AND v_pen_winner IS NOT NULL
        THEN (v_cup_roll->>'home_90')::int
      ELSE v_home_goals::int
    END
  );
  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_fixture.away_club_short_name,
    v_away_stats,
    CASE
      WHEN v_fixture.competition_type = 'cup' AND v_pen_winner IS NOT NULL
        THEN (v_cup_roll->>'away_90')::int
      ELSE v_away_goals::int
    END
  );

  BEGIN
    PERFORM public.competition_settle_fixture_gates(p_fixture_id);
  EXCEPTION
    WHEN OTHERS THEN
      v_gate_err := SQLERRM;
  END;

  IF v_fixture.competition_type = 'league' THEN
    BEGIN
      PERFORM public.competition_try_pay_league_division_prizes(
        v_fixture.season_id,
        v_fixture.division
      );
    EXCEPTION
      WHEN OTHERS THEN
        v_prize_err := SQLERRM;
    END;
  ELSE
    BEGIN
      PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
    EXCEPTION
      WHEN OTHERS THEN
        v_prize_err := SQLERRM;
    END;
    BEGIN
      PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
    EXCEPTION
      WHEN OTHERS THEN
        v_prize_err := coalesce(v_prize_err, SQLERRM);
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'competition_type', v_fixture.competition_type,
    'cup_code', v_fixture.cup_code,
    'cup_round', v_fixture.cup_round,
    'cup_leg', v_fixture.cup_leg,
    'home_club', v_fixture.home_club_short_name,
    'away_club', v_fixture.away_club_short_name,
    'score', v_score_label,
    'pen_winner', v_pen_winner,
    'matchday', v_fixture.matchday,
    'gpsl_month', v_fixture.gpsl_month,
    'gate_warning', v_gate_err,
    'prize_warning', v_prize_err
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Repair: level-on-aggregate two-leg ties with no pen winner → invent pens + advance
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_cup_repair_stuck_two_leg_pens(
  p_season_id bigint DEFAULT NULL,
  p_cup_code text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_cup text;
  v_node record;
  v_fx1 public.competition_fixtures;
  v_fx2 public.competition_fixtures;
  v_winner text;
  v_pen text;
  v_fixed int := 0;
  v_skipped int := 0;
  v_details jsonb := '[]'::jsonb;
  v_fill jsonb := NULL;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season := p_season_id;
  END IF;

  IF v_season IS NULL THEN
    RAISE EXCEPTION 'No season';
  END IF;

  IF p_cup_code IS NOT NULL AND btrim(p_cup_code) <> '' THEN
    IF to_regprocedure('public.competition_cup_normalize_code(text)') IS NOT NULL THEN
      v_cup := public.competition_cup_normalize_code(p_cup_code);
    ELSE
      v_cup := lower(btrim(p_cup_code));
    END IF;
  ELSE
    v_cup := NULL;
  END IF;

  FOR v_node IN
    SELECT n.*
    FROM public.competition_cup_bracket_nodes n
    WHERE n.season_id = v_season
      AND n.leg1_node_id IS NOT NULL
      AND (v_cup IS NULL OR lower(n.cup_code) = v_cup)
      AND n.winner_club_short_name IS NULL
    ORDER BY n.cup_code, n.round_no, n.match_no
  LOOP
    SELECT * INTO v_fx1
    FROM public.competition_fixtures f
    WHERE f.id = (
      SELECT l1.fixture_id
      FROM public.competition_cup_bracket_nodes l1
      WHERE l1.id = v_node.leg1_node_id
    );

    SELECT * INTO v_fx2
    FROM public.competition_fixtures f
    WHERE f.id = v_node.fixture_id;

    IF v_fx1.id IS NULL OR v_fx2.id IS NULL
       OR v_fx1.status IS DISTINCT FROM 'played'
       OR v_fx2.status IS DISTINCT FROM 'played'
       OR v_fx1.home_goals IS NULL OR v_fx1.away_goals IS NULL
       OR v_fx2.home_goals IS NULL OR v_fx2.away_goals IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- Already have a resolvable winner (agg or existing pens)?
    v_winner := NULL;
    IF to_regprocedure(
         'public.competition_cup_repair_two_leg_winner_for_node(bigint)'
       ) IS NOT NULL THEN
      v_winner := public.competition_cup_repair_two_leg_winner_for_node(v_node.id);
    END IF;

    IF v_winner IS NOT NULL THEN
      UPDATE public.competition_cup_bracket_nodes
      SET winner_club_short_name = v_winner
      WHERE id = v_node.id;
      PERFORM public.competition_cup_advance_node_winner(v_node.id);
      v_fixed := v_fixed + 1;
      v_details := v_details || jsonb_build_array(
        jsonb_build_object(
          'cup', v_node.cup_code,
          'round', v_node.round_no,
          'match', v_node.match_no,
          'action', 'advance_existing',
          'winner', v_winner
        )
      );
      CONTINUE;
    END IF;

    -- Need pens: aggregate must be level
    IF to_regprocedure(
         'public.competition_cup_two_leg_needs_decider(public.competition_fixtures,integer,integer)'
       ) IS NULL
       OR NOT public.competition_cup_two_leg_needs_decider(
            v_fx2, v_fx2.home_goals::int, v_fx2.away_goals::int
          ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_pen := CASE WHEN random() < 0.5
      THEN v_fx2.home_club_short_name
      ELSE v_fx2.away_club_short_name
    END;

    UPDATE public.competition_fixtures
    SET cup_pen_winner_club_short_name = v_pen
    WHERE id = v_fx2.id;

    PERFORM public.competition_cup_on_fixture_played(v_fx2.id);

    v_fixed := v_fixed + 1;
    v_details := v_details || jsonb_build_array(
      jsonb_build_object(
        'cup', v_node.cup_code,
        'round', v_node.round_no,
        'match', v_node.match_no,
        'fixture_id', v_fx2.id,
        'action', 'assign_pens',
        'pen_winner', v_pen
      )
    );
  END LOOP;

  IF to_regprocedure('public.competition_cup_repair_force_fill(bigint, text)') IS NOT NULL THEN
    IF v_cup IS NOT NULL THEN
      BEGIN
        v_fill := public.competition_cup_repair_force_fill(v_season, v_cup);
      EXCEPTION
        WHEN OTHERS THEN
          v_fill := jsonb_build_object('error', SQLERRM);
      END;
    ELSE
      v_fill := '{}'::jsonb;
      BEGIN
        v_fill := v_fill || jsonb_build_object(
          'bowl', public.competition_cup_repair_force_fill(v_season, 'bowl')
        );
      EXCEPTION
        WHEN OTHERS THEN
          v_fill := v_fill || jsonb_build_object('bowl', jsonb_build_object('error', SQLERRM));
      END;
      BEGIN
        v_fill := v_fill || jsonb_build_object(
          'super8', public.competition_cup_repair_force_fill(v_season, 'super8')
        );
      EXCEPTION
        WHEN OTHERS THEN
          v_fill := v_fill || jsonb_build_object('super8', jsonb_build_object('error', SQLERRM));
      END;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'cup_code', v_cup,
    'ties_fixed', v_fixed,
    'ties_skipped', v_skipped,
    'details', v_details,
    'force_fill', v_fill
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_testing_roll_cup_for_fixture(public.competition_fixtures) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_testing_roll_cup_open_play() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_testing_deploy_scheduled_fixture(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_repair_stuck_two_leg_pens(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- Repair stuck Bowl (current season) after applying this patch:
--   SELECT public.competition_cup_repair_stuck_two_leg_pens(NULL, 'bowl');
-- Then check November Bowl SF fixtures exist / End Month Early again.
-- =============================================================================
