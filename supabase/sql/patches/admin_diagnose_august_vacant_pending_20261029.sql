-- =============================================================================
-- Lightweight diagnose: August vacant / season-absent fixtures still scheduled
-- Read-only. Run this first (should be fast).
-- =============================================================================

SELECT
  f.id AS fixture_id,
  f.matchday,
  f.division,
  f.competition_type,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  public.competition_club_is_vacant(f.home_club_short_name) AS home_vacant,
  public.competition_club_is_vacant(f.away_club_short_name) AS away_vacant,
  public.club_is_season_absent(f.home_club_short_name, f.season_id) AS home_absent,
  public.club_is_season_absent(f.away_club_short_name, f.season_id) AS away_absent
FROM public.competition_fixtures f
WHERE f.season_id = (
    SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
  )
  AND f.status = 'scheduled'
  AND f.competition_type IN ('league', 'cup')
  AND lower(btrim(f.gpsl_month)) = 'august'
  AND (
    public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
    OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
  )
ORDER BY f.division, f.matchday, f.id;

SELECT
  count(*) AS august_inactive_pending,
  count(*) FILTER (
    WHERE public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
      AND public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
  ) AS both_inactive,
  count(*) FILTER (
    WHERE public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
      <> public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
  ) AS one_inactive
FROM public.competition_fixtures f
WHERE f.season_id = (
    SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
  )
  AND f.status = 'scheduled'
  AND lower(btrim(f.gpsl_month)) = 'august'
  AND (
    public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
    OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
  );

SELECT job_key, gpsl_month, ran_at, result->>'walkovers' AS walkovers, result->>'voids' AS voids
FROM public.competition_season_calendar_jobs
WHERE season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
)
  AND job_key LIKE 'vacant_walkovers:%'
ORDER BY ran_at;
