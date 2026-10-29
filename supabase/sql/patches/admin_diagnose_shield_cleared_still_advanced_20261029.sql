-- Diagnose: Shield (or any cup) nodes where fixture is unplayed but winner still advanced
-- Safe read-only.

SELECT
  n.id AS node_id,
  n.cup_code,
  n.round_code,
  n.round_index,
  n.bracket_index,
  n.home_club_short_name AS node_home,
  n.away_club_short_name AS node_away,
  n.winner_club_short_name AS node_winner,
  n.child_node_id,
  n.child_slot,
  n.fixture_id,
  f.status AS fixture_status,
  f.home_goals,
  f.away_goals,
  c.home_club_short_name AS child_home,
  c.away_club_short_name AS child_away,
  c.winner_club_short_name AS child_winner,
  c.fixture_id AS child_fixture_id,
  cf.status AS child_fixture_status
FROM public.competition_cup_bracket_nodes n
JOIN public.competition_seasons s ON s.id = n.season_id AND s.is_current
LEFT JOIN public.competition_fixtures f ON f.id = n.fixture_id
LEFT JOIN public.competition_cup_bracket_nodes c ON c.id = n.child_node_id
LEFT JOIN public.competition_fixtures cf ON cf.id = c.fixture_id
WHERE lower(btrim(coalesce(n.cup_code, ''))) = 'shield'
  AND n.winner_club_short_name IS NOT NULL
  AND (
    n.fixture_id IS NULL
    OR f.status IS DISTINCT FROM 'played'
    OR f.home_goals IS NULL
    OR f.away_goals IS NULL
  )
ORDER BY n.round_index, n.bracket_index;
