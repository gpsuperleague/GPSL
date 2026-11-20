-- Confirm was dying at the website role's 8s lock_timeout while the
-- transfer tick held row locks for about two minutes. Let confirm wait,
-- and stop that tick holding the tables for the full two minutes.
-- Safe re-run. Does not confirm any result.

DO $fix$
BEGIN
  PERFORM pg_cancel_backend(a.pid)
  FROM pg_stat_activity a
  WHERE a.query LIKE '%gpsl_transferengine_cron_tick%'
    AND a.pid <> pg_backend_pid()
    AND a.state <> 'idle';

  EXECUTE $a$ALTER FUNCTION public.competition_confirm_result(bigint, jsonb) SET lock_timeout = '90s'$a$;
  EXECUTE $b$ALTER FUNCTION public.gpsl_transferengine_cron_tick() SET statement_timeout = '20s'$b$;
END;
$fix$;

SELECT jsonb_build_object(
  'confirm_cfg', (
    SELECT proconfig
    FROM pg_proc
    WHERE oid = 'public.competition_confirm_result(bigint, jsonb)'::regprocedure
  ),
  'tick_cfg', (
    SELECT proconfig
    FROM pg_proc
    WHERE oid = 'public.gpsl_transferengine_cron_tick()'::regprocedure
  ),
  'tick_still_running', EXISTS (
    SELECT 1
    FROM pg_stat_activity a
    WHERE a.query LIKE '%gpsl_transferengine_cron_tick%'
      AND a.pid <> pg_backend_pid()
      AND a.state <> 'idle'
  )
);
