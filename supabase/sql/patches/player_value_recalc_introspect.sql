-- =============================================================================
-- Discover what blocks market_value writes on public."Players"
-- Run entire file; paste ALL result sets (especially triggers + view definition).
-- =============================================================================

-- A) All player-named relations
SELECT
  n.nspname AS schema,
  c.relname AS name,
  c.relkind AS kind
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname ILIKE '%player%'
  AND n.nspname = 'public'
ORDER BY c.relkind, c.relname;

-- B) View definition (if Players is a view)
SELECT pg_get_viewdef('public."Players"'::regclass, true) AS players_view_sql;

-- C) Triggers (full definitions)
SELECT
  t.tgname AS trigger_name,
  CASE t.tgtype::integer & 66
    WHEN 2 THEN 'BEFORE'
    WHEN 64 THEN 'INSTEAD OF'
    ELSE 'OTHER'
  END AS timing,
  pg_get_triggerdef(t.oid, true) AS trigger_def
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
WHERE c.relname = 'Players'
  AND NOT t.tgisinternal;

-- D) Trigger function source (if any triggers above)
SELECT
  t.tgname,
  p.proname AS function_name,
  pg_get_functiondef(p.oid) AS function_source
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_proc p ON p.oid = t.tgfoid
WHERE c.relname = 'Players'
  AND NOT t.tgisinternal;

-- E) Column metadata
SELECT
  column_name,
  data_type,
  is_generated,
  generation_expression
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'Players'
  AND column_name IN ('market_value', 'Maximum_Reserve_Price', 'Calc_Potential', 'Playstyle', 'Konami_ID');

-- F) Does a NON-MV column update stick? (Playstyle round-trip test)
UPDATE public."Players" p
SET "Playstyle" = coalesce(nullif(btrim(p."Playstyle"), ''), 'Build Up')
WHERE btrim(p."Konami_ID"::text) = '136184'
RETURNING p."Konami_ID", p."Name", p."Playstyle" AS returning_playstyle;

-- G) MV update test (expect returning_mv = 42412500 after fix; currently stuck at 10650000)
UPDATE public."Players" p
SET
  market_value = 42412500,
  "Maximum_Reserve_Price" = 63618750
WHERE btrim(p."Konami_ID"::text) = '136184'
RETURNING p."Konami_ID", p.market_value AS returning_mv, p."Maximum_Reserve_Price" AS returning_reserve;
