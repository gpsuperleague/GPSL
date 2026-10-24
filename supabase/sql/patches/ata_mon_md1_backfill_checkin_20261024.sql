-- =============================================================================
-- One-shot: ATA vs MON SuperLeague MD1 — backfill Monaco check-in (2026-10-24)
-- =============================================================================
-- ATA checked in; MON missed KO±10 (still August-checklist locked at KO).
-- They played / need to enter the result. Submit requires both check-ins.
-- Inserts MON (and ATA no-op if already present). Clears no-show flag.
-- Fixture id 8960 (ATA home, MON away, superleague MD1).
-- Safe re-run (ON CONFLICT DO NOTHING).
-- =============================================================================

DO $fix$
DECLARE
  v_fixture_id bigint := 8960;
  v_home text;
  v_away text;
  v_status text;
  v_home_in boolean;
  v_away_in boolean;
BEGIN
  SELECT f.home_club_short_name, f.away_club_short_name, f.status
    INTO v_home, v_away, v_status
  FROM public.competition_fixtures f
  JOIN public.competition_seasons se ON se.id = f.season_id AND se.is_current
  WHERE f.id = v_fixture_id;

  IF v_home IS NULL THEN
    RAISE EXCEPTION 'Fixture % not found in current season', v_fixture_id;
  END IF;

  IF upper(v_home) <> 'ATA' OR upper(v_away) <> 'MON' THEN
    RAISE EXCEPTION 'Fixture % is % vs % — expected ATA vs MON',
      v_fixture_id, v_home, v_away;
  END IF;

  IF v_status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture % status is % — not scheduled', v_fixture_id, v_status;
  END IF;

  INSERT INTO public.competition_fixture_checkin (fixture_id, club_short_name)
  VALUES
    (v_fixture_id, v_home),
    (v_fixture_id, v_away)
  ON CONFLICT (fixture_id, club_short_name) DO NOTHING;

  IF to_regprocedure('public.match_schedule_clear_no_show(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_clear_no_show(v_fixture_id);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = v_fixture_id AND c.club_short_name = v_home
  ), EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = v_fixture_id AND c.club_short_name = v_away
  )
  INTO v_home_in, v_away_in;

  RAISE NOTICE 'Fixture %: home_in=% away_in=% — either club can submit on Match Day',
    v_fixture_id, v_home_in, v_away_in;
END;
$fix$;

SELECT
  f.id,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  s.agreed_kickoff_at,
  s.no_show_club_short_name,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
  ) AS home_checked_in,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
  ) AS away_checked_in,
  c.club_short_name,
  c.checked_in_at
FROM public.competition_fixtures f
LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
LEFT JOIN public.competition_fixture_checkin c ON c.fixture_id = f.id
WHERE f.id = 8960
ORDER BY c.club_short_name;
