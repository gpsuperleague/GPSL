SELECT "ShortName", "Club"
FROM "Clubs"
WHERE "Club" ILIKE '%omni%'
   OR "Club" ILIKE '%corinth%'
   OR "Club" ILIKE '%sport%'
   OR "ShortName" ILIKE 'OMN%'
   OR "ShortName" ILIKE 'COR%'
ORDER BY 1
LIMIT 40;

SELECT id, matchday, gpsl_month, status, schedule_status, agreed_kickoff_at,
       home_club_short_name, away_club_short_name,
       home_checked_in, away_checked_in,
       is_catch_up, is_admin_replay,
       submission_id, home_goals, away_goals, competition_type, season_id
FROM competition_fixtures_public
WHERE competition_type = 'league'
  AND matchday = 1
  AND (
    home_club_short_name ILIKE '%OMN%'
    OR away_club_short_name ILIKE '%OMN%'
    OR home_club_short_name ILIKE '%COR%'
    OR away_club_short_name ILIKE '%COR%'
    OR home_club_name ILIKE '%Omni%'
    OR away_club_name ILIKE '%Omni%'
    OR home_club_name ILIKE '%Corinth%'
    OR away_club_name ILIKE '%Corinth%'
  )
ORDER BY season_id DESC, id DESC
LIMIT 30;
