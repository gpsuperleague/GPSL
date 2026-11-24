-- Super 8 and Bowl groups: points from the two-leg aggregate.
-- Win the aggregate 3, lose it 0.
-- A level aggregate is still a draw. More away goals takes 2, the other club takes 1.
-- Level away goals are 1 each.
-- Leg 1 is the first club at home. Leg 2 is the return.
-- Replaces competition_cup_group_tie_result, which gave the whole win to the away-goals side.

BEGIN;

DROP FUNCTION IF EXISTS public.competition_cup_group_tie_result(int, int, int, int);

CREATE OR REPLACE FUNCTION public.competition_cup_group_tie_points(
  p_home_leg1 int,
  p_away_leg1 int,
  p_home_leg2 int,
  p_away_leg2 int
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_home_leg1 IS NULL
      OR p_away_leg1 IS NULL
      OR p_home_leg2 IS NULL
      OR p_away_leg2 IS NULL THEN NULL
    WHEN (p_home_leg1 + p_away_leg2) > (p_away_leg1 + p_home_leg2) THEN jsonb_build_object(
      'home_points', 3,
      'away_points', 0,
      'result', 'home'
    )
    WHEN (p_home_leg1 + p_away_leg2) < (p_away_leg1 + p_home_leg2) THEN jsonb_build_object(
      'home_points', 0,
      'away_points', 3,
      'result', 'away'
    )
    WHEN p_away_leg2 > p_away_leg1 THEN jsonb_build_object(
      'home_points', 2,
      'away_points', 1,
      'result', 'draw'
    )
    WHEN p_away_leg1 > p_away_leg2 THEN jsonb_build_object(
      'home_points', 1,
      'away_points', 2,
      'result', 'draw'
    )
    ELSE jsonb_build_object(
      'home_points', 1,
      'away_points', 1,
      'result', 'draw'
    )
  END;
$$;

COMMENT ON FUNCTION public.competition_cup_group_tie_points(int, int, int, int) IS
  'Leg 1 is the first club at home. Leg 2 is the return. Aggregate win 3, loss 0. Level aggregate: 2 for more away goals, 1 for fewer, 1 each if away goals are level.';

NOTIFY pgrst, 'reload schema';

COMMIT;
