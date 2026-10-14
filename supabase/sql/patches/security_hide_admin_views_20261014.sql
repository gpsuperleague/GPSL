-- =============================================================================
-- Hide admin-only views from the public API (anon / authenticated).
-- Not read by the website or Edge Functions; the functions that use them are
-- SECURITY DEFINER and keep working. SQL editor access is unchanged.
--
-- Skips any view a live non-definer function (callable by the API) references.
-- Undo: GRANT SELECT ON public.<view> TO authenticated;
-- Safe re-run.
-- =============================================================================

DO $$
DECLARE
  v text;
  v_done text[] := ARRAY[]::text[];
  v_skipped text[] := ARRAY[]::text[];
BEGIN
  FOREACH v IN ARRAY ARRAY[
    'competition_club_attendance_admin_public',
    'squad_overflow_club_release_audit',
    'squad_overflow_mv_releases_pending_backfill'
  ] LOOP
    IF to_regclass(format('public.%I', v)) IS NULL THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND NOT p.prosecdef
        AND p.prosrc ~* ('\m' || v || '\M')
        AND (
          has_function_privilege('anon', p.oid, 'EXECUTE')
          OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
        )
    ) THEN
      v_skipped := v_skipped || v;
      CONTINUE;
    END IF;

    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', v);
    v_done := v_done || v;
  END LOOP;

  RAISE NOTICE 'Hidden: %; skipped (used by invoker function): %', v_done, v_skipped;
END $$;

NOTIFY pgrst, 'reload schema';

-- Report
SELECT c.relname AS view_name,
       has_table_privilege('anon', c.oid, 'SELECT') AS anon_can_read,
       has_table_privilege('authenticated', c.oid, 'SELECT') AS logged_in_can_read
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN (
    'competition_club_attendance_admin_public',
    'squad_overflow_club_release_audit',
    'squad_overflow_mv_releases_pending_backfill'
  )
ORDER BY 1;
