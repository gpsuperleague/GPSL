-- Super8 & Spoon: QF is one round (leg 1 Sep + leg 2 Oct), then SF Nov, Final Dec.
-- Re-draw Super8 and Spoon in Admin after applying (existing brackets keep old round_no).

DELETE FROM public.competition_cup_round_schedule
WHERE cup_code IN ('super8', 'spoon');

INSERT INTO public.competition_cup_round_schedule (
  cup_code, round_no, cup_leg, gpsl_month, stage, round_label, matches_in_round
) VALUES
  ('super8', 1, 1, 'september', 'qf', 'Quarter-final', 4),
  ('super8', 1, 2, 'october', 'qf', 'Quarter-final', 4),
  ('super8', 2, 1, 'november', 'sf', 'Semi-final', 2),
  ('super8', 3, 1, 'december', 'final', 'Final', 1),
  ('spoon', 1, 1, 'september', 'qf', 'Quarter-final', 4),
  ('spoon', 1, 2, 'october', 'qf', 'Quarter-final', 4),
  ('spoon', 2, 1, 'november', 'sf', 'Semi-final', 2),
  ('spoon', 3, 1, 'december', 'final', 'Final', 1);
