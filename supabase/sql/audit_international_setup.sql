-- =============================================================================
-- International / GPDB nations — setup audit (run in Supabase SQL Editor)
-- Confirms SQL patches are deployed and whether nation sync still needs running.
--
-- Expected run order (once):
--   1) competition_international.sql
--   2) international_callup_gpdb.sql
--   3) international_sync_gpdb_nations.sql
--   4) international_nation_player_pool.sql
--   5) international_nations_seed_rank_expand.sql  (if sync fails seed_rank check)
--   6) SELECT public.international_sync_gpdb_nations();  -- adds GPDB nations
--   7) SELECT public.international_refresh_gpdb_label_map();  -- if map empty
-- =============================================================================

-- 1) Patch checklist — scan status column; want all OK
SELECT
  c.check_name,
  c.status,
  c.detail
FROM (
  SELECT
    'Base: international_nations table' AS check_name,
    CASE WHEN to_regclass('public.international_nations') IS NOT NULL THEN 'OK' ELSE 'MISSING' END AS status,
    'Run competition_international.sql' AS detail
  UNION ALL
  SELECT
    'Base: international_normalize_nation_label()',
    CASE WHEN to_regprocedure('public.international_normalize_nation_label(text)') IS NOT NULL THEN 'OK' ELSE 'MISSING' END,
    'Run international_callup_gpdb.sql'
  UNION ALL
  SELECT
    'Sync patch: international_nation_catalog table',
    CASE WHEN to_regclass('public.international_nation_catalog') IS NOT NULL THEN 'OK' ELSE 'MISSING' END,
    'Run international_sync_gpdb_nations.sql'
  UNION ALL
  SELECT
    'Sync patch: international_sync_gpdb_nations()',
    CASE WHEN to_regprocedure('public.international_sync_gpdb_nations()') IS NOT NULL THEN 'OK' ELSE 'MISSING' END,
    'Run international_sync_gpdb_nations.sql'
  UNION ALL
  SELECT
    'Sync patch: international_catalog_match_code()',
    CASE WHEN to_regprocedure('public.international_catalog_match_code(text)') IS NOT NULL THEN 'OK' ELSE 'MISSING' END,
    'Run international_sync_gpdb_nations.sql'
  UNION ALL
  SELECT
    'Pool patch: international_gpdb_label_map table',
    CASE WHEN to_regclass('public.international_gpdb_label_map') IS NOT NULL THEN 'OK' ELSE 'MISSING' END,
    'Run international_nation_player_pool.sql'
  UNION ALL
  SELECT
    'Pool patch: international_refresh_gpdb_label_map()',
    CASE WHEN to_regprocedure('public.international_refresh_gpdb_label_map()') IS NOT NULL THEN 'OK' ELSE 'MISSING' END,
    'Run international_nation_player_pool.sql'
  UNION ALL
  SELECT
    'Pool patch: international_resolve_gpdb_nation_code()',
    CASE WHEN to_regprocedure('public.international_resolve_gpdb_nation_code(text)') IS NOT NULL THEN 'OK' ELSE 'MISSING' END,
    'Run international_nation_player_pool.sql (perf fix)'
  UNION ALL
  SELECT
    'Pool patch: international_nation_player_pool_report()',
    CASE WHEN to_regprocedure('public.international_nation_player_pool_report()') IS NOT NULL THEN 'OK' ELSE 'MISSING' END,
    'Run international_nation_player_pool.sql'
  UNION ALL
  SELECT
    'Pool patch: players_nation_norm_idx index',
    CASE WHEN EXISTS (
      SELECT 1 FROM pg_indexes
      WHERE schemaname = 'public'
        AND tablename = 'Players'
        AND indexname = 'players_nation_norm_idx'
    ) THEN 'OK' ELSE 'MISSING' END,
    'Run international_nation_player_pool.sql (or create index separately)'
  UNION ALL
  SELECT
    'View: international_nations_public',
    CASE WHEN to_regclass('public.international_nations_public') IS NOT NULL THEN 'OK' ELSE 'MISSING' END,
    'Run competition_international.sql (+ international_nation_owner_tag.sql if used)'
  UNION ALL
  SELECT
    'Seed rank limit expanded (GPDB sync)',
    CASE WHEN EXISTS (
      SELECT 1
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE n.nspname = 'public'
        AND t.relname = 'international_nations'
        AND c.conname = 'international_nations_seed_rank_check'
        AND pg_get_constraintdef(c.oid) LIKE '%32767%'
    ) THEN 'OK' ELSE 'MISSING' END,
    'Run international_nations_seed_rank_expand.sql (sync fails at rank 100 without this)'
  UNION ALL
  SELECT
    'View: international_selection_public has nations_total',
    CASE WHEN EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'international_selection_public'
        AND column_name = 'nations_total'
    ) THEN 'OK' ELSE 'MISSING' END,
    'Re-run international_sync_gpdb_nations.sql (updates view)'
) c
ORDER BY
  CASE c.status WHEN 'OK' THEN 1 ELSE 0 END,
  c.check_name;

