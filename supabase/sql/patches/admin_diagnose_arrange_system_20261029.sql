SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname ILIKE '%play_now%'
ORDER BY 1, 2;

SELECT
  (position('competition_process_scheduling_window_awards' IN d) > 0) AS window_awards_wired,
  (position('competition_notify_scheduling_deadline_warnings' IN d) > 0) AS deadline_warn_wired,
  (position('competition_enforce_scheduling_arrangement_fines' IN d) > 0) AS arrange_fines_wired,
  (position('competition_process_scheduling_response_deadlines' IN d) > 0) AS response_deadlines_wired,
  (position('competition_run_month_lock_side_effects' IN d) > 0) AS side_effects_wired
FROM (
  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) AS d
) x;
