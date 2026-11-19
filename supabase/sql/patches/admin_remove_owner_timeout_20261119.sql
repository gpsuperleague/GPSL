-- Admin remove-from-club was dying on the website with a 500.
-- The authenticated role stops a statement or a lock wait at 8 seconds.
-- This action can clear arranged fixtures for the club, so give it room.
-- Safe re-run.

ALTER FUNCTION public.admin_owner_remove_from_club(text, boolean, uuid)
  SET statement_timeout = '60s';

ALTER FUNCTION public.admin_owner_remove_from_club(text, boolean, uuid)
  SET lock_timeout = '30s';

ALTER FUNCTION public.admin_owner_detach_core(uuid, text, text)
  SET statement_timeout = '60s';

ALTER FUNCTION public.admin_owner_detach_core(uuid, text, text)
  SET lock_timeout = '30s';

SELECT p.proname, p.proconfig
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('admin_owner_remove_from_club', 'admin_owner_detach_core');
