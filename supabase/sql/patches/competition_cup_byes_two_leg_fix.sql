-- =============================================================================
-- Prestige + League Cup: fix first-round bye advancement (esp. two-legged QF)
--
-- Bug: Super8 / Bowl schedule R1 as two legs. Child wiring attaches to LEG 2,
-- but bye winners were only set/advanced on LEG 1 (no child_node_id) → bye
-- clubs never appeared in the next round (same cascade as League Cup TBDs).
--
-- Also: leg-2 of a bye was built as reversed (NULL home / club away), which
-- looked like a broken tie instead of a bye.
--
-- This patch:
--   1) competition_cup_complete_first_round_byes — shared bye → next-round fill
--   2) Rebuilds competition_build_knockout_bracket with correct two-leg byes
--   3) Updates repair_advancement + repair_force_fill to use the helper
--   4) Normalizes spoon → bowl in repair cup codes
--
-- After apply:
--   • Existing draws: Admin → each cup → Repair advancement / Force fill
--   • Or re-draw cups that still look wrong (saved byes kept)
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_cup_normalize_code(p_cup_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_cup_code, '')))
    WHEN 'spoon' THEN 'bowl'
    ELSE lower(btrim(coalesce(p_cup_code, '')))
  END;
$$;

-- ---------------------------------------------------------------------------
-- Complete R1 byes: set winners on leg1 (+ leg2 if present) and advance from
-- the parent that actually has child_node_id (leg2 for two-legged cups).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_complete_first_round_byes(
  p_season_id bigint,
  p_cup_code text
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cup text := public.competition_cup_normalize_code(p_cup_code);
  v_first int;
  v_node record;
  v_leg2_id bigint;
  v_leg2_child bigint;
  v_club text;
  v_done int := 0;
  v_advance_id bigint;
BEGIN
  SELECT min(round_no) INTO v_first
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = p_season_id
    AND cup_code = v_cup;

  IF v_first IS NULL THEN
    RETURN 0;
  END IF;

  FOR v_node IN
    SELECT *
    FROM public.competition_cup_bracket_nodes
    WHERE season_id = p_season_id
      AND cup_code = v_cup
      AND round_no = v_first
      AND coalesce(cup_leg, 1) = 1
      AND home_club_short_name IS NOT NULL
      AND away_club_short_name IS NULL
      AND fixture_id IS NULL
  LOOP
    v_club := v_node.home_club_short_name;

    UPDATE public.competition_cup_bracket_nodes
    SET winner_club_short_name = v_club
    WHERE id = v_node.id
      AND winner_club_short_name IS DISTINCT FROM v_club;

    SELECT leg2.id, leg2.child_node_id
    INTO v_leg2_id, v_leg2_child
    FROM public.competition_cup_bracket_nodes leg2
    WHERE leg2.leg1_node_id = v_node.id
    LIMIT 1;

    IF v_leg2_id IS NOT NULL THEN
      -- Two-legged R1: child wiring is on leg 2 — keep bye shape and advance from there
      UPDATE public.competition_cup_bracket_nodes
      SET home_club_short_name = v_club,
          away_club_short_name = NULL,
          winner_club_short_name = v_club,
          fixture_id = NULL
      WHERE id = v_leg2_id;

      v_advance_id := CASE
        WHEN v_leg2_child IS NOT NULL THEN v_leg2_id
        WHEN v_node.child_node_id IS NOT NULL THEN v_node.id
        ELSE v_leg2_id
      END;
    ELSE
      v_advance_id := v_node.id;
    END IF;

    PERFORM public.competition_cup_advance_node_winner(v_advance_id);
    v_done := v_done + 1;
  END LOOP;

  RETURN v_done;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Bracket builder (scatter byes + two-leg-safe bye advance)
-- ---------------------------------------------------------------------------

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
  v_cup text := public.competition_cup_normalize_code(p_cup_code);
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
  v_leg1_home text;
  v_leg1_away text;
  v_i int;
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
  v_bye_done int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_clubs IS NULL OR array_length(p_clubs, 1) IS NULL OR array_length(p_clubs, 1) < 2 THEN
    RAISE EXCEPTION 'Need at least 2 clubs to draw %', v_cup;
  END IF;

  v_max_round := public.competition_cup_scheduled_round_count(v_cup);
  IF v_max_round IS NULL OR v_max_round < 1 THEN
    RAISE EXCEPTION 'No schedule configured for cup %', v_cup;
  END IF;

  SELECT min(round_no)
  INTO v_first_round
  FROM public.competition_cup_round_schedule
  WHERE cup_code = v_cup;

  DELETE FROM public.competition_cup_bracket_nodes
  WHERE season_id = p_season_id AND cup_code = v_cup;

  DELETE FROM public.competition_fixtures
  WHERE season_id = p_season_id
    AND competition_type = 'cup'
    AND cup_code = v_cup;

  v_n := array_length(p_clubs, 1);
  SELECT max(matches_in_round) * 2
  INTO v_target
  FROM public.competition_cup_round_schedule
  WHERE cup_code = v_cup
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
      RAISE EXCEPTION 'Assign exactly % first-round bye club(s) for % before drawing', v_byes, v_cup;
    END IF;

    v_byes_clubs := ARRAY[]::text[];
    FOREACH v_b IN ARRAY p_bye_clubs LOOP
      v_b := upper(trim(v_b));
      IF NOT (v_b = ANY (p_clubs)) THEN
        RAISE EXCEPTION 'Bye club % is not in the qualified list for %', v_b, v_cup;
      END IF;
      IF v_b = ANY (v_byes_clubs) THEN
        RAISE EXCEPTION 'Duplicate bye club %', v_b;
      END IF;
      v_byes_clubs := array_append(v_byes_clubs, v_b);
    END LOOP;

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
        RAISE EXCEPTION 'Draw order club % is not qualified for %', v_b, v_cup;
      END IF;
      IF v_b = ANY (v_byes_clubs) THEN
        RAISE EXCEPTION 'Draw order club % is a bye club for %', v_b, v_cup;
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
    WHERE cup_code = v_cup
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
        SELECT home_club_short_name, away_club_short_name
        INTO v_leg1_home, v_leg1_away
        FROM public.competition_cup_bracket_nodes
        WHERE id = v_leg1_node_id;

        IF v_leg1_away IS NULL AND v_leg1_home IS NOT NULL THEN
          -- Bye: keep as bye on leg 2 (do not reverse into NULL vs club)
          v_home := v_leg1_home;
          v_away := NULL;
        ELSE
          -- Normal 2nd leg: reverse venues
          v_home := v_leg1_away;
          v_away := v_leg1_home;
        END IF;
      END IF;

      INSERT INTO public.competition_cup_bracket_nodes (
        season_id, cup_code, round_no, match_no, cup_leg,
        home_club_short_name, away_club_short_name, leg1_node_id
      )
      VALUES (
        p_season_id, v_cup, v_round, v_match, v_leg,
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
      -- Next-round parents are 2nd-leg nodes for two-legged rounds
      v_prev_round_ids := v_curr_round_ids;
    ELSIF v_prev_round_ids IS NOT NULL THEN
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

  v_bye_done := public.competition_cup_complete_first_round_byes(p_season_id, v_cup);

  FOR v_node IN
    SELECT *
    FROM public.competition_cup_bracket_nodes
    WHERE season_id = p_season_id
      AND cup_code = v_cup
      AND home_club_short_name IS NOT NULL
      AND away_club_short_name IS NOT NULL
      AND fixture_id IS NULL
  LOOP
    PERFORM public.competition_create_cup_fixture_for_node(v_node.id);
  END LOOP;

  RETURN jsonb_build_object(
    'cup_code', v_cup,
    'clubs', v_n,
    'byes', v_byes,
    'bye_clubs', to_jsonb(coalesce(v_byes_clubs, ARRAY[]::text[])),
    'bye_match_nos', to_jsonb(coalesce(v_bye_slots, ARRAY[]::int[])),
    'bye_advanced', v_bye_done,
    'rounds', v_max_round,
    'r1_fixtures', v_r1_count,
    'draw_order', to_jsonb(coalesce(v_players, ARRAY[]::text[]))
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Repair: use shared bye completer + bowl normalize
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_repair_advancement(
  p_season_id bigint DEFAULT NULL,
  p_cup_code text DEFAULT 'league_cup'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_cup text := public.competition_cup_normalize_code(
    coalesce(nullif(btrim(p_cup_code), ''), 'league_cup')
  );
  v_pass int;
  v_winners_set int := 0;
  v_byes_set int := 0;
  v_advanced int := 0;
  v_fixtures_created int := 0;
  v_incomplete_r2 int := 0;
  v_incomplete_later int := 0;
  v_missing_child int := 0;
  v_r2_fixtures int := 0;
  v_r3_fixtures int := 0;
  v_node record;
  v_winner text;
  v_before_home text;
  v_before_away text;
  v_child public.competition_cup_bracket_nodes;
  v_had_fixture boolean;
  v_first_round int;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season IS NULL THEN
    SELECT s.id INTO v_season
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  SELECT min(round_no) INTO v_first_round
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season AND cup_code = v_cup;

  IF v_first_round IS NULL THEN
    RAISE EXCEPTION 'No bracket nodes for % season %', v_cup, v_season;
  END IF;

  FOR v_pass IN 1..8 LOOP
    FOR v_node IN
      SELECT n.*
      FROM public.competition_cup_bracket_nodes n
      JOIN public.competition_fixtures f ON f.id = n.fixture_id
      WHERE n.season_id = v_season
        AND n.cup_code = v_cup
        AND f.status = 'played'
        AND (
          n.winner_club_short_name IS NULL
          OR n.winner_club_short_name IS DISTINCT FROM
            public.competition_cup_repair_node_winner_from_fixture(f.id)
        )
    LOOP
      v_winner := public.competition_cup_repair_node_winner_from_fixture(v_node.fixture_id);
      IF v_winner IS NULL THEN
        CONTINUE;
      END IF;
      UPDATE public.competition_cup_bracket_nodes
      SET winner_club_short_name = v_winner
      WHERE id = v_node.id
        AND winner_club_short_name IS DISTINCT FROM v_winner;
      IF FOUND THEN
        v_winners_set := v_winners_set + 1;
      END IF;
    END LOOP;

    v_byes_set := v_byes_set + public.competition_cup_complete_first_round_byes(v_season, v_cup);

    FOR v_node IN
      SELECT *
      FROM public.competition_cup_bracket_nodes
      WHERE season_id = v_season
        AND cup_code = v_cup
        AND winner_club_short_name IS NOT NULL
        AND child_node_id IS NOT NULL
        AND child_slot IS NOT NULL
      ORDER BY round_no, match_no, coalesce(cup_leg, 1)
    LOOP
      SELECT * INTO v_child
      FROM public.competition_cup_bracket_nodes
      WHERE id = v_node.child_node_id;

      IF NOT FOUND THEN
        CONTINUE;
      END IF;

      v_before_home := v_child.home_club_short_name;
      v_before_away := v_child.away_club_short_name;

      PERFORM public.competition_cup_advance_node_winner(v_node.id);

      SELECT home_club_short_name, away_club_short_name
      INTO v_child.home_club_short_name, v_child.away_club_short_name
      FROM public.competition_cup_bracket_nodes
      WHERE id = v_node.child_node_id;

      IF v_child.home_club_short_name IS DISTINCT FROM v_before_home
         OR v_child.away_club_short_name IS DISTINCT FROM v_before_away THEN
        v_advanced := v_advanced + 1;
      END IF;
    END LOOP;

    FOR v_node IN
      SELECT *
      FROM public.competition_cup_bracket_nodes
      WHERE season_id = v_season
        AND cup_code = v_cup
        AND home_club_short_name IS NOT NULL
        AND away_club_short_name IS NOT NULL
        AND fixture_id IS NULL
    LOOP
      v_had_fixture := false;
      PERFORM public.competition_create_cup_fixture_for_node(v_node.id);
      SELECT fixture_id IS NOT NULL INTO v_had_fixture
      FROM public.competition_cup_bracket_nodes
      WHERE id = v_node.id;
      IF v_had_fixture THEN
        v_fixtures_created := v_fixtures_created + 1;
      END IF;
    END LOOP;
  END LOOP;

  SELECT count(*)::int INTO v_missing_child
  FROM public.competition_cup_bracket_nodes n
  WHERE n.season_id = v_season
    AND n.cup_code = v_cup
    AND n.round_no = v_first_round
    AND coalesce(n.cup_leg, 1) = 1
    AND (
      (n.home_club_short_name IS NOT NULL AND n.away_club_short_name IS NOT NULL)
      OR (n.home_club_short_name IS NOT NULL AND n.away_club_short_name IS NULL)
    )
    AND n.child_node_id IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.competition_cup_bracket_nodes leg2
      WHERE leg2.leg1_node_id = n.id
        AND leg2.child_node_id IS NOT NULL
    );

  SELECT count(*)::int INTO v_incomplete_r2
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season
    AND cup_code = v_cup
    AND round_no = v_first_round + 1
    AND coalesce(cup_leg, 1) = 1
    AND (
      (home_club_short_name IS NOT NULL AND away_club_short_name IS NULL)
      OR (home_club_short_name IS NULL AND away_club_short_name IS NOT NULL)
      OR (home_club_short_name IS NULL AND away_club_short_name IS NULL)
    );

  SELECT count(*)::int INTO v_incomplete_later
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season
    AND cup_code = v_cup
    AND round_no > v_first_round + 1
    AND coalesce(cup_leg, 1) = 1
    AND (
      (home_club_short_name IS NOT NULL AND away_club_short_name IS NULL)
      OR (home_club_short_name IS NULL AND away_club_short_name IS NOT NULL)
    );

  SELECT count(*)::int INTO v_r2_fixtures
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season
    AND cup_code = v_cup
    AND round_no = v_first_round + 1
    AND coalesce(cup_leg, 1) = 1
    AND fixture_id IS NOT NULL;

  SELECT count(*)::int INTO v_r3_fixtures
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season
    AND cup_code = v_cup
    AND round_no = v_first_round + 2
    AND coalesce(cup_leg, 1) = 1
    AND fixture_id IS NOT NULL;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'cup_code', v_cup,
    'winners_synced_from_fixtures', v_winners_set,
    'bye_winners_set', v_byes_set,
    'child_slots_updated', v_advanced,
    'fixtures_created', v_fixtures_created,
    'r1_nodes_missing_child_wiring', v_missing_child,
    'next_round_incomplete_nodes', v_incomplete_r2,
    'later_incomplete_nodes', v_incomplete_later,
    'next_round_fixtures_now', v_r2_fixtures,
    'later_round_fixtures_now', v_r3_fixtures,
    'note', CASE
      WHEN v_missing_child > 0 THEN
        'Some R1 nodes have no child wiring — re-draw that cup after this patch.'
      WHEN v_incomplete_r2 > 0 THEN
        'Some next-round ties still await an opening-round winner (unplayed ties). Play those, then re-run repair.'
      ELSE
        'Advancement repaired (incl. two-legged byes). Refresh cups.html.'
    END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_cup_repair_force_fill(
  p_season_id bigint DEFAULT NULL,
  p_cup_code text DEFAULT 'league_cup'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_cup text := public.competition_cup_normalize_code(
    coalesce(nullif(btrim(p_cup_code), ''), 'league_cup')
  );
  v_first int;
  v_pass int;
  v_linked int := 0;
  v_winners int := 0;
  v_byes int := 0;
  v_filled int := 0;
  v_fixtures int := 0;
  v_node record;
  v_parent record;
  v_fx public.competition_fixtures;
  v_winner text;
  v_diag jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season IS NULL THEN
    SELECT s.id INTO v_season
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  SELECT min(round_no) INTO v_first
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season AND cup_code = v_cup;

  IF v_first IS NULL THEN
    RAISE EXCEPTION 'No bracket for % / season %', v_cup, v_season;
  END IF;

  FOR v_fx IN
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season
      AND f.competition_type = 'cup'
      AND f.cup_code = v_cup
      AND f.status = 'played'
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_cup_bracket_nodes n WHERE n.fixture_id = f.id
      )
  LOOP
    UPDATE public.competition_cup_bracket_nodes n
    SET fixture_id = v_fx.id
    WHERE n.season_id = v_season
      AND n.cup_code = v_cup
      AND n.fixture_id IS NULL
      AND n.round_no = coalesce(v_fx.cup_round, n.round_no)
      AND n.match_no = coalesce(v_fx.cup_match, n.match_no)
      AND n.home_club_short_name = v_fx.home_club_short_name
      AND n.away_club_short_name = v_fx.away_club_short_name;
    IF FOUND THEN
      v_linked := v_linked + 1;
    END IF;
  END LOOP;

  FOR v_pass IN 1..10 LOOP
    FOR v_node IN
      SELECT n.*
      FROM public.competition_cup_bracket_nodes n
      JOIN public.competition_fixtures f ON f.id = n.fixture_id
      WHERE n.season_id = v_season
        AND n.cup_code = v_cup
        AND f.status = 'played'
    LOOP
      v_winner := public.competition_cup_repair_node_winner_from_fixture(v_node.fixture_id);
      IF v_winner IS NULL THEN
        CONTINUE;
      END IF;
      UPDATE public.competition_cup_bracket_nodes
      SET winner_club_short_name = v_winner
      WHERE id = v_node.id
        AND winner_club_short_name IS DISTINCT FROM v_winner;
      IF FOUND THEN
        v_winners := v_winners + 1;
      END IF;
    END LOOP;

    v_byes := v_byes + public.competition_cup_complete_first_round_byes(v_season, v_cup);

    FOR v_parent IN
      SELECT *
      FROM public.competition_cup_bracket_nodes
      WHERE season_id = v_season
        AND cup_code = v_cup
        AND winner_club_short_name IS NOT NULL
        AND child_node_id IS NOT NULL
        AND child_slot IN ('home', 'away')
      ORDER BY round_no, match_no, coalesce(cup_leg, 1)
    LOOP
      IF v_parent.child_slot = 'home' THEN
        UPDATE public.competition_cup_bracket_nodes
        SET home_club_short_name = v_parent.winner_club_short_name
        WHERE id = v_parent.child_node_id
          AND home_club_short_name IS DISTINCT FROM v_parent.winner_club_short_name;
      ELSE
        UPDATE public.competition_cup_bracket_nodes
        SET away_club_short_name = v_parent.winner_club_short_name
        WHERE id = v_parent.child_node_id
          AND away_club_short_name IS DISTINCT FROM v_parent.winner_club_short_name;
      END IF;
      IF FOUND THEN
        v_filled := v_filled + 1;
      END IF;
    END LOOP;

    FOR v_node IN
      SELECT *
      FROM public.competition_cup_bracket_nodes
      WHERE season_id = v_season
        AND cup_code = v_cup
        AND home_club_short_name IS NOT NULL
        AND away_club_short_name IS NOT NULL
        AND fixture_id IS NULL
    LOOP
      PERFORM public.competition_create_cup_fixture_for_node(v_node.id);
      IF EXISTS (
        SELECT 1 FROM public.competition_cup_bracket_nodes
        WHERE id = v_node.id AND fixture_id IS NOT NULL
      ) THEN
        v_fixtures := v_fixtures + 1;
      END IF;
    END LOOP;
  END LOOP;

  IF to_regprocedure('public.competition_cup_sync_all_scheduled_cup_fixtures(bigint, text)') IS NOT NULL THEN
    PERFORM public.competition_cup_sync_all_scheduled_cup_fixtures(v_season, v_cup);
  END IF;

  IF to_regprocedure('public.competition_cup_repair_diagnose(bigint, text)') IS NOT NULL THEN
    v_diag := public.competition_cup_repair_diagnose(v_season, v_cup);
  ELSE
    v_diag := '{}'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'cup_code', v_cup,
    'fixtures_relinked', v_linked,
    'winners_synced', v_winners,
    'bye_winners_set', v_byes,
    'child_slots_force_filled', v_filled,
    'fixtures_created', v_fixtures,
    'still_incomplete', v_diag -> 'incomplete_later_rounds',
    'still_unresolved_r1', v_diag -> 'unresolved_r1_ties',
    'note', CASE
      WHEN jsonb_array_length(coalesce(v_diag -> 'unresolved_r1_ties', '[]'::jsonb)) > 0 THEN
        'Next round still blocked by unfinished opening-round ties in still_unresolved_r1.'
      WHEN jsonb_array_length(coalesce(v_diag -> 'incomplete_later_rounds', '[]'::jsonb)) > 0 THEN
        'Some later-round slots still empty — check still_incomplete, or re-draw after this patch.'
      ELSE
        'Bracket advancement looks complete (two-legged byes included). Refresh cups.html.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_normalize_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_complete_first_round_byes(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_build_knockout_bracket(bigint, text, text[], text[], text[], int[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_repair_advancement(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_repair_force_fill(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Optional one-shot repair for all prestige cups + league cup in the current season:
-- SELECT public.competition_cup_repair_force_fill(NULL, c)
-- FROM unnest(ARRAY['super8','plate','shield','bowl','league_cup']) AS c;
