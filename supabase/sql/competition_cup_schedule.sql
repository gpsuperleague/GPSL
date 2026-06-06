-- =============================================================================
-- GPSL — Cup calendars + two-legged QF (Super8 & Spoon)
-- Run once after competition_phase6_cups.sql
-- Re-draw cups in Admin after applying (existing brackets keep old schedule).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Schema: cup legs + schedule template
-- ---------------------------------------------------------------------------

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS cup_leg smallint NOT NULL DEFAULT 1;

ALTER TABLE public.competition_fixtures
  DROP CONSTRAINT IF EXISTS competition_fixtures_cup_leg_check;

ALTER TABLE public.competition_fixtures
  ADD CONSTRAINT competition_fixtures_cup_leg_check
  CHECK (cup_leg IS NULL OR cup_leg IN (1, 2));

ALTER TABLE public.competition_cup_bracket_nodes
  ADD COLUMN IF NOT EXISTS cup_leg smallint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS leg1_node_id bigint REFERENCES public.competition_cup_bracket_nodes (id) ON DELETE SET NULL;

DROP INDEX IF EXISTS public.competition_fixtures_cup_unique_idx;

CREATE UNIQUE INDEX IF NOT EXISTS competition_fixtures_cup_unique_idx
  ON public.competition_fixtures (season_id, cup_code, cup_round, cup_match, cup_leg)
  WHERE competition_type = 'cup';

ALTER TABLE public.competition_cup_bracket_nodes
  DROP CONSTRAINT IF EXISTS competition_cup_bracket_nodes_unique;

ALTER TABLE public.competition_cup_bracket_nodes
  ADD CONSTRAINT competition_cup_bracket_nodes_unique
  UNIQUE (season_id, cup_code, round_no, match_no, cup_leg);

CREATE TABLE IF NOT EXISTS public.competition_cup_round_schedule (
  cup_code text NOT NULL CHECK (
    cup_code IN ('super8', 'plate', 'shield', 'spoon', 'league_cup')
  ),
  round_no smallint NOT NULL CHECK (round_no >= 1),
  cup_leg smallint NOT NULL DEFAULT 1 CHECK (cup_leg IN (1, 2)),
  gpsl_month text NOT NULL CHECK (
    gpsl_month IN (
      'august', 'september', 'october', 'november', 'december',
      'january', 'february', 'march', 'april', 'may'
    )
  ),
  stage text NOT NULL CHECK (
    stage IN ('appearance', 'r1', 'r2', 'qf', 'sf', 'final', 'winner')
  ),
  round_label text NOT NULL,
  matches_in_round smallint NOT NULL CHECK (matches_in_round >= 1),
  PRIMARY KEY (cup_code, round_no, cup_leg)
);

TRUNCATE public.competition_cup_round_schedule;

INSERT INTO public.competition_cup_round_schedule (
  cup_code, round_no, cup_leg, gpsl_month, stage, round_label, matches_in_round
) VALUES
  -- Super8: one QF round (2 legs Sep/Oct), SF Nov, Final Dec
  ('super8', 1, 1, 'september', 'qf', 'Quarter-final', 4),
  ('super8', 1, 2, 'october', 'qf', 'Quarter-final', 4),
  ('super8', 2, 1, 'november', 'sf', 'Semi-final', 2),
  ('super8', 3, 1, 'december', 'final', 'Final', 1),
  -- Spoon: same calendar as Super8
  ('spoon', 1, 1, 'september', 'qf', 'Quarter-final', 4),
  ('spoon', 1, 2, 'october', 'qf', 'Quarter-final', 4),
  ('spoon', 2, 1, 'november', 'sf', 'Semi-final', 2),
  ('spoon', 3, 1, 'december', 'final', 'Final', 1),
  -- Plate: R16 Sep, QF Oct, SF Nov, Final Dec
  ('plate', 1, 1, 'september', 'r2', 'Last 16', 8),
  ('plate', 2, 1, 'october', 'qf', 'Quarter-final', 4),
  ('plate', 3, 1, 'november', 'sf', 'Semi-final', 2),
  ('plate', 4, 1, 'december', 'final', 'Final', 1),
  -- Shield: R32 Aug, R16 Sep, QF Oct, SF Nov, Final Dec
  ('shield', 1, 1, 'august', 'r1', 'Last 32', 16),
  ('shield', 2, 1, 'september', 'r2', 'Last 16', 8),
  ('shield', 3, 1, 'october', 'qf', 'Quarter-final', 4),
  ('shield', 4, 1, 'november', 'sf', 'Semi-final', 2),
  ('shield', 5, 1, 'december', 'final', 'Final', 1),
  -- League Cup: R64 Dec → Final May
  ('league_cup', 1, 1, 'december', 'r1', 'Last 64', 32),
  ('league_cup', 2, 1, 'january', 'r2', 'Last 32', 16),
  ('league_cup', 3, 1, 'february', 'r2', 'Last 16', 8),
  ('league_cup', 4, 1, 'march', 'qf', 'Quarter-final', 4),
  ('league_cup', 5, 1, 'april', 'sf', 'Semi-final', 2),
  ('league_cup', 6, 1, 'may', 'final', 'Final', 1);

