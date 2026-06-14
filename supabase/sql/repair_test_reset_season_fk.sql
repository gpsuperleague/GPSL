-- Fix: test reset blocked by Clubs.stadium_fill_season_id → competition_seasons FK
-- Run once in SQL Editor, then retry Execute on admin_test_reset.html
--
-- Prefer re-running the full patches/admin_prelaunch_test_reset.sql (includes this fix).

-- Quick unblock if reset failed mid-run (safe to run standalone):
UPDATE public."Clubs"
SET stadium_fill_season_id = NULL
WHERE stadium_fill_season_id IS NOT NULL;

UPDATE public.international_fixtures
SET season_id = NULL
WHERE season_id IS NOT NULL;

UPDATE public.international_wc_cycles
SET qual_season_id_1 = NULL,
    qual_season_id_2 = NULL,
    finals_after_season_id = NULL
WHERE qual_season_id_1 IS NOT NULL
   OR qual_season_id_2 IS NOT NULL
   OR finals_after_season_id IS NOT NULL;

-- Then re-deploy admin_test_reset_execute from patches/admin_prelaunch_test_reset.sql