-- 2) Data / sync state — what the site actually uses
SELECT
  (SELECT count(*)::integer FROM public.international_nations WHERE active = true) AS active_nations_in_db,
  (SELECT count(*)::integer FROM public.international_nation_catalog) AS catalog_rows,
  (SELECT count(*)::integer FROM public.international_gpdb_label_map) AS label_map_rows,
  (
    SELECT count(DISTINCT p."Nation")::integer
    FROM public."Players" p
    WHERE btrim(coalesce(p."Nation", '')) <> ''
  ) AS distinct_gpdb_nation_labels,
  (
    SELECT count(*)::integer
    FROM (
      SELECT p."Nation"
      FROM public."Players" p
      WHERE btrim(coalesce(p."Nation", '')) <> ''
        AND NOT EXISTS (
          SELECT 1
          FROM public.international_nations n
          WHERE n.active = true
            AND public.international_gpdb_matches_nation(p."Nation", n.code)
        )
      GROUP BY p."Nation"
    ) x
  ) AS gpdb_labels_still_unmatched;

-- 3) Interpretation (read the row above)
SELECT
  CASE
    WHEN (SELECT count(*) FROM public.international_nations WHERE active = true) <= 60
         AND (SELECT count(*) FROM (
           SELECT p."Nation" FROM public."Players" p
           WHERE btrim(coalesce(p."Nation", '')) <> ''
             AND NOT EXISTS (
               SELECT 1 FROM public.international_nations n
               WHERE n.active = true
                 AND public.international_gpdb_matches_nation(p."Nation", n.code)
             )
           GROUP BY p."Nation"
         ) x) > 0
    THEN 'ACTION: Run SELECT public.international_sync_gpdb_nations(); (admin) then SELECT public.international_refresh_gpdb_label_map();'
    WHEN (SELECT count(*) FROM public.international_gpdb_label_map) = 0
         AND to_regprocedure('public.international_refresh_gpdb_label_map()') IS NOT NULL
    THEN 'ACTION: Run SELECT public.international_refresh_gpdb_label_map();'
    WHEN (SELECT count(*) FROM public.international_nations WHERE active = true) > 60
         AND (SELECT count(*) FROM (
           SELECT p."Nation" FROM public."Players" p
           WHERE btrim(coalesce(p."Nation", '')) <> ''
             AND NOT EXISTS (
               SELECT 1 FROM public.international_nations n
               WHERE n.active = true
                 AND public.international_gpdb_matches_nation(p."Nation", n.code)
             )
           GROUP BY p."Nation"
         ) x) = 0
    THEN 'OK: Nations synced — nation select & player pool should list all active nations'
    ELSE 'Review query (1) for MISSING patches and query (2) counts'
  END AS setup_verdict;

-- 4) Optional: list unmatched GPDB labels (if any) — these need sync
SELECT
  p."Nation" AS gpdb_nation_label,
  count(*)::integer AS players
FROM public."Players" p
WHERE btrim(coalesce(p."Nation", '')) <> ''
  AND NOT EXISTS (
    SELECT 1
    FROM public.international_nations n
    WHERE n.active = true
      AND public.international_gpdb_matches_nation(p."Nation", n.code)
  )
GROUP BY p."Nation"
ORDER BY players DESC, p."Nation";
