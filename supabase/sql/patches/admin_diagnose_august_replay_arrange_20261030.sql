-- Which August (etc.) reset/replay fixtures should light Arrange / Club Wire?
-- Read-only.

SELECT
  f.id,
  f.home_club_short_name,
  f.away_club_short_name,
  f.matchday,
  f.gpsl_month,
  f.status,
  f.admin_replay_reset_at,
  public.match_schedule_fixture_is_catch_up(f.id) AS is_catch_up,
  sch.status AS schedule_status,
  sch.agreed_kickoff_at,
  cal.unlock_at AS month_unlock_at,
  cal.unlock_at > now() AS unlock_still_future
FROM public.competition_fixtures f
JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
LEFT JOIN public.competition_season_calendar cal
  ON cal.season_id = f.season_id
 AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
WHERE f.status = 'scheduled'
  AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
  AND (
    f.admin_replay_reset_at IS NOT NULL
    OR public.match_schedule_fixture_is_catch_up(f.id)
    OR lower(btrim(f.gpsl_month)) = 'august'
  )
  AND coalesce(sch.status, 'unscheduled') <> 'agreed'
ORDER BY f.admin_replay_reset_at DESC NULLS LAST, f.gpsl_month, f.matchday;
