-- Any schedule history / inbox for POR August homes
WITH season AS (
  SELECT id FROM competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
),
aug AS (
  SELECT f.id, f.matchday, f.away_club_short_name
  FROM competition_fixtures f
  JOIN season s ON s.id = f.season_id
  WHERE f.home_club_short_name = 'POR'
    AND lower(btrim(f.gpsl_month)) LIKE '%august%'
)
SELECT 'proposal' AS kind, a.id AS fixture_id, a.matchday, a.away_club_short_name AS away,
       p.status::text AS detail, p.proposed_by_club_short_name AS club,
       p.proposed_kickoff_at AS at, p.created_at
FROM aug a
JOIN competition_fixture_schedule_proposal p ON p.fixture_id = a.id
UNION ALL
SELECT 'inbox', a.id, a.matchday, a.away_club_short_name,
       i.message_type::text, i.club_short_name,
       NULL::timestamptz, i.created_at
FROM aug a
JOIN competition_inbox i ON i.fixture_id = a.id
WHERE i.club_short_name = 'POR'
ORDER BY created_at NULLS LAST;
