-- Hold the line compares two finished league tables.
-- The gauge for a month is that division's table once the month has locked,
-- using games played in that month or earlier. It is only compared with the
-- previous month's gauge after both months have locked.
-- A club holds the place when its new position is the same or better
-- (a lower position number).

CREATE OR REPLACE FUNCTION public.competition_challenge_month_locked(
  p_season_id bigint,
  p_sort int
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = p_season_id
      AND public.competition_challenge_month_sort(cal.gpsl_month) = p_sort
      AND cal.lock_at <= now()
  );
$gpsl$;

REVOKE ALL ON FUNCTION public.competition_challenge_month_locked(bigint, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_challenge_month_locked(bigint, int)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.competition_challenge_league_pos(
  p_season_id bigint,
  p_club_short_name text,
  p_through_sort int
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
  WITH me AS (
    SELECT upper(btrim(coalesce(p_club_short_name, ''))) AS club
  ),
  div AS (
    SELECT ccs.division
    FROM public.competition_club_seasons ccs
    CROSS JOIN me
    WHERE ccs.season_id = p_season_id
      AND upper(btrim(ccs.club_short_name)) = me.club
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
    LIMIT 1
  ),
  cal AS (
    SELECT cal.lock_at
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = p_season_id
      AND public.competition_challenge_month_sort(cal.gpsl_month) = p_through_sort
    LIMIT 1
  ),
  registered AS (
    SELECT
      upper(btrim(ccs.club_short_name)) AS club,
      coalesce(nullif(btrim(c."Club"), ''), ccs.club_short_name) AS club_name
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
    JOIN div d ON d.division = ccs.division
    WHERE ccs.season_id = p_season_id
  ),
  played AS (
    SELECT
      upper(btrim(f.home_club_short_name)) AS home_club,
      upper(btrim(f.away_club_short_name)) AS away_club,
      f.home_goals AS hg,
      f.away_goals AS ag
    FROM public.competition_fixtures f
    JOIN div d ON d.division = f.division
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND public.competition_challenge_month_sort(f.gpsl_month) IS NOT NULL
      AND public.competition_challenge_month_sort(f.gpsl_month) <= p_through_sort
  ),
  totals AS (
    SELECT
      club,
      sum(gf)::int AS gf,
      sum(ga)::int AS ga,
      (sum(w) * 3 + sum(d))::int AS pts
    FROM (
      SELECT home_club AS club,
        CASE WHEN hg > ag THEN 1 ELSE 0 END AS w,
        CASE WHEN hg = ag THEN 1 ELSE 0 END AS d,
        hg AS gf, ag AS ga
      FROM played
      UNION ALL
      SELECT away_club,
        CASE WHEN ag > hg THEN 1 ELSE 0 END,
        CASE WHEN ag = hg THEN 1 ELSE 0 END,
        ag, hg
      FROM played
    ) s
    GROUP BY club
  ),
  point_adj AS (
    SELECT upper(btrim(a.club_short_name)) AS club, sum(a.points_delta)::int AS adj
    FROM public.competition_league_points_adjustments a
    JOIN cal ON a.created_at <= cal.lock_at
    WHERE a.season_id = p_season_id
    GROUP BY upper(btrim(a.club_short_name))
  ),
  ranked AS (
    SELECT
      r.club,
      row_number() OVER (
        ORDER BY
          (coalesce(t.pts, 0) + coalesce(pa.adj, 0)) DESC,
          (coalesce(t.gf, 0) - coalesce(t.ga, 0)) DESC,
          coalesce(t.gf, 0) DESC,
          r.club_name ASC
      )::int AS rnk
    FROM registered r
    LEFT JOIN totals t ON t.club = r.club
    LEFT JOIN point_adj pa ON pa.club = r.club
  )
  SELECT ranked.rnk
  FROM ranked
  JOIN me ON me.club = ranked.club;
$gpsl$;

REVOKE ALL ON FUNCTION public.competition_challenge_league_pos(bigint, text, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_challenge_league_pos(bigint, text, int)
  TO authenticated, service_role;

DO $patch$
DECLARE
  v_def text;
  v_old text := $old$  IF p_stat_type = 'league_position_held' THEN
    FOR v_sort IN v_from..v_to LOOP
      IF v_sort < 1 THEN
        CONTINUE;
      END IF;
      v_now := public.competition_challenge_league_pos(p_season_id, v_club, v_sort);
      v_prev := public.competition_challenge_league_pos(p_season_id, v_club, v_sort - 1);
      IF v_now IS NOT NULL AND v_prev IS NOT NULL AND v_now <= v_prev THEN
        v_val := v_val + 1;
      END IF;
    END LOOP;
    RETURN v_val;
  END IF;$old$;
  v_new text := $new$  IF p_stat_type = 'league_position_held' THEN
    FOR v_sort IN v_from..v_to LOOP
      IF v_sort < 1 THEN
        CONTINUE;
      END IF;
      -- End-of-month gauge, then the month before. Skip until both have locked.
      IF NOT public.competition_challenge_month_locked(p_season_id, v_sort)
         OR NOT public.competition_challenge_month_locked(p_season_id, v_sort - 1) THEN
        CONTINUE;
      END IF;
      v_now := public.competition_challenge_league_pos(p_season_id, v_club, v_sort);
      v_prev := public.competition_challenge_league_pos(p_season_id, v_club, v_sort - 1);
      IF v_now IS NOT NULL AND v_prev IS NOT NULL AND v_now <= v_prev THEN
        v_val := v_val + 1;
      END IF;
    END LOOP;
    RETURN v_val;
  END IF;$new$;
BEGIN
  v_def := replace(
    pg_get_functiondef(
      'public.competition_challenge_extra_stat_value(bigint,text,text,text,text,boolean,boolean,text)'::regprocedure
    ),
    E'\r\n',
    E'\n'
  );
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'league_position_held block not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$patch$;

DO $check$
DECLARE
  v_held int;
BEGIN
  IF public.competition_challenge_month_locked(1, 9) THEN
    RAISE EXCEPTION 'March is locked; the zero check does not apply';
  END IF;
  v_held := public.competition_challenge_extra_stat_value(
    1, 'PSG', 'league_position_held', 'march', 'march', true, false, NULL
  );
  IF v_held IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'Hold the line still scores before March locks: %', v_held;
  END IF;
END;
$check$;

SELECT 'ready' AS ready;
