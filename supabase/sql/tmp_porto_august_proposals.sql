WITH season AS (
  SELECT id FROM competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
),
aug AS (
  SELECT f.id, f.matchday, f.away_club_short_name, f.competition_type
  FROM competition_fixtures f
  JOIN season s ON s.id = f.season_id
  WHERE f.home_club_short_name = 'POR'
    AND lower(btrim(f.gpsl_month)) LIKE '%august%'
    AND f.competition_type IN ('league','cup')
)
SELECT a.id AS fixture_id,
       a.matchday,
       a.away_club_short_name AS away,
       a.competition_type,
       p.id AS proposal_id,
       p.status AS proposal_status,
       p.proposed_by_club_short_name AS proposed_by,
       p.kickoff_at,
       p.created_at,
       public.match_schedule_home_has_proposed(a.id, now()) AS home_has_proposed
FROM aug a
LEFT JOIN competition_fixture_schedule_proposal p ON p.fixture_id = a.id
ORDER BY a.matchday, p.created_at NULLS LAST;
