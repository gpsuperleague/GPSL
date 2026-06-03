-- =============================================================================
-- Player economics columns (Potential + Calc_Potential) — no data migration
-- Run once in Supabase SQL Editor. Safe to re-run (IF NOT EXISTS).
-- Formulas live in player_value_calcs.js / data/player_value_tables.json
-- =============================================================================

ALTER TABLE public."Players"
  ADD COLUMN IF NOT EXISTS "Potential" integer;

ALTER TABLE public."Players"
  ADD COLUMN IF NOT EXISTS "Calc_Potential" integer;

COMMENT ON COLUMN public."Players"."Potential" IS
  'PES max rating (pesdb). Used as Pes Max (F) in Calc Value formula when equal to current Rating.';

COMMENT ON COLUMN public."Players"."Calc_Potential" IS
  'Calculated potential (Excel G2). Market value (J2) uses this, not raw Potential.';

-- Optional: backfill Calc_Potential from existing Rating only (conservative; no MV change).
-- Uncomment only if you want DB values without running a full import:
--
-- UPDATE public."Players" p
-- SET "Calc_Potential" = p."Rating"
-- WHERE p."Calc_Potential" IS NULL AND p."Rating" IS NOT NULL;

NOTIFY pgrst, 'reload schema';
