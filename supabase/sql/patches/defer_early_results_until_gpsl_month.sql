-- =============================================================================
-- Defer table + player-stat impact for results played before their GPSL month
-- (e.g. holiday early-play of September fixtures during June/July).
--
-- Score/status can still be confirmed early; standings and season/career/cup
-- aggregations only include fixtures once gpsl_month <= active GPSL month.
-- When that month unlocks, views include them automatically (no apply job).
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_fixture_counts_in_tables(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_active text;
  v_fixture_sort smallint;
  v_active_sort smallint;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_fixture.status IS DISTINCT FROM 'played' THEN
    RETURN false;
  END IF;

  IF v_fixture.home_goals IS NULL OR v_fixture.away_goals IS NULL THEN
    RETURN false;
  END IF;

  -- No calendar for season → legacy behaviour (all played count)
  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_fixture.season_id
  ) THEN
    RETURN true;
  END IF;

  v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());

  IF v_active IS NULL THEN
    -- Between months / before first unlock: only count months that have unlocked
    RETURN EXISTS (
      SELECT 1
      FROM public.competition_season_calendar m
      WHERE m.season_id = v_fixture.season_id
        AND lower(btrim(m.gpsl_month)) = lower(btrim(coalesce(v_fixture.gpsl_month, '')))
        AND now() >= m.unlock_at
    );
  END IF;

  v_fixture_sort := public.competition_gpsl_month_sort(v_fixture.gpsl_month);
  v_active_sort := public.competition_gpsl_month_sort(v_active);

  IF v_fixture_sort IS NULL OR v_active_sort IS NULL THEN
    RETURN true;
  END IF;

  RETURN v_fixture_sort <= v_active_sort;
END;
$function$;

COMMENT ON FUNCTION public.competition_fixture_counts_in_tables(bigint) IS
  'True when a played fixture should affect league tables / season player stats (gpsl_month <= active month).';

GRANT EXECUTE ON FUNCTION public.competition_fixture_counts_in_tables(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_fixture_counts_in_tables(bigint) TO anon;

-- ---------------------------------------------------------------------------
-- Standings
-- ---------------------------------------------------------------------------

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
    AND public.competition_fixture_counts_in_tables(f.id)
),
home_apps AS (
  SELECT
    season_id, division, home_club_short_name AS club_short_name, matchday,
    1 AS mp,
    CASE WHEN home_goals > away_goals THEN 1 ELSE 0 END AS w,
    CASE WHEN home_goals = away_goals THEN 1 ELSE 0 END AS d,
    CASE WHEN home_goals < away_goals THEN 1 ELSE 0 END AS l,
    home_goals AS gf, away_goals AS ga,
    CASE WHEN home_goals > away_goals THEN 'W' WHEN home_goals = away_goals THEN 'D' ELSE 'L' END AS result_char
  FROM played
),
away_apps AS (
  SELECT
    season_id, division, away_club_short_name AS club_short_name, matchday,
    1 AS mp,
    CASE WHEN away_goals > home_goals THEN 1 ELSE 0 END AS w,
    CASE WHEN away_goals = home_goals THEN 1 ELSE 0 END AS d,
    CASE WHEN away_goals < home_goals THEN 1 ELSE 0 END AS l,
    away_goals AS gf, home_goals AS ga,
    CASE WHEN away_goals > home_goals THEN 'W' WHEN away_goals = home_goals THEN 'D' ELSE 'L' END AS result_char
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
    r.season_id, r.division, r.club_short_name, r.club_name,
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
    ORDER BY pts DESC, gd DESC, gf DESC, club_name ASC
  )::int AS table_position,
  mp, w, d, l, gf, ga, gd, pts, form_last10
FROM combined;

GRANT SELECT ON public.competition_standings_public TO authenticated;
GRANT SELECT ON public.competition_standings_public TO anon;

-- ---------------------------------------------------------------------------
-- Clean sheets helper (used by season + career views)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_player_clean_sheets(
  p_season_id bigint,
  p_player_id text,
  p_club_short_name text DEFAULT NULL,
  p_include_cups boolean DEFAULT true
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::int
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
  WHERE m.season_id = p_season_id
    AND m.player_id = btrim(p_player_id)
    AND m.started = true
    AND f.status = 'played'
    AND public.competition_fixture_counts_in_tables(f.id)
    AND (
      p_include_cups
      OR f.competition_type = 'league'
    )
    AND (
      p_club_short_name IS NULL
      OR m.club_short_name = btrim(p_club_short_name)
    )
    AND public.competition_player_stat_role(p."Position") IN ('goalkeeper', 'defender')
    AND public.competition_player_conceded_in_fixture(f.id, m.club_short_name) = 0;
$$;

-- ---------------------------------------------------------------------------
-- League season stats
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.competition_player_season_stats_public;

CREATE VIEW public.competition_player_season_stats_public
WITH (security_invoker = false)
AS
SELECT
  m.season_id,
  m.player_id,
  p."Name" AS player_name,
  m.club_short_name,
  c."Club" AS club_name,
  ccs.division,
  p."Position" AS player_position,
  public.competition_player_stat_role(p."Position") AS stat_role,
  count(*) FILTER (WHERE m.appeared)::int AS appearances,
  count(*) FILTER (WHERE m.started)::int AS starts,
  count(*) FILTER (WHERE m.subbed_on)::int AS subs,
  coalesce(sum(m.goals), 0)::int AS goals,
  coalesce(sum(m.assists), 0)::int AS assists,
  round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2) AS avg_rating,
  count(*) FILTER (WHERE m.is_player_of_match)::int AS potm_awards,
  public.competition_player_clean_sheets(
    m.season_id,
    m.player_id,
    m.club_short_name,
    false
  ) AS clean_sheets
