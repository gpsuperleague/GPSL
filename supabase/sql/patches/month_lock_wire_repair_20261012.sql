-- Repair: two older patches (club_unplayed_month_snapshots_20260911,
-- match_scheduling_rules_20260911_part2) tried to add steps to
-- competition_run_month_lock_jobs with EXECUTE 'CREATE OR REPLACE ' || ...,
-- which is invalid because pg_get_functiondef already starts with
-- CREATE OR REPLACE. The error was swallowed, so the steps were never added.
-- This re-applies just those two wires. Safe to re-run.

-- 1) Unplayed-match snapshots at month lock
DO $wire$
DECLARE
  v_def text;
  v_marker text := 'club_unplayed_on_gpsl_month_lock';
  v_old text := E'  RETURN v_out;\nEND;';
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') IS NULL THEN
    RAISE NOTICE 'competition_run_month_lock_jobs(4-arg) missing — unplayed snapshot wire skipped';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) INTO v_def;

  IF v_def IS NULL THEN
    RETURN;
  END IF;

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Unplayed snapshots already wired into month-lock jobs';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'Could not locate RETURN v_out in month-lock jobs — unplayed snapshot wire skipped';
    RETURN;
  END IF;

  v_new :=
    E'  -- Freeze unplayed counts for owner-board missed totals (before catch-up sims)\n'
    || E'  BEGIN\n'
    || E'    IF to_regprocedure(''public.club_unplayed_on_gpsl_month_lock(bigint,text)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''unplayed_snapshots'',\n'
    || E'        public.club_unplayed_on_gpsl_month_lock(p_season_id, v_month)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION\n'
    || E'    WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''unplayed_snapshots'',\n'
    || E'        jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'  END;\n'
    || E'\n'
    || E'  RETURN v_out;\n'
    || E'END;';

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'Wired unplayed snapshots into competition_run_month_lock_jobs';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Unplayed snapshot month-lock wire failed (%)', SQLERRM;
END;
$wire$;

-- 2) Scheduling window awards + deadline warnings at month lock
DO $wire$
DECLARE
  v_def text;
  v_marker text := 'competition_process_scheduling_window_awards';
  v_old text := E'  RETURN v_out;\nEND;';
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') IS NULL THEN
    RAISE NOTICE 'month-lock jobs missing — window awards wire skipped';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) INTO v_def;

  IF v_def IS NULL OR position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Window awards already wired (or month-lock missing)';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'Could not locate RETURN v_out — window awards wire skipped';
    RETURN;
  END IF;

  v_new :=
    E'  BEGIN\n'
    || E'    IF to_regprocedure(''public.competition_process_scheduling_window_awards(bigint)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''scheduling_window_awards'',\n'
    || E'        public.competition_process_scheduling_window_awards(p_season_id)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION WHEN OTHERS THEN\n'
    || E'    v_out := v_out || jsonb_build_object(\n'
    || E'      ''scheduling_window_awards'', jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'    );\n'
    || E'  END;\n\n'
    || E'  BEGIN\n'
    || E'    IF to_regprocedure(''public.competition_notify_scheduling_deadline_warnings(bigint)'') IS NOT NULL THEN\n'
    || E'      PERFORM public.competition_notify_scheduling_deadline_warnings(p_season_id);\n'
    || E'    END IF;\n'
    || E'  EXCEPTION WHEN OTHERS THEN NULL;\n'
    || E'  END;\n\n'
    || E'  RETURN v_out;\nEND;';

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'Wired window awards + deadline warnings into month-lock jobs';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Window awards wire failed: %', SQLERRM;
END;
$wire$;

NOTIFY pgrst, 'reload schema';

-- Report: which month-end steps are now wired in, and whether their functions exist
WITH def AS (
  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) AS d
)
SELECT
  step,
  position(marker IN (SELECT d FROM def)) > 0 AS wired_into_month_lock,
  EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = marker
  ) AS function_exists
FROM (VALUES
  ('Unplayed-match snapshots (20260911)', 'club_unplayed_on_gpsl_month_lock'),
  ('Scheduling window awards (20260911)', 'competition_process_scheduling_window_awards'),
  ('Scheduling deadline warnings (20260911)', 'competition_notify_scheduling_deadline_warnings'),
  ('Month-end balance snapshot (loan credit, 20261012)', 'club_balance_snapshot_gpsl_month'),
  ('Monthly interest (20261012)', 'competition_post_monthly_interest')
) AS t(step, marker);
