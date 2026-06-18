-- =============================================================================
-- Fix cup byes: admin-selected clubs skip R1 and appear in round 2 correctly.
-- Bug: bye teams were placed on R2 home, then overwritten by R1 child links
--      (standard 2:1 pairing). Also leaves empty ghost R1 slots (M29–32).
-- Run after competition_cup_byes_admin.sql + competition_cup_weather_from_schedule.sql
-- Then re-draw the cup in GPSL Admin (saved byes are kept).
-- =============================================================================

DROP FUNCTION IF EXISTS public.competition_build_knockout_bracket(bigint, text, text[]);

CREATE OR REPLACE FUNCTION public.competition_build_knockout_bracket(
  p_season_id bigint,
  p_cup_code text,
  p_clubs text[],
  p_bye_clubs text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int;
  v_target int := 1;
  v_byes int;
  v_players text[];
  v_byes_clubs text[];
  v_sched record;
  v_round int;
  v_leg int;
  v_matches int;
  v_match int;
  v_home text;
  v_away text;
  v_i int;
  v_idx int;
  v_node_id bigint;
  v_leg1_node_id bigint;
  v_parent_id bigint;
  v_child_id bigint;
  v_prev_round_ids bigint[];
  v_curr_round_ids bigint[];
  v_leg1_ids bigint[];
  v_r1_ids bigint[];
  v_r2_ids bigint[];
  v_r1_playable int;
  v_r2_slot int;
  v_node record;
  v_r1_count int := 0;
  v_first_round int;
  v_max_round int;
  v_b text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_clubs IS NULL OR array_length(p_clubs, 1) IS NULL OR array_length(p_clubs, 1) < 2 THEN
    RAISE EXCEPTION 'Need at least 2 clubs to draw %', p_cup_code;
  END IF;

  v_max_round := public.competition_cup_scheduled_round_count(p_cup_code);
  IF v_max_round IS NULL OR v_max_round < 1 THEN
    RAISE EXCEPTION 'No schedule configured for cup %', p_cup_code;
  END IF;

  SELECT min(round_no)
  INTO v_first_round
  FROM public.competition_cup_round_schedule
  WHERE cup_code = p_cup_code;

  DELETE FROM public.competition_cup_bracket_nodes
  WHERE season_id = p_season_id AND cup_code = p_cup_code;

  DELETE FROM public.competition_fixtures
  WHERE season_id = p_season_id
    AND competition_type = 'cup'
    AND cup_code = p_cup_code;

  v_n := array_length(p_clubs, 1);
  SELECT max(matches_in_round) * 2
  INTO v_target
  FROM public.competition_cup_round_schedule
  WHERE cup_code = p_cup_code
    AND round_no = v_first_round;

  IF v_target IS NULL THEN
    WHILE v_target < v_n LOOP
      v_target := v_target * 2;
    END LOOP;
  END IF;

  WHILE v_target < v_n LOOP
    v_target := v_target * 2;
  END LOOP;

  v_byes := v_target - v_n;

  IF v_byes > 0 THEN
    IF p_bye_clubs IS NULL OR coalesce(array_length(p_bye_clubs, 1), 0) <> v_byes THEN
      RAISE EXCEPTION 'Assign exactly % first-round bye club(s) for % before drawing', v_byes, p_cup_code;
    END IF;

    v_byes_clubs := ARRAY[]::text[];
    FOREACH v_b IN ARRAY p_bye_clubs LOOP
      v_b := upper(trim(v_b));
      IF NOT (v_b = ANY (p_clubs)) THEN
        RAISE EXCEPTION 'Bye club % is not in the qualified list for %', v_b, p_cup_code;
      END IF;
      IF v_b = ANY (v_byes_clubs) THEN
        RAISE EXCEPTION 'Duplicate bye club %', v_b;
      END IF;
      v_byes_clubs := array_append(v_byes_clubs, v_b);
    END LOOP;

    SELECT coalesce(array_agg(x.club ORDER BY random()), ARRAY[]::text[])
    INTO v_players
    FROM (
      SELECT unnest(p_clubs) AS club
      EXCEPT
      SELECT unnest(v_byes_clubs)
    ) x;
  ELSE
    v_byes_clubs := ARRAY[]::text[];
    v_players := public.competition_shuffle_club_array(p_clubs);
  END IF;

  v_r1_playable := coalesce(array_length(v_players, 1), 0) / 2;

  v_prev_round_ids := NULL;
  v_leg1_ids := NULL;

  FOR v_sched IN
    SELECT *
    FROM public.competition_cup_round_schedule
    WHERE cup_code = p_cup_code
    ORDER BY round_no, cup_leg
  LOOP
    v_round := v_sched.round_no;
    v_leg := v_sched.cup_leg;
    v_matches := v_sched.matches_in_round;
    v_curr_round_ids := ARRAY[]::bigint[];

    FOR v_match IN 1..v_matches LOOP
      v_home := NULL;
      v_away := NULL;
      v_leg1_node_id := NULL;

      IF v_round = v_first_round AND v_leg = 1 THEN
        v_idx := (v_match - 1) * 2 + 1;
        IF v_idx <= coalesce(array_length(v_players, 1), 0) THEN
          v_home := v_players[v_idx];
        END IF;
        IF v_idx + 1 <= coalesce(array_length(v_players, 1), 0) THEN
          v_away := v_players[v_idx + 1];
        END IF;
      ELSIF v_leg = 2 THEN
        v_leg1_node_id := v_leg1_ids[v_match];
        SELECT away_club_short_name, home_club_short_name
        INTO v_home, v_away
        FROM public.competition_cup_bracket_nodes
        WHERE id = v_leg1_node_id;
      END IF;

      INSERT INTO public.competition_cup_bracket_nodes (
        season_id, cup_code, round_no, match_no, cup_leg,
        home_club_short_name, away_club_short_name, leg1_node_id
      )
      VALUES (
        p_season_id, p_cup_code, v_round, v_match, v_leg,
        v_home, v_away, v_leg1_node_id
      )
      RETURNING id INTO v_node_id;

      v_curr_round_ids := array_append(v_curr_round_ids, v_node_id);

      IF v_round = v_first_round AND v_leg = 1 THEN
        v_leg1_ids := coalesce(v_leg1_ids, ARRAY[]::bigint[]);
        v_leg1_ids := array_append(v_leg1_ids, v_node_id);
      END IF;

      IF v_home IS NOT NULL AND v_away IS NOT NULL THEN
        PERFORM public.competition_create_cup_fixture_for_node(v_node_id);
        IF v_round = v_first_round AND v_leg = 1 THEN
          v_r1_count := v_r1_count + 1;
        END IF;
      END IF;
    END LOOP;

    IF v_leg = 2 THEN
      v_prev_round_ids := v_curr_round_ids;
    ELSIF v_prev_round_ids IS NOT NULL THEN
      IF v_byes > 0 AND v_round = v_first_round + 1 THEN
        -- R1→R2 links are wired after the draw when byes are used.
        NULL;
      ELSE
        FOR v_i IN 1..coalesce(array_length(v_prev_round_ids, 1), 0) LOOP
          v_parent_id := v_prev_round_ids[v_i];
          v_child_id := v_curr_round_ids[(v_i + 1) / 2];
          UPDATE public.competition_cup_bracket_nodes
          SET child_node_id = v_child_id,
              child_slot = CASE WHEN v_i % 2 = 1 THEN 'home' ELSE 'away' END
          WHERE id = v_parent_id;
        END LOOP;
      END IF;
      v_prev_round_ids := v_curr_round_ids;
    ELSE
      v_prev_round_ids := v_curr_round_ids;
    END IF;
  END LOOP;

  IF v_byes > 0 THEN
    SELECT array_agg(id ORDER BY match_no)
    INTO v_r1_ids
    FROM public.competition_cup_bracket_nodes
    WHERE season_id = p_season_id
      AND cup_code = p_cup_code
      AND round_no = v_first_round
      AND coalesce(cup_leg, 1) = 1;

    SELECT array_agg(id ORDER BY match_no)
    INTO v_r2_ids
    FROM public.competition_cup_bracket_nodes
    WHERE season_id = p_season_id
      AND cup_code = p_cup_code
      AND round_no = v_first_round + 1
      AND coalesce(cup_leg, 1) = 1;

    UPDATE public.competition_cup_bracket_nodes
    SET child_node_id = NULL, child_slot = NULL
    WHERE season_id = p_season_id
      AND cup_code = p_cup_code
      AND round_no = v_first_round
      AND coalesce(cup_leg, 1) = 1;

    FOR v_i IN 1..v_byes LOOP
      UPDATE public.competition_cup_bracket_nodes n
      SET home_club_short_name = v_byes_clubs[v_i]
      WHERE n.id = v_r2_ids[v_i];

      UPDATE public.competition_cup_bracket_nodes
      SET child_node_id = v_r2_ids[v_i], child_slot = 'away'
      WHERE id = v_r1_ids[v_i];
    END LOOP;

    v_i := v_byes + 1;
    v_r2_slot := v_byes;
    WHILE v_i + 1 <= v_r1_playable LOOP
      v_r2_slot := v_r2_slot + 1;
      EXIT WHEN v_r2_ids IS NULL OR v_r2_slot > coalesce(array_length(v_r2_ids, 1), 0);

      UPDATE public.competition_cup_bracket_nodes
      SET child_node_id = v_r2_ids[v_r2_slot], child_slot = 'home'
      WHERE id = v_r1_ids[v_i];

      UPDATE public.competition_cup_bracket_nodes
      SET child_node_id = v_r2_ids[v_r2_slot], child_slot = 'away'
      WHERE id = v_r1_ids[v_i + 1];

      v_i := v_i + 2;
    END LOOP;
  END IF;

  FOR v_node IN
    SELECT *
    FROM public.competition_cup_bracket_nodes
    WHERE season_id = p_season_id
      AND cup_code = p_cup_code
      AND round_no = v_first_round
      AND coalesce(cup_leg, 1) = 1
  LOOP
    IF v_node.away_club_short_name IS NULL
       AND v_node.home_club_short_name IS NOT NULL
       AND v_node.winner_club_short_name IS NULL THEN
      UPDATE public.competition_cup_bracket_nodes
      SET winner_club_short_name = v_node.home_club_short_name
      WHERE id = v_node.id;
      PERFORM public.competition_cup_advance_node_winner(v_node.id);
    END IF;
  END LOOP;

  FOR v_node IN
    SELECT *
    FROM public.competition_cup_bracket_nodes
    WHERE season_id = p_season_id
      AND cup_code = p_cup_code
      AND home_club_short_name IS NOT NULL
      AND away_club_short_name IS NOT NULL
      AND fixture_id IS NULL
  LOOP
    PERFORM public.competition_create_cup_fixture_for_node(v_node.id);
  END LOOP;

  RETURN jsonb_build_object(
    'cup_code', p_cup_code,
    'clubs', v_n,
    'byes', v_byes,
    'bye_clubs', to_jsonb(coalesce(v_byes_clubs, ARRAY[]::text[])),
    'rounds', v_max_round,
    'r1_fixtures', v_r1_count
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_build_knockout_bracket(bigint, text, text[], text[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
