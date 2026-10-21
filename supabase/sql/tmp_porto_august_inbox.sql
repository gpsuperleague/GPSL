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
SELECT a.id AS fixture_id, a.matchday, a.away_club_short_name AS away,
       i.message_type, i.recipient_club_short_name, i.created_at
FROM aug a
JOIN competition_inbox i ON i.fixture_id = a.id
ORDER BY i.created_at;
