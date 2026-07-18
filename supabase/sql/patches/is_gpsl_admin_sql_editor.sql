-- =============================================================================
-- is_gpsl_admin: allow Supabase SQL Editor (postgres / supabase_admin)
--
-- Some later patches redefined this to email-only, which blocks SQL Editor
-- calls like: SELECT public.contract_tick_season_rollover();
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.is_gpsl_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    lower(coalesce(auth.jwt() ->> 'email', '')) = 'rotavator66@outlook.com'
    OR current_user IN ('postgres', 'supabase_admin')
    OR session_user IN ('postgres', 'supabase_admin')
    OR coalesce(auth.jwt() ->> 'role', '') = 'service_role';
$$;
