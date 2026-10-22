-- =============================================================================
-- DIAGNOSTIC (read-only): why scheduled fixtures can't submit results
-- =============================================================================
-- Buckets for current season. Use to see if "too early / too late / no check-in /
-- not agreed / wrong month" is league-wide.
-- Safe re-run. No writes.
-- =============================================================================

WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
active_month AS (
  SELECT lower(btrim(m.gpsl_month)) AS month
  FROM public.competition_season_calendar m
  JOIN cur c ON c.season_id = m.season_id
  WHERE m.unlock_at <= now()
    AND m.lock_at > now()
  ORDER BY m.unlock_at DESC
  LIMIT 1
),
fx AS (
  SELECT
    f.id,
    f.matchday,
    f.gpsl_month,
    f.competition_type,
    f.division,
    f.home_club_short_name AS home,
    f.away_club_short_name AS away,
    f.status AS fixture_status,
    coalesce(s.status, 'unscheduled') AS schedule_status,
    s.agreed_kickoff_at AS ko,
    EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
    ) AS home_in,
    EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
    ) AS away_in,
    EXISTS (
      SELECT 1 FROM public.competition_result_submissions rs
      WHERE rs.fixture_id = f.id AND rs.status = 'pending'
    ) AS has_pending_result,
    (SELECT am.month FROM active_month am) AS active_month,
    30 AS block_mins
  FROM public.competition_fixtures f
  JOIN cur c ON c.season_id = f.season_id
  LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
  WHERE f.status = 'scheduled'
    AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
)
SELECT
  id AS fixture_id,
  competition_type,
  division,
  matchday,
  gpsl_month,
  home || ' vs ' || away AS matchup,
  schedule_status,
  ko,
  home_in,
  away_in,
  CASE
    WHEN has_pending_result THEN 'pending_result'
    WHEN schedule_status <> 'agreed' OR ko IS NULL THEN 'not_agreed'
    WHEN NOT home_in OR NOT away_in THEN 'missing_checkin'
    WHEN now() < ko THEN 'too_early_before_ko'
    WHEN now() >= ko + make_interval(mins => block_mins) THEN 'too_late_after_play_block'
    WHEN lower(btrim(coalesce(gpsl_month, ''))) IS DISTINCT FROM active_month
      THEN 'wrong_gpsl_month_vs_active'
    ELSE 'submit_should_work'
  END AS bucket,
  CASE
    WHEN ko IS NOT NULL AND now() < ko
      THEN ceil(extract(epoch FROM (ko - now())) / 60.0)::int
    ELSE NULL
  END AS minutes_until_ko,
  CASE
    WHEN ko IS NOT NULL AND now() >= ko
      THEN floor(extract(epoch FROM (now() - ko)) / 60.0)::int
    ELSE NULL
  END AS minutes_since_ko
FROM fx
ORDER BY
  CASE
    WHEN has_pending_result THEN 0
    WHEN schedule_status = 'agreed' AND home_in AND away_in AND now() < ko THEN 1
    WHEN schedule_status = 'agreed' AND home_in AND away_in
         AND now() >= ko + make_interval(mins => block_mins) THEN 2
    WHEN schedule_status = 'agreed' AND (NOT home_in OR NOT away_in) THEN 3
    WHEN schedule_status <> 'agreed' THEN 4
    ELSE 5
  END,
  ko NULLS LAST,
  id;

-- Summary counts
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
active_month AS (
  SELECT lower(btrim(m.gpsl_month)) AS month
  FROM public.competition_season_calendar m
  JOIN cur c ON c.season_id = m.season_id
  WHERE m.unlock_at <= now()
    AND m.lock_at > now()
  ORDER BY m.unlock_at DESC
  LIMIT 1
),
fx AS (
  SELECT
    f.id,
    f.gpsl_month,
    coalesce(s.status, 'unscheduled') AS schedule_status,
    s.agreed_kickoff_at AS ko,
    EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
    ) AS home_in,
    EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
    ) AS away_in,
    EXISTS (
      SELECT 1 FROM public.competition_result_submissions rs
      WHERE rs.fixture_id = f.id AND rs.status = 'pending'
    ) AS has_pending_result,
    (SELECT am.month FROM active_month am) AS active_month,
    30 AS block_mins
  FROM public.competition_fixtures f
  JOIN cur c ON c.season_id = f.season_id
  LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
  WHERE f.status = 'scheduled'
    AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
)
SELECT
  CASE
    WHEN has_pending_result THEN 'pending_result'
    WHEN schedule_status <> 'agreed' OR ko IS NULL THEN 'not_agreed'
    WHEN NOT home_in OR NOT away_in THEN 'missing_checkin'
    WHEN now() < ko THEN 'too_early_before_ko'
    WHEN now() >= ko + make_interval(mins => block_mins) THEN 'too_late_after_play_block'
    WHEN lower(btrim(coalesce(gpsl_month, ''))) IS DISTINCT FROM active_month
      THEN 'wrong_gpsl_month_vs_active'
    ELSE 'submit_should_work'
  END AS bucket,
  count(*) AS fixtures
FROM fx
GROUP BY 1
ORDER BY fixtures DESC;
