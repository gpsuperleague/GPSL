-- =============================================================================
-- Fix: non-final cup rounds wrongly showed Wembley
--
-- Cause: competition_fixture_is_cup_final used LIKE '%final%', which also
-- matched "Quarter-final" and "Semi-final", so those fixtures were stamped
-- with venue_name = Wembley Stadium.
--
-- This patch:
--   1) Restricts is_cup_final to schedule stage = 'final' (or true Final label)
--   2) Clears venue stamp on non-final cup fixtures
--   3) Recreates bracket view so early rounds always use home stadium
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_fixture_is_cup_final(
  p_fixture public.competition_fixtures
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT coalesce(p_fixture.competition_type, '') = 'cup'
    AND p_fixture.cup_code IS NOT NULL
    AND p_fixture.cup_round IS NOT NULL
    AND (
      EXISTS (
        SELECT 1
        FROM public.competition_cup_round_schedule s
        WHERE s.cup_code = p_fixture.cup_code
          AND s.round_no = p_fixture.cup_round::smallint
          AND s.stage = 'final'
      )
      OR (
        -- Bracket max round only when schedule agrees it is the final
        -- (or there is no schedule row for this round — legacy brackets)
        p_fixture.cup_round = (
          SELECT max(n.round_no)
          FROM public.competition_cup_bracket_nodes n
          WHERE n.season_id = p_fixture.season_id
            AND n.cup_code = p_fixture.cup_code
        )
        AND coalesce(
          (
            SELECT s.stage
            FROM public.competition_cup_round_schedule s
            WHERE s.cup_code = p_fixture.cup_code
              AND s.round_no = p_fixture.cup_round::smallint
            ORDER BY s.cup_leg DESC
            LIMIT 1
          ),
          'final'
        ) = 'final'
      )
      OR lower(coalesce(
        (
          SELECT s.round_label
          FROM public.competition_cup_round_schedule s
          WHERE s.cup_code = p_fixture.cup_code
            AND s.round_no = p_fixture.cup_round::smallint
          ORDER BY s.cup_leg DESC
          LIMIT 1
        ),
        ''
      )) = 'final'
    );
$$;

-- Clear Wembley stamps from non-final cup ties
UPDATE public.competition_fixtures f
SET venue_name = NULL,
    venue_capacity = NULL
WHERE f.competition_type = 'cup'
  AND f.venue_name IS NOT NULL
  AND NOT public.competition_fixture_is_cup_final(f);

-- Re-stamp genuine finals only
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT f.id
    FROM public.competition_fixtures f
    WHERE f.competition_type = 'cup'
      AND public.competition_fixture_is_cup_final(f)
  LOOP
    PERFORM public.competition_apply_cup_final_venue(r.id);
  END LOOP;
END $$;

DROP VIEW IF EXISTS public.competition_cup_qualified_public;
DROP VIEW IF EXISTS public.competition_cup_bracket_public;

CREATE VIEW public.competition_cup_bracket_public
WITH (security_invoker = false)
AS
SELECT
  n.id,
  n.season_id,
  n.cup_code,
  n.round_no,
  n.match_no,
  n.cup_leg,
  n.leg1_node_id,
  sch.round_label,
  sch.gpsl_month AS round_gpsl_month,
  sch.stage AS round_stage,
  n.home_club_short_name,
  hc."Club" AS home_club_name,
  n.away_club_short_name,
  ac."Club" AS away_club_name,
  n.winner_club_short_name,
  wc."Club" AS winner_club_name,
  n.fixture_id,
  f.status AS fixture_status,
  f.home_goals,
  f.away_goals,
  f.gpsl_month AS fixture_gpsl_month,
  f.weather,
  f.pitch_condition,
  f.kit_season,
  public.competition_club_continent(n.home_club_short_name) AS home_continent,
  CASE
    WHEN sch.stage = 'final' THEN
      coalesce(
        nullif(btrim(f.venue_name), ''),
        nullif(btrim(gs.cup_final_venue_name), ''),
        'Wembley Stadium'
      )
    ELSE
      coalesce(
        nullif(btrim(hc."Stadium"), ''),
        hc."Club"
      )
  END AS venue_name,
  CASE
    WHEN sch.stage = 'final' THEN
      coalesce(
        nullif(f.venue_capacity, 0),
        gs.cup_final_venue_capacity,
        90000
      )
    ELSE
      hc."Capacity"
  END AS venue_capacity,
  n.child_node_id,
  n.child_slot
FROM public.competition_cup_bracket_nodes n
JOIN public.competition_seasons s ON s.id = n.season_id
LEFT JOIN public.global_settings gs ON gs.id = 1
LEFT JOIN public.competition_cup_round_schedule sch
  ON sch.cup_code = n.cup_code
 AND sch.round_no = n.round_no
 AND sch.cup_leg = coalesce(n.cup_leg, 1)
LEFT JOIN public."Clubs" hc ON hc."ShortName" = n.home_club_short_name
LEFT JOIN public."Clubs" ac ON ac."ShortName" = n.away_club_short_name
LEFT JOIN public."Clubs" wc ON wc."ShortName" = n.winner_club_short_name
LEFT JOIN public.competition_fixtures f ON f.id = n.fixture_id
WHERE s.status = 'active' AND s.is_current = true;

CREATE VIEW public.competition_cup_qualified_public
WITH (security_invoker = false)
AS
SELECT
  s.id AS season_id,
  cup.cup_code,
  q.club_short_name
FROM public.competition_seasons s
CROSS JOIN (
  VALUES ('super8'), ('plate'), ('shield'), ('bowl'), ('league_cup')
) AS cup(cup_code)
CROSS JOIN LATERAL unnest(public.competition_qualify_cup_clubs(s.id, cup.cup_code)) AS q(club_short_name)
WHERE s.is_current = true AND s.status = 'active';

GRANT SELECT ON public.competition_cup_bracket_public TO authenticated;
GRANT SELECT ON public.competition_cup_bracket_public TO anon;
GRANT SELECT ON public.competition_cup_qualified_public TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_fixture_is_cup_final(public.competition_fixtures) TO authenticated;

NOTIFY pgrst, 'reload schema';
