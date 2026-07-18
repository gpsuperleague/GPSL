-- =============================================================================
-- Fix: Championship B (etc.) champions missing from Discord (e.g. Valencia)
--
-- Cause: clinch math treats any side that can *equal* the leader's points as
-- able to finish above them. A points-tied 2nd (behind on GD) blocked the
-- champions announcement forever.
--
-- Fix is in gpsl_league_clinch_announcements.sql:
--   • After May lock (or all 38 played), table #1 is announced as champions
--   • Discord backfill for clinches that never got a queue row
--
-- Run THIS file in Supabase SQL editor (paste contents of the main patch after
-- the DROP), OR simply re-run the whole:
--   supabase/sql/patches/gpsl_league_clinch_announcements.sql
--
-- Then: Admin Discord → Scan league clinches → Push queue to Discord.
-- =============================================================================

DROP FUNCTION IF EXISTS public.competition_process_league_clinches_impl(bigint);

-- Re-apply the full clinch announcer from the main patch file in the repo
-- (open gpsl_league_clinch_announcements.sql and run it after this DROP).
--
-- Quick one-shot after the main patch is applied:
--   SELECT public.admin_competition_announce_clinches(NULL);

NOTIFY pgrst, 'reload schema';
