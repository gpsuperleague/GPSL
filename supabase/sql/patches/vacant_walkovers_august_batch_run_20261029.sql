-- =============================================================================
-- ONE August batch (5 fixtures, fast apply — no per-fixture prize spam).
-- 1) Run vacant_walkovers_august_batch_install_20261029.sql once
-- 2) Re-run THIS until august_left = 0
-- =============================================================================

SELECT public.admin_vacant_walkovers_august_batch(5) AS batch;
