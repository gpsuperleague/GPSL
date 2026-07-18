-- Club history position charts: monthly (current season) + final positions (current + past 9).
-- Run in Supabase SQL Editor.

CREATE OR REPLACE FUNCTION public.competition_club_table_position_through_month(
  p_season_id bigint,
  p_division text,
  p_club_short_name text,
  p_gpsl_month text
)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_month_sort smallint;
  v_pos int;
BEGIN
  IF p_season_id IS NULL OR p_division IS NULL OR p_club_short_name IS NULL OR v_month = '' THEN
    RETURN NULL;
  END IF;

  v_month_sort := public.competition_gpsl_month_sort(v_month);
  IF v_month_sort IS NULL THEN
    RETURN NULL;
  END IF;

  WITH played AS (
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.division = p_division
      AND f.competition_type = 'league'
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND f.gpsl_month IS NOT NULL
      AND public.competition_gpsl_month_sort(lower(f.gpsl_month)) <= v_month_sort
  ),
  apps AS (
    SELECT
      home_club_short_name AS club_short_name,
      1 AS mp,
      CASE WHEN home_goals > away_goals THEN 3 WHEN home_goals = away_goals THEN 1 ELSE 0 END AS pts,
      home_goals - away_goals AS gd,
      home_goals AS gf
    FROM played
    UNION ALL
    SELECT
      away_club_short_name,
      1,
      CASE WHEN away_goals > home_goals THEN 3 WHEN away_goals = home_goals THEN 1 ELSE 0 END,
      away_goals - home_goals,
      away_goals
    FROM played
  ),
  totals AS (
    SELECT
      club_short_name,
      sum(mp)::int AS mp,
      sum(pts)::int AS pts,
      sum(gd)::int AS gd,
      sum(gf)::int AS gf
    FROM apps
    GROUP BY club_short_name
  ),
  registered AS (
    SELECT ccs.club_short_name, c."Club" AS club_name
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
    WHERE ccs.season_id = p_season_id
      AND ccs.division = p_division
  ),
  ranked AS (
    SELECT
      r.club_short_name,
      coalesce(t.mp, 0) AS mp,
      coalesce(t.pts, 0) AS pts,
      coalesce(t.gd, 0) AS gd,
      row_number() OVER (
        ORDER BY coalesce(t.pts, 0) DESC, coalesce(t.gd, 0) DESC, coalesce(t.gf, 0) DESC, r.club_name ASC
      )::int AS table_position
    FROM registered r
    LEFT JOIN totals t ON t.club_short_name = r.club_short_name
  )
  SELECT table_position INTO v_pos
  FROM ranked
  WHERE club_short_name = p_club_short_name;

  RETURN v_pos;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_club_position_charts(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(coalesce(p_club_short_name, ''));
  v_season_id bigint;
  v_season_label text;
  v_division text;
  v_division_size int := 0;
  v_active_month text;
  v_active_sort smallint;
  v_month text;
  v_month_sort smallint;
  v_pos int;
  v_mp int;
  v_pts int;
  v_gd int;
  v_avg_att numeric;
  v_home_games int;
  v_monthly jsonb := '[]'::jsonb;
  v_seasons jsonb := '[]'::jsonb;
  v_past jsonb := '[]'::jsonb;
  v_current_pos int;
  v_current_in_archive boolean := false;
  v_months text[] := ARRAY[
    'august','september','october','november','december',
    'january','february','march','april','may'
  ];
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN '{}'::jsonb;
  END IF;

  SELECT s.id, s.label
  INTO v_season_id, v_season_label
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NOT NULL THEN
    SELECT ccs.division
    INTO v_division
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND ccs.club_short_name = v_club
    LIMIT 1;

    IF v_division IS NOT NULL THEN
      SELECT count(*)::int
      INTO v_division_size
      FROM public.competition_club_seasons ccs
      WHERE ccs.season_id = v_season_id
        AND ccs.division = v_division;

      v_active_month := public.competition_active_gpsl_month(v_season_id, now());
      IF v_active_month IS NULL THEN
        -- Fallback: latest GPSL month with a played league game in this division
        SELECT lower(f.gpsl_month)
        INTO v_active_month
        FROM public.competition_fixtures f
        WHERE f.season_id = v_season_id
          AND f.division = v_division
          AND f.competition_type = 'league'
          AND f.status = 'played'
          AND f.home_goals IS NOT NULL
          AND f.away_goals IS NOT NULL
          AND f.gpsl_month IS NOT NULL
        ORDER BY public.competition_gpsl_month_sort(lower(f.gpsl_month)) DESC
        LIMIT 1;
      END IF;
      v_active_sort := coalesce(public.competition_gpsl_month_sort(v_active_month), 10);

      FOREACH v_month IN ARRAY v_months
      LOOP
        v_month_sort := public.competition_gpsl_month_sort(v_month);
        IF v_month_sort IS NULL OR v_month_sort > v_active_sort THEN
          CONTINUE;
        END IF;

        -- Skip months with no league games played yet in this division up to this point
        IF NOT EXISTS (
          SELECT 1
          FROM public.competition_fixtures f
          WHERE f.season_id = v_season_id
            AND f.division = v_division
            AND f.competition_type = 'league'
            AND f.status = 'played'
            AND f.home_goals IS NOT NULL
            AND f.away_goals IS NOT NULL
            AND f.gpsl_month IS NOT NULL
            AND public.competition_gpsl_month_sort(lower(f.gpsl_month)) <= v_month_sort
        ) THEN
          CONTINUE;
        END IF;

        v_pos := public.competition_club_table_position_through_month(
          v_season_id, v_division, v_club, v_month
        );

        SELECT
          coalesce(sum(x.mp), 0)::int,
          coalesce(sum(x.pts), 0)::int,
          coalesce(sum(x.gd), 0)::int
        INTO v_mp, v_pts, v_gd
        FROM (
          SELECT
            1 AS mp,
            CASE WHEN f.home_goals > f.away_goals THEN 3 WHEN f.home_goals = f.away_goals THEN 1 ELSE 0 END AS pts,
            f.home_goals - f.away_goals AS gd
          FROM public.competition_fixtures f
          WHERE f.season_id = v_season_id
            AND f.division = v_division
            AND f.competition_type = 'league'
            AND f.status = 'played'
            AND f.home_goals IS NOT NULL
            AND f.away_goals IS NOT NULL
            AND f.gpsl_month IS NOT NULL
            AND public.competition_gpsl_month_sort(lower(f.gpsl_month)) <= v_month_sort
            AND f.home_club_short_name = v_club
          UNION ALL
          SELECT
            1,
            CASE WHEN f.away_goals > f.home_goals THEN 3 WHEN f.away_goals = f.home_goals THEN 1 ELSE 0 END,
            f.away_goals - f.home_goals
          FROM public.competition_fixtures f
          WHERE f.season_id = v_season_id
            AND f.division = v_division
            AND f.competition_type = 'league'
            AND f.status = 'played'
            AND f.home_goals IS NOT NULL
            AND f.away_goals IS NOT NULL
            AND f.gpsl_month IS NOT NULL
            AND public.competition_gpsl_month_sort(lower(f.gpsl_month)) <= v_month_sort
            AND f.away_club_short_name = v_club
        ) x;

        -- Avg home attendance for league games in this GPSL month (capacity × attendance_rate)
        SELECT
          round(avg(
            coalesce((l.metadata ->> 'capacity')::numeric, 0)
            * coalesce((l.metadata ->> 'attendance_rate')::numeric, 0)
          ))::numeric,
          count(*)::int
        INTO v_avg_att, v_home_games
        FROM public.competition_finance_ledger l
        JOIN public.competition_fixtures f ON f.id = l.fixture_id
        WHERE l.season_id = v_season_id
          AND l.club_short_name = v_club
          AND l.entry_type = 'gate_league_home'
          AND f.competition_type = 'league'
          AND lower(f.gpsl_month) = v_month
          AND coalesce((l.metadata ->> 'capacity')::numeric, 0) > 0
          AND coalesce((l.metadata ->> 'attendance_rate')::numeric, 0) > 0;

        v_monthly := v_monthly || jsonb_build_array(
          jsonb_build_object(
            'gpsl_month', v_month,
            'month_label', public.competition_gpsl_month_label(v_month),
            'position', v_pos,
            'mp', v_mp,
            'pts', v_pts,
            'gd', v_gd,
            'avg_home_attendance', v_avg_att,
            'home_games', coalesce(v_home_games, 0)
          )
        );
      END LOOP;

      SELECT s.table_position
      INTO v_current_pos
      FROM public.competition_standings_public s
      WHERE s.season_id = v_season_id
        AND s.club_short_name = v_club
      LIMIT 1;
    END IF;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.competition_club_season_archive a
    WHERE a.club_short_name = v_club
      AND a.season_id IS NOT DISTINCT FROM v_season_id
  ) INTO v_current_in_archive;

  WITH recent AS (
    SELECT
      a.season_label,
      a.season_id,
      a.division,
      a.final_position,
      a.mp,
      a.pts,
      a.gd,
      a.created_at
    FROM public.competition_club_season_archive a
    WHERE a.club_short_name = v_club
      AND (
        v_season_id IS NULL
        OR v_current_in_archive
        OR a.season_id IS DISTINCT FROM v_season_id
      )
    ORDER BY coalesce(a.season_id, 0) DESC, a.season_label DESC, a.created_at DESC
    LIMIT CASE
      WHEN v_current_in_archive OR v_current_pos IS NULL THEN 10
      ELSE 9
    END
  )
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'season_label', r.season_label,
        'season_id', r.season_id,
        'division', r.division,
        'position', r.final_position,
        'is_current', (r.season_id IS NOT DISTINCT FROM v_season_id),
        'is_final', true,
        'mp', r.mp,
        'pts', r.pts,
        'gd', r.gd
      )
      ORDER BY coalesce(r.season_id, 0) ASC, r.season_label ASC
    ),
    '[]'::jsonb
  )
  INTO v_past
  FROM recent r;

  v_seasons := v_past;

  IF NOT v_current_in_archive AND v_current_pos IS NOT NULL AND v_season_id IS NOT NULL THEN
    v_seasons := v_seasons || jsonb_build_array(
      jsonb_build_object(
        'season_label', coalesce(v_season_label, 'Current'),
        'season_id', v_season_id,
        'division', v_division,
        'position', v_current_pos,
        'is_current', true,
        'is_final', false
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'season_id', v_season_id,
    'season_label', v_season_label,
    'division', v_division,
    'division_size', v_division_size,
    'active_month', v_active_month,
    'monthly', v_monthly,
    'seasons', v_seasons
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_club_table_position_through_month(bigint, text, text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_table_position_through_month(bigint, text, text, text)
  TO anon;
GRANT EXECUTE ON FUNCTION public.competition_club_position_charts(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_position_charts(text) TO anon;

COMMENT ON FUNCTION public.competition_club_position_charts(text) IS
  'Club history charts: league position by GPSL month (current season, with avg home attendance) and final positions for current + past 9 seasons.';
