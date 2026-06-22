-- =============================================================================
-- Repair global_settings_public after finance SQL patches
-- (wages/taxes, subsidies, TV, challenges drop draft_bidding_open + league_phase)
-- Run once in Supabase SQL Editor if Draft Auction vanished from nav / GPDB.
-- =============================================================================

-- Ensure columns exist before recreating the view (safe if patches were skipped)
ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS league_phase text,
  ADD COLUMN IF NOT EXISTS wage_pct_superleague numeric(6, 3) NOT NULL DEFAULT 5.000,
  ADD COLUMN IF NOT EXISTS wage_pct_championship numeric(6, 3) NOT NULL DEFAULT 4.000,
  ADD COLUMN IF NOT EXISTS stadium_cost_tier1 numeric(14, 2) NOT NULL DEFAULT 5000,
  ADD COLUMN IF NOT EXISTS stadium_cost_tier2 numeric(14, 2) NOT NULL DEFAULT 7500,
  ADD COLUMN IF NOT EXISTS stadium_cost_tier3 numeric(14, 2) NOT NULL DEFAULT 10000,
  ADD COLUMN IF NOT EXISTS stadium_capacity_tier_mid integer NOT NULL DEFAULT 30000,
  ADD COLUMN IF NOT EXISTS stadium_capacity_tier_high integer NOT NULL DEFAULT 50000,
  ADD COLUMN IF NOT EXISTS stadium_expansion_cancel_penalty numeric(14, 2) NOT NULL DEFAULT 1000000,
  ADD COLUMN IF NOT EXISTS hg_sub_band1_max smallint NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS hg_sub_band1_per_player numeric(14, 2) NOT NULL DEFAULT 250000,
  ADD COLUMN IF NOT EXISTS hg_sub_band2_max smallint NOT NULL DEFAULT 8,
  ADD COLUMN IF NOT EXISTS hg_sub_band2_per_player numeric(14, 2) NOT NULL DEFAULT 1500000,
  ADD COLUMN IF NOT EXISTS hg_sub_band3_per_player numeric(14, 2) NOT NULL DEFAULT 2000000,
  ADD COLUMN IF NOT EXISTS youth_sub_band1_max smallint NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS youth_sub_band1_per_player numeric(14, 2) NOT NULL DEFAULT 200000,
  ADD COLUMN IF NOT EXISTS youth_sub_band2_max smallint NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS youth_sub_band2_per_player numeric(14, 2) NOT NULL DEFAULT 750000,
  ADD COLUMN IF NOT EXISTS youth_sub_band3_max smallint NOT NULL DEFAULT 7,
  ADD COLUMN IF NOT EXISTS youth_sub_band3_per_player numeric(14, 2) NOT NULL DEFAULT 1250000,
  ADD COLUMN IF NOT EXISTS youth_sub_band4_per_player numeric(14, 2) NOT NULL DEFAULT 2000000,
  ADD COLUMN IF NOT EXISTS bnb_max_rating smallint NOT NULL DEFAULT 72,
  ADD COLUMN IF NOT EXISTS bnb_min_players smallint NOT NULL DEFAULT 14,
  ADD COLUMN IF NOT EXISTS bnb_per_player numeric(14, 2) NOT NULL DEFAULT 10000000,
  ADD COLUMN IF NOT EXISTS tv_per_match_amount numeric(14, 2) NOT NULL DEFAULT 1000000,
  ADD COLUMN IF NOT EXISTS tv_matches_per_month smallint NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS tv_club_min_season smallint NOT NULL DEFAULT 4,
  ADD COLUMN IF NOT EXISTS tv_club_max_season smallint NOT NULL DEFAULT 12,
  ADD COLUMN IF NOT EXISTS tv_weight_top8_clash smallint NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS tv_weight_title_race smallint NOT NULL DEFAULT 80,
  ADD COLUMN IF NOT EXISTS tv_weight_promotion smallint NOT NULL DEFAULT 70,
  ADD COLUMN IF NOT EXISTS tv_weight_relegation smallint NOT NULL DEFAULT 70,
  ADD COLUMN IF NOT EXISTS tv_weight_super8 smallint NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS tv_weight_playoff smallint NOT NULL DEFAULT 50,
  ADD COLUMN IF NOT EXISTS tv_weight_dry_spell smallint NOT NULL DEFAULT 40,
  ADD COLUMN IF NOT EXISTS tv_weight_below_min smallint NOT NULL DEFAULT 200,
  ADD COLUMN IF NOT EXISTS challenge_default_prize numeric(14, 2) NOT NULL DEFAULT 1000000,
  ADD COLUMN IF NOT EXISTS challenge_period_bonus numeric(14, 2) NOT NULL DEFAULT 5000000,
  ADD COLUMN IF NOT EXISTS wage_34plus_min_rating smallint NOT NULL DEFAULT 34,
  ADD COLUMN IF NOT EXISTS wage_34plus_per_player numeric(14, 2) NOT NULL DEFAULT 500000,
  ADD COLUMN IF NOT EXISTS star_tax_min_rating smallint NOT NULL DEFAULT 70,
  ADD COLUMN IF NOT EXISTS star_tax_per_player numeric(14, 2) NOT NULL DEFAULT 1000000,
  ADD COLUMN IF NOT EXISTS emergency_tac_pct numeric(6, 3) NOT NULL DEFAULT 10.000,
  ADD COLUMN IF NOT EXISTS emergency_tac_threshold numeric(14, 2) NOT NULL DEFAULT 100000000,
  ADD COLUMN IF NOT EXISTS manager_draft_auction_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS club_auction_enabled boolean NOT NULL DEFAULT false;

