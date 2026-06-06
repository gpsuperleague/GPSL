-- Repair Super8 & Spoon brackets drawn under the old 4-round schedule:
-- leg-2 QF nodes were stored at round_no 2 and fixtures at cup_round 2.
-- Safe to re-run (only touches leg-2 rows still on round_no 2).

UPDATE public.competition_cup_bracket_nodes n
SET round_no = 1
WHERE n.cup_code IN ('super8', 'spoon')
  AND coalesce(n.cup_leg, 1) = 2
  AND n.leg1_node_id IS NOT NULL
  AND n.round_no = 2;

UPDATE public.competition_fixtures f
SET cup_round = 1
FROM public.competition_cup_bracket_nodes n
WHERE n.fixture_id = f.id
  AND f.cup_code IN ('super8', 'spoon')
  AND coalesce(f.cup_leg, 1) = 2
  AND f.cup_round = 2
  AND n.leg1_node_id IS NOT NULL;
