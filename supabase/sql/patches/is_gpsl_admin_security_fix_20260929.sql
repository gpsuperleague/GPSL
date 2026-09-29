-- =============================================================================
-- SECURITY FIX: is_gpsl_admin() returned true for every caller.
--
-- The function is SECURITY DEFINER (owned by postgres), so inside it
-- current_user is always the owner → the "current_user IN ('postgres', …)"
-- test passed for every logged-in user.
--
-- session_user is NOT changed by SECURITY DEFINER:
--   • website / PostgREST calls  → 'authenticator'  (not admin unless email matches)
--   • SQL Editor / pg_cron       → 'postgres'       (still admin)
--   • edge functions (service key) → JWT role 'service_role' (still admin)
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
    OR session_user IN ('postgres', 'supabase_admin')
    OR coalesce(auth.jwt() ->> 'role', '') = 'service_role';
$$;

GRANT EXECUTE ON FUNCTION public.is_gpsl_admin() TO authenticated, service_role;

-- Same hole in other admin gates ("OR current_user IN ('postgres', …)").
-- Rewrite every public function using that test to session_user.
DO $$
DECLARE
  r record;
  v_def text;
  v_new text;
  v_fixed text[] := ARRAY[]::text[];
BEGIN
  FOR r IN
    SELECT p.oid, p.oid::regprocedure::text AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.prosrc ~* 'current_user\s+in\s*\('
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_def, 'current_user(\s+)IN(\s*)\(', 'session_user\1IN\2(', 'gi');
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
      v_fixed := v_fixed || r.sig;
    END IF;
  END LOOP;
  RAISE NOTICE 'Fixed % function(s): %', coalesce(array_length(v_fixed, 1), 0), v_fixed;
END $$;

-- Should return 0 rows
SELECT p.oid::regprocedure AS still_using_current_user
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.prosrc ~* 'current_user\s+in\s*\(';

NOTIFY pgrst, 'reload schema';
