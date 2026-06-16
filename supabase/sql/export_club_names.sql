-- =============================================================================
-- Export club names — single column
-- =============================================================================
--
-- A) Supabase SQL Editor — run the SELECT, then "Download CSV" (one column).
--
-- B) psql — plain text, one name per line (no header):
--
--   \copy (
--     SELECT c."Club"
--     FROM public."Clubs" c
--     WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
--     ORDER BY c."Club"
--   ) TO 'club_names.txt' WITH (FORMAT text)
--
-- C) Node (from repo root):
--   node scripts/export_club_names.mjs -o club_names.txt
--
-- =============================================================================

-- Full display names (60 league clubs; excludes FOREIGN buyer sentinel)
SELECT c."Club" AS club_name
FROM public."Clubs" c
WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
ORDER BY c."Club";

-- Short codes instead (LIV, MCI, …):
-- SELECT c."ShortName" AS club_code
-- FROM public."Clubs" c
-- WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
-- ORDER BY c."Club";
