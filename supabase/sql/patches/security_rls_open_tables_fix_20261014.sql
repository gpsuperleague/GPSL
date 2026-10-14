-- =============================================================================
-- Follow-up to security_rls_lockdown_20261014.sql: tables left "open" because
-- an invoker trigger function writes them (e.g. Player_Transfer_Listings).
--
-- Trigger functions fire for whoever writes the base table, so they need the
-- caller to have write access. Making them SECURITY DEFINER lets them write as
-- the owner instead, and the tables can drop to read-only / owner-insert.
--
-- STEP 1 is read-only (preview). STEP 2 applies. Safe re-run.
-- =============================================================================

-- Writers of every table the lockdown left open
CREATE OR REPLACE FUNCTION public.gpsl_rls_open_table_writers()
RETURNS TABLE (
  table_name text,
  function_sig text,
  is_trigger boolean,
  api_can_execute boolean
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    l.table_name,
    p.oid::regprocedure::text,
    p.prorettype = 'trigger'::regtype,
    has_function_privilege('anon', p.oid, 'EXECUTE')
      OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
  FROM public.gpsl_rls_hardening_log l
  JOIN pg_proc p ON true
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE l.reason LIKE 'open:%'
    AND n.nspname = 'public'
    AND NOT p.prosecdef
    AND p.prokind IN ('f', 'p')
    AND p.prosrc ~* (
      '(insert\s+into|update|delete\s+from)\s+(only\s+)?(public\s*\.\s*)?"?'
      || l.table_name || '"?\M'
    )
  ORDER BY 1, 2;
$$;

REVOKE EXECUTE ON FUNCTION public.gpsl_rls_open_table_writers() FROM PUBLIC, anon, authenticated;

-- STEP 1 (preview — read only)
SELECT * FROM public.gpsl_rls_open_table_writers();


-- STEP 2 (apply)
DO $$
DECLARE
  f record;
  t record;
  v_fixed text[] := ARRAY[]::text[];
BEGIN
  -- 1) Invoker trigger functions writing open tables → run as owner.
  FOR f IN
    SELECT DISTINCT function_sig
    FROM public.gpsl_rls_open_table_writers()
    WHERE is_trigger
  LOOP
    EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER', f.function_sig);
    EXECUTE format('ALTER FUNCTION %s SET search_path = public, extensions', f.function_sig);
    v_fixed := v_fixed || f.function_sig;
  END LOOP;

  -- 2) Re-evaluate open tables: close writes when no API-reachable writer is left.
  FOR t IN
    SELECT l.table_name
    FROM public.gpsl_rls_hardening_log l
    WHERE l.reason LIKE 'open:%'
      AND NOT EXISTS (
        SELECT 1 FROM public.gpsl_rls_open_table_writers() w
        WHERE w.table_name = l.table_name
          AND (w.is_trigger OR w.api_can_execute)
      )
      AND NOT (l.table_name = ANY (public.gpsl_rls_client_written_tables()))
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS gpsl_api_insert ON public.%I', t.table_name);
    EXECUTE format('DROP POLICY IF EXISTS gpsl_api_update ON public.%I', t.table_name);
    EXECUTE format('DROP POLICY IF EXISTS gpsl_api_delete ON public.%I', t.table_name);

    IF t.table_name = 'Player_Transfer_Listings' THEN
      EXECUTE format(
        'CREATE POLICY gpsl_api_insert ON public.%I FOR INSERT TO authenticated WITH CHECK ('
        || 'public.is_gpsl_admin() OR EXISTS (SELECT 1 FROM public."Clubs" c '
        || 'WHERE c."ShortName" = seller_club_id AND c.owner_id = auth.uid()))',
        t.table_name
      );
      UPDATE public.gpsl_rls_hardening_log
      SET reason = 'owner_insert: website creates listings (own club only)', applied_at = now()
      WHERE table_name = t.table_name;
    ELSE
      UPDATE public.gpsl_rls_hardening_log
      SET reason = 'none: read-only (writers now definer / not callable)', applied_at = now()
      WHERE table_name = t.table_name;
    END IF;
  END LOOP;

  RAISE NOTICE 'Trigger functions switched to SECURITY DEFINER: %', v_fixed;
END $$;

NOTIFY pgrst, 'reload schema';

-- Report
SELECT 'table' AS kind, l.table_name || ' → ' || l.reason AS detail
FROM public.gpsl_rls_hardening_log l
WHERE l.reason LIKE 'open:%' OR l.reason LIKE 'owner_insert:%' OR l.applied_at > now() - interval '5 minutes'
UNION ALL
SELECT 'still open writer', w.table_name || ' ← ' || w.function_sig
  || CASE WHEN w.api_can_execute THEN ' (callable by API)' ELSE '' END
FROM public.gpsl_rls_open_table_writers() w
UNION ALL
SELECT 'policy', tablename || ': ' || policyname || ' (' || cmd || ')'
FROM pg_policies
WHERE schemaname = 'public' AND tablename = 'Player_Transfer_Listings'
ORDER BY 1, 2;
