-- =============================================================================
-- Match fitness: fitness_matches_to_max = consecutive apps PER LEVEL (not to L5)
--
-- Old (too fast): 4 apps total → L5, so 2 apps → Managing Load (L3).
-- New: 4 apps → +1 level. With default 4:
--   0–3 → Fully Fit (1)
--   4–7 → Match Ready (2)
--   8–11 → Managing Load (3)
--   12–15 → Fitness Concern (4)
--   16+ → Injury Risk (5)
--
-- Recalibrates non-injured rows from stored consecutive_appearances, then
-- re-syncs active injuries (L5→L2 scale unchanged).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_match_fitness_level_from_streak(
  p_streak int,
  p_to_max int DEFAULT 4
)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_streak, 0) <= 0 THEN 1
    ELSE least(
      5,
      1 + (coalesce(p_streak, 0) / greatest(coalesce(p_to_max, 4), 1))
    )
  END;
$$;

COMMENT ON FUNCTION public.competition_match_fitness_level_from_streak(int, int) IS
  'Fitness level 1–5 from consecutive appearance streak; p_to_max apps needed per level up.';

CREATE OR REPLACE FUNCTION public.competition_match_fitness_streak_for_level(
  p_level int,
  p_to_max int DEFAULT 4
)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_level, 1) <= 1 THEN 0
    ELSE (least(5, greatest(coalesce(p_level, 1), 1)) - 1)
      * greatest(coalesce(p_to_max, 4), 1)
  END;
$$;

COMMENT ON FUNCTION public.competition_match_fitness_streak_for_level(int, int) IS
  'Minimum consecutive streak that maps to the given fitness level.';

COMMENT ON COLUMN public.competition_injury_settings.fitness_matches_to_max IS
  'Consecutive league/cup appearances needed to climb one fitness level (not total to L5). Cup + league both count; cups are scheduled first each GPSL month. Default 4.';

-- Recalibrate current-season rows that are not on an active injury timeline
DO $$
DECLARE
  v_to_max int := 4;
  v_season bigint;
BEGIN
  SELECT greatest(coalesce(fitness_matches_to_max, 4), 1)
  INTO v_to_max
  FROM public.competition_injury_settings
  WHERE id = 1;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.competition_player_match_fitness f
  SET
    fitness_level = public.competition_match_fitness_level_from_streak(
      f.consecutive_appearances,
      v_to_max
    ),
    updated_at = now()
  WHERE f.season_id = v_season
    AND NOT EXISTS (
      SELECT 1
      FROM public.competition_player_injuries i
      WHERE i.player_id = f.player_id
        AND i.status = 'active'
        AND (
          coalesce(i.matches_out_remaining, 0) > 0
          OR coalesce(i.recovery_remaining, 0) > 0
        )
    );

  -- Keep injured players on the injury recovery scale
  IF to_regprocedure('public.competition_match_fitness_sync_from_injury(bigint)') IS NOT NULL THEN
    PERFORM public.competition_match_fitness_sync_from_injury(i.id)
    FROM public.competition_player_injuries i
    WHERE i.status = 'active'
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      );
  END IF;
END $$;
