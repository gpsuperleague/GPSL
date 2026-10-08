-- =============================================================================
-- EMERGENCY (draft night overload): pause auto-bids + end stuck long queries
-- =============================================================================
-- Run straight after a database restart (or whenever the editor can connect).
-- Auto-bid plans keep their settings; unpause later with:
--   UPDATE public.global_settings SET draft_autobid_paused = false WHERE id = 1;
-- =============================================================================

UPDATE public.global_settings SET draft_autobid_paused = true WHERE id = 1;

SELECT
  count(*) FILTER (WHERE pg_terminate_backend(a.pid)) AS long_queries_ended,
  (SELECT draft_autobid_paused FROM public.global_settings WHERE id = 1) AS autobid_paused
FROM pg_stat_activity a
WHERE a.datname = current_database()
  AND a.pid <> pg_backend_pid()
  AND a.usename IN ('postgres', 'authenticator')
  AND a.state = 'active'
  AND now() - a.query_start > interval '30 seconds';
