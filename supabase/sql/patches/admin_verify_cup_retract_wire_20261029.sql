SELECT
  (position('competition_cup_retract_advancement_for_fixture' IN pg_get_functiondef(
    'public.admin_fixture_reset_for_replay(bigint,text,text)'::regprocedure
  )) > 0) AS retract_wired_into_reset,
  n.winner_club_short_name AS cleared_node_winner,
  n.fixture_id,
  f.status
FROM public.competition_cup_bracket_nodes n
LEFT JOIN public.competition_fixtures f ON f.id = n.fixture_id
WHERE n.fixture_id = 9722;
