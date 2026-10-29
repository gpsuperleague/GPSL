-- =============================================================================
-- Tonight: Championship A MD4 BEN vs ARS (9376) — check-in / no-show snapshot
-- Also force-evaluate check-in window if past KO+10m and not yet recorded.
-- =============================================================================

-- Identity + schedule + check-ins
SELECT
  f.id AS fixture_id,
  f.matchday,
  f.gpsl_month,
  f.division,
  f.status,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  s.status AS sch_status,
  s.play_attempt_count,
  s.no_show_club_short_name,
  to_char(timezone('Europe/London', s.agreed_kickoff_at), 'Dy DD Mon YYYY HH24:MI') AS agreed_ko_uk,
  s.agreed_kickoff_at,
  to_char(timezone('Europe/London', now()), 'Dy DD Mon YYYY HH24:MI:SS') AS now_uk,
  public.match_schedule_checkin_minutes() AS checkin_mins,
  CASE
    WHEN s.agreed_kickoff_at IS NULL THEN 'no agreed KO'
    WHEN now() < s.agreed_kickoff_at - make_interval(mins => public.match_schedule_checkin_minutes())
      THEN 'before check-in opens'
    WHEN now() <= s.agreed_kickoff_at + make_interval(mins => public.match_schedule_checkin_minutes())
      THEN 'check-in window OPEN'
    ELSE 'check-in window CLOSED — no-show eligible'
  END AS window_state,
  (SELECT string_agg(ci.club_short_name || ' @ ' ||
      to_char(timezone('Europe/London', ci.checked_in_at), 'HH24:MI'), ', ')
   FROM public.competition_fixture_checkin ci WHERE ci.fixture_id = f.id) AS checkins,
  EXISTS (SELECT 1 FROM public.competition_fixture_checkin ci
          WHERE ci.fixture_id = f.id
            AND upper(ci.club_short_name) = upper(f.home_club_short_name)) AS home_in,
  EXISTS (SELECT 1 FROM public.competition_fixture_checkin ci
          WHERE ci.fixture_id = f.id
            AND upper(ci.club_short_name) = upper(f.away_club_short_name)) AS away_in
FROM public.competition_fixtures f
LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
WHERE f.id = 9376;

-- Existing no-show events on this fixture
SELECT *
FROM public.competition_fixture_no_show_events e
WHERE e.fixture_id = 9376
ORDER BY e.created_at;

-- Existing no-show fines on this fixture
SELECT
  fa.id, fa.tariff_code, fa.amount, fa.waived, fa.club_short_name,
  fa.description, fa.note,
  to_char(timezone('Europe/London', fa.applied_at), 'Dy DD Mon YYYY HH24:MI') AS applied_uk
FROM public.competition_fine_applied fa
WHERE fa.fixture_id = 9376
  AND fa.tariff_code ILIKE '%no_show%'
ORDER BY fa.applied_at;

-- Try to record no-show now (no-op if window still open / both checked in)
SELECT public.fixture_try_checkin_forfeit(9376) AS resolve_recorded;

-- Re-read after resolve
SELECT
  s.status,
  s.play_attempt_count,
  s.no_show_club_short_name,
  to_char(timezone('Europe/London', s.agreed_kickoff_at), 'Dy DD Mon YYYY HH24:MI') AS agreed_ko_uk,
  (SELECT string_agg(ci.club_short_name, ', ') FROM public.competition_fixture_checkin ci
   WHERE ci.fixture_id = 9376) AS checkins_now
FROM public.competition_fixture_schedule s
WHERE s.fixture_id = 9376;

SELECT
  e.club_short_name, e.both_miss, e.play_attempt_no,
  to_char(timezone('Europe/London', e.kickoff_at), 'Dy DD Mon YYYY HH24:MI') AS missed_ko_uk,
  e.created_at
FROM public.competition_fixture_no_show_events e
WHERE e.fixture_id = 9376
ORDER BY e.created_at;

-- Kneiver totals after tonight (past only)
SELECT
  count(*) FILTER (WHERE NOT coalesce(e.both_miss, false)) AS ars_one_sided_noshows_past,
  count(*) FILTER (WHERE coalesce(e.both_miss, false)) AS ars_both_miss_past,
  count(*) AS ars_noshow_events_past_total
FROM public.competition_fixture_no_show_events e
WHERE upper(e.club_short_name) = 'ARS'
  AND e.kickoff_at <= now();