-- ---------------------------------------------------------------------------
-- Schedule helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_schedule_row(
  p_cup_code text,
  p_round_no int,
  p_cup_leg int DEFAULT 1
)
RETURNS public.competition_cup_round_schedule
LANGUAGE sql
STABLE
AS $$
  SELECT *
  FROM public.competition_cup_round_schedule s
  WHERE s.cup_code = p_cup_code
    AND s.round_no = p_round_no::smallint
    AND s.cup_leg = coalesce(p_cup_leg, 1)::smallint;
$$;

CREATE OR REPLACE FUNCTION public.competition_cup_scheduled_round_count(p_cup_code text)
RETURNS int
LANGUAGE sql
STABLE
AS $$
  SELECT count(DISTINCT round_no)::int
  FROM public.competition_cup_round_schedule
  WHERE cup_code = p_cup_code;
$$;

CREATE OR REPLACE FUNCTION public.competition_weather_for_gpsl_month(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT public.competition_weather_for_month(p_month);
$$;

CREATE OR REPLACE FUNCTION public.competition_cup_round_stage(
  p_cup_code text,
  p_round_no int,
  p_max_round int DEFAULT NULL
)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    (
      SELECT s.stage
      FROM public.competition_cup_round_schedule s
      WHERE s.cup_code = p_cup_code
        AND s.round_no = p_round_no::smallint
      ORDER BY s.cup_leg DESC
      LIMIT 1
    ),
    CASE
      WHEN p_round_no = p_max_round THEN 'final'
      WHEN p_round_no = p_max_round - 1 THEN 'sf'
      WHEN p_round_no = p_max_round - 2 THEN 'qf'
      WHEN p_round_no = 1 THEN 'r1'
      ELSE 'r2'
    END
  );
$$;

CREATE OR REPLACE FUNCTION public.competition_cup_fixture_label(p_fixture public.competition_fixtures)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT format(
    '%s %s%s',
    upper(replace(coalesce(p_fixture.cup_code, 'cup'), '_', ' ')),
    coalesce(
      (
        SELECT s.round_label
        FROM public.competition_cup_round_schedule s
        WHERE s.cup_code = p_fixture.cup_code
          AND s.round_no = p_fixture.cup_round
          AND s.cup_leg = coalesce(p_fixture.cup_leg, 1)
        LIMIT 1
      ),
      format('R%s M%s', p_fixture.cup_round, p_fixture.cup_match)
    ),
    CASE
      WHEN coalesce(p_fixture.cup_leg, 1) = 2 THEN ' (2nd leg)'
      WHEN EXISTS (
        SELECT 1
        FROM public.competition_cup_round_schedule s
        WHERE s.cup_code = p_fixture.cup_code
          AND s.round_no = p_fixture.cup_round
          AND s.cup_leg = 2
      ) AND coalesce(p_fixture.cup_leg, 1) = 1 THEN ' (1st leg)'
      ELSE ''
    END
  );
$$;

