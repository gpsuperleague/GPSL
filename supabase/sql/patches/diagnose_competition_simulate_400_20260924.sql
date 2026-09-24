-- =============================================================================
-- Diagnose competition_simulate_fixture_result 400s
-- Run in Supabase SQL Editor (read-only checks + optional tip).
-- =============================================================================

-- 1) Functions present?
SELECT
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS args,
  CASE WHEN p.prosecdef THEN 'SECURITY DEFINER' ELSE 'INVOKER' END AS security
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'competition_simulate_fixture_result',
    'competition_simulate_fixture_result_core',
    'match_result_simulation_enabled',
    'competition_assert_fixture_month_unlocked',
    'my_club_shortname'
  )
ORDER BY 1, 2;

-- 2) Simulation toggle
SELECT public.match_result_simulation_enabled() AS simulation_enabled;

-- 3) If core is missing but wrapper exists, wrapper 400s with "function does not exist"
SELECT
  to_regprocedure('public.competition_simulate_fixture_result(bigint)') IS NOT NULL AS wrapper_exists,
  to_regprocedure('public.competition_simulate_fixture_result_core(bigint)') IS NOT NULL AS core_exists;

-- Tip: if wrapper_exists AND NOT core_exists, re-apply:
--   match_result_simulation.sql (or latest stars/cards patch that defines the full body)
-- then
--   match_sim_month_lock_all_roles_20260814.sql
--   match_sim_block_club_impersonation_20260902.sql
--
-- Common RAISE messages behind HTTP 400:
--   • Match result simulation is disabled
--   • No club linked to this account
--   • Your club is not in this fixture
--   • Fixture is not open for simulation (status=…)
--   • … matches unlock at … / … matches locked since …
--   • function competition_simulate_fixture_result_core(bigint) does not exist
