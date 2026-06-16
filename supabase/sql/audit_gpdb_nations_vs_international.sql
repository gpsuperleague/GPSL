-- =============================================================================
-- GPDB Players.Nation vs international_nations (nation select / player pool)
-- Run in Supabase SQL Editor (requires international_sync_gpdb_nations.sql)
-- =============================================================================

-- 1) All nations in nation player pool & nation select (active international list)
SELECT
  n.code,
  n.name,
  n.seed_rank,
  n.active
FROM public.international_nations n
WHERE n.active = true
ORDER BY n.seed_rank;

-- 2) GPDB player nationalities with NO matching international nation (missing from select list)
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

-- 3) International nations with zero GPDB players matched (empty pool row)
SELECT
  n.code,
  n.name,
  n.seed_rank
FROM public.international_nations n
WHERE n.active = true
  AND NOT EXISTS (
    SELECT 1
    FROM public."Players" p
    WHERE public.international_gpdb_matches_nation(p."Nation", n.code)
  )
ORDER BY n.seed_rank;

-- 4) Summary counts
SELECT
  (SELECT count(*) FROM public.international_nations WHERE active = true) AS international_nations_active,
  (
    SELECT count(DISTINCT p."Nation")
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
  ) AS gpdb_labels_missing_from_international;
