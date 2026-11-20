-- Website role lock_timeout is 8s. A claim waiting on a cron lock
-- died with "canceling statement due to lock timeout" and a 500.
-- The function already allows 120s of work. Let the lock wait use that too.

ALTER FUNCTION public.waiting_list_claim_vacant_club(text)
  SET lock_timeout = '60s';

SELECT proconfig
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'waiting_list_claim_vacant_club';
