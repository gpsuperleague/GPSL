-- =============================================================================
-- Write test — proves whether UPDATE commits at all (run as ONE statement).
-- =============================================================================
-- If this returns 0 rows → WHERE not matching or read-only connection.
-- If market_value = 42412500 here but Table Editor still shows 10650000 → wrong project/branch.
-- If error "generated column" or "read-only" → paste error message.
-- =============================================================================

-- What is Players? (r=table, v=view)
SELECT c.relname, c.relkind, n.nspname AS schema
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname = 'Players';

-- Column metadata for market_value
SELECT
  column_name,
  data_type,
  is_nullable,
  is_generated,
  generation_expression
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'Players'
  AND column_name IN ('market_value', 'Maximum_Reserve_Price', 'Calc_Potential', 'Konami_ID');

-- Literal write test (single CTE — UPDATE + proof in one result)
WITH updated AS (
  UPDATE public."Players" p
  SET
    market_value = 42412500,
    "Maximum_Reserve_Price" = 63618750,
    "Calc_Potential" = 90
  WHERE btrim(p."Konami_ID"::text) = '136184'
  RETURNING
    p."Konami_ID",
    p."Name",
    p.market_value,
    p."Maximum_Reserve_Price",
    p."Calc_Potential"
)
SELECT
  (SELECT count(*)::integer FROM updated) AS rows_updated,
  u.*
FROM updated u;
