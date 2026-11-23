-- New season-challenge stats.
-- Safe re-run.

ALTER TABLE public.competition_challenge_config
  DROP CONSTRAINT IF EXISTS competition_challenge_config_stat_type_check;

ALTER TABLE public.competition_challenge_config
  ADD CONSTRAINT competition_challenge_config_stat_type_check
  CHECK (
    stat_type IN (
      'player_max_goals',
      'player_max_assists',
      'club_wins',
      'club_goals_for',
      'club_clean_sheets',
      'club_potm_awards',
      'transfer_sign_nation',
      'transfer_sign_homegrown',
      'transfer_sign_rated',
      'player_hattrick_matchday',
      'match_hg_xi_unbeaten',
      'match_defender_goal_unbeaten',
      'league_position_held',
      'player_max_gk_clean_sheets',
      'match_win_by_3_spread',
      'transfer_sell_foreign_window',
      'unbeaten_run_scheduled',
      'match_u21_xi',
      'match_young_xi'
    )
  );

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
  WITH games AS (
    SELECT
      upper(btrim(f.home_club_short_name)) AS home_club,
      upper(btrim(f.away_club_short_name)) AS away_club,
      coalesce(f.home_goals, 0) AS hg,
      coalesce(f.away_goals, 0) AS ag
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'played'
      AND coalesce(f.is_void, false) = false
      AND public.competition_challenge_month_sort(f.gpsl_month) IS NOT NULL
      AND public.competition_challenge_month_sort(f.gpsl_month) <= p_through_sort
  ),
  rows AS (
    SELECT club, sum(pts)::int AS pts, sum(gf)::int AS gf, sum(ga)::int AS ga
    FROM (
      SELECT home_club AS club,
        CASE WHEN hg > ag THEN 3 WHEN hg = ag THEN 1 ELSE 0 END AS pts,
        hg AS gf, ag AS ga
      FROM games
      UNION ALL
      SELECT away_club,
        CASE WHEN ag > hg THEN 3 WHEN ag = hg THEN 1 ELSE 0 END,
        ag, hg
      FROM games
    ) s
    GROUP BY club
  ),
  ranked AS (
    SELECT club,
      rank() OVER (ORDER BY pts DESC, (gf - ga) DESC, gf DESC, club) AS rnk
    FROM rows
  )
  SELECT rnk::int
  FROM ranked
  WHERE club = upper(btrim(coalesce(p_club_short_name, '')));
$gpsl$;

