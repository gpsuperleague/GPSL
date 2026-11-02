-- =============================================================================
-- Vacant clubs sink to the bottom of live league tables (A–Z among themselves).
-- Occupied clubs keep normal merit order (pts, GD, GF, name).
-- Points / results unchanged — table_position ranking only.
-- When a club gets an owner_id again, they return to merit position automatically.
--
-- Safe re-run. Apply in Supabase SQL Editor.
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
    c."Club" AS club_name,
    (c.owner_id IS NULL) AS is_vacant
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
    AND (f.is_void OR (f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL))
    AND public.competition_fixture_counts_in_tables(f.id)
),
home_apps AS (
  SELECT
    season_id, division, home_club_short_name AS club_short_name, matchday,
    1 AS mp,
    CASE WHEN NOT is_void AND home_goals > away_goals THEN 1 ELSE 0 END AS w,
    CASE WHEN NOT is_void AND home_goals = away_goals THEN 1 ELSE 0 END AS d,
    CASE WHEN NOT is_void AND home_goals < away_goals THEN 1 ELSE 0 END AS l,
    coalesce(home_goals, 0) AS gf, coalesce(away_goals, 0) AS ga,
    CASE
      WHEN is_void THEN '-'
      WHEN home_goals > away_goals THEN 'W'
      WHEN home_goals = away_goals THEN 'D'
      ELSE 'L'
    END AS result_char
  FROM played
),
away_apps AS (
  SELECT
    season_id, division, away_club_short_name AS club_short_name, matchday,
    1 AS mp,
    CASE WHEN NOT is_void AND away_goals > home_goals THEN 1 ELSE 0 END AS w,
    CASE WHEN NOT is_void AND away_goals = home_goals THEN 1 ELSE 0 END AS d,
    CASE WHEN NOT is_void AND away_goals < home_goals THEN 1 ELSE 0 END AS l,
    coalesce(away_goals, 0) AS gf, coalesce(home_goals, 0) AS ga,
    CASE
      WHEN is_void THEN '-'
      WHEN away_goals > home_goals THEN 'W'
      WHEN away_goals = home_goals THEN 'D'
      ELSE 'L'
    END AS result_char
  FROM played
),
all_apps AS (
  SELECT * FROM home_apps UNION ALL SELECT * FROM away_apps
),
totals AS (
  SELECT
    season_id, division, club_short_name,
    sum(mp)::int AS mp, sum(w)::int AS w, sum(d)::int AS d, sum(l)::int AS l,
    sum(gf)::int AS gf, sum(ga)::int AS ga, sum(gf) - sum(ga) AS gd,
    sum(w) * 3 + sum(d) AS pts
  FROM all_apps
  GROUP BY season_id, division, club_short_name
),
point_adj AS (
  SELECT a.season_id, a.club_short_name, sum(a.points_delta)::int AS adj_pts
  FROM public.competition_league_points_adjustments a
  JOIN active_season s ON s.id = a.season_id
  GROUP BY a.season_id, a.club_short_name
),
form_strings AS (
  SELECT
    r.season_id, r.division, r.club_short_name,
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
    r.season_id, r.division, r.club_short_name, r.club_name, r.is_vacant,
    coalesce(t.mp, 0) AS mp, coalesce(t.w, 0) AS w, coalesce(t.d, 0) AS d,
    coalesce(t.l, 0) AS l, coalesce(t.gf, 0) AS gf, coalesce(t.ga, 0) AS ga,
    coalesce(t.gd, 0) AS gd,
    coalesce(t.pts, 0) + coalesce(pa.adj_pts, 0) AS pts,
    coalesce(f.form_last10, '') AS form_last10
  FROM registered r
  LEFT JOIN totals t
    ON t.season_id = r.season_id AND t.division = r.division AND t.club_short_name = r.club_short_name
  LEFT JOIN point_adj pa
    ON pa.season_id = r.season_id AND pa.club_short_name = r.club_short_name
  LEFT JOIN form_strings f
    ON f.season_id = r.season_id AND f.division = r.division AND f.club_short_name = r.club_short_name
)
SELECT
  season_id, division, club_short_name, club_name,
  row_number() OVER (
    PARTITION BY season_id, division
    ORDER BY
      -- Vacant last; among vacant, A–Z only (ignore pts)
      CASE WHEN is_vacant THEN 1 ELSE 0 END ASC,
      CASE WHEN is_vacant THEN club_name ELSE NULL END ASC NULLS LAST,
      -- Occupied: normal merit
      CASE WHEN NOT is_vacant THEN pts ELSE NULL END DESC NULLS LAST,
      CASE WHEN NOT is_vacant THEN gd ELSE NULL END DESC NULLS LAST,
      CASE WHEN NOT is_vacant THEN gf ELSE NULL END DESC NULLS LAST,
      club_name ASC
  )::int AS table_position,
  mp, w, d, l, gf, ga, gd, pts, form_last10
FROM combined;

GRANT SELECT ON public.competition_standings_public TO authenticated;
GRANT SELECT ON public.competition_standings_public TO anon;

