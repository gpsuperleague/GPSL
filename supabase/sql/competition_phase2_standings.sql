-- =============================================================================
-- GPSL Competition — Phase 2: league standings, zones, form (last 10 by matchday)
-- Requires: competition_phase0.sql, competition_phase1_fixtures.sql
-- Points: W=3, D=1, L=0. Form uses last 10 *played* fixtures in matchday order.
-- =============================================================================

CREATE OR REPLACE VIEW public.competition_standings_public
WITH (security_invoker = false)
AS
WITH active_season AS (
  SELECT id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  LIMIT 1
),
registered AS (
  SELECT
    ccs.season_id,
    ccs.division,
    ccs.club_short_name,
    c."Club" AS club_name
  FROM public.competition_club_seasons ccs
  JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
  JOIN active_season s ON s.id = ccs.season_id
  WHERE ccs.division IN ('superleague', 'championship_a', 'championship_b')
),
played AS (
  SELECT f.*
  FROM public.competition_fixtures f
  JOIN active_season s ON s.id = f.season_id
  WHERE f.competition_type = 'league'
    AND f.status = 'played'
    AND f.home_goals IS NOT NULL
    AND f.away_goals IS NOT NULL
),
home_apps AS (
  SELECT
    season_id,
    division,
    home_club_short_name AS club_short_name,
    matchday,
    1 AS mp,
    CASE WHEN home_goals > away_goals THEN 1 ELSE 0 END AS w,
    CASE WHEN home_goals = away_goals THEN 1 ELSE 0 END AS d,
    CASE WHEN home_goals < away_goals THEN 1 ELSE 0 END AS l,
    home_goals AS gf,
    away_goals AS ga,
    CASE
      WHEN home_goals > away_goals THEN 'W'
      WHEN home_goals = away_goals THEN 'D'
      ELSE 'L'
    END AS result_char
  FROM played
),
away_apps AS (
  SELECT
    season_id,
    division,
    away_club_short_name AS club_short_name,
    matchday,
    1 AS mp,
    CASE WHEN away_goals > home_goals THEN 1 ELSE 0 END AS w,
    CASE WHEN away_goals = home_goals THEN 1 ELSE 0 END AS d,
    CASE WHEN away_goals < home_goals THEN 1 ELSE 0 END AS l,
    away_goals AS gf,
    home_goals AS ga,
    CASE
      WHEN away_goals > home_goals THEN 'W'
      WHEN away_goals = home_goals THEN 'D'
      ELSE 'L'
    END AS result_char
  FROM played
),
all_apps AS (
  SELECT * FROM home_apps
  UNION ALL
  SELECT * FROM away_apps
),
totals AS (
  SELECT
    season_id,
    division,
    club_short_name,
    sum(mp)::int AS mp,
    sum(w)::int AS w,
    sum(d)::int AS d,
    sum(l)::int AS l,
    sum(gf)::int AS gf,
    sum(ga)::int AS ga,
    sum(gf) - sum(ga) AS gd,
    sum(w) * 3 + sum(d) AS pts
  FROM all_apps
  GROUP BY season_id, division, club_short_name
),
form_strings AS (
  SELECT
    r.season_id,
    r.division,
    r.club_short_name,
    (
      SELECT string_agg(x.result_char, '' ORDER BY x.matchday)
      FROM (
        SELECT a2.result_char, a2.matchday
        FROM all_apps a2
        WHERE a2.season_id = r.season_id
          AND a2.division = r.division
          AND a2.club_short_name = r.club_short_name
        ORDER BY a2.matchday DESC
        LIMIT 10
      ) x
    ) AS form_last10
  FROM registered r
),
combined AS (
  SELECT
    r.season_id,
    r.division,
    r.club_short_name,
    r.club_name,
    coalesce(t.mp, 0) AS mp,
    coalesce(t.w, 0) AS w,
    coalesce(t.d, 0) AS d,
    coalesce(t.l, 0) AS l,
    coalesce(t.gf, 0) AS gf,
    coalesce(t.ga, 0) AS ga,
    coalesce(t.gd, 0) AS gd,
    coalesce(t.pts, 0) AS pts,
    coalesce(f.form_last10, '') AS form_last10
  FROM registered r
  LEFT JOIN totals t
    ON t.season_id = r.season_id
   AND t.division = r.division
   AND t.club_short_name = r.club_short_name
  LEFT JOIN form_strings f
    ON f.season_id = r.season_id
   AND f.division = r.division
   AND f.club_short_name = r.club_short_name
)
SELECT
  season_id,
  division,
  club_short_name,
  club_name,
  row_number() OVER (
    PARTITION BY season_id, division
    ORDER BY pts DESC, gd DESC, gf DESC, club_name ASC
  )::int AS table_position,
  mp,
  w,
  d,
  l,
  gf,
  ga,
  gd,
  pts,
  form_last10
FROM combined;

GRANT SELECT ON public.competition_standings_public TO authenticated;
GRANT SELECT ON public.competition_standings_public TO anon;

-- Admin helper until Phase 3 matchday flow (record a played result)
CREATE OR REPLACE FUNCTION public.competition_admin_record_result(
  p_fixture_id bigint,
  p_home_goals smallint,
  p_away_goals smallint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_home_goals IS NULL OR p_away_goals IS NULL OR p_home_goals < 0 OR p_away_goals < 0 THEN
    RAISE EXCEPTION 'Invalid score';
  END IF;

  UPDATE public.competition_fixtures
  SET home_goals = p_home_goals,
      away_goals = p_away_goals,
      status = 'played'
  WHERE id = p_fixture_id
    AND competition_type = 'league';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_record_result(bigint, smallint, smallint)
  TO authenticated;
