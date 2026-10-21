WITH season AS (
  SELECT id FROM competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
),
aug AS (
  SELECT f.id, f.matchday, f.gpsl_month, f.competition_type, f.status,
         f.home_club_short_name, f.away_club_short_name
  FROM competition_fixtures f
  JOIN season s ON s.id = f.season_id
  WHERE f.home_club_short_name = 'POR'
    AND lower(btrim(f.gpsl_month)) LIKE '%august%'
    AND f.competition_type IN ('league','cup')
)
SELECT a.id AS fixture_id,
       a.matchday,
       a.gpsl_month,
       a.competition_type,
       a.away_club_short_name AS away,
       sch.status AS sched_status,
       sch.agreed_kickoff_at,
       sch.home_proposal_count,
       sch.away_proposal_count,
       sch.pending_proposal_id,
       sch.response_required_club_short_name AS reply_from,
       sch.response_due_at,
       sch.response_deadline_warned_at,
       sch.updated_at AS sched_updated_at
FROM aug a
LEFT JOIN competition_fixture_schedule sch ON sch.fixture_id = a.id
ORDER BY a.matchday, a.id;
