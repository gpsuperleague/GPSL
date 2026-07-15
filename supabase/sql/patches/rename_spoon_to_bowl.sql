-- =============================================================================
-- Rename prestige cup code spoon → bowl (display: Bowl)
-- Run once in Supabase SQL Editor after competition_phase6_cups.sql
-- =============================================================================

-- Data migration
UPDATE public.competition_fixtures SET cup_code = 'bowl' WHERE cup_code = 'spoon';
UPDATE public.competition_cup_bracket_nodes SET cup_code = 'bowl' WHERE cup_code = 'spoon';
UPDATE public.competition_cup_manual_qualifiers SET cup_code = 'bowl' WHERE cup_code = 'spoon';
UPDATE public.competition_cup_prize_config SET cup_code = 'bowl' WHERE cup_code = 'spoon';
UPDATE public.competition_cup_season_winner SET cup_code = 'bowl' WHERE cup_code = 'spoon';

UPDATE public.competition_cup_manual_qualifiers
SET qualifier_role = 'bowl_playoff_loser'
WHERE qualifier_role = 'spoon_playoff_loser';

-- Round schedule: drop CHECK first, then spoon → bowl
DO $$
DECLARE
  r record;
BEGIN
  IF to_regclass('public.competition_cup_round_schedule') IS NULL THEN
    RETURN;
  END IF;

  FOR r IN
    SELECT c.conname
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'competition_cup_round_schedule'
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%cup_code%'
  LOOP
    EXECUTE format(
      'ALTER TABLE public.competition_cup_round_schedule DROP CONSTRAINT IF EXISTS %I',
      r.conname
    );
  END LOOP;

  UPDATE public.competition_cup_round_schedule
  SET cup_code = 'bowl'
  WHERE cup_code = 'spoon';

  ALTER TABLE public.competition_cup_round_schedule
    DROP CONSTRAINT IF EXISTS competition_cup_round_schedule_cup_code_check;
  ALTER TABLE public.competition_cup_round_schedule
    ADD CONSTRAINT competition_cup_round_schedule_cup_code_check
    CHECK (cup_code IN ('super8', 'plate', 'shield', 'bowl', 'league_cup'));
END $$;

-- competition_owner_season_ranking column rename
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'competition_owner_season_ranking'
      AND column_name = 'spoon_points'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'competition_owner_season_ranking'
      AND column_name = 'bowl_points'
  ) THEN
    ALTER TABLE public.competition_owner_season_ranking
      RENAME COLUMN spoon_points TO bowl_points;
  END IF;
END $$;

-- competition_fixtures cup_code check
ALTER TABLE public.competition_fixtures
  DROP CONSTRAINT IF EXISTS competition_fixtures_cup_fields_check;

ALTER TABLE public.competition_fixtures
  ADD CONSTRAINT competition_fixtures_cup_fields_check
  CHECK (
    (competition_type = 'league' AND cup_code IS NULL)
    OR (
      competition_type = 'cup'
      AND cup_code IN ('super8', 'plate', 'shield', 'bowl', 'league_cup')
      AND cup_round IS NOT NULL
      AND cup_match IS NOT NULL
    )
  );

-- competition_cup_bracket_nodes
ALTER TABLE public.competition_cup_bracket_nodes
  DROP CONSTRAINT IF EXISTS competition_cup_bracket_nodes_cup_code_check;

ALTER TABLE public.competition_cup_bracket_nodes
  ADD CONSTRAINT competition_cup_bracket_nodes_cup_code_check
  CHECK (cup_code IN ('super8', 'plate', 'shield', 'bowl', 'league_cup'));

-- competition_cup_manual_qualifiers
ALTER TABLE public.competition_cup_manual_qualifiers
  DROP CONSTRAINT IF EXISTS competition_cup_manual_qualifiers_cup_code_check;

ALTER TABLE public.competition_cup_manual_qualifiers
  ADD CONSTRAINT competition_cup_manual_qualifiers_cup_code_check
  CHECK (cup_code IN ('shield', 'bowl'));

ALTER TABLE public.competition_cup_manual_qualifiers
  DROP CONSTRAINT IF EXISTS competition_cup_manual_qualifiers_qualifier_role_check;

ALTER TABLE public.competition_cup_manual_qualifiers
  ADD CONSTRAINT competition_cup_manual_qualifiers_qualifier_role_check
  CHECK (qualifier_role IN ('shield_playoff_winner', 'bowl_playoff_loser'));

-- competition_cup_prize_config
ALTER TABLE public.competition_cup_prize_config
  DROP CONSTRAINT IF EXISTS competition_cup_prize_config_cup_code_check;

ALTER TABLE public.competition_cup_prize_config
  ADD CONSTRAINT competition_cup_prize_config_cup_code_check
  CHECK (cup_code IN ('super8', 'plate', 'shield', 'bowl', 'league_cup'));

-- competition_cup_season_winner
ALTER TABLE public.competition_cup_season_winner
  DROP CONSTRAINT IF EXISTS competition_cup_season_winner_cup_code_check;

