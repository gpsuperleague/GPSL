-- =============================================================================
-- Repair global_settings_public after finance SQL patches
-- (wages/taxes, subsidies, TV, challenges drop draft_bidding_open + league_phase)
-- Run once in Supabase SQL Editor if Draft Auction vanished from nav / GPDB.
-- =============================================================================

DROP VIEW IF EXISTS public.global_settings_public;

CREATE VIEW public.global_settings_public
WITH (security_invoker = false)
AS
SELECT
  id,
  transfer_window_open,
  draft_auction_enabled,
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
  ) AS draft_bidding_open
FROM public.global_settings;

GRANT SELECT ON public.global_settings_public TO authenticated;
GRANT SELECT ON public.global_settings_public TO anon;

NOTIFY pgrst, 'reload schema';
