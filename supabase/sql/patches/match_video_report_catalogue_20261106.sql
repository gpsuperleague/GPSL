-- =============================================================================
-- Video-report breach list
--
-- The R-button was offering every active matchday/squad/manager fine,
-- including no-shows and squad-registration fines that are not video breaches.
-- This keeps those fines active for the automatic paths and limits the
-- report form (and new submissions) to the video catalogue below.
--
-- Label tweaks:
--   Use of SA                         → Use of PA1, PA2 or SA
--   off by 10 no score                → off by 10 minutes no score
--   plays more than 10                → plays more than 10 minutes
--   Matchroom settings not displayed (Away)
--                                     → Matchroom settings not cross check and displayed (Away)
--   Dragged players… (long sanction)  → Dragged players off the default formation
--
-- Safe re-run. Run in the Supabase SQL editor.
-- =============================================================================

UPDATE public.competition_fine_tariff
SET label = 'Use of PA1, PA2 or SA', updated_at = now()
WHERE code = 'use_of_sa';

UPDATE public.competition_fine_tariff
SET label = 'Ineligible Player Starts - off by 10 minutes no score', updated_at = now()
WHERE code = 'ineligible_starts_off_by_10';

UPDATE public.competition_fine_tariff
SET label = 'Ineligible Player Starts - plays more than 10 minutes', updated_at = now()
WHERE code = 'ineligible_starts_plays_10';

UPDATE public.competition_fine_tariff
SET label = 'Matchroom settings not cross check and displayed (Away)', updated_at = now()
WHERE code = 'matchroom_not_displayed_away';

UPDATE public.competition_fine_tariff
SET label = 'Dragged players off the default formation', updated_at = now()
WHERE code = 'formation_player_drag';

-- The R-button list is now the on_video_report tick on each tariff.
-- Run fine_tariff_video_report_20261106.sql for that column, the form filter,
-- and the admin checkbox. Re-running the function below would lock the list
-- back to a hard-coded set, so it is intentionally not created here.

NOTIFY pgrst, 'reload schema';
