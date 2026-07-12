-- =============================================================================
-- GPSL Sport — Division standings snapshot + monthly desk notes
-- Full league tables as of the edition month, plus blurbs for:
--   highest climber, best home form, best away form, most goals, fewest conceded
-- Safe re-run. Rebuild edition after apply.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_build_standings_page(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_month_label text;
  v_month_sort smallint;
  v_out jsonb;
BEGIN
  IF p_season_id IS NULL OR v_month = '' THEN
    RETURN '{}'::jsonb;
  END IF;

  v_month_sort := public.competition_gpsl_month_sort(v_month);
  IF v_month_sort IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);

  WITH registered AS (
    SELECT
      ccs.season_id,
      ccs.division,
      ccs.club_short_name,
      c."Club" AS club_name
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
  ),
  played_to_date AS (
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND f.gpsl_month IS NOT NULL
      AND public.competition_gpsl_month_sort(lower(f.gpsl_month)) <= v_month_sort
  ),
  played_before AS (
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND f.gpsl_month IS NOT NULL
      AND public.competition_gpsl_month_sort(lower(f.gpsl_month)) < v_month_sort
  ),
  played_month AS (
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND lower(f.gpsl_month) = v_month
  ),
  apps_to_date AS (
    SELECT
      season_id,
      division,
      home_club_short_name AS club_short_name,
      matchday,
      coalesce(public.competition_gpsl_month_sort(lower(gpsl_month)), 0) AS month_sort,
      id AS fixture_id,
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
      END AS result_char,
      'home'::text AS venue
    FROM played_to_date
    UNION ALL
    SELECT
      season_id,
      division,
      away_club_short_name,
      matchday,
      coalesce(public.competition_gpsl_month_sort(lower(gpsl_month)), 0),
      id,
      1,
      CASE WHEN away_goals > home_goals THEN 1 ELSE 0 END,
      CASE WHEN away_goals = home_goals THEN 1 ELSE 0 END,
      CASE WHEN away_goals < home_goals THEN 1 ELSE 0 END,
      away_goals,
      home_goals,
      CASE
        WHEN away_goals > home_goals THEN 'W'
        WHEN away_goals = home_goals THEN 'D'
        ELSE 'L'
      END,
      'away'
    FROM played_to_date
  ),
  apps_before AS (
    SELECT
      season_id,
      division,
      home_club_short_name AS club_short_name,
      1 AS mp,
      CASE WHEN home_goals > away_goals THEN 1 ELSE 0 END AS w,
      CASE WHEN home_goals = away_goals THEN 1 ELSE 0 END AS d,
      home_goals AS gf,
      away_goals AS ga
    FROM played_before
    UNION ALL
    SELECT
      season_id,
      division,
      away_club_short_name,
      1,
      CASE WHEN away_goals > home_goals THEN 1 ELSE 0 END,
      CASE WHEN away_goals = home_goals THEN 1 ELSE 0 END,
      away_goals,
      home_goals
    FROM played_before
  ),
  month_apps AS (
    SELECT
      season_id,
      division,
      home_club_short_name AS club_short_name,
      'home'::text AS venue,
      id AS fixture_id,
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
    FROM played_month
    UNION ALL
    SELECT
      season_id,
      division,
      away_club_short_name,
      'away',
      id,
      matchday,
      1,
      CASE WHEN away_goals > home_goals THEN 1 ELSE 0 END,
      CASE WHEN away_goals = home_goals THEN 1 ELSE 0 END,
      CASE WHEN away_goals < home_goals THEN 1 ELSE 0 END,
      away_goals,
      home_goals,
      CASE
        WHEN away_goals > home_goals THEN 'W'
        WHEN away_goals = home_goals THEN 'D'
        ELSE 'L'
      END
    FROM played_month
  ),
  totals AS (
    SELECT
      a.season_id,
      a.division,
      a.club_short_name,
      sum(a.mp)::int AS mp,
      sum(a.w)::int AS w,
      sum(a.d)::int AS d,
      sum(a.l)::int AS l,
      sum(a.gf)::int AS gf,
      sum(a.ga)::int AS ga,
      (sum(a.gf) - sum(a.ga))::int AS gd,
      (sum(a.w) * 3 + sum(a.d))::int AS pts
    FROM apps_to_date a
    GROUP BY a.season_id, a.division, a.club_short_name
  ),
  form_strings AS (
    SELECT
      r.season_id,
      r.division,
      r.club_short_name,
      (
        SELECT string_agg(x.result_char, '' ORDER BY x.ord)
        FROM (
          SELECT a2.result_char, row_number() OVER (ORDER BY a2.month_sort DESC, a2.matchday DESC, a2.fixture_id DESC) AS ord
          FROM apps_to_date a2
          WHERE a2.season_id = r.season_id
            AND a2.division = r.division
            AND a2.club_short_name = r.club_short_name
          ORDER BY a2.month_sort DESC, a2.matchday DESC, a2.fixture_id DESC
          LIMIT 10
        ) x
      ) AS form_last10
    FROM registered r
  ),
  table_now AS (
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
      coalesce(f.form_last10, '') AS form_last10,
      row_number() OVER (
        PARTITION BY r.division
        ORDER BY coalesce(t.pts, 0) DESC, coalesce(t.gd, 0) DESC, coalesce(t.gf, 0) DESC, r.club_name ASC
      )::int AS table_position
    FROM registered r
    LEFT JOIN totals t
      ON t.season_id = r.season_id AND t.division = r.division AND t.club_short_name = r.club_short_name
    LEFT JOIN form_strings f
      ON f.season_id = r.season_id AND f.division = r.division AND f.club_short_name = r.club_short_name
  ),
  before_totals AS (
    SELECT
      a.season_id,
      a.division,
      a.club_short_name,
      sum(a.mp)::int AS mp,
      sum(a.w)::int AS w,
      sum(a.d)::int AS d,
      sum(a.gf)::int AS gf,
      sum(a.ga)::int AS ga,
      (sum(a.gf) - sum(a.ga))::int AS gd,
      (sum(a.w) * 3 + sum(a.d))::int AS pts
    FROM apps_before a
    GROUP BY a.season_id, a.division, a.club_short_name
  ),
  table_before AS (
    SELECT
      r.division,
      r.club_short_name,
      row_number() OVER (
        PARTITION BY r.division
        ORDER BY coalesce(b.pts, 0) DESC, coalesce(b.gd, 0) DESC, coalesce(b.gf, 0) DESC, r.club_name ASC
      )::int AS table_position
    FROM registered r
    LEFT JOIN before_totals b
      ON b.season_id = r.season_id AND b.division = r.division AND b.club_short_name = r.club_short_name
    WHERE EXISTS (SELECT 1 FROM played_before)
  ),
  month_home AS (
    SELECT
      m.division,
      m.club_short_name,
      sum(m.mp)::int AS mp,
      sum(m.w)::int AS w,
      sum(m.d)::int AS d,
      (sum(m.w) * 3 + sum(m.d))::int AS pts,
      string_agg(m.result_char, '' ORDER BY m.matchday, m.fixture_id) AS form
    FROM month_apps m
    WHERE m.venue = 'home'
    GROUP BY m.division, m.club_short_name
    HAVING sum(m.mp) > 0
  ),
  month_away AS (
    SELECT
      m.division,
      m.club_short_name,
      sum(m.mp)::int AS mp,
      sum(m.w)::int AS w,
      sum(m.d)::int AS d,
      (sum(m.w) * 3 + sum(m.d))::int AS pts,
      string_agg(m.result_char, '' ORDER BY m.matchday, m.fixture_id) AS form
    FROM month_apps m
    WHERE m.venue = 'away'
    GROUP BY m.division, m.club_short_name
    HAVING sum(m.mp) > 0
  ),
  climbers AS (
    SELECT
      n.division,
      n.club_short_name,
      n.club_name,
      b.table_position AS from_pos,
      n.table_position AS to_pos,
      (b.table_position - n.table_position)::int AS places_gained
    FROM table_now n
    JOIN table_before b
      ON b.division = n.division AND b.club_short_name = n.club_short_name
    WHERE b.table_position > n.table_position
  ),
  divs AS (
    SELECT DISTINCT division FROM registered
  )
  SELECT coalesce(jsonb_object_agg(d.division, payload), '{}'::jsonb)
  INTO v_out
  FROM divs d
  CROSS JOIN LATERAL (
    SELECT jsonb_build_object(
      'division_label', CASE d.division
        WHEN 'superleague' THEN 'SuperLeague'
        WHEN 'championship_a' THEN 'Championship A'
        WHEN 'championship_b' THEN 'Championship B'
        ELSE initcap(replace(d.division, '_', ' '))
      END,
      'as_of_month', v_month,
      'as_of_month_label', v_month_label,
      'table', coalesce((
        SELECT jsonb_agg(
          jsonb_build_object(
            'position', t.table_position,
            'club_short', t.club_short_name,
            'club_name', t.club_name,
            'owner', public.gpsl_sport_owner_byline(t.club_short_name),
            'mp', t.mp,
            'w', t.w,
            'd', t.d,
            'l', t.l,
            'gf', t.gf,
            'ga', t.ga,
            'gd', t.gd,
            'pts', t.pts,
            'form', t.form_last10
          )
          ORDER BY t.table_position
        )
        FROM table_now t
        WHERE t.division = d.division
      ), '[]'::jsonb),
      'leader', (
        SELECT jsonb_build_object(
          'club_short', t.club_short_name,
          'club_name', t.club_name,
          'owner', public.gpsl_sport_owner_byline(t.club_short_name),
          'pts', t.pts,
          'position', t.table_position,
          'form', t.form_last10,
          'mp', t.mp,
          'gd', t.gd,
          'pts_ahead', t.pts - coalesce((
            SELECT t2.pts FROM table_now t2
            WHERE t2.division = d.division AND t2.table_position = 2
          ), t.pts)
        )
        FROM table_now t
        WHERE t.division = d.division
        ORDER BY t.table_position
        LIMIT 1
      ),
      'chasers', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
          'club_short', t.club_short_name,
          'club_name', t.club_name,
          'owner', public.gpsl_sport_owner_byline(t.club_short_name),
          'pts', t.pts,
          'position', t.table_position,
          'pts_behind', (
            SELECT t1.pts FROM table_now t1
            WHERE t1.division = d.division AND t1.table_position = 1
          ) - t.pts
        ) ORDER BY t.table_position)
        FROM table_now t
        WHERE t.division = d.division AND t.table_position BETWEEN 2 AND 3
      ), '[]'::jsonb),
      'flying', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
          'club_short', t.club_short_name,
          'club_name', t.club_name,
          'owner', public.gpsl_sport_owner_byline(t.club_short_name),
          'pts', t.pts,
          'position', t.table_position,
          'form', t.form_last10
        ) ORDER BY t.table_position)
        FROM table_now t
        WHERE t.division = d.division AND t.table_position <= 3
      ), '[]'::jsonb),
      'highlights', jsonb_build_object(
        'climber', (
          SELECT jsonb_build_object(
            'club_short', c.club_short_name,
            'club_name', c.club_name,
            'owner', public.gpsl_sport_owner_byline(c.club_short_name),
            'from_pos', c.from_pos,
            'to_pos', c.to_pos,
            'places_gained', c.places_gained,
            'blurb', format(
              'Highest climber of %s: %s (%s) rocketed %s place%s — from %s to %s — after a month that finally moved the needle.',
              v_month_label,
              c.club_name,
              public.gpsl_sport_owner_byline(c.club_short_name),
              c.places_gained,
              CASE WHEN c.places_gained = 1 THEN '' ELSE 's' END,
              c.from_pos,
              c.to_pos
            )
          )
          FROM climbers c
          WHERE c.division = d.division
          ORDER BY c.places_gained DESC, c.to_pos ASC, c.club_name ASC
          LIMIT 1
        ),
        'best_home', (
          SELECT jsonb_build_object(
            'club_short', h.club_short_name,
            'club_name', public.gpsl_sport_club_display_name(h.club_short_name),
            'owner', public.gpsl_sport_owner_byline(h.club_short_name),
            'pts', h.pts,
            'mp', h.mp,
            'form', h.form,
            'blurb', format(
              'Best home form in %s belonged to %s (%s): %s point%s from %s home game%s%s.',
              v_month_label,
              public.gpsl_sport_club_display_name(h.club_short_name),
              public.gpsl_sport_owner_byline(h.club_short_name),
              h.pts,
              CASE WHEN h.pts = 1 THEN '' ELSE 's' END,
              h.mp,
              CASE WHEN h.mp = 1 THEN '' ELSE 's' END,
              CASE WHEN nullif(h.form, '') IS NOT NULL THEN format(' (%s)', h.form) ELSE '' END
            )
          )
          FROM month_home h
          WHERE h.division = d.division
          ORDER BY h.pts DESC, h.w DESC, (h.pts::numeric / nullif(h.mp, 0)) DESC NULLS LAST, h.club_short_name ASC
          LIMIT 1
        ),
        'best_away', (
          SELECT jsonb_build_object(
            'club_short', a.club_short_name,
            'club_name', public.gpsl_sport_club_display_name(a.club_short_name),
            'owner', public.gpsl_sport_owner_byline(a.club_short_name),
            'pts', a.pts,
            'mp', a.mp,
            'form', a.form,
            'blurb', format(
              'On the road, %s (%s) posted the division''s best away return in %s — %s point%s from %s trip%s%s.',
              public.gpsl_sport_club_display_name(a.club_short_name),
              public.gpsl_sport_owner_byline(a.club_short_name),
              v_month_label,
              a.pts,
              CASE WHEN a.pts = 1 THEN '' ELSE 's' END,
              a.mp,
              CASE WHEN a.mp = 1 THEN '' ELSE 's' END,
              CASE WHEN nullif(a.form, '') IS NOT NULL THEN format(' (%s)', a.form) ELSE '' END
            )
          )
          FROM month_away a
          WHERE a.division = d.division
          ORDER BY a.pts DESC, a.w DESC, (a.pts::numeric / nullif(a.mp, 0)) DESC NULLS LAST, a.club_short_name ASC
          LIMIT 1
        ),
        'most_goals', (
          SELECT jsonb_build_object(
            'club_short', t.club_short_name,
            'club_name', t.club_name,
            'owner', public.gpsl_sport_owner_byline(t.club_short_name),
            'gf', t.gf,
            'blurb', format(
              'Sharpest attack to date: %s (%s) lead the scoring charts with %s goals scored.',
              t.club_name,
              public.gpsl_sport_owner_byline(t.club_short_name),
              t.gf
            )
          )
          FROM table_now t
          WHERE t.division = d.division AND t.mp > 0
          ORDER BY t.gf DESC, t.gd DESC, t.pts DESC, t.club_name ASC
          LIMIT 1
        ),
        'best_defence', (
          SELECT jsonb_build_object(
            'club_short', t.club_short_name,
            'club_name', t.club_name,
            'owner', public.gpsl_sport_owner_byline(t.club_short_name),
            'ga', t.ga,
            'blurb', format(
              'Meanest defence belongs to %s (%s) — just %s goal%s conceded through %s.',
              t.club_name,
              public.gpsl_sport_owner_byline(t.club_short_name),
              t.ga,
              CASE WHEN t.ga = 1 THEN '' ELSE 's' END,
              v_month_label
            )
          )
          FROM table_now t
          WHERE t.division = d.division AND t.mp > 0
          ORDER BY t.ga ASC, t.gd DESC, t.pts DESC, t.club_name ASC
          LIMIT 1
        )
      )
    ) AS payload
  ) x;

  RETURN coalesce(v_out, '{}'::jsonb);
