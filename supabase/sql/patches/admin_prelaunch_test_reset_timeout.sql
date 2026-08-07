-- =============================================================================
-- Fix: admin_test_reset_execute statement timeout
-- Prefer re-running full admin_prelaunch_test_reset.sql (includes this).
-- This file only raises the timeout if you need a quick apply first.
-- =============================================================================

ALTER FUNCTION public.admin_test_reset_execute(text, jsonb)
  SET statement_timeout = '600s';

NOTIFY pgrst, 'reload schema';
