-- Cup knockouts: 90 min score + optional extra time + penalty shootout.
-- Run once after competition_phase6_cups.sql.
-- League matches unchanged (home_goals / away_goals only).

ALTER TABLE public.competition_result_submissions
  ADD COLUMN IF NOT EXISTS et_home_goals smallint CHECK (et_home_goals IS NULL OR et_home_goals >= 0),
  ADD COLUMN IF NOT EXISTS et_away_goals smallint CHECK (et_away_goals IS NULL OR et_away_goals >= 0),
  ADD COLUMN IF NOT EXISTS pen_home_goals smallint CHECK (pen_home_goals IS NULL OR pen_home_goals >= 0),
  ADD COLUMN IF NOT EXISTS pen_away_goals smallint CHECK (pen_away_goals IS NULL OR pen_away_goals >= 0);

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS cup_pen_home_goals smallint CHECK (cup_pen_home_goals IS NULL OR cup_pen_home_goals >= 0),
  ADD COLUMN IF NOT EXISTS cup_pen_away_goals smallint CHECK (cup_pen_away_goals IS NULL OR cup_pen_away_goals >= 0);

COMMENT ON COLUMN public.competition_result_submissions.home_goals IS
  'League: final score. Cup: goals after 90 minutes only.';
COMMENT ON COLUMN public.competition_result_submissions.et_home_goals IS
  'Cup only: extra-time goals (added to 90 min for open-play total).';
COMMENT ON COLUMN public.competition_result_submissions.pen_home_goals IS
  'Cup only: penalty shootout score if still level after ET.';

CREATE OR REPLACE FUNCTION public.competition_cup_open_play_totals(
  p_home_90 smallint,
  p_away_90 smallint,
  p_et_home smallint,
  p_et_away smallint
)
RETURNS TABLE (home_total smallint, away_total smallint)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    (coalesce(p_home_90, 0) + coalesce(p_et_home, 0))::smallint,
    (coalesce(p_away_90, 0) + coalesce(p_et_away, 0))::smallint;
$$;