END;
$function$;

-- Refresh hook: overwrite standings after rich build (+ keep MotM / scorers hooks)
CREATE OR REPLACE FUNCTION public.gpsl_sport_refresh_inseason_edition_by_id(
  p_edition_id bigint
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.gpsl_sport_editions%ROWTYPE;
  v_month text;
  v_month_label text;
  v_built jsonb;
  v_id bigint;
  v_scorers jsonb;
  v_motm jsonb;
  v_standings jsonb;
BEGIN
  SELECT * INTO v_row
  FROM public.gpsl_sport_editions
  WHERE id = p_edition_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_month := lower(btrim(v_row.gpsl_month));
  IF v_month IN ('may', 'june', 'july', '') THEN
    RETURN p_edition_id;
  END IF;

  IF to_regprocedure('public.gpsl_sport_build_inseason_month_content(bigint, text)') IS NULL THEN
    RAISE EXCEPTION 'gpsl_sport_build_inseason_month_content is not installed';
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);
  v_built := public.gpsl_sport_build_inseason_month_content(v_row.season_id, v_month);

  IF v_built ? 'error' THEN
    RAISE EXCEPTION 'gpsl_sport_build_inseason_month_content failed: %', v_built->>'error';
  END IF;

  IF to_regprocedure('public.gpsl_sport_month_top_scorers(bigint, text)') IS NOT NULL THEN
    v_scorers := public.gpsl_sport_month_top_scorers(v_row.season_id, v_month);
    v_built := jsonb_set(
      v_built,
      '{stats_page,top_scorers}',
      coalesce(v_scorers, '{}'::jsonb),
      true
    );
  END IF;

  IF to_regprocedure('public.gpsl_sport_build_standings_page(bigint, text)') IS NOT NULL THEN
    v_standings := public.gpsl_sport_build_standings_page(v_row.season_id, v_month);
    v_built := jsonb_set(
      v_built,
      '{stats_page,standings}',
      coalesce(v_standings, '{}'::jsonb),
      true
    );
    -- Keep front-page standings teasers in sync
    IF v_built ? 'front_page' THEN
      v_built := jsonb_set(
        v_built,
        '{front_page,standings_snapshot}',
        coalesce(v_standings, '{}'::jsonb),
        true
      );
    END IF;
  END IF;

  IF to_regprocedure('public.gpsl_sport_build_motm_report(bigint, text)') IS NOT NULL THEN
    v_motm := public.gpsl_sport_build_motm_report(v_row.season_id, v_month);
    IF coalesce((v_motm->>'enabled')::boolean, false) THEN
      v_built := jsonb_set(v_built, '{match_page}', v_motm, true);
    END IF;
  END IF;

  UPDATE public.gpsl_sport_editions e
  SET
    edition_label = v_month_label,
    story_type = coalesce(v_built->>'story_type', 'inseason_month'),
    front_page = v_built->'front_page',
    back_page = coalesce(v_built->'back_page', '{}'::jsonb),
    detail = coalesce(e.detail, '{}'::jsonb) || jsonb_build_object(
      'generated_at', now(),
      'inseason_rich', true,
      'stats_page', coalesce(v_built->'stats_page', '{}'::jsonb),
      'match_page', coalesce(v_built->'match_page', '{}'::jsonb),
      'refreshed_at', now()
    ),
    published_at = coalesce(e.published_at, now())
  WHERE e.id = p_edition_id
  RETURNING e.id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'gpsl_sport_refresh_inseason_edition_by_id: edition % not updated', p_edition_id;
  END IF;

  DELETE FROM public.gpsl_sport_reads r WHERE r.edition_id = v_id;
  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_build_standings_page(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_refresh_inseason_edition_by_id(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_refresh_inseason_edition_by_id(bigint) TO service_role;

NOTIFY pgrst, 'reload schema';
