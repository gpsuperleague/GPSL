-- Publish March GPSL Sport NOW.
-- 1) Run gpsl_sport_early_month_publish_fix.sql first (once).
-- 2) Then run this in the Supabase SQL Editor.

-- Clear stuck job marker if March edition is missing
DO $$
DECLARE
  v_season_id bigint;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE NOTICE 'No current season';
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.gpsl_sport_editions e
    WHERE e.season_id = v_season_id AND lower(e.gpsl_month) = 'march'
  ) THEN
    DELETE FROM public.competition_season_calendar_jobs j
    WHERE j.season_id = v_season_id
      AND j.job_key = 'gpsl_sport:march';
  END IF;
END $$;

-- Create / rebuild March edition (works in SQL Editor as postgres)
SELECT public.competition_admin_regenerate_gpsl_sport('march', NULL) AS result;

-- If that returns admin_only, use this instead:
-- SELECT public.gpsl_sport_generate_edition(
--   (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1),
--   'march'
-- ) AS edition_id;
