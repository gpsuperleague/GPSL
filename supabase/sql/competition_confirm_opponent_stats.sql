-- Opponent must submit squad stats when confirming a pending result.
-- Run after competition_cup_extra_time.sql (safe to re-run).

-- Required for Match Day lineup (started / subbed on). Harmless if already applied.
ALTER TABLE public.competition_match_player_stats
  ADD COLUMN IF NOT EXISTS started boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS subbed_on boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.competition_expected_goals_for_club(
  p_fixture public.competition_fixtures,
  p_sub public.competition_result_submissions,
  p_club text
)
RETURNS int
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_home_total int;
  v_away_total int;
BEGIN
  IF p_fixture.competition_type = 'cup' THEN
    SELECT t.home_total, t.away_total
    INTO v_home_total, v_away_total
    FROM public.competition_cup_open_play_totals(
      p_sub.home_goals, p_sub.away_goals, p_sub.et_home_goals, p_sub.et_away_goals
    ) t;
  ELSE
    v_home_total := p_sub.home_goals;
    v_away_total := p_sub.away_goals;
  END IF;

  IF p_club = p_fixture.home_club_short_name THEN
    RETURN v_home_total;
  END IF;
  RETURN v_away_total;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_apply_club_player_stats(
  p_fixture_id bigint,
  p_season_id bigint,
  p_club text,
  p_player_stats jsonb,
  p_expected_goals int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_item jsonb;
  v_player_id text;
  v_goals int;
  v_assists int;
  v_rating numeric;
  v_potm boolean;
  v_started boolean;
  v_subbed boolean;
  v_appeared boolean;
  v_team_goals int := 0;
  v_potm_count int := 0;
  v_started_count int := 0;
  v_subbed_count int := 0;
BEGIN
  IF p_player_stats IS NULL OR jsonb_typeof(p_player_stats) <> 'array' THEN
    RAISE EXCEPTION 'player_stats must be a JSON array';
  END IF;

  IF jsonb_array_length(p_player_stats) = 0 THEN
    RAISE EXCEPTION 'Squad match stats are required';
  END IF;

  DELETE FROM public.competition_match_player_stats
  WHERE fixture_id = p_fixture_id
    AND club_short_name = p_club;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_player_stats)
  LOOP
    v_player_id := trim(both '"' FROM (v_item ->> 'player_id'));
    v_goals := coalesce((v_item ->> 'goals')::int, 0);
    v_assists := coalesce((v_item ->> 'assists')::int, 0);
    v_rating := nullif(v_item ->> 'rating', '')::numeric;
    v_potm := coalesce((v_item ->> 'potm')::boolean, false);
    v_started := coalesce((v_item ->> 'started')::boolean, false);
    v_subbed := coalesce((v_item ->> 'subbed_on')::boolean, false);

    IF v_item ? 'started' OR v_item ? 'subbed_on' THEN
      v_appeared := v_started OR v_subbed;
    ELSE
      v_appeared := coalesce((v_item ->> 'appeared')::boolean, false);
    END IF;

    IF v_started AND v_subbed THEN
      RAISE EXCEPTION 'Player % cannot be both started and subbed on', v_player_id;
    END IF;

    IF v_player_id IS NULL OR v_player_id = '' THEN
      CONTINUE;
    END IF;

    IF NOT v_appeared AND v_goals = 0 AND v_assists = 0 AND v_rating IS NULL AND NOT v_potm THEN
      CONTINUE;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = v_player_id
        AND p."Contracted_Team" = p_club
    ) THEN
      RAISE EXCEPTION 'Player % is not on your club roster', v_player_id;
    END IF;

    IF v_potm THEN
      v_potm_count := v_potm_count + 1;
    END IF;

    IF v_started THEN
      v_started_count := v_started_count + 1;
    END IF;
    IF v_subbed THEN
      v_subbed_count := v_subbed_count + 1;
    END IF;

    v_team_goals := v_team_goals + v_goals;

    INSERT INTO public.competition_match_player_stats (
      fixture_id, season_id, club_short_name, player_id,
      appeared, started, subbed_on, goals, assists, rating, is_player_of_match
    )
    VALUES (
      p_fixture_id, p_season_id, p_club, v_player_id,
      v_appeared, v_started, v_subbed, v_goals, v_assists, v_rating, v_potm
    );
  END LOOP;

  IF v_started_count <> 11 THEN
    RAISE EXCEPTION 'Exactly 11 players must be marked as started (currently %)', v_started_count;
  END IF;

  IF v_subbed_count > 5 THEN
    RAISE EXCEPTION 'Maximum 5 players can be subbed on (currently %)', v_subbed_count;
  END IF;

  IF v_potm_count > 1 THEN
    RAISE EXCEPTION 'Only one player of the match allowed';
  END IF;

  IF v_team_goals > 0 AND v_team_goals <> p_expected_goals THEN
    RAISE EXCEPTION 'Player goals (%) must match your team score (%)', v_team_goals, p_expected_goals;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_apply_submission_player_stats(
  p_submission_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sub public.competition_result_submissions;
  v_fixture public.competition_fixtures;
  v_expected int;
BEGIN
  SELECT * INTO v_sub
  FROM public.competition_result_submissions
  WHERE id = p_submission_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = v_sub.fixture_id;

  IF v_sub.player_stats IS NULL
     OR jsonb_typeof(v_sub.player_stats) <> 'array'
     OR jsonb_array_length(v_sub.player_stats) = 0 THEN
    RETURN;
  END IF;

  v_expected := public.competition_expected_goals_for_club(
    v_fixture, v_sub, v_sub.submitted_by_club
  );

  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_sub.submitted_by_club,
    v_sub.player_stats,
    v_expected
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_confirm_result(
  p_submission_id bigint,
  p_confirmer_player_stats jsonb DEFAULT '[]'::jsonb
)
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
  v_confirmer_expected int;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF p_confirmer_player_stats IS NULL OR jsonb_typeof(p_confirmer_player_stats) <> 'array' THEN
    RAISE EXCEPTION 'player_stats must be a JSON array';
  END IF;

  IF jsonb_array_length(p_confirmer_player_stats) = 0 THEN
    RAISE EXCEPTION 'Enter your squad match stats (11 starters) before confirming';
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

  v_confirmer_expected := public.competition_expected_goals_for_club(v_fixture, v_sub, v_club);

  IF v_fixture.competition_type = 'cup' THEN
    SELECT t.home_total, t.away_total
    INTO v_home_total, v_away_total
    FROM public.competition_cup_open_play_totals(
      v_sub.home_goals, v_sub.away_goals, v_sub.et_home_goals, v_sub.et_away_goals
    ) t;

    IF public.competition_cup_winner_from_submission(
      v_sub.home_goals, v_sub.away_goals, v_sub.et_home_goals, v_sub.et_away_goals,
      v_sub.pen_winner_club_short_name,
      v_fixture.home_club_short_name, v_fixture.away_club_short_name
    ) IS NULL THEN
      RAISE EXCEPTION 'Invalid cup submission — extra time or penalties required';
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

  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_club,
    p_confirmer_player_stats,
    v_confirmer_expected
  );

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
      '%s — %s–%s confirmed (90 min %s–%s, after ET %s–%s).',
      v_label, v_home_total, v_away_total,
      v_sub.home_goals, v_sub.away_goals, v_sub.et_home_goals, v_sub.et_away_goals
    );
  ELSE
    v_body := format(
      '%s — %s–%s confirmed (90 min %s–%s).',
      v_label, v_home_total, v_away_total, v_sub.home_goals, v_sub.away_goals
    );
  END IF;

  IF v_sub.pen_winner_club_short_name IS NOT NULL THEN
    SELECT "Club" INTO v_pen_winner_name FROM public."Clubs" WHERE "ShortName" = v_sub.pen_winner_club_short_name;
    v_body := v_body || format(' Pens: %s won.', coalesce(v_pen_winner_name, v_sub.pen_winner_club_short_name));
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

