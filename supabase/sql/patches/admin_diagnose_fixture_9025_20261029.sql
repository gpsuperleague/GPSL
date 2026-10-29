-- =============================================================================
-- Fixture 9025 — SLB vs WOL MD7 holiday / schedule / play-now snapshot
-- =============================================================================

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
  to_char(timezone('Europe/London', s.agreed_kickoff_at), 'Dy DD Mon YYYY HH24:MI') AS agreed_ko_uk,
  s.agreed_kickoff_at,
  s.mutual_override_used,
  s.pending_proposal_id,
  s.play_attempt_count,
  to_char(timezone('Europe/London', public.match_schedule_current_uk_slot()), 'Dy DD Mon HH24:MI') AS current_uk_slot,
  to_char(timezone('Europe/London', now()), 'Dy DD Mon HH24:MI:SS') AS now_uk,
  CASE
    WHEN s.agreed_kickoff_at IS NULL THEN 'no agreed KO'
    WHEN now() >= s.agreed_kickoff_at THEN 'at/after agreed KO — check in / play (no Play now)'
    WHEN public.match_schedule_current_uk_slot() + interval '30 minutes' >= s.agreed_kickoff_at
      AND now() >= public.match_schedule_current_uk_slot() + interval '10 minutes'
      THEN 'only next slot is the agreed KO — use check-in from 18:50 UK, not Play now'
    ELSE 'Play now OK if they pick a future UK 30-min slot before agreed KO'
  END AS play_now_advice,
  CASE
    WHEN to_regprocedure('public.match_schedule_play_now_status(bigint)') IS NOT NULL
    THEN public.match_schedule_play_now_status(f.id)
    ELSE NULL
  END AS play_now_status,
  (SELECT jsonb_build_object(
      'unlock', w.unlock_at,
      'lock', w.lock_at,
      'month', w.gpsl_month,
      'catch_up', w.is_catch_up,
      'holiday_early', w.is_holiday_early
    )
   FROM public.match_schedule_proposal_kickoff_window(f.id) w
   LIMIT 1) AS proposal_window
FROM public.competition_fixtures f
LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
WHERE f.id = 9025;

-- Holidays
SELECT
  h.club_short_name,
  h.starts_at,
  h.ends_at,
  public.club_holiday_overlap_inclusive_days(
    h.starts_at, h.ends_at, cal.unlock_at, cal.lock_at
  ) AS sept_overlap_days,
  public.club_holiday_allows_fixture_early(9025, h.club_short_name) AS allows_early_now
FROM public.club_owner_holidays h
JOIN public.competition_fixtures f ON f.id = 9025 AND h.season_id = f.season_id
JOIN public.competition_season_calendar cal
  ON cal.season_id = f.season_id
 AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
WHERE upper(h.club_short_name) IN ('SLB', 'WOL')
ORDER BY h.club_short_name, h.starts_at;

-- Pending mutual
SELECT
  m.id,
  m.kind,
  m.status,
  m.requested_by_club,
  to_char(timezone('Europe/London', m.proposed_kickoff_at), 'Dy DD Mon HH24:MI') AS proposed_uk,
  m.home_confirmed_at,
  m.away_confirmed_at,
  m.expires_at
FROM public.competition_fixture_mutual_override m
WHERE m.fixture_id = 9025
ORDER BY m.created_at DESC
LIMIT 10;

-- Check-ins
SELECT club_short_name, checked_in_at
FROM public.competition_fixture_checkin
WHERE fixture_id = 9025;
