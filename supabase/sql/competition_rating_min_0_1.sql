-- Allow match ratings from 0.1 to 10.0 (was minimum 1.0).
-- Run once after competition_phase4_player_stats.sql.

ALTER TABLE public.competition_match_player_stats
  DROP CONSTRAINT IF EXISTS competition_match_player_stats_rating_check;

ALTER TABLE public.competition_match_player_stats
  ADD CONSTRAINT competition_match_player_stats_rating_check
  CHECK (rating IS NULL OR (rating >= 0.1 AND rating <= 10));
