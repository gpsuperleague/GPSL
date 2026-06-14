-- =============================================================================
-- Export ALL public tables to CSV — GPSL backup helper
-- =============================================================================
--
-- Supabase SQL Editor cannot save files to your PC. Use ONE of:
--
-- A) SQL Editor (no CLI) — run STEP 1 below, then for EACH row copy
--    `export_query`, run it, click Download CSV. Save as table_name.csv
--
-- B) psql on your PC — run STEP 2 output in PowerShell (one command per table,
--    or save STEP 2 to export_all.ps1). See bottom of this file.
--
-- C) Supabase CLI — supabase db dump -f full_backup.sql (schema + data, not CSV)
--
-- Tips:
--   • Skip huge tables you already have (e.g. Players) if unchanged.
--   • Empty tables still export as header-only CSV — fine for completeness.
--   • Auth users are NOT in public — back up separately (Dashboard → Authentication).
--
-- =============================================================================

-- STEP 1 — List every public table + ready SELECT (run once, download this result too)
SELECT
  t.tablename AS table_name,
  (
    SELECT count(*)::bigint
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = t.tablename
      AND c.relkind = 'r'
  ) AS approx_listed,
  format(
    'SELECT * FROM public.%I;',
    t.tablename
  ) AS export_query
FROM pg_catalog.pg_tables t
WHERE t.schemaname = 'public'
ORDER BY t.tablename;


-- STEP 2 — Generate psql \copy commands (run once; copy column psql_copy_command)
-- Requires: psql + database connection string from Supabase → Settings → Database
/*
SELECT format(
  E'\\copy (SELECT * FROM public.%I) TO ''GPSL_backup_%s.csv'' WITH (FORMAT CSV, HEADER true, ENCODING ''UTF8'');',
  tablename,
  tablename
) AS psql_copy_command
FROM pg_catalog.pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;
*/


-- STEP 3 — Priority tables for “league progress” backup (run each, Download CSV)
-- Uncomment and run one at a time in SQL Editor if you only want essentials.

-- SELECT * FROM public."Players" ORDER BY "Konami_ID";
-- SELECT * FROM public."Managers" ORDER BY id;
-- SELECT * FROM public."Clubs" ORDER BY "ShortName";
-- SELECT * FROM public."Club_Finances" ORDER BY club_short_name;
-- SELECT * FROM public.gpsl_owner_registry ORDER BY owner_email;
-- SELECT * FROM public.competition_seasons ORDER BY id;
-- SELECT * FROM public.competition_club_seasons ORDER BY season_id, club_short_name;
-- SELECT * FROM public.competition_fixtures ORDER BY season_id, id;
-- SELECT * FROM public.competition_finance_ledger ORDER BY id;
-- SELECT * FROM public.bank_ledger ORDER BY id;
-- SELECT * FROM public."Transfer_History" ORDER BY id;
-- SELECT * FROM public."Player_Transfer_Listings" ORDER BY id;
-- SELECT * FROM public."Player_Transfer_Bids" ORDER BY id;
-- SELECT * FROM public."Manager_Transfer_Listings" ORDER BY id;
-- SELECT * FROM public."Manager_Transfer_Bids" ORDER BY id;
-- SELECT * FROM public.global_settings WHERE id = 1;
-- SELECT * FROM public."Club_Auction_Listings" ORDER BY id;
-- SELECT * FROM public."Club_Auction_Bids" ORDER BY id;
-- SELECT * FROM public.competition_inbox ORDER BY id;
-- SELECT * FROM public.club_loans ORDER BY id;


-- =============================================================================
-- PowerShell helper (after STEP 2 — paste psql_copy lines into export_all.ps1)
-- =============================================================================
--
-- $env:PGCONN = "postgresql://postgres.[REF]:[PASSWORD]@aws-0-[REGION].pooler.supabase.com:6543/postgres"
-- psql $env:PGCONN -f export_all.ps1
--
-- Or single table:
-- psql $env:PGCONN -c "\copy (SELECT * FROM public.\"Players\") TO 'Players.csv' WITH (FORMAT CSV, HEADER true, ENCODING 'UTF8')"
--
-- =============================================================================
