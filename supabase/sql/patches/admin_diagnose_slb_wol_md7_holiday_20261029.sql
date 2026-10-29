-- =============================================================================
-- Diagnose: Super League MD7 Bratislava (SLB) vs Wolves (WOL) — holiday early /
-- schedule / play-now state. Safe read-only.
-- =============================================================================

-- 1) Fixture + holiday/schedule/play-now flags
WITH fx AS (
  SELECT f.*
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
  WHERE f.competition_type = 'league'
    AND (
      (upper(f.home_club_short_name) = 'SLB' AND upper(f.away_club_short_name) = 'WOL')
      OR (upper(f.home_club_short_name) = 'WOL' AND upper(f.away_club_short_name) = 'SLB')
    )
  ORDER BY
    CASE WHEN lower(btrim(f.gpsl_month)) = 'september' THEN 0 ELSE 1 END,
    f.matchday NULLS LAST,
    f.id
  LIMIT 5
)
SELECT
  f.id AS fixture_id,
  f.matchday,
  f.gpsl_month,
  f.division,
  f.status,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  public.competition_active_gpsl_month(f.season_id, now()) AS active_gpsl_month,
  public.match_schedule_fixture_is_holiday_early(f.id) AS is_holiday_early,
  CASE
    WHEN to_regprocedure('public.match_schedule_fixture_is_holiday_impacted(bigint)') IS NOT NULL
    THEN public.match_schedule_fixture_is_holiday_impacted(f.id)
    ELSE NULL
  END AS is_holiday_impacted,
  public.match_schedule_fixture_is_catch_up(f.id) AS is_catch_up,
  public.match_schedule_fixture_play_month_closed(f.id) AS play_month_closed,
  public.match_schedule_fixture_within_play_window(f.id, now()) AS within_play_window,
  public.club_squad_minimum_shortfall(f.home_club_short_name) AS home_short_of_24,
  public.club_squad_minimum_shortfall(f.away_club_short_name) AS away_short_of_24,
  public.match_schedule_club_timezone(f.home_club_short_name) AS home_tz,
  public.match_schedule_club_timezone(f.away_club_short_name) AS away_tz,
  s.status AS sch_status,
  s.agreed_kickoff_at,
  to_char(timezone('Europe/London', s.agreed_kickoff_at), 'Dy DD Mon HH24:MI') AS agreed_ko_uk,
  s.mutual_override_used,
  s.pending_proposal_id,
  s.play_attempt_count,
  w.unlock_at AS prop_unlock,
  w.lock_at AS prop_lock,
  w.gpsl_month AS prop_month,
  w.is_catch_up AS prop_catch_up,
  w.is_holiday_early AS prop_holiday_early,
  to_char(timezone('Europe/London', public.match_schedule_current_uk_slot()), 'Dy DD Mon HH24:MI') AS current_uk_slot,
  now() AS db_now,
  CASE
    WHEN to_regprocedure('public.match_schedule_play_now_status(bigint)') IS NOT NULL
    THEN public.match_schedule_play_now_status(f.id)
    ELSE NULL
  END AS play_now_status
FROM fx f
LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
LEFT JOIN LATERAL public.match_schedule_proposal_kickoff_window(f.id) w ON true;

-- 2) Holidays (September overlap)
SELECT
  h.id,
  h.club_short_name,
  h.starts_at,
  h.ends_at,
  h.created_at,
  public.club_holiday_overlap_inclusive_days(
    h.starts_at, h.ends_at, cal.unlock_at, cal.lock_at
  ) AS overlap_days_on_september
FROM public.club_owner_holidays h
JOIN public.competition_seasons s ON s.id = h.season_id AND s.is_current
JOIN public.competition_season_calendar cal
  ON cal.season_id = h.season_id
 AND lower(btrim(cal.gpsl_month)) = 'september'
WHERE upper(h.club_short_name) IN ('SLB', 'WOL')
ORDER BY h.club_short_name, h.starts_at;

-- 3) Recent mutual overrides for SLB–WOL September
SELECT
  m.id,
  m.fixture_id,
  m.kind AS mo_kind,
  m.status,
  m.requested_by_club,
  to_char(timezone('Europe/London', m.proposed_kickoff_at), 'Dy DD Mon HH24:MI') AS proposed_uk,
  m.home_confirmed_at IS NOT NULL AS home_confirmed,
  m.away_confirmed_at IS NOT NULL AS away_confirmed,
  m.expires_at,
  m.created_at
FROM public.competition_fixture_mutual_override m
JOIN public.competition_fixtures f ON f.id = m.fixture_id
JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
WHERE f.competition_type = 'league'
  AND lower(btrim(f.gpsl_month)) = 'september'
  AND (
    (upper(f.home_club_short_name) = 'SLB' AND upper(f.away_club_short_name) = 'WOL')
    OR (upper(f.home_club_short_name) = 'WOL' AND upper(f.away_club_short_name) = 'SLB')
  )
ORDER BY m.created_at DESC
LIMIT 20;

-- 4) Recent proposals
SELECT
  p.id,
  p.fixture_id,
  p.status,
  p.proposed_by_club_short_name,
  to_char(timezone('Europe/London', p.kickoff_at), 'Dy DD Mon HH24:MI') AS ko_uk,
  p.created_at
FROM public.competition_fixture_schedule_proposal p
JOIN public.competition_fixtures f ON f.id = p.fixture_id
JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
WHERE f.competition_type = 'league'
  AND lower(btrim(f.gpsl_month)) = 'september'
  AND (
    (upper(f.home_club_short_name) = 'SLB' AND upper(f.away_club_short_name) = 'WOL')
    OR (upper(f.home_club_short_name) = 'WOL' AND upper(f.away_club_short_name) = 'SLB')
  )
ORDER BY p.created_at DESC
LIMIT 20;
