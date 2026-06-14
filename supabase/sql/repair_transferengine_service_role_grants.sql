-- =============================================================================
-- Transfer engine cron — allow Edge Function (service_role) to run RPCs
-- Run once in Supabase SQL Editor if GitHub Actions gets HTTP 500 from Edge Function.
-- =============================================================================

GRANT EXECUTE ON FUNCTION public.transferengine_run() TO service_role;
GRANT EXECUTE ON FUNCTION public.transferengine_run_report() TO service_role;

NOTIFY pgrst, 'reload schema';
