-- =============================================================================
-- Expand international_nations.seed_rank limit (was 1–99, blocks GPDB sync ~173)
-- Run once before re-running: SELECT public.international_sync_gpdb_nations();
-- =============================================================================

ALTER TABLE public.international_nations
  DROP CONSTRAINT IF EXISTS international_nations_seed_rank_check;

ALTER TABLE public.international_nations
  ADD CONSTRAINT international_nations_seed_rank_check
  CHECK (seed_rank >= 1 AND seed_rank <= 32767);

NOTIFY pgrst, 'reload schema';
