-- How each seasonal challenge was won: the matches or signings that counted,
-- plus the players when a player did the work. Read by the challenges page.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.competition_challenge_win_stories()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_out jsonb := '[]'::jsonb;
  r record;
  v_types text[];
  v_from int;
  v_to int;
  v_bounds record;
  v_rated jsonb;
  v_events jsonb;
  v_players jsonb;
  v_event_count int;
  v_player_count int;
  v_headline text;
  v_detail text;
BEGIN
  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  FOR r IN
    SELECT
      a.challenge_id,
      a.club_short_name,
      a.amount,
      a.stat_value,
      a.awarded_at,
      c.title,
      c.window_phase,
      c.stat_type,
      c.stat_param,
      c.gpsl_month_from,
      c.gpsl_month_to,
      c.include_league,
      c.include_cup,
      c.target_value,
      cl."Club" AS club_name
    FROM public.competition_challenge_awarded a
    JOIN public.competition_challenge_config c ON c.id = a.challenge_id
    JOIN public."Clubs" cl ON cl."ShortName" = a.club_short_name
    WHERE a.season_id = v_season
    ORDER BY a.awarded_at DESC, a.challenge_id, a.club_short_name
  LOOP
    v_events := '[]'::jsonb;
    v_players := '[]'::jsonb;
    v_event_count := 0;
    v_player_count := 0;
    v_headline := NULL;
    v_detail := NULL;
    v_types := public.competition_challenge_comp_types(r.include_league, r.include_cup);
    v_from := public.competition_challenge_month_sort(r.gpsl_month_from);
    v_to := public.competition_challenge_month_sort(r.gpsl_month_to);

    BEGIN
      IF r.stat_type = 'club_clean_sheets' THEN
        v_headline := format('%s clean %s', r.stat_value, CASE WHEN r.stat_value = 1 THEN 'sheet' ELSE 'sheets' END);
        v_detail := format(
          'Kept a clean sheet in %s %s.',
          r.stat_value,
          CASE WHEN r.stat_value = 1 THEN 'match' ELSE 'matches' END
        );
        SELECT count(*)::int INTO v_event_count
        FROM public.competition_fixtures f
        WHERE f.season_id = v_season AND f.status = 'played'
          AND f.competition_type = ANY (v_types)
          AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
          AND (
            (f.home_club_short_name = r.club_short_name AND f.away_goals = 0)
            OR (f.away_club_short_name = r.club_short_name AND f.home_goals = 0)
          );
        SELECT coalesce(jsonb_agg(x ORDER BY ord), '[]'::jsonb) INTO v_events
        FROM (
          SELECT jsonb_build_object(
            'kind', 'match',
            'when', f.result_posted_at,
            'month', initcap(f.gpsl_month),
            'competition', f.competition_type,
            'matchday', f.matchday,
            'home', f.home_club_short_name,
            'away', f.away_club_short_name,
            'home_goals', f.home_goals,
            'away_goals', f.away_goals,
            'note', 'Clean sheet'
          ) AS x, f.result_posted_at AS ord
          FROM public.competition_fixtures f
          WHERE f.season_id = v_season AND f.status = 'played'
            AND f.competition_type = ANY (v_types)
            AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
            AND (
              (f.home_club_short_name = r.club_short_name AND f.away_goals = 0)
              OR (f.away_club_short_name = r.club_short_name AND f.home_goals = 0)
            )
          ORDER BY f.result_posted_at NULLS LAST, f.id
          LIMIT 8
        ) q;

      ELSIF r.stat_type = 'club_wins' THEN
        v_headline := format('%s %s', r.stat_value, CASE WHEN r.stat_value = 1 THEN 'win' ELSE 'wins' END);
        v_detail := format('Won %s in the challenge window.', CASE WHEN r.stat_value = 1 THEN 'the match' ELSE format('%s matches', r.stat_value) END);
        SELECT count(*)::int INTO v_event_count
        FROM public.competition_fixtures f
        WHERE f.season_id = v_season AND f.status = 'played'
          AND f.competition_type = ANY (v_types)
          AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
          AND (
            (f.home_club_short_name = r.club_short_name AND f.home_goals > f.away_goals)
            OR (f.away_club_short_name = r.club_short_name AND f.away_goals > f.home_goals)
          );
        SELECT coalesce(jsonb_agg(x ORDER BY ord), '[]'::jsonb) INTO v_events
        FROM (
          SELECT jsonb_build_object(
            'kind', 'match', 'when', f.result_posted_at, 'month', initcap(f.gpsl_month),
            'competition', f.competition_type, 'matchday', f.matchday,
            'home', f.home_club_short_name, 'away', f.away_club_short_name,
            'home_goals', f.home_goals, 'away_goals', f.away_goals, 'note', 'Win'
          ) AS x, f.result_posted_at AS ord
          FROM public.competition_fixtures f
          WHERE f.season_id = v_season AND f.status = 'played'
            AND f.competition_type = ANY (v_types)
            AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
            AND (
              (f.home_club_short_name = r.club_short_name AND f.home_goals > f.away_goals)
              OR (f.away_club_short_name = r.club_short_name AND f.away_goals > f.home_goals)
            )
          ORDER BY f.result_posted_at NULLS LAST, f.id
          LIMIT 8
        ) q;

      ELSIF r.stat_type = 'club_goals_for' THEN
        v_headline := format('%s goals', r.stat_value);
        v_detail := format('Scored %s goals in the challenge window.', r.stat_value);
        SELECT coalesce(jsonb_agg(x ORDER BY goals DESC), '[]'::jsonb) INTO v_players
        FROM (
          SELECT jsonb_build_object(
            'konami_id', p."Konami_ID"::text,
            'name', p."Name",
            'rating', p."Rating",
            'age', p."Age",
            'nation', p."Nation",
            'goals', t.goals,
            'assists', t.assists,
            'potm', t.potm,
            'note', format('%s in the window', CASE WHEN t.goals = 1 THEN '1 goal' ELSE format('%s goals', t.goals) END)
          ) AS x, t.goals
          FROM (
            SELECT m.player_id,
              coalesce(sum(m.goals), 0)::int AS goals,
              coalesce(sum(m.assists), 0)::int AS assists,
              count(*) FILTER (WHERE m.is_player_of_match)::int AS potm
            FROM public.competition_match_player_stats m
            JOIN public.competition_fixtures f ON f.id = m.fixture_id
            WHERE m.season_id = v_season
              AND m.club_short_name = r.club_short_name
              AND f.status = 'played'
              AND f.competition_type = ANY (v_types)
              AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
            GROUP BY m.player_id
            HAVING coalesce(sum(m.goals), 0) > 0
            ORDER BY sum(m.goals) DESC, sum(m.assists) DESC
            LIMIT 4
          ) t
          LEFT JOIN public."Players" p ON p."Konami_ID"::text = t.player_id
        ) q;
        SELECT count(*)::int INTO v_player_count
        FROM (
          SELECT m.player_id
          FROM public.competition_match_player_stats m
          JOIN public.competition_fixtures f ON f.id = m.fixture_id
          WHERE m.season_id = v_season
            AND m.club_short_name = r.club_short_name
            AND f.status = 'played'
            AND f.competition_type = ANY (v_types)
            AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
          GROUP BY m.player_id
          HAVING coalesce(sum(m.goals), 0) > 0
        ) t;

      ELSIF r.stat_type = 'club_potm_awards' THEN
        v_headline := format('%s player-of-the-match %s', r.stat_value, CASE WHEN r.stat_value = 1 THEN 'award' ELSE 'awards' END);
        v_detail := 'Player of the match in the challenge window.';
        SELECT count(*)::int INTO v_player_count
        FROM (
          SELECT m.player_id
          FROM public.competition_match_player_stats m
          JOIN public.competition_fixtures f ON f.id = m.fixture_id
          WHERE m.season_id = v_season
            AND m.club_short_name = r.club_short_name
            AND m.is_player_of_match = true
            AND f.status = 'played'
            AND f.competition_type = ANY (v_types)
            AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
          GROUP BY m.player_id
        ) t;
        SELECT coalesce(jsonb_agg(x ORDER BY potm DESC), '[]'::jsonb) INTO v_players
        FROM (
          SELECT jsonb_build_object(
            'konami_id', p."Konami_ID"::text,
            'name', coalesce(p."Name", t.player_id),
            'rating', p."Rating",
            'age', p."Age",
            'nation', p."Nation",
            'goals', t.goals,
            'assists', t.assists,
            'potm', t.potm,
            'note', format('%s player-of-the-match %s', t.potm, CASE WHEN t.potm = 1 THEN 'award' ELSE 'awards' END)
          ) AS x, t.potm
          FROM (
            SELECT m.player_id,
              coalesce(sum(m.goals), 0)::int AS goals,
              coalesce(sum(m.assists), 0)::int AS assists,
              count(*)::int AS potm
            FROM public.competition_match_player_stats m
            JOIN public.competition_fixtures f ON f.id = m.fixture_id
            WHERE m.season_id = v_season
              AND m.club_short_name = r.club_short_name
              AND m.is_player_of_match = true
              AND f.status = 'played'
              AND f.competition_type = ANY (v_types)
              AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
            GROUP BY m.player_id
            ORDER BY count(*) DESC, sum(m.goals) DESC
            LIMIT 6
          ) t
          LEFT JOIN public."Players" p ON p."Konami_ID"::text = t.player_id
        ) q;

      ELSIF r.stat_type IN ('player_max_goals', 'player_max_assists') THEN
        v_headline := CASE
          WHEN r.stat_type = 'player_max_goals' THEN format('A player reached %s goals', r.target_value)
          ELSE format('A player reached %s assists', r.target_value)
        END;
        v_detail := v_headline || ' in the challenge window.';
        SELECT count(*)::int INTO v_player_count
        FROM (
          SELECT m.player_id
          FROM public.competition_match_player_stats m
          JOIN public.competition_fixtures f ON f.id = m.fixture_id
          WHERE m.season_id = v_season
            AND m.club_short_name = r.club_short_name
            AND f.status = 'played'
            AND f.competition_type = ANY (v_types)
            AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
          GROUP BY m.player_id
          HAVING (
            r.stat_type = 'player_max_goals' AND coalesce(sum(m.goals), 0) >= r.target_value
          ) OR (
            r.stat_type = 'player_max_assists' AND coalesce(sum(m.assists), 0) >= r.target_value
          )
        ) t;
        SELECT coalesce(jsonb_agg(x ORDER BY sort_key DESC), '[]'::jsonb) INTO v_players
        FROM (
          SELECT jsonb_build_object(
            'konami_id', p."Konami_ID"::text,
            'name', coalesce(p."Name", t.player_id),
            'rating', p."Rating",
            'age', p."Age",
            'nation', p."Nation",
            'goals', t.goals,
            'assists', t.assists,
            'potm', t.potm,
            'note', CASE
              WHEN r.stat_type = 'player_max_goals' THEN format('%s goals in the window', t.goals)
              ELSE format('%s assists in the window', t.assists)
            END
          ) AS x,
          CASE WHEN r.stat_type = 'player_max_goals' THEN t.goals ELSE t.assists END AS sort_key
          FROM (
            SELECT m.player_id,
              coalesce(sum(m.goals), 0)::int AS goals,
              coalesce(sum(m.assists), 0)::int AS assists,
              count(*) FILTER (WHERE m.is_player_of_match)::int AS potm
            FROM public.competition_match_player_stats m
            JOIN public.competition_fixtures f ON f.id = m.fixture_id
            WHERE m.season_id = v_season
              AND m.club_short_name = r.club_short_name
              AND f.status = 'played'
              AND f.competition_type = ANY (v_types)
              AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
            GROUP BY m.player_id
            HAVING (
              r.stat_type = 'player_max_goals' AND coalesce(sum(m.goals), 0) >= r.target_value
            ) OR (
              r.stat_type = 'player_max_assists' AND coalesce(sum(m.assists), 0) >= r.target_value
            )
            ORDER BY
              CASE WHEN r.stat_type = 'player_max_goals' THEN sum(m.goals) ELSE sum(m.assists) END DESC
            LIMIT 4
          ) t
          LEFT JOIN public."Players" p ON p."Konami_ID"::text = t.player_id
        ) q;

      ELSIF r.stat_type = 'player_hattrick_matchday' THEN
        v_headline := format('Hat-trick on matchday %s', coalesce(r.stat_param, '?'));
        v_detail := v_headline || '.';
        SELECT count(*)::int INTO v_player_count
        FROM (
          SELECT DISTINCT m.player_id
          FROM public.competition_match_player_stats m
          JOIN public.competition_fixtures f ON f.id = m.fixture_id
          WHERE m.season_id = v_season
            AND m.club_short_name = r.club_short_name
            AND coalesce(m.goals, 0) >= 3
            AND f.status = 'played'
            AND f.competition_type = ANY (v_types)
            AND f.matchday = nullif(regexp_replace(coalesce(r.stat_param, ''), '[^0-9]', '', 'g'), '')::int
            AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
        ) t;
        SELECT coalesce(jsonb_agg(x ORDER BY goals DESC), '[]'::jsonb) INTO v_players
        FROM (
          SELECT jsonb_build_object(
            'konami_id', p."Konami_ID"::text,
            'name', coalesce(p."Name", t.player_id),
            'rating', p."Rating",
            'age', p."Age",
            'nation', p."Nation",
            'goals', t.goals,
            'assists', t.assists,
            'note', format(
              'Hat-trick, %s %s–%s %s',
              t.home, t.home_goals, t.away_goals, t.away
            )
          ) AS x, t.goals
          FROM (
            SELECT DISTINCT ON (m.player_id)
              m.player_id, m.goals, m.assists,
              f.home_club_short_name AS home, f.away_club_short_name AS away,
              f.home_goals, f.away_goals
            FROM public.competition_match_player_stats m
            JOIN public.competition_fixtures f ON f.id = m.fixture_id
            WHERE m.season_id = v_season
              AND m.club_short_name = r.club_short_name
              AND coalesce(m.goals, 0) >= 3
              AND f.status = 'played'
              AND f.competition_type = ANY (v_types)
              AND f.matchday = nullif(regexp_replace(coalesce(r.stat_param, ''), '[^0-9]', '', 'g'), '')::int
              AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from AND v_to
            ORDER BY m.player_id, m.goals DESC
            LIMIT 4
          ) t
          LEFT JOIN public."Players" p ON p."Konami_ID"::text = t.player_id
        ) q;

      ELSIF r.stat_type IN ('transfer_sign_nation', 'transfer_sign_homegrown', 'transfer_sign_rated') THEN
        SELECT * INTO v_bounds
        FROM public.competition_challenge_window_bounds(v_season, r.gpsl_month_from, r.gpsl_month_to);

        IF r.stat_type = 'transfer_sign_rated' THEN
          v_rated := public.competition_challenge_parse_rated_param(r.stat_param);
        END IF;

        v_headline := format('%s matching %s', r.stat_value, CASE WHEN r.stat_value = 1 THEN 'signing' ELSE 'signings' END);
        v_detail := 'These signings counted toward the challenge.';

        SELECT count(*)::int INTO v_player_count
        FROM public."Transfer_History" h
        JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
        JOIN public."Clubs" c ON c."ShortName" = h.buyer_club_id
        WHERE h.buyer_club_id = r.club_short_name
          AND h.buyer_club_id IS DISTINCT FROM 'FOREIGN'
          AND h.transfer_time >= v_bounds.window_start
          AND h.transfer_time <= v_bounds.window_end
          AND (
            (r.stat_type = 'transfer_sign_nation'
              AND public.competition_challenge_nation_matches(p."Nation", upper(btrim(coalesce(r.stat_param, '')))))
            OR (r.stat_type = 'transfer_sign_homegrown'
              AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
              AND public.normalize_nation_key(p."Nation") <> '')
            OR (r.stat_type = 'transfer_sign_rated'
              AND public.player_rating_as_numeric(p."Rating"::text) > 0
              AND public.player_rating_as_numeric(p."Rating"::text) <= (v_rated->>'max_rating')::int
              AND (
                NOT coalesce((v_rated->>'require_age')::boolean, false)
                OR (p."Age" IS NOT NULL AND btrim(p."Age"::text) <> '' AND btrim(p."Age"::text)::numeric <= coalesce((v_rated->>'max_age')::int, 21))
              )
              AND (
                NOT coalesce((v_rated->>'require_hg')::boolean, false)
                OR (
                  public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
                  AND public.normalize_nation_key(p."Nation") <> ''
                )
              ))
          );

        SELECT coalesce(jsonb_agg(x ORDER BY signed_at), '[]'::jsonb) INTO v_players
        FROM (
          SELECT jsonb_build_object(
            'konami_id', p."Konami_ID"::text,
            'name', p."Name",
            'rating', p."Rating",
            'age', p."Age",
            'nation', p."Nation",
            'note', format('Signed %s', to_char(h.transfer_time AT TIME ZONE 'Europe/London', 'DD Mon YYYY'))
          ) AS x, h.transfer_time AS signed_at
          FROM public."Transfer_History" h
          JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
          JOIN public."Clubs" c ON c."ShortName" = h.buyer_club_id
          WHERE h.buyer_club_id = r.club_short_name
            AND h.buyer_club_id IS DISTINCT FROM 'FOREIGN'
            AND h.transfer_time >= v_bounds.window_start
            AND h.transfer_time <= v_bounds.window_end
            AND (
              (r.stat_type = 'transfer_sign_nation'
                AND public.competition_challenge_nation_matches(p."Nation", upper(btrim(coalesce(r.stat_param, '')))))
              OR (r.stat_type = 'transfer_sign_homegrown'
                AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
                AND public.normalize_nation_key(p."Nation") <> '')
              OR (r.stat_type = 'transfer_sign_rated'
                AND public.player_rating_as_numeric(p."Rating"::text) > 0
                AND public.player_rating_as_numeric(p."Rating"::text) <= (v_rated->>'max_rating')::int
                AND (
                  NOT coalesce((v_rated->>'require_age')::boolean, false)
                  OR (p."Age" IS NOT NULL AND btrim(p."Age"::text) <> '' AND btrim(p."Age"::text)::numeric <= coalesce((v_rated->>'max_age')::int, 21))
                )
                AND (
                  NOT coalesce((v_rated->>'require_hg')::boolean, false)
                  OR (
                    public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
                    AND public.normalize_nation_key(p."Nation") <> ''
                  )
                ))
            )
          ORDER BY h.transfer_time
          LIMIT 6
        ) q;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_events := '[]'::jsonb;
      v_players := '[]'::jsonb;
      v_detail := NULL;
    END;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'challenge_id', r.challenge_id,
      'title', r.title,
      'window_phase', r.window_phase,
      'club_short_name', r.club_short_name,
      'club_name', r.club_name,
      'amount', r.amount,
      'stat_value', r.stat_value,
      'target_value', r.target_value,
      'awarded_at', r.awarded_at,
      'headline', coalesce(v_headline, r.title),
      'detail', v_detail,
      'events', coalesce(v_events, '[]'::jsonb),
      'players', coalesce(v_players, '[]'::jsonb),
      'more_events', greatest(coalesce(v_event_count, 0) - coalesce(jsonb_array_length(v_events), 0), 0),
      'more_players', greatest(coalesce(v_player_count, 0) - coalesce(jsonb_array_length(v_players), 0), 0)
    ));
  END LOOP;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_challenge_win_stories() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.competition_challenge_win_stories() TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
