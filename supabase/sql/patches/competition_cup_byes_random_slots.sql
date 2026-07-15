-- =============================================================================
-- League/prestige cup: scatter first-round byes randomly through the bracket
-- (no longer always dumped in the last R1 slots → Last 32 "Club vs TBD" cluster).
--
-- Uses standard R1→R2 pairing: matches (2k-1, 2k) feed Last-32 slot k.
-- Bye in an R1 slot auto-advances; sibling tie fills the other side when played.
--
-- Optional p_bye_match_nos: fixed R1 match numbers for byes (cup ceremony).
-- If null, SQL picks random distinct slots.
-- Safe re-run.
-- =============================================================================

DROP FUNCTION IF EXISTS public.competition_build_knockout_bracket(bigint, text, text[], text[], text[]);
DROP FUNCTION IF EXISTS public.competition_build_knockout_bracket(bigint, text, text[], text[], text[], int[]);

CREATE OR REPLACE FUNCTION public.competition_build_knockout_bracket(
  p_season_id bigint,
  p_cup_code text,
  p_clubs text[],
  p_bye_clubs text[] DEFAULT NULL,
  p_player_order text[] DEFAULT NULL,
  p_bye_match_nos int[] DEFAULT NULL
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
  v_expected_players int;
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
  v_node record;
  v_r1_count int := 0;
  v_first_round int;
  v_max_round int;
  v_b text;
  v_r1_matches int;
  v_bye_slots int[] := ARRAY[]::int[];
  v_bye_pos int := 1;
  v_player_pos int := 1;
  v_slot int;
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
  v_r1_matches := v_target / 2;

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

    -- Scatter bye clubs randomly in list order for slot assignment
    SELECT coalesce(array_agg(c ORDER BY random()), v_byes_clubs)
    INTO v_byes_clubs
    FROM unnest(v_byes_clubs) AS c;
  ELSE
    v_byes_clubs := ARRAY[]::text[];
  END IF;

  v_expected_players := v_n - coalesce(array_length(v_byes_clubs, 1), 0);

  IF p_player_order IS NOT NULL
     AND coalesce(array_length(p_player_order, 1), 0) > 0 THEN
    IF coalesce(array_length(p_player_order, 1), 0) <> v_expected_players THEN
      RAISE EXCEPTION 'Player draw order must contain exactly % club(s)', v_expected_players;
    END IF;

    v_players := ARRAY[]::text[];
    FOREACH v_b IN ARRAY p_player_order LOOP
      v_b := upper(trim(v_b));
      IF NOT (v_b = ANY (p_clubs)) THEN
        RAISE EXCEPTION 'Draw order club % is not qualified for %', v_b, p_cup_code;
      END IF;
      IF v_b = ANY (v_byes_clubs) THEN
        RAISE EXCEPTION 'Draw order club % is a bye club for %', v_b, p_cup_code;
      END IF;
      IF v_b = ANY (v_players) THEN
        RAISE EXCEPTION 'Duplicate club % in draw order', v_b;
      END IF;
      v_players := array_append(v_players, v_b);
    END LOOP;
  ELSIF v_byes > 0 THEN
    SELECT coalesce(array_agg(x.club ORDER BY random()), ARRAY[]::text[])
    INTO v_players
    FROM (
      SELECT unnest(p_clubs) AS club
      EXCEPT
      SELECT unnest(v_byes_clubs)
    ) x;
  ELSE
    v_players := public.competition_shuffle_club_array(p_clubs);
  END IF;

  -- Bye match slots: client-provided or random among R1 matches
  IF v_byes > 0 THEN
    IF p_bye_match_nos IS NOT NULL
       AND coalesce(array_length(p_bye_match_nos, 1), 0) = v_byes THEN
      v_bye_slots := ARRAY[]::int[];
      FOREACH v_slot IN ARRAY p_bye_match_nos LOOP
        IF v_slot IS NULL OR v_slot < 1 OR v_slot > v_r1_matches THEN
          RAISE EXCEPTION 'Bye match number % out of range 1–%', v_slot, v_r1_matches;
        END IF;
        IF v_slot = ANY (v_bye_slots) THEN
          RAISE EXCEPTION 'Duplicate bye match number %', v_slot;
        END IF;
        v_bye_slots := array_append(v_bye_slots, v_slot);
      END LOOP;
    ELSE
      SELECT coalesce(array_agg(m ORDER BY m), ARRAY[]::int[])
      INTO v_bye_slots
      FROM (
        SELECT m
        FROM generate_series(1, v_r1_matches) AS m
        ORDER BY random()
        LIMIT v_byes
      ) s;
    END IF;
  END IF;

  v_prev_round_ids := NULL;
  v_leg1_ids := NULL;
  v_bye_pos := 1;
  v_player_pos := 1;

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
        IF v_byes > 0 AND v_match = ANY (v_bye_slots) THEN
          v_home := v_byes_clubs[v_bye_pos];
          v_away := NULL;
          v_bye_pos := v_bye_pos + 1;
        ELSE
          IF v_player_pos <= coalesce(array_length(v_players, 1), 0) THEN
            v_home := v_players[v_player_pos];
            v_player_pos := v_player_pos + 1;
          END IF;
          IF v_player_pos <= coalesce(array_length(v_players, 1), 0) THEN
            v_away := v_players[v_player_pos];
            v_player_pos := v_player_pos + 1;
          END IF;
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
      -- Standard pairing for every round (including R1→R2 with scattered byes)
      FOR v_i IN 1..coalesce(array_length(v_prev_round_ids, 1), 0) LOOP
        v_parent_id := v_prev_round_ids[v_i];
        v_child_id := v_curr_round_ids[(v_i + 1) / 2];
        UPDATE public.competition_cup_bracket_nodes
        SET child_node_id = v_child_id,
            child_slot = CASE WHEN v_i % 2 = 1 THEN 'home' ELSE 'away' END
        WHERE id = v_parent_id;
      END LOOP;
      v_prev_round_ids := v_curr_round_ids;
    ELSE
      v_prev_round_ids := v_curr_round_ids;
    END IF;
  END LOOP;

  -- Auto-advance first-round byes into the next round
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
    'bye_match_nos', to_jsonb(coalesce(v_bye_slots, ARRAY[]::int[])),
    'rounds', v_max_round,
    'r1_fixtures', v_r1_count,
    'draw_order', to_jsonb(coalesce(v_players, ARRAY[]::text[]))
  );
