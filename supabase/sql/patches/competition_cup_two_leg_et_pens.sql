-- =============================================================================
-- Two-legged cups (Super8 / Bowl): ET + pens only on 2nd leg when aggregate level
--
-- Leg 1: draws allowed; no extra time / penalties.
-- Leg 2: after 90 min, if aggregate is level → ET then pens if still level.
-- Single-leg cups unchanged (ET/pens whenever level after 90).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_cup_fixture_has_second_leg(
  p_cup_code text,
  p_cup_round int
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_cup_round_schedule s
    WHERE s.cup_code = p_cup_code
      AND s.round_no = p_cup_round
      AND s.cup_leg = 2
  );
$$;

CREATE OR REPLACE FUNCTION public.competition_cup_is_two_leg_first(
  p_fixture public.competition_fixtures
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT p_fixture.competition_type = 'cup'
    AND coalesce(p_fixture.cup_leg, 1) = 1
    AND public.competition_cup_fixture_has_second_leg(p_fixture.cup_code, p_fixture.cup_round);
$$;

CREATE OR REPLACE FUNCTION public.competition_cup_is_two_leg_second(
  p_fixture public.competition_fixtures
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT p_fixture.competition_type = 'cup'
    AND coalesce(p_fixture.cup_leg, 1) = 2;
$$;

-- Aggregate from tie-home perspective (leg1 home club) after leg2 open-play totals
CREATE OR REPLACE FUNCTION public.competition_cup_two_leg_aggregate(
  p_leg1_home_goals int,
  p_leg1_away_goals int,
  p_leg2_home_goals int,
  p_leg2_away_goals int
)
RETURNS TABLE (tie_home_agg int, tie_away_agg int)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    coalesce(p_leg1_home_goals, 0) + coalesce(p_leg2_away_goals, 0),
    coalesce(p_leg1_away_goals, 0) + coalesce(p_leg2_home_goals, 0);
$$;

CREATE OR REPLACE FUNCTION public.competition_cup_leg1_fixture_for(
  p_leg2 public.competition_fixtures
)
RETURNS public.competition_fixtures
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_leg1 public.competition_fixtures;
BEGIN
  SELECT f.* INTO v_leg1
  FROM public.competition_fixtures f
  WHERE f.season_id = p_leg2.season_id
    AND f.competition_type = 'cup'
    AND f.cup_code = p_leg2.cup_code
    AND f.cup_round = p_leg2.cup_round
    AND f.cup_match = p_leg2.cup_match
    AND coalesce(f.cup_leg, 1) = 1
  LIMIT 1;

  RETURN v_leg1;
END;
$function$;

-- True when leg2 open-play (90 or after ET) leaves the tie level on aggregate
CREATE OR REPLACE FUNCTION public.competition_cup_two_leg_needs_decider(
  p_leg2 public.competition_fixtures,
  p_leg2_home_open int,
  p_leg2_away_open int
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_leg1 public.competition_fixtures;
  v_th int;
  v_ta int;
BEGIN
  IF NOT public.competition_cup_is_two_leg_second(p_leg2) THEN
    RETURN false;
  END IF;

  v_leg1 := public.competition_cup_leg1_fixture_for(p_leg2);
  IF v_leg1.id IS NULL THEN
    RETURN false;
  END IF;

  IF v_leg1.status IS DISTINCT FROM 'played'
     OR v_leg1.home_goals IS NULL OR v_leg1.away_goals IS NULL THEN
    RETURN false;
  END IF;

  SELECT a.tie_home_agg, a.tie_away_agg
  INTO v_th, v_ta
  FROM public.competition_cup_two_leg_aggregate(
    v_leg1.home_goals,
    v_leg1.away_goals,
    p_leg2_home_open,
    p_leg2_away_open
  ) a;

  RETURN v_th = v_ta;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_submit_result(
  p_fixture_id bigint,
  p_home_goals smallint,
  p_away_goals smallint,
  p_player_stats jsonb DEFAULT '[]'::jsonb,
  p_et_home_goals smallint DEFAULT NULL,
  p_et_away_goals smallint DEFAULT NULL,
  p_pen_winner_club text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_fixture public.competition_fixtures;
  v_opponent text;
  v_submission_id bigint;
  v_home_name text;
  v_away_name text;
  v_title text;
  v_body text;
  v_label text;
  v_home_total int;
  v_away_total int;
  v_winner text;
  v_pen_winner text;
  v_pen_winner_name text;
  v_needs_decider boolean;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF p_home_goals IS NULL OR p_away_goals IS NULL OR p_home_goals < 0 OR p_away_goals < 0 THEN
    RAISE EXCEPTION 'Invalid score';
  END IF;

  IF p_player_stats IS NOT NULL AND jsonb_typeof(p_player_stats) <> 'array' THEN
    RAISE EXCEPTION 'player_stats must be a JSON array';
  END IF;

  SELECT f.* INTO v_fixture
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id
  WHERE f.id = p_fixture_id
    AND s.is_current = true
    AND s.status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found on current season';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for result entry';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  v_pen_winner := nullif(trim(p_pen_winner_club), '');

  IF v_fixture.competition_type = 'league' THEN
    IF p_et_home_goals IS NOT NULL OR p_et_away_goals IS NOT NULL OR v_pen_winner IS NOT NULL THEN
      RAISE EXCEPTION 'Extra time and penalties apply to cup matches only';
    END IF;
  END IF;

  IF v_fixture.competition_type = 'cup' THEN
    IF public.competition_cup_is_two_leg_first(v_fixture) THEN
      -- First leg: draws OK; never ET/pens
      IF p_et_home_goals IS NOT NULL OR p_et_away_goals IS NOT NULL OR v_pen_winner IS NOT NULL THEN
        RAISE EXCEPTION 'Extra time and penalties are only used in the 2nd leg (if aggregate is level)';
      END IF;
    ELSIF public.competition_cup_is_two_leg_second(v_fixture) THEN
      v_needs_decider := public.competition_cup_two_leg_needs_decider(
        v_fixture, p_home_goals, p_away_goals
      );

      IF NOT v_needs_decider THEN
        IF p_et_home_goals IS NOT NULL OR p_et_away_goals IS NOT NULL OR v_pen_winner IS NOT NULL THEN
          RAISE EXCEPTION 'Extra time and penalties only when the tie is level on aggregate after 90 minutes';
        END IF;
      ELSE
        IF p_et_home_goals IS NULL OR p_et_away_goals IS NULL THEN
          RAISE EXCEPTION 'Tie level on aggregate after 90 minutes — enter total score after extra time';
        END IF;

        IF p_et_home_goals < p_home_goals OR p_et_away_goals < p_away_goals THEN
          RAISE EXCEPTION 'Score after extra time cannot be less than the 90 minute score';
        END IF;

        v_home_total := p_et_home_goals;
        v_away_total := p_et_away_goals;

        IF public.competition_cup_two_leg_needs_decider(v_fixture, v_home_total, v_away_total) THEN
          IF v_pen_winner IS NULL THEN
            RAISE EXCEPTION 'Still level on aggregate after extra time — select penalty shootout winner';
          END IF;
          IF v_pen_winner NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
            RAISE EXCEPTION 'Penalty winner must be home or away club';
          END IF;
        ELSIF v_pen_winner IS NOT NULL THEN
          RAISE EXCEPTION 'Penalties only when still level on aggregate after extra time';
        END IF;
      END IF;
    ELSE
      -- Single-leg cup
      IF p_home_goals <> p_away_goals THEN
        IF p_et_home_goals IS NOT NULL OR p_et_away_goals IS NOT NULL OR v_pen_winner IS NOT NULL THEN
          RAISE EXCEPTION 'Extra time and penalties only when level after 90 minutes';
        END IF;
      ELSE
        IF p_et_home_goals IS NULL OR p_et_away_goals IS NULL THEN
          RAISE EXCEPTION 'Cup draw after 90 minutes — enter total score after extra time';
        END IF;

        IF p_et_home_goals < p_home_goals OR p_et_away_goals < p_away_goals THEN
          RAISE EXCEPTION 'Score after extra time cannot be less than the 90 minute score';
        END IF;

        v_home_total := p_et_home_goals;
        v_away_total := p_et_away_goals;

        IF v_home_total = v_away_total THEN
          IF v_pen_winner IS NULL THEN
            RAISE EXCEPTION 'Still level after extra time — select penalty shootout winner';
          END IF;
          IF v_pen_winner NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
            RAISE EXCEPTION 'Penalty winner must be home or away club';
          END IF;
        ELSIF v_pen_winner IS NOT NULL THEN
          RAISE EXCEPTION 'Penalties only when still level after extra time';
        END IF;
      END IF;

      v_winner := public.competition_cup_winner_from_submission(
        p_home_goals, p_away_goals, p_et_home_goals, p_et_away_goals,
        v_pen_winner,
        v_fixture.home_club_short_name, v_fixture.away_club_short_name
      );
      IF v_winner IS NULL THEN
        RAISE EXCEPTION 'Could not determine cup winner from scores';
      END IF;
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_result_submissions s
    WHERE s.fixture_id = p_fixture_id AND s.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A result is already awaiting confirmation for this fixture';
  END IF;

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);

  INSERT INTO public.competition_result_submissions (
    fixture_id, submitted_by_club, home_goals, away_goals, status, player_stats,
    et_home_goals, et_away_goals, pen_winner_club_short_name
  )
  VALUES (
    p_fixture_id, v_club, p_home_goals, p_away_goals, 'pending',
    coalesce(p_player_stats, '[]'::jsonb),
    p_et_home_goals, p_et_away_goals, v_pen_winner
  )
  RETURNING id INTO v_submission_id;

  SELECT "Club" INTO v_home_name FROM public."Clubs" WHERE "ShortName" = v_fixture.home_club_short_name;
  SELECT "Club" INTO v_away_name FROM public."Clubs" WHERE "ShortName" = v_fixture.away_club_short_name;

  v_label := public.competition_cup_fixture_label(v_fixture);

  v_title := format('Confirm result: %s vs %s', v_home_name, v_away_name);
  v_body := format(
    '%s — %s submitted %s %s–%s %s (90 min).',
    v_label, v_club, v_home_name, p_home_goals, p_away_goals, v_away_name
  );

  IF p_et_home_goals IS NOT NULL THEN
    v_body := v_body || format(' After ET %s–%s.', p_et_home_goals, p_et_away_goals);
  END IF;
  IF v_pen_winner IS NOT NULL THEN
    SELECT "Club" INTO v_pen_winner_name FROM public."Clubs" WHERE "ShortName" = v_pen_winner;
    v_body := v_body || format(' Pens: %s won.', coalesce(v_pen_winner_name, v_pen_winner));
  END IF;
  v_body := v_body || ' Confirm or reject.';

  PERFORM public.competition_inbox_notify(
    v_opponent, 'result_to_confirm', p_fixture_id, v_submission_id, v_title, v_body
  );

  RETURN v_submission_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_confirm_result(p_submission_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_sub public.competition_result_submissions;
  v_fixture public.competition_fixtures;
  v_opponent text;
  v_home_name text;
  v_away_name text;
  v_label text;
  v_home_total smallint;
  v_away_total smallint;
  v_body text;
  v_pen_winner_name text;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_sub
  FROM public.competition_result_submissions
  WHERE id = p_submission_id AND status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pending submission not found';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = v_sub.fixture_id;

  v_opponent := public.competition_fixture_opponent(v_sub.fixture_id, v_club);
  IF v_opponent <> v_sub.submitted_by_club THEN
    RAISE EXCEPTION 'Only the opponent can confirm this result';
  END IF;

  IF v_fixture.competition_type = 'cup' THEN
    SELECT t.home_total, t.away_total
    INTO v_home_total, v_away_total
    FROM public.competition_cup_open_play_totals(
      v_sub.home_goals, v_sub.away_goals, v_sub.et_home_goals, v_sub.et_away_goals
    ) t;

    IF public.competition_cup_is_two_leg_first(v_fixture) THEN
      IF v_sub.et_home_goals IS NOT NULL OR v_sub.et_away_goals IS NOT NULL
         OR nullif(btrim(coalesce(v_sub.pen_winner_club_short_name, '')), '') IS NOT NULL THEN
        RAISE EXCEPTION 'Invalid 1st-leg submission — no extra time or penalties';
      END IF;
      v_home_total := v_sub.home_goals;
      v_away_total := v_sub.away_goals;
    ELSIF public.competition_cup_is_two_leg_second(v_fixture) THEN
      IF public.competition_cup_two_leg_needs_decider(v_fixture, v_sub.home_goals, v_sub.away_goals) THEN
        IF v_sub.et_home_goals IS NULL OR v_sub.et_away_goals IS NULL THEN
          RAISE EXCEPTION 'Invalid 2nd-leg submission — extra time required when aggregate is level';
        END IF;
        IF public.competition_cup_two_leg_needs_decider(v_fixture, v_home_total, v_away_total)
           AND nullif(btrim(coalesce(v_sub.pen_winner_club_short_name, '')), '') IS NULL THEN
          RAISE EXCEPTION 'Invalid 2nd-leg submission — penalties required when still level after ET';
        END IF;
      END IF;
    ELSE
      IF public.competition_cup_winner_from_submission(
        v_sub.home_goals, v_sub.away_goals, v_sub.et_home_goals, v_sub.et_away_goals,
        v_sub.pen_winner_club_short_name,
        v_fixture.home_club_short_name, v_fixture.away_club_short_name
      ) IS NULL THEN
        RAISE EXCEPTION 'Invalid cup submission — extra time or penalties required';
      END IF;
    END IF;

    UPDATE public.competition_fixtures
    SET home_goals = v_home_total,
        away_goals = v_away_total,
        cup_pen_winner_club_short_name = v_sub.pen_winner_club_short_name,
        status = 'played'
    WHERE id = v_sub.fixture_id;
  ELSE
    v_home_total := v_sub.home_goals;
    v_away_total := v_sub.away_goals;

    UPDATE public.competition_fixtures
    SET home_goals = v_sub.home_goals,
        away_goals = v_sub.away_goals,
        cup_pen_winner_club_short_name = NULL,
        status = 'played'
    WHERE id = v_sub.fixture_id;
  END IF;

  PERFORM public.competition_apply_submission_player_stats(p_submission_id);
  PERFORM public.competition_settle_fixture_gates(v_sub.fixture_id);

  IF v_fixture.competition_type = 'cup' THEN
    PERFORM public.competition_cup_on_fixture_played(v_sub.fixture_id);
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'confirmed',
      responded_by_club = v_club,
      responded_at = now()
  WHERE id = p_submission_id;

  UPDATE public.competition_inbox
  SET read_at = coalesce(read_at, now())
  WHERE submission_id = p_submission_id
    AND recipient_club_short_name = v_club
    AND message_type = 'result_to_confirm';

  SELECT "Club" INTO v_home_name FROM public."Clubs" WHERE "ShortName" = v_fixture.home_club_short_name;
  SELECT "Club" INTO v_away_name FROM public."Clubs" WHERE "ShortName" = v_fixture.away_club_short_name;

  v_label := CASE
    WHEN v_fixture.competition_type = 'cup' THEN public.competition_cup_fixture_label(v_fixture)
    ELSE format('Matchday %s', v_fixture.matchday)
  END;

  IF v_sub.et_home_goals IS NOT NULL THEN
    v_body := format(
      '%s confirmed: %s %s–%s %s (90 min), after ET %s–%s.',
      v_label, v_home_name, v_sub.home_goals, v_sub.away_goals, v_away_name,
      v_sub.et_home_goals, v_sub.et_away_goals
    );
  ELSE
    v_body := format(
      '%s confirmed: %s %s–%s %s.',
      v_label, v_home_name, v_home_total, v_away_total, v_away_name
    );
  END IF;

  IF v_sub.pen_winner_club_short_name IS NOT NULL THEN
    SELECT "Club" INTO v_pen_winner_name FROM public."Clubs" WHERE "ShortName" = v_sub.pen_winner_club_short_name;
    v_body := v_body || format(' Pens: %s won.', coalesce(v_pen_winner_name, v_sub.pen_winner_club_short_name));
  END IF;

  PERFORM public.competition_inbox_notify(
    v_sub.submitted_by_club, 'result_confirmed', v_sub.fixture_id, p_submission_id,
    format('Result confirmed: %s vs %s', v_home_name, v_away_name),
    v_body
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_fixture_has_second_leg(text, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_two_leg_aggregate(int, int, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_leg1_fixture_for(public.competition_fixtures) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_two_leg_needs_decider(public.competition_fixtures, int, int) TO authenticated;

-- Remove unused variable leftover safety
-- (confirm_result body is complete above)

GRANT EXECUTE ON FUNCTION public.competition_submit_result(bigint, smallint, smallint, jsonb, smallint, smallint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_confirm_result(bigint) TO authenticated;