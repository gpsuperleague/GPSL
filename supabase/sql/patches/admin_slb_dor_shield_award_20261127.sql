-- November Shield quarter-final: Slovan Bratislava vs Dortmund, fixture 9960.
-- Award 3–0 to Slovan. Window-expiry tariff is ₿0, so Dortmund is not fined.
-- The winner fills the away slot of Shield round 5 against Barcelona.
-- Safe re-run.

DO $award$
DECLARE
  v_f public.competition_fixtures%ROWTYPE;
BEGIN
  PERFORM set_config('statement_timeout', '180s', true);
  PERFORM set_config('gpsl.skip_bookies_reprice', 'on', true);

  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = 9960
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture 9960 not found';
  END IF;

  IF v_f.status = 'played'
     AND v_f.home_goals = 3
     AND v_f.away_goals = 0
     AND coalesce(v_f.is_forfeit, false)
     AND upper(v_f.forfeit_loser_club) = 'DOR' THEN
    RETURN;
  END IF;

  IF v_f.status IS DISTINCT FROM 'scheduled'
     OR v_f.competition_type IS DISTINCT FROM 'cup'
     OR lower(v_f.cup_code) IS DISTINCT FROM 'shield'
     OR v_f.cup_round IS DISTINCT FROM 4
     OR lower(v_f.gpsl_month) IS DISTINCT FROM 'november'
     OR upper(v_f.home_club_short_name) IS DISTINCT FROM 'SLB'
     OR upper(v_f.away_club_short_name) IS DISTINCT FROM 'DOR' THEN
    RAISE EXCEPTION 'Fixture 9960 is not the scheduled November Shield Slovan vs Dortmund';
  END IF;

  PERFORM public.fixture_apply_forfeit(
    9960,
    'DOR',
    'match_window_expiry',
    'November Shield awarded 3–0 to Slovan Bratislava.'
  );
END
$award$;

SELECT jsonb_build_object(
  'fixture', (
    SELECT jsonb_build_object(
      'status', f.status,
      'home', f.home_club_short_name,
      'away', f.away_club_short_name,
      'home_goals', f.home_goals,
      'away_goals', f.away_goals,
      'forfeit', f.is_forfeit,
      'loser', f.forfeit_loser_club
    )
    FROM public.competition_fixtures f
    WHERE f.id = 9960
  ),
  'next', (
    SELECT jsonb_build_object(
      'round', n.round_no,
      'match', n.match_no,
      'home', n.home_club_short_name,
      'away', n.away_club_short_name,
      'fixture_id', n.fixture_id
    )
    FROM public.competition_cup_bracket_nodes n
    WHERE n.id = 1431
  )
) AS payload;
