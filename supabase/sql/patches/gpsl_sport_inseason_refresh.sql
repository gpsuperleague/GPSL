-- =============================================================================
-- GPSL Sport — rebuild an existing in-season edition (e.g. bare-bones August)
--
-- 1. Run gpsl_sport_inseason_rich_edition.sql (full file) in Supabase SQL Editor
-- 2. Then run ONE of the options below
--
-- Do NOT run gpsl_sport_inseason_v_u_fix.sql — it is deprecated and reverts the rich generator.
-- =============================================================================

-- Option A — rebuild August for the current season (paste and run):
-- SELECT public.competition_admin_regenerate_gpsl_sport('august', NULL);

-- Option B — Admin → Season → Calendar → "Rebuild GPSL Sport edition" (august selected)
