SELECT i.fixture_id,
       f.matchday,
       f.away_club_short_name AS away,
       i.message_type,
       i.recipient_club_short_name,
       i.title,
       left(i.body, 500) AS body,
       i.created_at,
       i.read_at
FROM competition_inbox i
JOIN competition_fixtures f ON f.id = i.fixture_id
WHERE i.fixture_id IN (8980, 9719)
  AND i.message_type ILIKE '%mutual%'
ORDER BY i.created_at;
