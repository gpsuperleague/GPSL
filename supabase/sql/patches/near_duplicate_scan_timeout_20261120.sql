ALTER FUNCTION public.gpdb_player_near_duplicates(text)
  SET statement_timeout = '8s';

SELECT coalesce(jsonb_agg(jsonb_build_object(
  'pid', a.pid,
  'cancelled', pg_cancel_backend(a.pid),
  'age_s', extract(epoch FROM (now() - a.xact_start))::int,
  'query', left(regexp_replace(a.query, '\s+', ' ', 'g'), 160)
)), '[]'::jsonb) AS cancelled
FROM pg_stat_activity a
WHERE a.datname = current_database()
  AND a.pid <> pg_backend_pid()
  AND a.state = 'active'
  AND a.xact_start < now() - interval '10 seconds'
  AND (
    a.query ILIKE '%transferengine_run_report%'
    OR a.query ILIKE '%gpdb_player_near_duplicates%'
    OR a.query ILIKE '%gpsl_transferengine_cron_tick%'
  );