CREATE OR REPLACE FUNCTION public.competition_challenge_extra_stat_value(
  p_season_id bigint,
  p_club_short_name text,
  p_stat_type text,
  p_month_from text,
  p_month_to text,
  p_include_league boolean,
  p_include_cup boolean,
  p_stat_param text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '20s'
AS $gpsl$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_from int := public.competition_challenge_month_sort(p_month_from);
  v_to int := public.competition_challenge_month_sort(p_month_to);
  v_types text[];
  v_val int := 0;
  v_sort int;
  v_now int;
  v_prev int;
  v_bounds record;
BEGIN
  IF v_club = '' OR v_from IS NULL OR v_to IS NULL THEN
    RETURN 0;
  END IF;

  IF p_stat_type = 'league_position_held' THEN
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
  END IF;

  IF p_stat_type = 'transfer_sell_foreign_window' THEN
    SELECT * INTO v_bounds
    FROM public.competition_challenge_window_bounds(p_season_id, p_month_from, p_month_to);

    SELECT count(*)::int INTO v_val
    FROM public."Transfer_History" h
    JOIN public.competition_season_calendar cal
      ON cal.season_id = p_season_id
     AND h.transfer_time >= cal.unlock_at
     AND h.transfer_time < cal.lock_at
    WHERE upper(btrim(h.seller_club_id)) = v_club
      AND upper(btrim(h.buyer_club_id)) = 'FOREIGN'
      AND lower(btrim(cal.gpsl_month)) IN ('june', 'july', 'august', 'january')
      AND public.competition_challenge_month_sort(cal.gpsl_month) BETWEEN v_from AND v_to
      AND h.transfer_time >= v_bounds.window_start
      AND h.transfer_time <= v_bounds.window_end;

    RETURN coalesce(v_val, 0);
  END IF;

  v_types := public.competition_challenge_comp_types(p_include_league, p_include_cup);
  IF v_types = ARRAY[]::text[] THEN
    RETURN 0;
  END IF;

  IF p_stat_type = 'player_max_gk_clean_sheets' THEN
    SELECT coalesce(max(x.cs), 0)::int INTO v_val
    FROM (
      SELECT m.player_id, count(DISTINCT m.fixture_id)::int AS cs
      FROM public.competition_match_player_stats m
      JOIN public.competition_fixtures f ON f.id = m.fixture_id
      JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
      WHERE m.season_id = p_season_id
        AND upper(btrim(m.club_short_name)) = v_club
        AND coalesce(m.started, false)
        AND upper(btrim(p."Position")) IN ('GK', 'GOALKEEPER')
        AND f.status = 'played'
        AND coalesce(f.is_void, false) = false
        AND f.competition_type = ANY (v_types)
        AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
        AND CASE
              WHEN upper(btrim(f.home_club_short_name)) = v_club THEN coalesce(f.away_goals, 0)
              ELSE coalesce(f.home_goals, 0)
            END = 0
      GROUP BY m.player_id
    ) x;
    RETURN coalesce(v_val, 0);
  END IF;

  IF p_stat_type = 'unbeaten_run_scheduled' THEN
    WITH played AS (
      SELECT
        row_number() OVER (
          ORDER BY (
            SELECT s.agreed_kickoff_at
            FROM public.competition_fixture_schedule s
            WHERE s.fixture_id = f.id
              AND s.status = 'agreed'
            ORDER BY s.agreed_kickoff_at
            LIMIT 1
          ) NULLS LAST,
            public.competition_challenge_month_sort(f.gpsl_month),
            f.matchday NULLS LAST,
            f.id
        ) AS rn,
        CASE
          WHEN upper(btrim(f.home_club_short_name)) = v_club
            THEN coalesce(f.home_goals, 0) >= coalesce(f.away_goals, 0)
          ELSE coalesce(f.away_goals, 0) >= coalesce(f.home_goals, 0)
        END AS unbeaten
      FROM public.competition_fixtures f
      WHERE f.season_id = p_season_id
        AND f.status = 'played'
        AND coalesce(f.is_void, false) = false
        AND f.competition_type = ANY (v_types)
        AND v_club IN (
          upper(btrim(f.home_club_short_name)),
          upper(btrim(f.away_club_short_name))
        )
        AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
    ),
    marked AS (
      SELECT rn, unbeaten,
        sum(CASE WHEN unbeaten THEN 0 ELSE 1 END) OVER (ORDER BY rn) AS grp
      FROM played
    )
    SELECT coalesce(max(n), 0)::int INTO v_val
    FROM (
      SELECT count(*)::int AS n
      FROM marked
      WHERE unbeaten
      GROUP BY grp
    ) s;
    RETURN coalesce(v_val, 0);
  END IF;

  IF p_stat_type = 'match_hg_xi_unbeaten' THEN
    SELECT count(*)::int INTO v_val
    FROM public.competition_fixtures f
    JOIN public."Clubs" c ON upper(btrim(c."ShortName")) = v_club
    WHERE f.season_id = p_season_id
      AND f.status = 'played'
      AND coalesce(f.is_void, false) = false
      AND f.competition_type = ANY (v_types)
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
      AND CASE
            WHEN upper(btrim(f.home_club_short_name)) = v_club
              THEN coalesce(f.home_goals, 0) >= coalesce(f.away_goals, 0)
            ELSE coalesce(f.away_goals, 0) >= coalesce(f.home_goals, 0)
          END
      AND (
        SELECT count(*)
        FROM public.competition_match_player_stats m
        JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
        WHERE m.fixture_id = f.id
          AND upper(btrim(m.club_short_name)) = v_club
          AND coalesce(m.started, false)
          AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
          AND public.normalize_nation_key(p."Nation") <> ''
      ) >= 5;
    RETURN coalesce(v_val, 0);
  END IF;

  IF p_stat_type = 'match_defender_goal_unbeaten' THEN
    SELECT count(*)::int INTO v_val
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.status = 'played'
      AND coalesce(f.is_void, false) = false
      AND f.competition_type = ANY (v_types)
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
      AND CASE
            WHEN upper(btrim(f.home_club_short_name)) = v_club
              THEN coalesce(f.home_goals, 0) >= coalesce(f.away_goals, 0)
            ELSE coalesce(f.away_goals, 0) >= coalesce(f.home_goals, 0)
          END
      AND EXISTS (
        SELECT 1
        FROM public.competition_match_player_stats m
        JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
        WHERE m.fixture_id = f.id
          AND upper(btrim(m.club_short_name)) = v_club
          AND coalesce(m.goals, 0) > 0
          AND upper(btrim(p."Position")) IN ('CB', 'LB', 'RB', 'LWB', 'RWB')
      );
    RETURN coalesce(v_val, 0);
  END IF;

  IF p_stat_type = 'match_win_by_3_spread' THEN
    SELECT count(*)::int INTO v_val
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.status = 'played'
      AND coalesce(f.is_void, false) = false
      AND f.competition_type = ANY (v_types)
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
      AND CASE
            WHEN upper(btrim(f.home_club_short_name)) = v_club
              THEN coalesce(f.home_goals, 0) - coalesce(f.away_goals, 0)
            ELSE coalesce(f.away_goals, 0) - coalesce(f.home_goals, 0)
          END >= 3
      AND (
        SELECT count(DISTINCT m.player_id)
        FROM public.competition_match_player_stats m
        WHERE m.fixture_id = f.id
          AND upper(btrim(m.club_short_name)) = v_club
          AND coalesce(m.goals, 0) > 0
      ) >= 3
      AND (
        SELECT count(DISTINCT m.player_id)
        FROM public.competition_match_player_stats m
        WHERE m.fixture_id = f.id
          AND upper(btrim(m.club_short_name)) = v_club
          AND coalesce(m.assists, 0) > 0
      ) >= 3;
    RETURN coalesce(v_val, 0);
  END IF;

  IF p_stat_type = 'match_u21_xi' THEN
    SELECT count(*)::int INTO v_val
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.status = 'played'
      AND coalesce(f.is_void, false) = false
      AND f.competition_type = ANY (v_types)
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
      AND (
        SELECT count(*)
        FROM public.competition_match_player_stats m
        JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
        WHERE m.fixture_id = f.id
          AND upper(btrim(m.club_short_name)) = v_club
          AND coalesce(m.started, false)
          AND btrim(coalesce(p."Age"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
          AND btrim(p."Age"::text)::numeric <= 21
      ) >= 3;
    RETURN coalesce(v_val, 0);
  END IF;

  IF p_stat_type = 'match_young_xi' THEN
    SELECT count(*)::int INTO v_val
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.status = 'played'
      AND coalesce(f.is_void, false) = false
      AND f.competition_type = ANY (v_types)
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
      AND (
        SELECT count(*) >= 8 AND avg(btrim(p."Age"::text)::numeric) < 25
        FROM public.competition_match_player_stats m
        JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
        WHERE m.fixture_id = f.id
          AND upper(btrim(m.club_short_name)) = v_club
          AND coalesce(m.started, false)
          AND btrim(coalesce(p."Age"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
      );
    RETURN coalesce(v_val, 0);
  END IF;

  RETURN 0;
END;
$gpsl$;

REVOKE ALL ON FUNCTION public.competition_challenge_extra_stat_value(bigint, text, text, text, text, boolean, boolean, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_challenge_extra_stat_value(bigint, text, text, text, text, boolean, boolean, text)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.competition_challenge_league_pos(bigint, text, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_challenge_league_pos(bigint, text, int)
  TO authenticated, service_role;

DO $patch$
DECLARE
  v_def text;
  v_old text := $old$  v_to_sort := public.competition_challenge_month_sort(p_month_to);

  -- ---- Transfer: specific nationality ----$old$;
  v_new text := $new$  v_to_sort := public.competition_challenge_month_sort(p_month_to);

  IF p_stat_type IN (
    'match_hg_xi_unbeaten',
    'match_defender_goal_unbeaten',
    'league_position_held',
    'player_max_gk_clean_sheets',
    'match_win_by_3_spread',
    'transfer_sell_foreign_window',
    'unbeaten_run_scheduled',
    'match_u21_xi',
    'match_young_xi'
  ) THEN
    RETURN public.competition_challenge_extra_stat_value(
      p_season_id, p_club_short_name, p_stat_type,
      p_month_from, p_month_to, p_include_league, p_include_cup, p_stat_param
    );
  END IF;

  -- ---- Transfer: specific nationality ----$new$;
BEGIN
  v_old := replace(replace(v_old, E'\r\n', E'\n'), E'\r', E'\n');
  v_new := replace(replace(v_new, E'\r\n', E'\n'), E'\r', E'\n');
  v_def := replace(replace(
    pg_get_functiondef('public.competition_challenge_stat_value(bigint,text,text,text,text,boolean,boolean,text)'::regprocedure),
    E'\r\n', E'\n'), E'\r', E'\n');
  IF position('competition_challenge_extra_stat_value' IN v_def) > 0 THEN
    RAISE NOTICE 'stat value already calls extra';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'challenge stat value needle missing';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  v_def := replace(v_def, '$function$', '$gpsl$');
  IF right(v_def, 1) <> ';' THEN
    v_def := v_def || ';';
  END IF;
  EXECUTE v_def;
END;
$patch$;

SELECT jsonb_build_object(
  'extra', to_regprocedure('public.competition_challenge_extra_stat_value(bigint,text,text,text,text,boolean,boolean,text)') IS NOT NULL,
  'wired', position(
    'competition_challenge_extra_stat_value' IN pg_get_functiondef(
      'public.competition_challenge_stat_value(bigint,text,text,text,text,boolean,boolean,text)'::regprocedure
    )
  ) > 0
) AS ready;