CREATE OR REPLACE FUNCTION public.competition_cup_winner_from_submission(
  p_home_90 smallint,
  p_away_90 smallint,
  p_et_home smallint,
  p_et_away smallint,
  p_pen_home smallint,
  p_pen_away smallint,
  p_home_club text,
  p_away_club text
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_home int;
  v_away int;
BEGIN
  v_home := coalesce(p_home_90, 0) + coalesce(p_et_home, 0);
  v_away := coalesce(p_away_90, 0) + coalesce(p_et_away, 0);

  IF v_home > v_away THEN
    RETURN p_home_club;
  ELSIF v_away > v_home THEN
    RETURN p_away_club;
  END IF;

  IF p_pen_home IS NULL OR p_pen_away IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_pen_home > p_pen_away THEN
    RETURN p_home_club;
  ELSIF p_pen_away > p_pen_home THEN
    RETURN p_away_club;
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_cup_on_fixture_played(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_node public.competition_cup_bracket_nodes;
  v_winner text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id AND competition_type = 'cup';

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_fixture.home_goals IS NULL OR v_fixture.away_goals IS NULL THEN
    RETURN;
  END IF;

  IF v_fixture.home_goals > v_fixture.away_goals THEN
    v_winner := v_fixture.home_club_short_name;
  ELSIF v_fixture.away_goals > v_fixture.home_goals THEN
    v_winner := v_fixture.away_club_short_name;
  ELSIF v_fixture.cup_pen_home_goals IS NOT NULL
    AND v_fixture.cup_pen_away_goals IS NOT NULL
    AND v_fixture.cup_pen_home_goals <> v_fixture.cup_pen_away_goals THEN
    IF v_fixture.cup_pen_home_goals > v_fixture.cup_pen_away_goals THEN
      v_winner := v_fixture.home_club_short_name;
    ELSE
      v_winner := v_fixture.away_club_short_name;
    END IF;
  ELSE
    RETURN;
  END IF;

  SELECT * INTO v_node
  FROM public.competition_cup_bracket_nodes
  WHERE fixture_id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  UPDATE public.competition_cup_bracket_nodes
  SET winner_club_short_name = v_winner
  WHERE id = v_node.id;

  PERFORM public.competition_cup_advance_node_winner(v_node.id);
  PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_submit_result(
  p_fixture_id bigint,
  p_home_goals smallint,
  p_away_goals smallint,
  p_player_stats jsonb DEFAULT '[]'::jsonb,
  p_et_home_goals smallint DEFAULT NULL,
  p_et_away_goals smallint DEFAULT NULL,
  p_pen_home_goals smallint DEFAULT NULL,
  p_pen_away_goals smallint DEFAULT NULL
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
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
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

  IF v_fixture.competition_type = 'league' THEN
    IF p_et_home_goals IS NOT NULL OR p_et_away_goals IS NOT NULL
       OR p_pen_home_goals IS NOT NULL OR p_pen_away_goals IS NOT NULL THEN
      RAISE EXCEPTION 'Extra time and penalties apply to cup matches only';
    END IF;
  END IF;

  IF v_fixture.competition_type = 'cup' THEN
    v_home_total := p_home_goals + coalesce(p_et_home_goals, 0);
    v_away_total := p_away_goals + coalesce(p_et_away_goals, 0);

    IF p_home_goals = p_away_goals THEN
      IF p_et_home_goals IS NULL OR p_et_away_goals IS NULL THEN
        RAISE EXCEPTION 'Cup draw after 90 minutes — enter extra time scores';
      END IF;
      IF v_home_total = v_away_total THEN
        IF p_pen_home_goals IS NULL OR p_pen_away_goals IS NULL THEN
          RAISE EXCEPTION 'Still level after extra time — enter penalty shootout score';
        END IF;
        IF p_pen_home_goals = p_pen_away_goals THEN
          RAISE EXCEPTION 'Penalty shootout must have a winner';
        END IF;
      END IF;
    ELSE
      IF p_et_home_goals IS NOT NULL OR p_et_away_goals IS NOT NULL
         OR p_pen_home_goals IS NOT NULL OR p_pen_away_goals IS NOT NULL THEN
        RAISE EXCEPTION 'Extra time and penalties only when the match is level after 90 minutes';
      END IF;
    END IF;

    v_winner := public.competition_cup_winner_from_submission(
      p_home_goals, p_away_goals, p_et_home_goals, p_et_away_goals,
      p_pen_home_goals, p_pen_away_goals,
      v_fixture.home_club_short_name, v_fixture.away_club_short_name
    );
    IF v_winner IS NULL THEN
      RAISE EXCEPTION 'Could not determine cup winner from scores';
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
    et_home_goals, et_away_goals, pen_home_goals, pen_away_goals
  )
  VALUES (
    p_fixture_id, v_club, p_home_goals, p_away_goals, 'pending',
    coalesce(p_player_stats, '[]'::jsonb),
    p_et_home_goals, p_et_away_goals, p_pen_home_goals, p_pen_away_goals
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
    v_body := v_body || format(' ET %s–%s.', p_et_home_goals, p_et_away_goals);
  END IF;
  IF p_pen_home_goals IS NOT NULL THEN
    v_body := v_body || format(' Pens %s–%s.', p_pen_home_goals, p_pen_away_goals);
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
    v_home_total := (v_sub.home_goals + coalesce(v_sub.et_home_goals, 0))::smallint;
    v_away_total := (v_sub.away_goals + coalesce(v_sub.et_away_goals, 0))::smallint;

    IF public.competition_cup_winner_from_submission(
      v_sub.home_goals, v_sub.away_goals, v_sub.et_home_goals, v_sub.et_away_goals,
      v_sub.pen_home_goals, v_sub.pen_away_goals,
      v_fixture.home_club_short_name, v_fixture.away_club_short_name
    ) IS NULL THEN
      RAISE EXCEPTION 'Invalid cup submission — extra time or penalties required';
    END IF;

    UPDATE public.competition_fixtures
    SET home_goals = v_home_total,
        away_goals = v_away_total,
        cup_pen_home_goals = v_sub.pen_home_goals,
        cup_pen_away_goals = v_sub.pen_away_goals,
        status = 'played'
    WHERE id = v_sub.fixture_id;
  ELSE
    v_home_total := v_sub.home_goals;
    v_away_total := v_sub.away_goals;

    UPDATE public.competition_fixtures
    SET home_goals = v_sub.home_goals,
        away_goals = v_sub.away_goals,
        cup_pen_home_goals = NULL,
        cup_pen_away_goals = NULL,
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

  v_body := format(
    '%s — %s–%s confirmed (90 min %s–%s).',
    v_label, v_home_total, v_away_total, v_sub.home_goals, v_sub.away_goals
  );
  IF v_sub.et_home_goals IS NOT NULL THEN
    v_body := v_body || format(' ET %s–%s.', v_sub.et_home_goals, v_sub.et_away_goals);
  END IF;
  IF v_sub.pen_home_goals IS NOT NULL THEN
    v_body := v_body || format(' Pens %s–%s.', v_sub.pen_home_goals, v_sub.pen_away_goals);
  END IF;

  PERFORM public.competition_inbox_notify(
    v_sub.submitted_by_club,
    'result_confirmed',
    v_sub.fixture_id,
    p_submission_id,
    format('Result confirmed: %s vs %s', v_home_name, v_away_name),
    v_body
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_confirm_submission(p_submission_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sub public.competition_result_submissions;
  v_fixture public.competition_fixtures;
  v_home_total smallint;
  v_away_total smallint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_sub
  FROM public.competition_result_submissions
  WHERE id = p_submission_id AND status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pending submission not found';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = v_sub.fixture_id;

  IF v_fixture.competition_type = 'cup' THEN
    v_home_total := (v_sub.home_goals + coalesce(v_sub.et_home_goals, 0))::smallint;
    v_away_total := (v_sub.away_goals + coalesce(v_sub.et_away_goals, 0))::smallint;

    UPDATE public.competition_fixtures
    SET home_goals = v_home_total,
        away_goals = v_away_total,
        cup_pen_home_goals = v_sub.pen_home_goals,
        cup_pen_away_goals = v_sub.pen_away_goals,
        status = 'played'
    WHERE id = v_sub.fixture_id;
  ELSE
    UPDATE public.competition_fixtures
    SET home_goals = v_sub.home_goals,
        away_goals = v_sub.away_goals,
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
      responded_by_club = 'ADMIN',
      responded_at = now()
  WHERE id = p_submission_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_submit_result(
  bigint, smallint, smallint, jsonb, smallint, smallint, smallint, smallint
) TO authenticated;
