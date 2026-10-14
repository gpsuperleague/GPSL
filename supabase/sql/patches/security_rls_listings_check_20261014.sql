-- Read-only: why can anyone still INSERT into Player_Transfer_Listings?
SELECT 'policy' AS kind,
       policyname || ' | ' || cmd || ' | ' || permissive || ' | roles=' || roles::text
       || ' | using=' || coalesce(qual, '-') || ' | check=' || coalesce(with_check, '-') AS detail
FROM pg_policies
WHERE schemaname = 'public' AND tablename = 'Player_Transfer_Listings'
UNION ALL
SELECT 'rls flags', 'enabled=' || c.relrowsecurity || ', forced=' || c.relforcerowsecurity
       || ', owner=' || pg_get_userbyid(c.relowner)
FROM pg_class c
WHERE c.oid = 'public."Player_Transfer_Listings"'::regclass
UNION ALL
SELECT 'hardening log', reason || ' @ ' || applied_at::text
FROM public.gpsl_rls_hardening_log
WHERE table_name = 'Player_Transfer_Listings'
UNION ALL
SELECT 'plan now', api_write || ' | ' || reason || ' | writers=' || coalesce(invoker_writers, '-')
FROM public.gpsl_rls_lockdown_plan()
WHERE table_name = 'Player_Transfer_Listings'
UNION ALL
SELECT 'role bypassrls', rolname || '=' || rolbypassrls
FROM pg_roles
WHERE rolname IN ('anon', 'authenticated')
ORDER BY 1, 2;
