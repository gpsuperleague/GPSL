-- Admin-selected first-round cup byes (no empty R1 fixtures).
-- Run after competition_cup_schedule.sql / competition_phase6_cups.sql.

CREATE TABLE IF NOT EXISTS public.competition_cup_first_round_byes (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  cup_code text NOT NULL,
  club_short_name text NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT competition_cup_first_round_byes_pkey
    PRIMARY KEY (season_id, cup_code, club_short_name),
  CONSTRAINT competition_cup_first_round_byes_cup_check
    CHECK (cup_code IN ('super8', 'plate', 'shield', 'spoon', 'league_cup'))
);

CREATE INDEX IF NOT EXISTS competition_cup_first_round_byes_season_cup_idx
  ON public.competition_cup_first_round_byes (season_id, cup_code);

ALTER TABLE public.competition_cup_first_round_byes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_cup_byes_select ON public.competition_cup_first_round_byes;
CREATE POLICY competition_cup_byes_select ON public.competition_cup_first_round_byes
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS competition_cup_byes_admin ON public.competition_cup_first_round_byes;
CREATE POLICY competition_cup_byes_admin ON public.competition_cup_first_round_byes
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

-- ---------------------------------------------------------------------------
-- Bye requirement helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_first_round_slots(p_cup_code text)
RETURNS int
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    (
      SELECT (max(s.matches_in_round) * 2)::int
      FROM public.competition_cup_round_schedule s
      WHERE s.cup_code = p_cup_code
        AND s.round_no = 1
    ),
    0
  );
$$;