DROP FUNCTION IF EXISTS public.competition_confirm_result(bigint);

GRANT EXECUTE ON FUNCTION public.competition_confirm_result(bigint, jsonb) TO authenticated;

-- Pending submission ET / pens on fixtures view for Match Day confirm UI
DROP VIEW IF EXISTS public.competition_cup_qualified_public;
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
  sub.proposed_away_goals,
  sub.proposed_et_home_goals,
  sub.proposed_et_away_goals,
  sub.proposed_pen_winner_club
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
    rs.away_goals AS proposed_away_goals,
    rs.et_home_goals AS proposed_et_home_goals,
    rs.et_away_goals AS proposed_et_away_goals,
    rs.pen_winner_club_short_name AS proposed_pen_winner_club
  FROM public.competition_result_submissions rs
  WHERE rs.fixture_id = f.id
    AND rs.status = 'pending'
    AND (
      public.is_gpsl_admin()
      OR public.my_club_shortname() = f.home_club_short_name
      OR public.my_club_shortname() = f.away_club_short_name
    )
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
  n.child_node_id,
  n.child_slot
FROM public.competition_cup_bracket_nodes n
JOIN public.competition_seasons s ON s.id = n.season_id
LEFT JOIN public."Clubs" hc ON hc."ShortName" = n.home_club_short_name
LEFT JOIN public."Clubs" ac ON ac."ShortName" = n.away_club_short_name
LEFT JOIN public."Clubs" wc ON wc."ShortName" = n.winner_club_short_name
LEFT JOIN public.competition_fixtures f ON f.id = n.fixture_id
WHERE s.status = 'active' AND s.is_current = true;

CREATE VIEW public.competition_cup_qualified_public
WITH (security_invoker = false)
AS
SELECT
  s.id AS season_id,
  cup.cup_code,
  q.club_short_name
FROM public.competition_seasons s
CROSS JOIN (
  VALUES ('super8'), ('plate'), ('shield'), ('spoon'), ('league_cup')
) AS cup(cup_code)
CROSS JOIN LATERAL unnest(public.competition_qualify_cup_clubs(s.id, cup.cup_code)) AS q(club_short_name)
WHERE s.is_current = true AND s.status = 'active';

GRANT SELECT ON public.competition_fixtures_public TO authenticated;
GRANT SELECT ON public.competition_fixtures_public TO anon;
GRANT SELECT ON public.competition_cup_bracket_public TO authenticated;
GRANT SELECT ON public.competition_cup_bracket_public TO anon;
GRANT SELECT ON public.competition_cup_qualified_public TO authenticated;
GRANT SELECT ON public.competition_cup_qualified_public TO anon;
