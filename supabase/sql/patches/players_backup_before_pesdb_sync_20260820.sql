-- =============================================================================
-- Backup public."Players" before PESDB / GPDB sync Apply
-- Run in Supabase SQL Editor BEFORE Apply.
-- =============================================================================
-- Creates a full row copy you can restore from if the sync goes wrong.
-- Safe to re-run: drops and recreates the dated backup table.
-- =============================================================================

DROP TABLE IF EXISTS public."Players_backup_20260820";

CREATE TABLE public."Players_backup_20260820" AS
TABLE public."Players";

COMMENT ON TABLE public."Players_backup_20260820" IS
  'Full Players snapshot taken 2026-08-20 before PESDB sync apply. Restore from this if needed.';

-- Sanity check — counts should match
SELECT
  (SELECT count(*) FROM public."Players") AS live_rows,
  (SELECT count(*) FROM public."Players_backup_20260820") AS backup_rows;

-- Optional: sample a few columns to confirm copy looks right
-- SELECT "Konami_ID", "Name", "Age", "Rating", "market_value", "Contracted_Team"
-- FROM public."Players_backup_20260820"
-- ORDER BY "Konami_ID"
-- LIMIT 20;

-- =============================================================================
-- RESTORE (only if sync Apply went wrong — do NOT run with the backup)
-- =============================================================================
-- Full replace of synced economics fields from the backup (adjust columns if needed):
--
-- UPDATE public."Players" p
-- SET
--   "Age" = b."Age",
--   "Rating" = b."Rating",
--   "Potential" = b."Potential",
--   "Calc_Potential" = b."Calc_Potential",
--   "Playstyle" = b."Playstyle",
--   "Position" = b."Position",
--   "Nation" = b."Nation",
--   "market_value" = b."market_value",
--   "Maximum_Reserve_Price" = b."Maximum_Reserve_Price"
-- FROM public."Players_backup_20260820" b
-- WHERE p."Konami_ID" = b."Konami_ID";
--
-- Contract / club ownership columns are intentionally left alone in that example
-- so a bad economics sync can be rolled back without undoing transfers.
-- For a full row restore, contact/admin review first — prefer column-scoped restore.
-- =============================================================================
