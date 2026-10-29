SELECT
  (position('competition_cup_retract_advancement_for_fixture' IN pg_get_functiondef(
    'public.admin_fixture_reset_for_replay(bigint,text,text)'::regprocedure
  )) > 0) AS retract_wired_into_reset;

SELECT
  n.id AS node_id,
  n.winner_club_short_name AS node_winner,
  n.fixture_id,
  f.status AS fixture_status,
  c.home_club_short_name AS child_home,
  c.away_club_short_name AS child_away,
  c.fixture_id AS child_fixture_id
FROM public.competition_cup_bracket_nodes n
LEFT JOIN public.competition_fixtures f ON f.id = n.fixture_id
LEFT JOIN public.competition_cup_bracket_nodes c ON c.id = n.child_node_id
WHERE n.fixture_id = 9722;

-- Next-round nodes that still list LIV from a cleared feeder should be empty away
SELECT id, home_club_short_name, away_club_short_name, fixture_id, winner_club_short_name
FROM public.competition_cup_bracket_nodes
WHERE id = (
  SELECT child_node_id FROM public.competition_cup_bracket_nodes WHERE fixture_id = 9722 LIMIT 1
);
