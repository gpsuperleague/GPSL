-- =============================================================================
-- Slightly easier stadium fill (performance bands + recovery).
-- Updates live global_settings and column defaults. Safe to re-run.
-- Tune further on Admin → Stadium settings.
-- =============================================================================

-- Previous (v2 defaults) → eased
--   slight gap ratio     0.10 → 0.15   (more room before "bad")
--   bad gap ratio        0.25 → 0.35
--   slight under −%        10 → 7
--   bad under −%           20 → 15
--   abysmal under −%       25 → 20
--   gain / on-target       12.5 → 15
--   monthly drift %         2 → 2.5

ALTER TABLE public.global_settings
  ALTER COLUMN stadium_under_slight_gap_ratio SET DEFAULT 0.150,
  ALTER COLUMN stadium_under_bad_gap_ratio SET DEFAULT 0.350,
  ALTER COLUMN stadium_under_slight_penalty_pct SET DEFAULT 7.00,
  ALTER COLUMN stadium_under_bad_penalty_pct SET DEFAULT 15.00,
  ALTER COLUMN stadium_under_abysmal_penalty_pct SET DEFAULT 20.00,
  ALTER COLUMN stadium_season_gain_on_target_pct SET DEFAULT 15.00,
  ALTER COLUMN stadium_monthly_drift_pct SET DEFAULT 2.50;

UPDATE public.global_settings
SET
  stadium_under_slight_gap_ratio = 0.150,
  stadium_under_bad_gap_ratio = 0.350,
  stadium_under_slight_penalty_pct = 7.00,
  stadium_under_bad_penalty_pct = 15.00,
  stadium_under_abysmal_penalty_pct = 20.00,
  stadium_season_gain_on_target_pct = 15.00,
  stadium_monthly_drift_pct = 2.50,
  updated_at = now()
WHERE id = 1;
