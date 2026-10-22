-- =============================================================================
-- Open result-submit window for AND vs ATM MD1 only (2026-10-23)
-- =============================================================================
-- Does NOT clear check-ins or unschedule.
-- Nudges agreed kick-off to 2 minutes ago so:
--   • client "submit opens at kick-off" is satisfied
--   • DB 30-minute play block (KO → KO+30) is open
-- Safe re-run. This fixture only.
-- =============================================================================

DO $fix$
DECLARE
  v_fixture_id bigint;
  v_home text;
  v_away text;
  v_ko timestamptz;
  v_status text;
  v_home_in boolean;
  v_away_in boolean;
BEGIN
  SELECT f.id, f.home_club_short_name, f.away_club_short_name,
         s.status, s.agreed_kickoff_at
  INTO v_fixture_id, v_home, v_away, v_status, v_ko
  FROM public.competition_fixtures f
  JOIN public.competition_seasons se ON se.id = f.season_id AND se.is_current
  LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
  WHERE f.competition_type = 'league'
    AND f.matchday = 1
    AND f.status = 'scheduled'
    AND (
      (upper(f.home_club_short_name) = 'AND' AND upper(f.away_club_short_name) = 'ATM')
      OR (upper(f.home_club_short_name) = 'ATM' AND upper(f.away_club_short_name) = 'AND')
    )
  ORDER BY f.id
  LIMIT 1;

  IF v_fixture_id IS NULL THEN
    RAISE EXCEPTION 'AND vs ATM league MD1 not found';
  END IF;

  IF v_status IS DISTINCT FROM 'agreed' OR v_ko IS NULL THEN
    RAISE EXCEPTION 'Fixture % is not agreed (status=%, ko=%) — arrange/play-now first',
      v_fixture_id, v_status, v_ko;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = v_fixture_id AND c.club_short_name = v_home
  ), EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = v_fixture_id AND c.club_short_name = v_away
  )
  INTO v_home_in, v_away_in;

  RAISE NOTICE 'Before: id=% % vs % ko=% home_in=% away_in=%',
    v_fixture_id, v_home, v_away, v_ko, v_home_in, v_away_in;

  UPDATE public.competition_fixture_schedule
  SET
    agreed_kickoff_at = now() - interval '2 minutes',
    updated_at = now()
  WHERE fixture_id = v_fixture_id;

  RAISE NOTICE 'Kick-off set to now()-2m on fixture % — submit within the next ~28 minutes.',
    v_fixture_id;
END;
$fix$;

SELECT
  f.id AS fixture_id,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  f.gpsl_month,
  s.status,
  s.agreed_kickoff_at,
  s.agreed_kickoff_at + interval '30 minutes' AS play_block_ends_at,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
  ) AS home_checked_in,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
  ) AS away_checked_in
FROM public.competition_fixtures f
JOIN public.competition_seasons se ON se.id = f.season_id AND se.is_current
LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
WHERE f.competition_type = 'league'
  AND f.matchday = 1
  AND (
    (upper(f.home_club_short_name) = 'AND' AND upper(f.away_club_short_name) = 'ATM')
    OR (upper(f.home_club_short_name) = 'ATM' AND upper(f.away_club_short_name) = 'AND')
  );