CREATE OR REPLACE FUNCTION public.competition_cup_compute_bye_requirements(
  p_season_id bigint,
  p_cup_code text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_clubs text[];
  v_n int;
  v_target int;
  v_slots int;
  v_byes int;
BEGIN
  v_clubs := public.competition_qualify_cup_clubs(p_season_id, p_cup_code);
  v_n := coalesce(array_length(v_clubs, 1), 0);

  v_slots := public.competition_cup_first_round_slots(p_cup_code);
  v_target := greatest(v_slots, 1);

  IF v_slots IS NULL OR v_slots < 1 THEN
    v_target := 1;
    WHILE v_target < v_n LOOP
      v_target := v_target * 2;
    END LOOP;
  ELSIF v_target < v_n THEN
    WHILE v_target < v_n LOOP
      v_target := v_target * 2;
    END LOOP;
  END IF;

  v_byes := greatest(v_target - v_n, 0);

  RETURN jsonb_build_object(
    'cup_code', p_cup_code,
    'qualified_count', v_n,
    'first_round_slots', v_target,
    'required_byes', v_byes,
    'r1_fixtures', v_target / 2,
    'qualified_clubs', to_jsonb(coalesce(v_clubs, ARRAY[]::text[]))
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_cup_byes_get(
  p_season_id bigint,
  p_cup_code text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_req jsonb;
  v_selected text[];
BEGIN
  v_req := public.competition_cup_compute_bye_requirements(p_season_id, p_cup_code);

  SELECT coalesce(array_agg(b.club_short_name ORDER BY b.sort_order, b.club_short_name), ARRAY[]::text[])
  INTO v_selected
  FROM public.competition_cup_first_round_byes b
  WHERE b.season_id = p_season_id
    AND b.cup_code = p_cup_code;

  RETURN v_req || jsonb_build_object(
    'selected_byes', to_jsonb(v_selected),
    'selected_count', coalesce(array_length(v_selected, 1), 0),
    'ready_to_draw',
      coalesce((v_req ->> 'required_byes')::int, 0) = coalesce(array_length(v_selected, 1), 0)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_set_cup_byes(
  p_season_id bigint,
  p_cup_code text,
  p_clubs text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_req jsonb;
  v_required int;
  v_qualified text[];
  v_norm text[];
  v_club text;
  v_i int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_cup_code NOT IN ('super8', 'plate', 'shield', 'spoon', 'league_cup') THEN
    RAISE EXCEPTION 'Invalid cup code';
  END IF;

  v_req := public.competition_cup_compute_bye_requirements(p_season_id, p_cup_code);
  v_required := coalesce((v_req ->> 'required_byes')::int, 0);
  v_qualified := ARRAY(
    SELECT jsonb_array_elements_text(coalesce(v_req -> 'qualified_clubs', '[]'::jsonb))
  );

  v_norm := ARRAY[]::text[];
  IF p_clubs IS NOT NULL THEN
    FOREACH v_club IN ARRAY p_clubs LOOP
      v_club := upper(trim(coalesce(v_club, '')));
      IF v_club = '' THEN
        CONTINUE;
      END IF;
      IF NOT (v_club = ANY (v_qualified)) THEN
        RAISE EXCEPTION 'Club % is not qualified for %', v_club, p_cup_code;
      END IF;
      IF v_club = ANY (v_norm) THEN
        RAISE EXCEPTION 'Duplicate bye club %', v_club;
      END IF;
      v_norm := array_append(v_norm, v_club);
    END LOOP;
  END IF;

  IF coalesce(array_length(v_norm, 1), 0) <> v_required THEN
    RAISE EXCEPTION 'Select exactly % bye club(s) for % (% qualified, % first-round slots)',
      v_required, p_cup_code,
      coalesce((v_req ->> 'qualified_count')::int, 0),
      coalesce((v_req ->> 'first_round_slots')::int, 0);
  END IF;

  DELETE FROM public.competition_cup_first_round_byes
  WHERE season_id = p_season_id
    AND cup_code = p_cup_code;

  v_i := 0;
  FOREACH v_club IN ARRAY v_norm LOOP
    v_i := v_i + 1;
    INSERT INTO public.competition_cup_first_round_byes (
      season_id, cup_code, club_short_name, sort_order
    )
    VALUES (p_season_id, p_cup_code, v_club, v_i);
  END LOOP;

  RETURN public.competition_cup_byes_get(p_season_id, p_cup_code);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_cup_load_saved_byes(
  p_season_id bigint,
  p_cup_code text
)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    array_agg(b.club_short_name ORDER BY b.sort_order, b.club_short_name),
    ARRAY[]::text[]
  )
  FROM public.competition_cup_first_round_byes b
  WHERE b.season_id = p_season_id
    AND b.cup_code = p_cup_code;
$$;

-- ---------------------------------------------------------------------------
-- Bracket builder — admin bye clubs (optional 4th arg)
-- ---------------------------------------------------------------------------

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
  v_r2_ids bigint[];
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
    AND round_no = 1;

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

      IF v_round = 1 AND v_leg = 1 THEN
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

      IF v_round = 1 AND v_leg = 1 THEN
        v_leg1_ids := coalesce(v_leg1_ids, ARRAY[]::bigint[]);
        v_leg1_ids := array_append(v_leg1_ids, v_node_id);
      END IF;

      IF v_home IS NOT NULL AND v_away IS NOT NULL THEN
        PERFORM public.competition_create_cup_fixture_for_node(v_node_id);
        IF v_round = 1 AND v_leg = 1 THEN
          v_r1_count := v_r1_count + 1;
        END IF;
      END IF;
    END LOOP;

    IF v_leg = 2 THEN
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

  SELECT min(round_no)
  INTO v_first_round
  FROM public.competition_cup_round_schedule
  WHERE cup_code = p_cup_code;

  SELECT array_agg(id ORDER BY match_no)
  INTO v_r2_ids
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = p_season_id
    AND cup_code = p_cup_code
    AND round_no = v_first_round + 1;

  v_i := 1;
  FOR v_match IN 1..coalesce(array_length(v_byes_clubs, 1), 0) LOOP
    EXIT WHEN v_r2_ids IS NULL OR v_i > coalesce(array_length(v_r2_ids, 1), 0);
    UPDATE public.competition_cup_bracket_nodes n
    SET home_club_short_name = coalesce(n.home_club_short_name, v_byes_clubs[v_match])
    WHERE n.id = v_r2_ids[v_i];
    v_i := v_i + 1;
  END LOOP;

  FOR v_node IN
    SELECT *
    FROM public.competition_cup_bracket_nodes
    WHERE season_id = p_season_id
      AND cup_code = p_cup_code
      AND round_no = v_first_round
      AND cup_leg = 1
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

-- ---------------------------------------------------------------------------
-- Draw RPCs — use saved admin byes
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_draw_prestige_cup(
  p_season_id bigint,
  p_cup_code text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_clubs text[];
  v_byes text[];
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

  RETURN public.competition_build_knockout_bracket(
    p_season_id,
    p_cup_code,
    v_clubs,
    CASE WHEN coalesce(array_length(v_byes, 1), 0) > 0 THEN v_byes ELSE NULL END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_draw_league_cup(
  p_season_id bigint,
  p_byes smallint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_clubs text[];
  v_byes text[];
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_clubs := public.competition_qualify_cup_clubs(p_season_id, 'league_cup');

  IF coalesce(array_length(v_clubs, 1), 0) < 8 THEN
    RAISE EXCEPTION 'Need at least 8 clubs in season for league cup';
  END IF;

  v_byes := public.competition_cup_load_saved_byes(p_season_id, 'league_cup');

  RETURN public.competition_build_knockout_bracket(
    p_season_id,
    'league_cup',
    v_clubs,
    CASE WHEN coalesce(array_length(v_byes, 1), 0) > 0 THEN v_byes ELSE NULL END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_compute_bye_requirements(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_byes_get(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_set_cup_byes(bigint, text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_load_saved_byes(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
