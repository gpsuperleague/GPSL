-- =============================================================================
-- Undo security_enable_rls_all_public_20261006.sql.
-- Run the whole file to undo every table, or set v_only to one table name to
-- undo just that table (e.g. if one page broke).
-- =============================================================================

DO $$
DECLARE
  v_only text := NULL;   -- <- e.g. 'admin_expiry_bid_audit_snapshot' to undo one table
  r record;
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT l.table_name
    FROM public.gpsl_rls_hardening_log l
    WHERE v_only IS NULL OR l.table_name = v_only
  LOOP
    IF to_regclass(format('public.%I', r.table_name)) IS NULL THEN
      CONTINUE;
    END IF;
    EXECUTE format('DROP POLICY IF EXISTS gpsl_keep_current_access ON public.%I', r.table_name);
    EXECUTE format('ALTER TABLE public.%I DISABLE ROW LEVEL SECURITY', r.table_name);
    DELETE FROM public.gpsl_rls_hardening_log WHERE table_name = r.table_name;
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'Rolled back % table(s).', v_n;
END $$;
