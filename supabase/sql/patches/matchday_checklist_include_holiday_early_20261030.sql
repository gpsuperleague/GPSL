-- =============================================================================
-- Matchday checklist: include holiday-early (play-early) fixtures
-- (2026-10-30)
--
-- Bug: dashboard_matchday_checklist / matchday_checklist_for_club only listed
-- fixtures in the *active* GPSL month (+ pending result / video grace).
-- Holiday-corridor November fixtures are arrange/playable before November
-- unlocks, so they never appeared on the Dashboard Matchday checklist.
--
-- Fix: also include scheduled fixtures where
--   match_schedule_fixture_is_holiday_early(id) is true.
--
-- Safe re-run (idempotent needle inject).
-- =============================================================================

DO $inject$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.matchday_checklist_for_club(text,boolean)') IS NULL THEN
    RAISE EXCEPTION 'matchday_checklist_for_club missing';
  END IF;

  v_old := replace($n$
      AND (
        (v_month IS NOT NULL AND lower(btrim(f.gpsl_month)) = lower(v_month))
        OR EXISTS (
          SELECT 1 FROM public.competition_result_submissions s
          WHERE s.fixture_id = f.id AND s.status = 'pending'
        )
$n$, E'\r\n', E'\n');

  v_new := replace($n$
      AND (
        (v_month IS NOT NULL AND lower(btrim(f.gpsl_month)) = lower(v_month))
        -- Holiday corridor: arrange/play early before the fixture's GPSL month
        OR (
          f.status = 'scheduled'
          AND to_regprocedure('public.match_schedule_fixture_is_holiday_early(bigint)') IS NOT NULL
          AND public.match_schedule_fixture_is_holiday_early(f.id)
        )
        OR EXISTS (
          SELECT 1 FROM public.competition_result_submissions s
          WHERE s.fixture_id = f.id AND s.status = 'pending'
        )
$n$, E'\r\n', E'\n');

  SELECT replace(
           pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure),
           E'\r\n',
           E'\n'
         )
    INTO v_def;

  IF position('match_schedule_fixture_is_holiday_early(f.id)' IN v_def) > 0 THEN
    RAISE NOTICE 'matchday_checklist_for_club already includes holiday-early fixtures';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION
      'Could not find checklist month-filter needle — holiday-early inject aborted';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'matchday_checklist_for_club: holiday-early fixtures included';
END;
$inject$;

-- Flag holiday-early rows so the dashboard card is obvious
DO $flag$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.matchday_checklist_for_club(text,boolean)') IS NULL THEN
    RETURN;
  END IF;

  SELECT replace(
           pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure),
           E'\r\n',
           E'\n'
         )
    INTO v_def;

  IF position('Holiday early — arrange/play before' IN v_def) > 0 THEN
    RAISE NOTICE 'holiday_early flag already present';
    RETURN;
  END IF;

  v_old := E'    SELECT h.ends_at INTO v_hol\n'
        || E'    FROM public.club_owner_holidays h\n'
        || E'    WHERE h.season_id = v_season_id\n'
        || E'      AND upper(btrim(h.club_short_name)) = v_opp\n';

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'opp-holiday needle missing — skip holiday_early flag (filter still applied)';
    RETURN;
  END IF;

  v_new := replace($n$    IF to_regprocedure('public.match_schedule_fixture_is_holiday_early(bigint)') IS NOT NULL
       AND public.match_schedule_fixture_is_holiday_early(r.id) THEN
      v_flags := v_flags || jsonb_build_array(jsonb_build_object(
        'key', 'holiday_early',
        'level', 'info',
        'text', 'Holiday early — arrange/play before ' || initcap(coalesce(r.gpsl_month, 'that month'))
      ));
    END IF;

    SELECT h.ends_at INTO v_hol
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_season_id
      AND upper(btrim(h.club_short_name)) = v_opp
$n$, E'\r\n', E'\n');

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'holiday_early checklist flag applied';
END;
$flag$;

NOTIFY pgrst, 'reload schema';

-- Smoke: function still present + holiday-early filter wired
SELECT
  to_regprocedure('public.matchday_checklist_for_club(text,boolean)') IS NOT NULL AS checklist_fn,
  position(
    'match_schedule_fixture_is_holiday_early(f.id)'
    IN pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure)
  ) > 0 AS includes_holiday_early;
