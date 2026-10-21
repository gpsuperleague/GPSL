SELECT m.fixture_id, f.matchday, f.away_club_short_name AS away,
       m.requested_by_club, m.kind, m.proposed_kickoff_at, m.status,
       m.home_confirmed_at, m.away_confirmed_at,
       m.created_at, m.expires_at, m.applied_at
FROM competition_fixture_mutual_override m
JOIN competition_fixtures f ON f.id = m.fixture_id
WHERE m.fixture_id IN (8980, 9719)
ORDER BY m.created_at;