END;
$function$;

DROP FUNCTION IF EXISTS public.competition_draw_league_cup(bigint, text[]);
DROP FUNCTION IF EXISTS public.competition_draw_league_cup(bigint, text[], int[]);

CREATE OR REPLACE FUNCTION public.competition_draw_league_cup(
  p_season_id bigint,
  p_player_order text[] DEFAULT NULL,
  p_bye_match_nos int[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_clubs text[];
  v_byes text[];
  v_result jsonb;
  v_sync jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_clubs := public.competition_qualify_cup_clubs(p_season_id, 'league_cup');

  IF coalesce(array_length(v_clubs, 1), 0) < 8 THEN
    RAISE EXCEPTION 'Need at least 8 clubs in season for league cup';
  END IF;

  v_byes := public.competition_cup_load_saved_byes(p_season_id, 'league_cup');

  v_result := public.competition_build_knockout_bracket(
    p_season_id,
    'league_cup',
    v_clubs,
    CASE WHEN coalesce(array_length(v_byes, 1), 0) > 0 THEN v_byes ELSE NULL END,
    p_player_order,
    p_bye_match_nos
  );

  IF to_regprocedure('public.competition_cup_sync_all_scheduled_cup_fixtures(bigint, text)') IS NOT NULL THEN
    v_sync := public.competition_cup_sync_all_scheduled_cup_fixtures(p_season_id, 'league_cup');
    v_result := v_result || v_sync;
  END IF;

  RETURN v_result;
END;
$function$;

DROP FUNCTION IF EXISTS public.competition_draw_prestige_cup(bigint, text, text[]);
DROP FUNCTION IF EXISTS public.competition_draw_prestige_cup(bigint, text, text[], int[]);

CREATE OR REPLACE FUNCTION public.competition_draw_prestige_cup(
  p_season_id bigint,
  p_cup_code text,
  p_player_order text[] DEFAULT NULL,
  p_bye_match_nos int[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_clubs text[];
  v_byes text[];
  v_result jsonb;
  v_sync jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_cup_code NOT IN ('super8', 'plate', 'shield', 'spoon') THEN
    RAISE EXCEPTION 'Invalid prestige cup code';
  END IF;

  v_clubs := public.competition_qualify_cup_clubs(p_season_id, p_cup_code);

  IF coalesce(array_length(v_clubs, 1), 0) < 2 THEN
    RAISE EXCEPTION 'Not enough qualified clubs for % (% found)', p_cup_code, coalesce(array_length(v_clubs, 1), 0);
  END IF;

  v_byes := public.competition_cup_load_saved_byes(p_season_id, p_cup_code);

  v_result := public.competition_build_knockout_bracket(
    p_season_id,
    p_cup_code,
    v_clubs,
    CASE WHEN coalesce(array_length(v_byes, 1), 0) > 0 THEN v_byes ELSE NULL END,
    p_player_order,
    p_bye_match_nos
  );

  IF to_regprocedure('public.competition_cup_sync_all_scheduled_cup_fixtures(bigint, text)') IS NOT NULL THEN
    v_sync := public.competition_cup_sync_all_scheduled_cup_fixtures(p_season_id, p_cup_code);
    v_result := v_result || v_sync;
  END IF;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_build_knockout_bracket(bigint, text, text[], text[], text[], int[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_draw_prestige_cup(bigint, text, text[], int[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_draw_league_cup(bigint, text[], int[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