-- ---------------------------------------------------------------------------
-- Create fixture with GPSL month from schedule
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_create_cup_fixture_for_node(p_node_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_node public.competition_cup_bracket_nodes;
  v_sched public.competition_cup_round_schedule;
  v_fixture_id bigint;
BEGIN
  SELECT * INTO v_node FROM public.competition_cup_bracket_nodes WHERE id = p_node_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Bracket node not found';
  END IF;

  IF v_node.home_club_short_name IS NULL OR v_node.away_club_short_name IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_node.fixture_id IS NOT NULL THEN
    RETURN v_node.fixture_id;
  END IF;

  SELECT * INTO v_sched
  FROM public.competition_cup_round_schedule s
  WHERE s.cup_code = v_node.cup_code
    AND s.round_no = v_node.round_no
    AND s.cup_leg = coalesce(v_node.cup_leg, 1);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No cup schedule for % round % leg %',
      v_node.cup_code, v_node.round_no, v_node.cup_leg;
  END IF;

  INSERT INTO public.competition_fixtures (
    season_id,
    division,
    competition_type,
    matchday,
    gpsl_month,
    week_in_month,
    home_club_short_name,
    away_club_short_name,
    weather,
    cup_code,
    cup_round,
    cup_match,
    cup_leg
  )
  VALUES (
    v_node.season_id,
    'cup',
    'cup',
    v_node.round_no,
    v_sched.gpsl_month,
    1,
    v_node.home_club_short_name,
    v_node.away_club_short_name,
    public.competition_weather_for_gpsl_month(v_sched.gpsl_month),
    v_node.cup_code,
    v_node.round_no,
    v_node.match_no,
    coalesce(v_node.cup_leg, 1)
  )
  RETURNING id INTO v_fixture_id;

  UPDATE public.competition_cup_bracket_nodes
  SET fixture_id = v_fixture_id
  WHERE id = p_node_id;

  RETURN v_fixture_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Two-leg aggregate winner (leg1 home team = tie "home")
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_two_leg_winner(
  p_leg1_home_goals int,
  p_leg1_away_goals int,
  p_leg2_home_goals int,
  p_leg2_away_goals int,
  p_tie_home_club text,
  p_tie_away_club text,
  p_leg2_home_club text,
  p_leg2_away_club text
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_home_agg int;
  v_away_agg int;
BEGIN
  -- Leg 2 is always reversed (leg1 away team at home in leg2).
  v_home_agg := coalesce(p_leg1_home_goals, 0) + coalesce(p_leg2_away_goals, 0);
  v_away_agg := coalesce(p_leg1_away_goals, 0) + coalesce(p_leg2_home_goals, 0);

  IF v_home_agg > v_away_agg THEN
    RETURN p_tie_home_club;
  ELSIF v_away_agg > v_home_agg THEN
    RETURN p_tie_away_club;
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_cup_fixture_counts_as_round_win(
  p_fixture public.competition_fixtures
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT NOT EXISTS (
    SELECT 1
    FROM public.competition_cup_bracket_nodes n
    WHERE n.fixture_id = p_fixture.id
      AND EXISTS (
        SELECT 1
        FROM public.competition_cup_bracket_nodes leg2
        WHERE leg2.leg1_node_id = n.id
      )
  );
$$;

-- ---------------------------------------------------------------------------
-- Scheduled knockout bracket builder
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_build_knockout_bracket(
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
  v_byes_clubs := p_clubs[1:v_byes];
  v_players := p_clubs[(v_byes + 1):v_n];

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
        IF v_idx <= array_length(v_players, 1) THEN
          v_home := v_players[v_idx];
        END IF;
        IF v_idx + 1 <= array_length(v_players, 1) THEN
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
      FOR v_i IN 1..array_length(v_prev_round_ids, 1) LOOP
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
    EXIT WHEN v_r2_ids IS NULL OR v_i > array_length(v_r2_ids, 1);
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
    'rounds', v_max_round,
    'r1_fixtures', v_r1_count
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- On played: single leg OR two-leg aggregate
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_on_fixture_played(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_node public.competition_cup_bracket_nodes;
  v_leg1_node public.competition_cup_bracket_nodes;
  v_leg1_fixture public.competition_fixtures;
  v_winner text;
  v_tie_home text;
  v_tie_away text;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.competition_type <> 'cup' THEN
    RETURN;
  END IF;

  IF v_fixture.home_goals = v_fixture.away_goals THEN
    RETURN;
  END IF;

  SELECT * INTO v_node
  FROM public.competition_cup_bracket_nodes
  WHERE fixture_id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_node.leg1_node_id IS NOT NULL THEN
    SELECT * INTO v_leg1_node
    FROM public.competition_cup_bracket_nodes
    WHERE id = v_node.leg1_node_id;

    SELECT * INTO v_leg1_fixture
    FROM public.competition_fixtures
    WHERE id = v_leg1_node.fixture_id;

    IF v_leg1_fixture.id IS NULL OR v_leg1_fixture.status <> 'played' THEN
      PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
      RETURN;
    END IF;

    v_tie_home := v_leg1_node.home_club_short_name;
    v_tie_away := v_leg1_node.away_club_short_name;

    v_winner := public.competition_cup_two_leg_winner(
      v_leg1_fixture.home_goals,
      v_leg1_fixture.away_goals,
      v_fixture.home_goals,
      v_fixture.away_goals,
      v_tie_home,
      v_tie_away,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );

    IF v_winner IS NULL THEN
      PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
      RETURN;
    END IF;

    UPDATE public.competition_cup_bracket_nodes
    SET winner_club_short_name = v_winner
    WHERE id = v_node.id;

    PERFORM public.competition_cup_advance_node_winner(v_node.id);
    PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.competition_cup_bracket_nodes leg2
    WHERE leg2.leg1_node_id = v_node.id
  ) THEN
    PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
    RETURN;
  END IF;

  IF v_fixture.home_goals > v_fixture.away_goals THEN
    v_winner := v_fixture.home_club_short_name;
  ELSE
    v_winner := v_fixture.away_club_short_name;
  END IF;

  UPDATE public.competition_cup_bracket_nodes
  SET winner_club_short_name = v_winner
  WHERE id = v_node.id;

  PERFORM public.competition_cup_advance_node_winner(v_node.id);
  PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Prizes: use scheduled stage
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_pay_cup_fixture_prizes(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_stage text;
  v_winner text;
  v_round_winner text;
  v_amount numeric;
  v_club text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id AND competition_type = 'cup';

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_stage := public.competition_cup_round_stage(
    v_fixture.cup_code,
    v_fixture.cup_round,
    NULL
  );

  IF v_fixture.home_goals > v_fixture.away_goals THEN
    v_winner := v_fixture.home_club_short_name;
  ELSIF v_fixture.away_goals > v_fixture.home_goals THEN
    v_winner := v_fixture.away_club_short_name;
  ELSE
    RETURN;
  END IF;

  FOREACH v_club IN ARRAY ARRAY[v_fixture.home_club_short_name, v_fixture.away_club_short_name]
  LOOP
    SELECT amount INTO v_amount
    FROM public.competition_cup_prize_config
    WHERE season_id = v_fixture.season_id
      AND cup_code = v_fixture.cup_code
      AND stage = 'appearance';

    IF v_amount IS NOT NULL AND v_amount > 0
       AND NOT EXISTS (
         SELECT 1 FROM public.competition_cup_prize_paid
         WHERE fixture_id = p_fixture_id
           AND club_short_name = v_club
           AND stage = 'appearance'
       ) THEN
      PERFORM public.competition_credit_club_balance(v_club, v_amount);
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
      )
      VALUES (
        v_fixture.season_id,
        p_fixture_id,
        v_club,
        'prize',
        v_amount,
        format('%s appearance — %s', upper(v_fixture.cup_code), public.competition_cup_fixture_label(v_fixture)),
        jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', 'appearance')
      );
      INSERT INTO public.competition_cup_prize_paid (fixture_id, club_short_name, stage, amount)
      VALUES (p_fixture_id, v_club, 'appearance', v_amount);
    END IF;
  END LOOP;

  SELECT n.winner_club_short_name
  INTO v_round_winner
  FROM public.competition_cup_bracket_nodes n
  WHERE n.fixture_id = p_fixture_id;

  IF v_round_winner IS NOT NULL THEN
    v_winner := v_round_winner;
  END IF;

  SELECT amount INTO v_amount
  FROM public.competition_cup_prize_config
  WHERE season_id = v_fixture.season_id
    AND cup_code = v_fixture.cup_code
    AND stage = v_stage;

  IF v_amount IS NOT NULL AND v_amount > 0
     AND v_winner IS NOT NULL
     AND public.competition_cup_fixture_counts_as_round_win(v_fixture)
     AND NOT EXISTS (
       SELECT 1 FROM public.competition_cup_prize_paid
       WHERE fixture_id = p_fixture_id
         AND club_short_name = v_winner
         AND stage = v_stage
     ) THEN
    PERFORM public.competition_credit_club_balance(v_winner, v_amount);
    INSERT INTO public.competition_finance_ledger (
      season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
    )
    VALUES (
      v_fixture.season_id,
      p_fixture_id,
      v_winner,
      'prize',
      v_amount,
      format('%s %s winner — %s', upper(v_fixture.cup_code), v_stage, public.competition_cup_fixture_label(v_fixture)),
      jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', v_stage)
    );
    INSERT INTO public.competition_cup_prize_paid (fixture_id, club_short_name, stage, amount)
    VALUES (p_fixture_id, v_winner, v_stage);
  END IF;

  IF v_stage = 'final'
     AND v_winner IS NOT NULL
     AND public.competition_cup_fixture_counts_as_round_win(v_fixture) THEN
    SELECT amount INTO v_amount
    FROM public.competition_cup_prize_config
    WHERE season_id = v_fixture.season_id
      AND cup_code = v_fixture.cup_code
      AND stage = 'winner';

    IF v_amount IS NOT NULL AND v_amount > 0
       AND NOT EXISTS (
         SELECT 1 FROM public.competition_cup_prize_paid
         WHERE fixture_id = p_fixture_id
           AND club_short_name = v_winner
           AND stage = 'winner'
       ) THEN
      PERFORM public.competition_credit_club_balance(v_winner, v_amount);
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
      )
      VALUES (
        v_fixture.season_id,
        p_fixture_id,
        v_winner,
        'prize',
        v_amount,
        format('%s champion — %s', upper(v_fixture.cup_code), public.competition_cup_fixture_label(v_fixture)),
        jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', 'winner')
      );
      INSERT INTO public.competition_cup_prize_paid (fixture_id, club_short_name, stage, amount)
      VALUES (p_fixture_id, v_winner, 'winner', v_amount);
    END IF;
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Public views (cup leg + schedule labels)
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.competition_cup_bracket_public;
DROP VIEW IF EXISTS public.competition_fixtures_public;

CREATE VIEW public.competition_fixtures_public
WITH (security_invoker = false)
AS
SELECT
  f.id,
  f.season_id,
  f.division,
  f.competition_type,
  f.cup_code,
  f.cup_round,
  f.cup_match,
  f.cup_leg,
  f.matchday,
  f.gpsl_month,
  f.week_in_month,
  f.home_club_short_name,
  hc."Club" AS home_club_name,
  f.away_club_short_name,
  ac."Club" AS away_club_name,
  f.weather,
  f.home_goals,
  f.away_goals,
  f.status,
  sub.submission_id,
  sub.submission_status,
  sub.submitted_by_club,
  sub.proposed_home_goals,
  sub.proposed_away_goals
FROM public.competition_fixtures f
JOIN public.competition_seasons s ON s.id = f.season_id
JOIN public."Clubs" hc ON hc."ShortName" = f.home_club_short_name
JOIN public."Clubs" ac ON ac."ShortName" = f.away_club_short_name
LEFT JOIN LATERAL (
  SELECT
    rs.id AS submission_id,
    rs.status AS submission_status,
    rs.submitted_by_club,
    rs.home_goals AS proposed_home_goals,
    rs.away_goals AS proposed_away_goals
  FROM public.competition_result_submissions rs
  WHERE rs.fixture_id = f.id AND rs.status = 'pending'
  LIMIT 1
) sub ON true
WHERE s.status = 'active' AND s.is_current = true;

CREATE VIEW public.competition_cup_bracket_public
WITH (security_invoker = false)
AS
SELECT
  n.id,
  n.season_id,
  n.cup_code,
  n.round_no,
  n.match_no,
  n.cup_leg,
  n.leg1_node_id,
  sch.round_label,
  sch.gpsl_month AS round_gpsl_month,
  n.home_club_short_name,
  hc."Club" AS home_club_name,
  n.away_club_short_name,
  ac."Club" AS away_club_name,
  n.winner_club_short_name,
  wc."Club" AS winner_club_name,
  n.fixture_id,
  f.status AS fixture_status,
  f.home_goals,
  f.away_goals,
  f.gpsl_month AS fixture_gpsl_month,
  n.child_node_id,
  n.child_slot
FROM public.competition_cup_bracket_nodes n
JOIN public.competition_seasons s ON s.id = n.season_id
LEFT JOIN public.competition_cup_round_schedule sch
  ON sch.cup_code = n.cup_code
 AND sch.round_no = n.round_no
 AND sch.cup_leg = coalesce(n.cup_leg, 1)
LEFT JOIN public."Clubs" hc ON hc."ShortName" = n.home_club_short_name
LEFT JOIN public."Clubs" ac ON ac."ShortName" = n.away_club_short_name
LEFT JOIN public."Clubs" wc ON wc."ShortName" = n.winner_club_short_name
LEFT JOIN public.competition_fixtures f ON f.id = n.fixture_id
WHERE s.status = 'active' AND s.is_current = true;

GRANT SELECT ON public.competition_fixtures_public TO authenticated;
GRANT SELECT ON public.competition_fixtures_public TO anon;
GRANT SELECT ON public.competition_cup_bracket_public TO authenticated;
GRANT SELECT ON public.competition_cup_bracket_public TO anon;
