SELECT i.fixture_id,
       f.matchday,
       f.away_club_short_name AS away,
       i.message_type,
       i.recipient_club_short_name,
       i.title,
       left(i.body, 400) AS body,
       i.created_at,
       i.read_at
FROM competition_inbox i
JOIN competition_fixtures f ON f.id = i.fixture_id
WHERE i.fixture_id IN (8980, 9719)
  AND i.message_type ILIKE '%mutual%'
ORDER BY i.created_at;

SELECT fixture_id, status, home_proposal_count, away_proposal_count,
       mutual_override_used, discord_hint_shown, agreed_kickoff_at, updated_at
FROM competition_fixture_schedule
WHERE fixture_id IN (8980, 9719);

-- Any pending mutual override rows if table exists
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public' AND table_name ILIKE '%mutual%';