-- Same rule for any-season standings (seeding / movements) when not archived
CREATE OR REPLACE FUNCTION public.competition_league_standings_for_season(
  p_season_id bigint
)
RETURNS TABLE (
  season_id bigint,
  division text,
  club_short_name text,
  club_name text,
  table_position int,
  mp int,
  w int,
  d int,
  l int,
  gf int,
  ga int,
  gd int,
  pts int
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_season_id IS NULL THEN
    RETURN;
  END IF;

  IF (
    SELECT count(*)::int
    FROM public.competition_club_season_archive a
    WHERE a.season_id = p_season_id
      AND a.division IN ('superleague', 'championship_a', 'championship_b')
  ) >= 60 THEN
    RETURN QUERY
    SELECT
      a.season_id,
      a.division,
      a.club_short_name,
      coalesce(c."Club", a.club_short_name) AS club_name,
      a.final_position::int AS table_position,
      coalesce(a.mp, 0)::int,
      coalesce(a.won, 0)::int,
      coalesce(a.drawn, 0)::int,
      coalesce(a.lost, 0)::int,
      coalesce(a.gf, 0)::int,
      coalesce(a.ga, 0)::int,
      coalesce(a.gd, 0)::int,
      coalesce(a.pts, 0)::int
    FROM public.competition_club_season_archive a
    LEFT JOIN public."Clubs" c ON c."ShortName" = a.club_short_name
    WHERE a.season_id = p_season_id
      AND a.division IN ('superleague', 'championship_a', 'championship_b')
    ORDER BY a.division, a.final_position;
    RETURN;
  END IF;

  RETURN QUERY
  WITH registered AS (
    SELECT
      ccs.season_id,
      ccs.division,
      ccs.club_short_name,
      c."Club" AS club_name,
      (c.owner_id IS NULL) AS is_vacant
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
  ),
  played AS (
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'played'
      AND (f.is_void OR (f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL))
  ),
  home_apps AS (
    SELECT
      season_id, division, home_club_short_name AS club_short_name,
      1 AS mp,
      CASE WHEN NOT is_void AND home_goals > away_goals THEN 1 ELSE 0 END AS w,
      CASE WHEN NOT is_void AND home_goals = away_goals THEN 1 ELSE 0 END AS d,
      CASE WHEN NOT is_void AND home_goals < away_goals THEN 1 ELSE 0 END AS l,
      coalesce(home_goals, 0) AS gf, coalesce(away_goals, 0) AS ga
    FROM played
  ),
  away_apps AS (
    SELECT
      season_id, division, away_club_short_name AS club_short_name,
      1 AS mp,
      CASE WHEN NOT is_void AND away_goals > home_goals THEN 1 ELSE 0 END AS w,
      CASE WHEN NOT is_void AND away_goals = home_goals THEN 1 ELSE 0 END AS d,
      CASE WHEN NOT is_void AND away_goals < home_goals THEN 1 ELSE 0 END AS l,
      coalesce(away_goals, 0) AS gf, coalesce(home_goals, 0) AS ga
    FROM played
  ),
  all_apps AS (
    SELECT * FROM home_apps UNION ALL SELECT * FROM away_apps
  ),
  totals AS (
    SELECT
      a.season_id, a.division, a.club_short_name,
      sum(a.mp)::int AS mp, sum(a.w)::int AS w, sum(a.d)::int AS d, sum(a.l)::int AS l,
      sum(a.gf)::int AS gf, sum(a.ga)::int AS ga, (sum(a.gf) - sum(a.ga))::int AS gd,
      (sum(a.w) * 3 + sum(a.d))::int AS pts
    FROM all_apps a
    GROUP BY a.season_id, a.division, a.club_short_name
  ),
  point_adj AS (
    SELECT a.season_id, a.club_short_name, sum(a.points_delta)::int AS adj_pts
    FROM public.competition_league_points_adjustments a
    WHERE a.season_id = p_season_id
    GROUP BY a.season_id, a.club_short_name
  ),
  combined AS (
    SELECT
      r.season_id, r.division, r.club_short_name, r.club_name, r.is_vacant,
      coalesce(t.mp, 0) AS mp, coalesce(t.w, 0) AS w, coalesce(t.d, 0) AS d,
      coalesce(t.l, 0) AS l, coalesce(t.gf, 0) AS gf, coalesce(t.ga, 0) AS ga,
      coalesce(t.gd, 0) AS gd,
      coalesce(t.pts, 0) + coalesce(pa.adj_pts, 0) AS pts
    FROM registered r
    LEFT JOIN totals t
      ON t.season_id = r.season_id
     AND t.division = r.division
     AND t.club_short_name = r.club_short_name
    LEFT JOIN point_adj pa
      ON pa.season_id = r.season_id
     AND pa.club_short_name = r.club_short_name
  )
  SELECT
    c.season_id,
    c.division,
    c.club_short_name,
    c.club_name,
    row_number() OVER (
      PARTITION BY c.season_id, c.division
      ORDER BY
        CASE WHEN c.is_vacant THEN 1 ELSE 0 END ASC,
        CASE WHEN c.is_vacant THEN c.club_name ELSE NULL END ASC NULLS LAST,
        CASE WHEN NOT c.is_vacant THEN c.pts ELSE NULL END DESC NULLS LAST,
        CASE WHEN NOT c.is_vacant THEN c.gd ELSE NULL END DESC NULLS LAST,
        CASE WHEN NOT c.is_vacant THEN c.gf ELSE NULL END DESC NULLS LAST,
        c.club_name ASC
    )::int AS table_position,
    c.mp, c.w, c.d, c.l, c.gf, c.ga, c.gd, c.pts
  FROM combined c;
END;
$function$;

NOTIFY pgrst, 'reload schema';