FROM public.competition_match_player_stats m
JOIN public.competition_fixtures f ON f.id = m.fixture_id
JOIN public.competition_seasons s ON s.id = m.season_id
JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
LEFT JOIN public.competition_club_seasons ccs
  ON ccs.season_id = m.season_id AND ccs.club_short_name = m.club_short_name
WHERE s.is_current = true
  AND s.status = 'active'
  AND f.status = 'played'
  AND f.competition_type = 'league'
  AND public.competition_fixture_counts_in_tables(f.id)
GROUP BY
  m.season_id,
  m.player_id,
  p."Name",
  p."Position",
  m.club_short_name,
  c."Club",
  ccs.division;

GRANT SELECT ON public.competition_player_season_stats_public TO authenticated;
GRANT SELECT ON public.competition_player_season_stats_public TO anon;

-- ---------------------------------------------------------------------------
-- Cup season stats
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.competition_player_cup_stats_public;

CREATE VIEW public.competition_player_cup_stats_public
WITH (security_invoker = false)
AS
SELECT
  m.season_id,
  f.cup_code,
  m.player_id,
  p."Name" AS player_name,
  m.club_short_name,
  c."Club" AS club_name,
  p."Position" AS player_position,
  public.competition_player_stat_role(p."Position") AS stat_role,
  count(*) FILTER (WHERE m.appeared)::int AS appearances,
  count(*) FILTER (WHERE m.started)::int AS starts,
  count(*) FILTER (WHERE m.subbed_on)::int AS subs,
  coalesce(sum(m.goals), 0)::int AS goals,
  coalesce(sum(m.assists), 0)::int AS assists,
  round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2) AS avg_rating,
  count(*) FILTER (WHERE m.is_player_of_match)::int AS potm_awards,
  count(DISTINCT m.fixture_id) FILTER (
    WHERE m.started
      AND public.competition_player_stat_role(p."Position") IN ('goalkeeper', 'defender')
      AND public.competition_player_conceded_in_fixture(f.id, m.club_short_name) = 0
  )::int AS clean_sheets
FROM public.competition_match_player_stats m
JOIN public.competition_fixtures f ON f.id = m.fixture_id
JOIN public.competition_seasons s ON s.id = m.season_id
JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
WHERE s.is_current = true
  AND s.status = 'active'
  AND f.status = 'played'
  AND f.competition_type = 'cup'
  AND f.cup_code IS NOT NULL
  AND public.competition_fixture_counts_in_tables(f.id)
GROUP BY
  m.season_id,
  f.cup_code,
  m.player_id,
  p."Name",
  p."Position",
  m.club_short_name,
  c."Club";

GRANT SELECT ON public.competition_player_cup_stats_public TO authenticated;
GRANT SELECT ON public.competition_player_cup_stats_public TO anon;

-- ---------------------------------------------------------------------------
-- Live half of career view (current season stints)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.competition_player_career_public
WITH (security_invoker = false)
AS
SELECT
  a.season_id,
  a.season_label,
  a.player_id,
  p."Name" AS player_name,
  a.club_short_name,
  c."Club" AS club_name,
  a.division,
  a.player_position,
  a.stat_role,
  a.appearances,
  a.starts,
  a.goals,
  a.assists,
  a.avg_rating,
  a.potm_awards,
  a.clean_sheets,
  a.ballon_points,
  false AS is_live,
  a.archived_at AS as_of
FROM public.competition_player_season_archive a
JOIN public."Players" p ON p."Konami_ID"::text = a.player_id
JOIN public."Clubs" c ON c."ShortName" = a.club_short_name

UNION ALL

SELECT
  m.season_id,
  s.label,
  m.player_id,
  p."Name",
  m.club_short_name,
  c."Club",
  ccs.division,
  p."Position",
  public.competition_player_stat_role(p."Position"),
  count(*) FILTER (WHERE m.appeared)::int,
  count(*) FILTER (WHERE m.started)::int,
  coalesce(sum(m.goals), 0)::int,
  coalesce(sum(m.assists), 0)::int,
  round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2),
  count(*) FILTER (WHERE m.is_player_of_match)::int,
  public.competition_player_clean_sheets(m.season_id, m.player_id, m.club_short_name, true),
  public.competition_player_ballon_points(
    count(*) FILTER (WHERE m.appeared)::int,
    coalesce(sum(m.goals), 0)::int,
    coalesce(sum(m.assists), 0)::int,
    round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2),
    count(*) FILTER (WHERE m.is_player_of_match)::int,
    public.competition_player_clean_sheets(m.season_id, m.player_id, m.club_short_name, true),
    public.competition_player_stat_role(p."Position")
  ),
  true,
  now()
FROM public.competition_match_player_stats m
JOIN public.competition_fixtures f ON f.id = m.fixture_id
JOIN public.competition_seasons s ON s.id = m.season_id
JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
LEFT JOIN public.competition_club_seasons ccs
  ON ccs.season_id = m.season_id AND ccs.club_short_name = m.club_short_name
WHERE s.is_current = true
  AND s.status = 'active'
  AND f.status = 'played'
  AND public.competition_fixture_counts_in_tables(f.id)
  AND NOT EXISTS (
    SELECT 1
    FROM public.competition_player_season_archive ar
    WHERE ar.season_id = m.season_id
      AND ar.player_id = m.player_id
      AND ar.club_short_name = m.club_short_name
  )
GROUP BY
  m.season_id, s.label, m.player_id, p."Name", m.club_short_name,
  c."Club", ccs.division, p."Position";

GRANT SELECT ON public.competition_player_career_public TO authenticated;
GRANT SELECT ON public.competition_player_career_public TO anon;

NOTIFY pgrst, 'reload schema';
