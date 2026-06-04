-- Adds started / subbed_on columns required by Match Day confirm & submit.
-- Run once if you see: column "started" of relation "competition_match_player_stats" does not exist
-- Then re-run competition_confirm_opponent_stats.sql (or competition_match_stats_started_sub.sql).

ALTER TABLE public.competition_match_player_stats
  ADD COLUMN IF NOT EXISTS started boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS subbed_on boolean NOT NULL DEFAULT false;
