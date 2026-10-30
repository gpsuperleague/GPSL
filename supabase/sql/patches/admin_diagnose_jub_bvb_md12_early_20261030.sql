-- Diagnose: Júbilo vs Dortmund MD12 holiday-early — score entry vs stats-edit
-- Safe read-only (+ optional notices). Re-run OK.

WITH fx AS (
  SELECT f.*
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
  WHERE f.matchday = 12
    AND coalesce(f.competition_type, 'league') = 'league'
    AND (
      (upper(f.home_club_short_name) = 'JUB' AND upper(f.away_club_short_name) IN ('BVB', 'DOR', 'BOR'))
      OR (upper(f.away_club_short_name) = 'JUB' AND upper(f.home_club_short_name) IN ('BVB', 'DOR', 'BOR'))
      OR (
        upper(f.home_club_short_name) IN ('JUB', 'BVB', 'DOR', 'BOR')
        AND upper(f.away_club_short_name) IN ('JUB', 'BVB', 'DOR', 'BOR')
      )
    )
)
SELECT
  f.id,
  f.home_club_short_name,
  f.away_club_short_name,
  f.matchday,
  f.gpsl_month,
  f.status,
  f.home_goals,
  f.away_goals,
  f.result_posted_at,
  f.result_posted_gpsl_month,
  f.home_stats_edit_used_at,
  f.away_stats_edit_used_at,
  public.competition_active_gpsl_month(f.season_id, now()) AS active_month,
  public.match_schedule_fixture_is_holiday_early(f.id) AS is_holiday_early,
  public.match_schedule_fixture_is_holiday_impacted(f.id) AS is_holiday_impacted,
  public.match_schedule_result_month_allows_submit(f.id) AS month_allows_submit,
  sch.status AS schedule_status,
  sch.agreed_kickoff_at,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
  ) AS home_checked_in,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
  ) AS away_checked_in
FROM fx f
LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id;

SELECT
  s.id AS submission_id,
  s.fixture_id,
  s.status,
  s.submitted_by_club,
  s.home_goals,
  s.away_goals,
  s.created_at,
  s.responded_at
FROM public.competition_result_submissions s
WHERE s.fixture_id IN (
  SELECT f.id
  FROM public.competition_fixtures f
  JOIN public.competition_seasons se ON se.id = f.season_id AND se.is_current
  WHERE f.matchday = 12
    AND coalesce(f.competition_type, 'league') = 'league'
    AND (
      upper(f.home_club_short_name) = 'JUB'
      OR upper(f.away_club_short_name) = 'JUB'
    )
    AND (
      upper(f.home_club_short_name) IN ('BVB', 'DOR', 'BOR', 'JUB')
      OR upper(f.away_club_short_name) IN ('BVB', 'DOR', 'BOR', 'JUB')
    )
)
ORDER BY s.id DESC;

-- Stats-edit list eligibility (same rules as Match Day)
SELECT
  f.id,
  f.status,
  f.result_posted_gpsl_month,
  public.competition_active_gpsl_month(f.season_id, now()) AS active_month,
  (f.status = 'played'
    AND lower(btrim(coalesce(f.result_posted_gpsl_month, '')))
        = lower(nullif(btrim(coalesce(
            public.competition_active_gpsl_month(f.season_id, now()), ''
          )), ''))
  ) AS would_appear_as_stats_edit
FROM public.competition_fixtures f
JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
WHERE f.matchday = 12
  AND coalesce(f.competition_type, 'league') = 'league'
  AND (upper(f.home_club_short_name) = 'JUB' OR upper(f.away_club_short_name) = 'JUB');