ALTER TABLE public.competition_cup_season_winner
  ADD CONSTRAINT competition_cup_season_winner_cup_code_check
  CHECK (cup_code IN ('super8', 'plate', 'shield', 'bowl', 'league_cup'));

-- Honours view label
CREATE OR REPLACE VIEW public.competition_club_honours_public
WITH (security_invoker = false)
AS
SELECT
  a.club_short_name,
  c."Club" AS club_name,
  a.season_label,
  a.season_id,
  'league_champion'::text AS honour_type,
  CASE a.division
    WHEN 'superleague' THEN 'SuperLeague champions'
    WHEN 'championship_a' THEN 'Championship A champions'
    WHEN 'championship_b' THEN 'Championship B champions'
    ELSE a.division
  END AS honour_label,
  a.division,
  NULL::text AS cup_code,
  a.created_at AS honoured_at
FROM public.competition_club_season_archive a
JOIN public."Clubs" c ON c."ShortName" = a.club_short_name
WHERE a.final_position = 1

UNION ALL

SELECT
  w.winner_club_short_name,
  c."Club",
  w.season_label,
  w.season_id,
  'cup_winner',
  CASE w.cup_code
    WHEN 'super8' THEN 'Super8 winners'
    WHEN 'plate' THEN 'Plate winners'
    WHEN 'shield' THEN 'Shield winners'
    WHEN 'bowl' THEN 'Bowl winners'
    WHEN 'league_cup' THEN 'League Cup winners'
    ELSE w.cup_code
  END,
  NULL,
  w.cup_code,
  w.archived_at
FROM public.competition_cup_season_winner w
JOIN public."Clubs" c ON c."ShortName" = w.winner_club_short_name;

GRANT SELECT ON public.competition_club_honours_public TO authenticated;
GRANT SELECT ON public.competition_club_honours_public TO anon;

-- Owner ranking: accept bowl cup code + expose bowl_points column
CREATE OR REPLACE FUNCTION public.competition_owner_cup_points(
  p_cup_code text,
  p_achievement text
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE coalesce(p_cup_code, '')
    WHEN 'super8' THEN CASE p_achievement
      WHEN 'winner' THEN 6
      WHEN 'runner_up' THEN 4
      WHEN 'sf' THEN 3
      WHEN 'qf' THEN 2
      ELSE 0
    END
    WHEN 'plate' THEN CASE p_achievement
      WHEN 'winner' THEN 4
      WHEN 'runner_up' THEN 3
      WHEN 'sf' THEN 2
      WHEN 'qf' THEN 1
      WHEN 'r16' THEN 0.5
      ELSE 0
    END
    WHEN 'shield' THEN CASE p_achievement
      WHEN 'winner' THEN 3
      WHEN 'runner_up' THEN 2
      WHEN 'sf' THEN 1
      WHEN 'qf' THEN 0.5
      WHEN 'r16' THEN 0.25
      WHEN 'r32' THEN 0
      ELSE 0
    END
    WHEN 'bowl' THEN CASE p_achievement
      WHEN 'winner' THEN 1
      WHEN 'runner_up' THEN 0.5
      WHEN 'sf' THEN 0.25
      WHEN 'qf' THEN 0
      ELSE 0
    END
    WHEN 'spoon' THEN CASE p_achievement
      WHEN 'winner' THEN 1
      WHEN 'runner_up' THEN 0.5
      WHEN 'sf' THEN 0.25
      WHEN 'qf' THEN 0
      ELSE 0
    END
    WHEN 'league_cup' THEN CASE p_achievement
      WHEN 'winner' THEN 4.5
      WHEN 'runner_up' THEN 3
      WHEN 'sf' THEN 2
      WHEN 'qf' THEN 1
      WHEN 'r16' THEN 0.5
      WHEN 'r32' THEN 0.25
      WHEN 'r64' THEN 0
      ELSE 0
    END
    ELSE 0
  END;
$$;

DROP VIEW IF EXISTS public.competition_owner_season_ranking_public;
CREATE VIEW public.competition_owner_season_ranking_public
WITH (security_invoker = false)
AS
SELECT
  r.season_id,
  r.season_label,
  r.club_short_name,
  c."Club" AS club_name,
  r.owner_id,
  public.competition_owner_display_name(r.owner_id) AS owner_name,
  coalesce(
    nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''),
    nullif(btrim(r.owner_tag), '')
  ) AS owner_tag,
  r.league_points,
  r.super8_points,
  r.plate_points,
  r.shield_points,
  coalesce(r.bowl_points, 0) AS bowl_points,
  r.league_cup_points,
  r.season_total,
  r.detail,
  r.computed_at
FROM public.competition_owner_season_ranking r
JOIN public."Clubs" c ON c."ShortName" = r.club_short_name
ORDER BY r.season_id DESC, r.season_total DESC;

GRANT SELECT ON public.competition_owner_season_ranking_public TO authenticated;

NOTIFY pgrst, 'reload schema';
