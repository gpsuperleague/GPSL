-- Diagnose AC Milan (ACM) new-owner catch-up vs August fixtures / Oct holiday
-- Read-only. Safe re-run.

SELECT
  c."ShortName",
  c."Club",
  c.owner,
  c.owner_id,
  c.owner_assigned_at,
  c.owner_assigned_season_id,
  public.competition_gpsl_month_sort(
    (
      SELECT cal.gpsl_month
      FROM public.competition_season_calendar cal
      WHERE cal.season_id = s.id
        AND cal.unlock_at IS NOT NULL
        AND cal.unlock_at <= c.owner_assigned_at
      ORDER BY cal.unlock_at DESC
      LIMIT 1
    )
  ) AS join_month_sort,
  public.club_new_owner_catchup_through_sort(s.id, c."ShortName") AS catchup_through_sort,
  (
    SELECT cal.gpsl_month
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = s.id
      AND public.competition_gpsl_month_sort(cal.gpsl_month)
        = public.club_new_owner_catchup_through_sort(s.id, c."ShortName")
    LIMIT 1
  ) AS catchup_through_month,
  public.club_scheduling_fines_in_new_owner_grace(s.id, c."ShortName", 'august')
    AS august_lock_fine_grace
FROM public."Clubs" c
CROSS JOIN LATERAL (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
) s
WHERE upper(c."ShortName") = 'ACM'
   OR upper(coalesce(c.owner, '')) LIKE '%MAKXX%';

SELECT
  h.id,
  h.club_short_name,
  h.starts_at,
  h.ends_at,
  h.day_count,
  CASE
    WHEN now() >= h.starts_at AND now() < h.ends_at THEN 'active'
    WHEN now() < h.starts_at THEN 'upcoming'
    ELSE 'ended'
  END AS status
FROM public.club_owner_holidays h
JOIN public.competition_seasons s ON s.id = h.season_id AND s.is_current
WHERE upper(h.club_short_name) = 'ACM'
ORDER BY h.starts_at;

SELECT
  f.id,
  f.matchday,
  f.gpsl_month,
  f.status,
  f.home_club_short_name,
  f.away_club_short_name,
  sch.status AS schedule_status,
  sch.agreed_kickoff_at,
  public.match_schedule_fixture_within_play_window(f.id) AS in_play_window,
  public.match_schedule_fixture_is_catch_up(f.id) AS is_catch_up,
  public.match_schedule_fixture_play_window_expired(f.id, 'august') AS expired_if_august_lock,
  public.match_schedule_fixture_play_window_expired(f.id, 'september') AS expired_if_september_lock,
  public.match_schedule_fixture_play_window_expired(f.id, 'october') AS expired_if_october_lock,
  public.match_schedule_fixture_new_owner_catchup_through_sort(f.id) AS owner_catchup_through,
  CASE
    WHEN to_regprocedure('public.club_holiday_allows_fixture_early(bigint, text)') IS NOT NULL
    THEN public.club_holiday_allows_fixture_early(f.id, 'ACM')
    ELSE NULL
  END AS holiday_early_acm
FROM public.competition_fixtures f
LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
WHERE f.competition_type = 'league'
  AND lower(f.gpsl_month) = 'august'
  AND (
    upper(f.home_club_short_name) = 'ACM'
    OR upper(f.away_club_short_name) = 'ACM'
  )
ORDER BY f.matchday, f.id;
