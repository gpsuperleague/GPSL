-- =============================================================================
-- Fix: Shield (and other cup) draw fails with competition_fixtures_unique_pair
--
-- That UNIQUE covered (season, division, competition_type, matchday, home, away)
-- without cup_code. All cups use division='cup' and matchday=round_no, so e.g.
-- Shield Last 32 CHE vs X colliding with Plate/League Cup round 1 same pair
-- (or a leftover from another cup) raises 409 Conflict.
--
-- League keeps a unique home/away per matchday.
-- Cups already have competition_fixtures_cup_unique_idx on
--   (season_id, cup_code, cup_round, cup_match, cup_leg).
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_fixtures
  DROP CONSTRAINT IF EXISTS competition_fixtures_unique_pair;

DROP INDEX IF EXISTS public.competition_fixtures_unique_pair;

-- League only: one pairing per division matchday
CREATE UNIQUE INDEX IF NOT EXISTS competition_fixtures_unique_league_pair_idx
  ON public.competition_fixtures (
    season_id,
    division,
    matchday,
    home_club_short_name,
    away_club_short_name
  )
  WHERE competition_type = 'league';

-- Ensure cup identity unique index exists (from cup schedule patch)
CREATE UNIQUE INDEX IF NOT EXISTS competition_fixtures_cup_unique_idx
  ON public.competition_fixtures (
    season_id,
    cup_code,
    cup_round,
    cup_match,
    cup_leg
  )
  WHERE competition_type = 'cup';

NOTIFY pgrst, 'reload schema';
