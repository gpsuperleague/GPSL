-- =============================================================================
-- Diagnose why Play now is hidden for holiday-early / agreed MD7 fixtures.
-- Edit the club short names (or fixture id) then run.
-- =============================================================================

-- Option A: by fixture id
-- \set fid 12345

WITH params AS (
  SELECT NULL::bigint AS fixture_id  -- set e.g. 12345, or leave null to scan MD7
),
md7 AS (
  SELECT f.id, f.gpsl_month, f.home_club_short_name, f.away_club_short_name, f.status
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
  JOIN params p ON true
  WHERE f.status = 'scheduled'
    AND (
      (p.fixture_id IS NOT NULL AND f.id = p.fixture_id)
      OR (
        p.fixture_id IS NULL
        AND lower(btrim(f.gpsl_month)) = 'september'
        AND f.competition_type = 'league'
      )
    )
),
sch AS (
  SELECT m.*, s.status AS sch_status, s.agreed_kickoff_at
  FROM md7 m
  LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = m.id
)
SELECT
  x.id AS fixture_id,
  x.home_club_short_name AS home,
  x.away_club_short_name AS away,
  x.gpsl_month,
  x.sch_status,
  x.agreed_kickoff_at,
  public.match_schedule_fixture_is_holiday_early(x.id) AS is_holiday_early,
  CASE
    WHEN to_regprocedure('public.match_schedule_fixture_is_holiday_impacted(bigint)') IS NOT NULL
    THEN public.match_schedule_fixture_is_holiday_impacted(x.id)
    ELSE NULL
  END AS is_holiday_impacted,
  public.club_squad_minimum_shortfall(x.home_club_short_name) AS home_short_of_24,
  public.club_squad_minimum_shortfall(x.away_club_short_name) AS away_short_of_24,
  w.unlock_at AS prop_unlock,
  w.lock_at AS prop_lock,
  w.gpsl_month AS prop_month,
  w.is_holiday_early AS prop_holiday_early,
  public.match_schedule_current_uk_slot() AS current_uk_slot,
  CASE
    WHEN to_regprocedure('public.match_schedule_play_now_status(bigint)') IS NOT NULL
    THEN public.match_schedule_play_now_status(x.id)
    ELSE NULL
  END AS play_now_status
FROM sch x
LEFT JOIN LATERAL public.match_schedule_proposal_kickoff_window(x.id) w ON true
WHERE x.sch_status = 'agreed'
ORDER BY x.id;
