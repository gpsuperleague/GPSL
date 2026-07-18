-- Align government subsidy rates with intended band table.
-- Safe re-run. Does not change band cutoffs (still 5 / 8 and 3 / 5 / 7).

UPDATE public.global_settings
SET
  hg_sub_band1_max = 5,
  hg_sub_band1_per_player = 500000,
  hg_sub_band2_max = 8,
  hg_sub_band2_per_player = 1500000,
  hg_sub_band3_per_player = 2000000,
  youth_sub_band1_max = 3,
  youth_sub_band1_per_player = 500000,
  youth_sub_band2_max = 5,
  youth_sub_band2_per_player = 1000000,
  youth_sub_band3_max = 7,
  youth_sub_band3_per_player = 1250000,
  youth_sub_band4_per_player = 1500000
WHERE id = 1;
