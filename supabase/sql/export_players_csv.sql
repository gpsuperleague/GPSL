-- =============================================================================
-- Export entire Players table to CSV
-- =============================================================================
--
-- Supabase SQL Editor cannot save files to disk. Use ONE of:
--
-- A) SQL Editor — run the SELECT below, then use "Download CSV" on the results.
--
-- B) psql on your PC (full table, best for backup before GPDB sync):
--
--   psql "postgresql://postgres.[PROJECT-REF]:[PASSWORD]@aws-0-[REGION].pooler.supabase.com:6543/postgres" ^
--     -c "\copy (SELECT * FROM public.\"Players\" ORDER BY \"Konami_ID\") TO 'players_export.csv' WITH (FORMAT CSV, HEADER true, ENCODING 'UTF8')"
--
--   Or interactive psql:
--   \copy (SELECT * FROM public."Players" ORDER BY "Konami_ID") TO 'players_export.csv' WITH (FORMAT CSV, HEADER true, ENCODING 'UTF8')
--
-- C) Supabase CLI (if installed):
--   supabase db dump --data-only --table public.Players -f players_data.sql
--
-- =============================================================================

-- All columns (backup / full export)
SELECT *
FROM public."Players"
ORDER BY "Konami_ID";

-- GPDB / PESDB sync subset (economics + contract state only)
-- SELECT
--   "Konami_ID",
--   "Name",
--   "Position",
--   "Nation",
--   "Age",
--   "Rating",
--   "Potential",
--   "Calc_Potential",
--   "Playstyle",
--   "market_value",
--   "Maximum_Reserve_Price",
--   "Contracted_Team",
--   "Season_Signed",
--   contract_seasons_remaining,
--   contract_wage,
--   foreign_contract_club,
--   foreign_contract_sold_season_id,
--   foreign_contract_unlock_season_label,
--   foreign_contract_lock_kind
-- FROM public."Players"
-- ORDER BY "Konami_ID";