DROP VIEW IF EXISTS public.global_settings_public;

CREATE VIEW public.global_settings_public
WITH (security_invoker = false)
AS
SELECT
  id,
  transfer_window_open,
  draft_auction_enabled,
  manager_draft_auction_enabled,
  club_auction_enabled,
  draft_auction_start_time,
  updated_at,
  league_phase,
  wage_pct_superleague,
  wage_pct_championship,
  stadium_cost_tier1,
  stadium_cost_tier2,
  stadium_cost_tier3,
  stadium_capacity_tier_mid,
  stadium_capacity_tier_high,
  stadium_expansion_cancel_penalty,
  hg_sub_band1_max,
  hg_sub_band1_per_player,
  hg_sub_band2_max,
  hg_sub_band2_per_player,
  hg_sub_band3_per_player,
  youth_sub_band1_max,
  youth_sub_band1_per_player,
  youth_sub_band2_max,
  youth_sub_band2_per_player,
  youth_sub_band3_max,
  youth_sub_band3_per_player,
  youth_sub_band4_per_player,
  bnb_max_rating,
  bnb_min_players,
  bnb_per_player,
  tv_per_match_amount,
  tv_matches_per_month,
  tv_club_min_season,
  tv_club_max_season,
  tv_weight_top8_clash,
  tv_weight_title_race,
  tv_weight_promotion,
  tv_weight_relegation,
  tv_weight_super8,
  tv_weight_playoff,
  tv_weight_dry_spell,
  tv_weight_below_min,
  challenge_default_prize,
  challenge_period_bonus,
  wage_34plus_min_rating,
  wage_34plus_per_player,
  star_tax_min_rating,
  star_tax_per_player,
  emergency_tac_pct,
  emergency_tac_threshold,
  (
    COALESCE(draft_auction_enabled, false)
    AND draft_auction_start_time IS NOT NULL
    AND draft_random_finish_time IS NOT NULL
    AND now() >= draft_auction_start_time
    AND now() < draft_random_finish_time
  ) AS draft_bidding_open,
  (
    COALESCE(manager_draft_auction_enabled, false)
    AND draft_auction_start_time IS NOT NULL
    AND draft_random_finish_time IS NOT NULL
    AND now() >= draft_auction_start_time
    AND now() < draft_random_finish_time
  ) AS manager_draft_bidding_open,
  (
    COALESCE(club_auction_enabled, false)
    AND draft_auction_start_time IS NOT NULL
    AND draft_random_finish_time IS NOT NULL
    AND now() >= draft_auction_start_time
    AND now() < draft_random_finish_time
  ) AS club_auction_bidding_open,
  CASE
    WHEN draft_random_finish_time IS NOT NULL
     AND now() >= draft_random_finish_time
    THEN draft_random_finish_time
    ELSE NULL
  END AS draft_random_finish_revealed
FROM public.global_settings;

GRANT SELECT ON public.global_settings_public TO authenticated;
GRANT SELECT ON public.global_settings_public TO anon;

NOTIFY pgrst, 'reload schema';
