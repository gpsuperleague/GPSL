-- =============================================================================
-- One-shot: apocalips3 (TIG) — backfill check-in MD1 + unlock MD2 (2026-10-25)
-- =============================================================================
-- MD1 9340 TIG vs LIL: LIL checked in; TIG marked no-show. They played.
--   → insert TIG check-in, clear no-show flag.
-- MD2 9351 LEV vs TIG: both-miss cleared KO (unscheduled, attempt 2). They played.
--   → re-lock a recent KO, check in both clubs, clear no-show so result can be entered.
-- Safe re-run (ON CONFLICT DO NOTHING / idempotent clears).
-- =============================================================================

DO $fix$
DECLARE
  v_md1 bigint := 9340;
  v_md2 bigint := 9351;
  v_home text;
  v_away text;
  v_status text;
  v_home_in boolean;
  v_away_in boolean;
  v_ko timestamptz;
BEGIN
  -- -------------------------------------------------------------------------
  -- MD1: TIG (home) vs LIL — backfill TIG only
  -- -------------------------------------------------------------------------
  SELECT f.home_club_short_name, f.away_club_short_name, f.status
    INTO v_home, v_away, v_status
  FROM public.competition_fixtures f
  JOIN public.competition_seasons se ON se.id = f.season_id AND se.is_current
  WHERE f.id = v_md1;

  IF v_home IS NULL THEN
    RAISE EXCEPTION 'MD1 fixture % not found in current season', v_md1;
  END IF;
  IF upper(v_home) <> 'TIG' OR upper(v_away) <> 'LIL' THEN
    RAISE EXCEPTION 'MD1 fixture % is % vs % — expected TIG vs LIL', v_md1, v_home, v_away;
  END IF;
  IF v_status <> 'scheduled' THEN
    RAISE EXCEPTION 'MD1 fixture % status is % — not scheduled', v_md1, v_status;
  END IF;

  INSERT INTO public.competition_fixture_checkin (fixture_id, club_short_name)
  VALUES (v_md1, 'TIG')
  ON CONFLICT (fixture_id, club_short_name) DO NOTHING;

  IF to_regprocedure('public.match_schedule_clear_no_show(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_clear_no_show(v_md1);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = v_md1 AND c.club_short_name = 'TIG'
  ), EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = v_md1 AND c.club_short_name = 'LIL'
  )
  INTO v_home_in, v_away_in;

  RAISE NOTICE 'MD1 %: TIG_in=% LIL_in=%', v_md1, v_home_in, v_away_in;

  -- -------------------------------------------------------------------------
  -- MD2: LEV (home) vs TIG — restore KO + both check-ins
  -- -------------------------------------------------------------------------
  SELECT f.home_club_short_name, f.away_club_short_name, f.status
    INTO v_home, v_away, v_status
  FROM public.competition_fixtures f
  JOIN public.competition_seasons se ON se.id = f.season_id AND se.is_current
  WHERE f.id = v_md2;

  IF v_home IS NULL THEN
    RAISE EXCEPTION 'MD2 fixture % not found in current season', v_md2;
  END IF;
  IF upper(v_home) <> 'LEV' OR upper(v_away) <> 'TIG' THEN
    RAISE EXCEPTION 'MD2 fixture % is % vs % — expected LEV vs TIG', v_md2, v_home, v_away;
  END IF;
  IF v_status <> 'scheduled' THEN
    RAISE EXCEPTION 'MD2 fixture % status is % — not scheduled', v_md2, v_status;
  END IF;

  -- Prefer an existing agreed KO; otherwise use a recent past slot so submit
  -- is not blocked by a future check-in window / forfeit tick.
  SELECT s.agreed_kickoff_at INTO v_ko
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = v_md2;

  IF v_ko IS NULL THEN
    IF to_regprocedure('public.match_schedule_current_uk_slot()') IS NOT NULL THEN
      v_ko := public.match_schedule_current_uk_slot() - interval '30 minutes';
    ELSE
      v_ko := date_trunc('hour', now()) - interval '30 minutes';
    END IF;
  END IF;

  UPDATE public.competition_fixture_schedule
  SET status = 'agreed',
      agreed_kickoff_at = v_ko,
      no_show_club_short_name = NULL,
      no_show_kickoff_at = NULL,
      updated_at = now()
  WHERE fixture_id = v_md2;

  IF NOT FOUND THEN
    INSERT INTO public.competition_fixture_schedule (
      fixture_id, status, agreed_kickoff_at, play_attempt_count, updated_at
    ) VALUES (
      v_md2, 'agreed', v_ko, 2, now()
    );
  END IF;

  INSERT INTO public.competition_fixture_checkin (fixture_id, club_short_name)
  VALUES
    (v_md2, 'LEV'),
    (v_md2, 'TIG')
  ON CONFLICT (fixture_id, club_short_name) DO NOTHING;

  IF to_regprocedure('public.match_schedule_clear_no_show(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_clear_no_show(v_md2);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = v_md2 AND c.club_short_name = 'LEV'
  ), EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = v_md2 AND c.club_short_name = 'TIG'
  )
  INTO v_home_in, v_away_in;

  RAISE NOTICE 'MD2 %: LEV_in=% TIG_in=% ko=%', v_md2, v_home_in, v_away_in, v_ko;
END;
$fix$;

SELECT
  f.id,
  f.matchday,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  s.status AS sch,
  s.agreed_kickoff_at,
  s.no_show_club_short_name,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
  ) AS home_in,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
  ) AS away_in
FROM public.competition_fixtures f
LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
WHERE f.id IN (9340, 9351)
ORDER BY f.matchday;
