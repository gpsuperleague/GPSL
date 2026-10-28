-- =============================================================================
-- GPSL all-time records — weekly refresh
-- UI: league_records / cup_records / fun_records
-- Safe re-run. Cron: Mondays 06:00 UTC.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_alltime_records (
  catalog text NOT NULL CHECK (catalog IN ('league', 'cup', 'fun')),
  record_id text NOT NULL,
  holder_name text,
  holder_club text,
  holder_key text,
  owner_tag text,
  value_num numeric,
  value_text text,
  context_label text,
  meta jsonb NOT NULL DEFAULT '{}'::jsonb,
  computed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (catalog, record_id)
);

ALTER TABLE public.gpsl_alltime_records
  ADD COLUMN IF NOT EXISTS owner_tag text;

CREATE TABLE IF NOT EXISTS public.gpsl_alltime_records_meta (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  last_refresh_at timestamptz,
  last_refresh_ok boolean,
  last_refresh_detail jsonb NOT NULL DEFAULT '{}'::jsonb
);

INSERT INTO public.gpsl_alltime_records_meta (id) VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.gpsl_alltime_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpsl_alltime_records_meta ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_alltime_records_select ON public.gpsl_alltime_records;
CREATE POLICY gpsl_alltime_records_select ON public.gpsl_alltime_records
  FOR SELECT TO authenticated, anon USING (true);

DROP POLICY IF EXISTS gpsl_alltime_records_meta_select ON public.gpsl_alltime_records_meta;
CREATE POLICY gpsl_alltime_records_meta_select ON public.gpsl_alltime_records_meta
  FOR SELECT TO authenticated, anon USING (true);

REVOKE ALL ON TABLE public.gpsl_alltime_records FROM PUBLIC;
REVOKE ALL ON TABLE public.gpsl_alltime_records_meta FROM PUBLIC;
GRANT SELECT ON public.gpsl_alltime_records TO authenticated, anon;
GRANT SELECT ON public.gpsl_alltime_records_meta TO authenticated, anon;

-- Owner at achievement time (season ranking) — never current Clubs.owner
CREATE OR REPLACE FUNCTION public.gpsl_records_historical_owner(
  p_club_short text,
  p_season_label text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short, '')));
  v_label text := nullif(btrim(coalesce(p_season_label, '')), '');
  v_owner uuid;
  v_tag text;
BEGIN
  IF v_club = '' THEN RETURN NULL; END IF;
  IF v_label IS NOT NULL THEN
    v_label := btrim(regexp_replace(v_label, '\s*\(.*\)$', ''));
  END IF;
  IF v_label IN ('Current', 'League', 'All cups', 'All-time league', 'Cup match', 'Super League') THEN
    v_label := NULL;
  END IF;
  IF to_regclass('public.competition_owner_season_ranking') IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT r.owner_id INTO v_owner
  FROM public.competition_owner_season_ranking r
  WHERE upper(r.club_short_name) = v_club
    AND r.owner_id IS NOT NULL
    AND (
      (p_season_id IS NOT NULL AND r.season_id = p_season_id)
      OR (v_label IS NOT NULL AND r.season_label = v_label)
    )
  ORDER BY r.season_id DESC NULLS LAST
  LIMIT 1;

  IF v_owner IS NULL AND v_label IS NOT NULL THEN
    SELECT r.owner_id INTO v_owner
    FROM public.competition_owner_season_ranking r
    WHERE upper(r.club_short_name) = v_club
      AND r.owner_id IS NOT NULL
      AND (
        r.season_label = v_label
        OR v_label LIKE r.season_label || ' %'
        OR v_label LIKE r.season_label || '·%'
        OR v_label LIKE r.season_label || '· %'
      )
    ORDER BY r.season_id DESC NULLS LAST
    LIMIT 1;
  END IF;

  IF v_owner IS NULL THEN RETURN NULL; END IF;

  BEGIN
    IF to_regprocedure('public.owner_registry_resolve_tag(uuid)') IS NOT NULL THEN
      v_tag := nullif(btrim(public.owner_registry_resolve_tag(v_owner)), '');
    END IF;
  EXCEPTION WHEN OTHERS THEN v_tag := NULL;
  END;
  IF v_tag IS NULL AND to_regprocedure('public.competition_owner_display_name(uuid)') IS NOT NULL THEN
    BEGIN
      v_tag := nullif(btrim(public.competition_owner_display_name(v_owner)), '');
    EXCEPTION WHEN OTHERS THEN v_tag := NULL;
    END;
  END IF;
  RETURN v_tag;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_records_upsert(
  p_catalog text,
  p_record_id text,
  p_holder_name text,
  p_holder_club text,
  p_holder_key text,
  p_value_num numeric,
  p_value_text text,
  p_context text,
  p_meta jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner text;
  v_club_key text;
  v_season_label text;
  v_season_id bigint;
  v_meta jsonb := coalesce(p_meta, '{}'::jsonb);
BEGIN
  IF p_holder_name IS NULL AND p_value_text IS NULL AND p_value_num IS NULL THEN
    RETURN;
  END IF;

  v_club_key := nullif(btrim(coalesce(p_holder_club, '')), '');
  IF v_club_key IS NULL THEN
    v_club_key := nullif(btrim(coalesce(p_holder_key, '')), '');
  END IF;

  v_season_label := nullif(btrim(coalesce(v_meta->>'season_label', '')), '');
  IF v_season_label IS NULL THEN
    v_season_label := nullif(btrim(coalesce(p_context, '')), '');
  END IF;
  BEGIN
    v_season_id := nullif(v_meta->>'season_id', '')::bigint;
  EXCEPTION WHEN OTHERS THEN
    v_season_id := NULL;
  END;

  IF v_club_key IS NOT NULL THEN
    v_owner := public.gpsl_records_historical_owner(v_club_key, v_season_label, v_season_id);
  END IF;

  INSERT INTO public.gpsl_alltime_records (
    catalog, record_id, holder_name, holder_club, holder_key, owner_tag,
    value_num, value_text, context_label, meta, computed_at
  ) VALUES (
    p_catalog, p_record_id, p_holder_name, p_holder_club, p_holder_key, v_owner,
    p_value_num, p_value_text, p_context, v_meta, now()
  )
  ON CONFLICT (catalog, record_id) DO UPDATE SET
    holder_name = excluded.holder_name,
    holder_club = excluded.holder_club,
    holder_key = excluded.holder_key,
    owner_tag = excluded.owner_tag,
    value_num = excluded.value_num,
    value_text = excluded.value_text,
    context_label = excluded.context_label,
    meta = excluded.meta,
    computed_at = now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_records_club_name(p_short text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT c."Club" FROM public."Clubs" c WHERE upper(c."ShortName") = upper(btrim(p_short)) LIMIT 1),
    p_short
  );
$$;

CREATE OR REPLACE FUNCTION public.gpsl_records_player_name(p_id text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT p."Name" FROM public."Players" p WHERE p."Konami_ID"::text = btrim(p_id) LIMIT 1),
    p_id
  );
$$;

CREATE OR REPLACE FUNCTION public.gpsl_records_season_rows()
RETURNS TABLE (
  club_short_name text,
  season_label text,
  division text,
  final_position int,
  mp int, won int, drawn int, lost int, gf int, ga int, gd int, pts int
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    a.club_short_name::text,
    a.season_label::text,
    a.division::text,
    a.final_position::int,
    a.mp::int, a.won::int, a.drawn::int, a.lost::int,
    a.gf::int, a.ga::int, a.gd::int, a.pts::int
  FROM public.competition_club_season_archive a
  UNION ALL
  SELECT
    s.club_short_name::text,
    coalesce(cs.label, 'Current')::text,
    s.division::text,
    NULL::int,
    s.mp::int, s.w::int, s.d::int, s.l::int,
    s.gf::int, s.ga::int, s.gd::int, s.pts::int
  FROM public.competition_standings_public s
  LEFT JOIN public.competition_seasons cs ON cs.id = s.season_id
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.competition_club_season_archive a
    WHERE a.club_short_name = s.club_short_name
      AND a.season_label = coalesce(cs.label, 'Current')
  );
$$;

CREATE OR REPLACE FUNCTION public.gpsl_records_refresh()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '180s'
AS $function$
DECLARE
  v_started timestamptz := clock_timestamp();
  v_n int := 0;
  v_club text;
  v_key text;
  v_val numeric;
  v_txt text;
  v_ctx text;
  v_label text;
  v_sid bigint;
BEGIN
  PERFORM set_config('statement_timeout', '180s', true);

  -- Most Super League titles
  SELECT club_short_name, count(*)::int
  INTO v_club, v_val
  FROM public.competition_club_season_archive
  WHERE division = 'superleague' AND final_position = 1
  GROUP BY club_short_name
  ORDER BY count(*) DESC, club_short_name
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_league_titles',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' title(s)', 'Super League', '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  -- Season extremes
  SELECT club_short_name, season_label, pts INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE pts IS NOT NULL
  ORDER BY pts DESC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_points_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' pts', v_ctx, '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, pts INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE mp >= 10 AND pts IS NOT NULL
  ORDER BY pts ASC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'fewest_points_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' pts', v_ctx || ' (≥10 matches)', '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, won INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE won IS NOT NULL
  ORDER BY won DESC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_wins_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' wins', v_ctx, '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, won INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE mp >= 10 AND won IS NOT NULL
  ORDER BY won ASC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'fewest_wins_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' wins', v_ctx || ' (≥10 matches)', '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, lost INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE mp >= 10 AND lost IS NOT NULL
  ORDER BY lost ASC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'fewest_defeats_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' defeat(s)', v_ctx || ' (≥10 matches)', '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, drawn INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE drawn IS NOT NULL
  ORDER BY drawn DESC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_draws_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' draws', v_ctx, '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, gf INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE gf IS NOT NULL
  ORDER BY gf DESC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_goals_scored_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' scored', v_ctx, '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, ga INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE mp >= 10 AND ga IS NOT NULL
  ORDER BY ga ASC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'fewest_goals_conceded_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' conceded', v_ctx || ' (≥10 matches)', '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, gd INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE gd IS NOT NULL
  ORDER BY gd DESC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'best_goal_difference',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val,
      CASE WHEN v_val > 0 THEN '+' ELSE '' END || v_val::text,
      v_ctx, '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  -- Title margins
  SELECT c.club_short_name, c.season_label, (c.pts - r.pts2)
  INTO v_club, v_ctx, v_val
  FROM public.competition_club_season_archive c
  JOIN (
    SELECT season_label, max(pts) FILTER (WHERE final_position = 2) AS pts2
    FROM public.competition_club_season_archive
    WHERE division = 'superleague'
    GROUP BY season_label
  ) r ON r.season_label = c.season_label
  WHERE c.division = 'superleague' AND c.final_position = 1 AND r.pts2 IS NOT NULL
  ORDER BY (c.pts - r.pts2) DESC
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'biggest_title_margin',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' pts clear', v_ctx, '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT c.club_short_name, c.season_label, (c.pts - r.pts2)
  INTO v_club, v_ctx, v_val
  FROM public.competition_club_season_archive c
  JOIN (
    SELECT season_label, max(pts) FILTER (WHERE final_position = 2) AS pts2
    FROM public.competition_club_season_archive
    WHERE division = 'superleague'
    GROUP BY season_label
  ) r ON r.season_label = c.season_label
  WHERE c.division = 'superleague' AND c.final_position = 1 AND r.pts2 IS NOT NULL
  ORDER BY (c.pts - r.pts2) ASC
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'smallest_title_margin',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' pts clear', v_ctx, '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  -- Home / away wins
  SELECT home_club_short_name, coalesce(cs.label, f.season_id::text), count(*)::int
  INTO v_club, v_ctx, v_val
  FROM public.competition_fixtures f
  LEFT JOIN public.competition_seasons cs ON cs.id = f.season_id
  WHERE f.competition_type = 'league' AND f.status = 'played' AND f.home_goals > f.away_goals
  GROUP BY home_club_short_name, coalesce(cs.label, f.season_id::text)
  ORDER BY count(*) DESC LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_home_wins_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' home wins', v_ctx, '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT away_club_short_name, coalesce(cs.label, f.season_id::text), count(*)::int
  INTO v_club, v_ctx, v_val
  FROM public.competition_fixtures f
  LEFT JOIN public.competition_seasons cs ON cs.id = f.season_id
  WHERE f.competition_type = 'league' AND f.status = 'played' AND f.away_goals > f.home_goals
  GROUP BY away_club_short_name, coalesce(cs.label, f.season_id::text)
  ORDER BY count(*) DESC LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_away_wins_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' away wins', v_ctx, '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  -- Match extremes (season_id in meta → historical owner at that season)
  SELECT
    CASE WHEN f.home_goals >= f.away_goals THEN f.home_club_short_name ELSE f.away_club_short_name END,
    abs(f.home_goals - f.away_goals)::int,
    format('%s %s–%s %s', f.home_club_short_name, f.home_goals, f.away_goals, f.away_club_short_name),
    f.season_id,
    cs.label
  INTO v_club, v_val, v_ctx, v_sid, v_label
  FROM public.competition_fixtures f
  LEFT JOIN public.competition_seasons cs ON cs.id = f.season_id
  WHERE f.competition_type = 'league' AND f.status = 'played'
    AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL AND f.home_goals <> f.away_goals
  ORDER BY abs(f.home_goals - f.away_goals) DESC, (f.home_goals + f.away_goals) DESC
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'biggest_league_win',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' goal margin', coalesce(v_label, v_ctx),
      jsonb_build_object('season_id', v_sid, 'season_label', v_label, 'match', v_ctx)
    );
    v_n := v_n + 1;
  END IF;

  SELECT
    (f.home_goals + f.away_goals)::int,
    format('%s %s–%s %s', f.home_club_short_name, f.home_goals, f.away_goals, f.away_club_short_name),
    CASE WHEN f.home_goals >= f.away_goals THEN f.home_club_short_name ELSE f.away_club_short_name END,
    f.season_id,
    cs.label
  INTO v_val, v_ctx, v_club, v_sid, v_label
  FROM public.competition_fixtures f
  LEFT JOIN public.competition_seasons cs ON cs.id = f.season_id
  WHERE f.competition_type = 'league' AND f.status = 'played'
    AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL
  ORDER BY (f.home_goals + f.away_goals) DESC
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'highest_scoring_match',
      v_ctx, v_club, v_club,
      v_val, v_val::text || ' goals', coalesce(v_label, v_ctx),
      jsonb_build_object('season_id', v_sid, 'season_label', v_label, 'match', v_ctx)
    );
    v_n := v_n + 1;
  END IF;

  SELECT
    CASE WHEN f.home_goals >= f.away_goals THEN f.home_club_short_name ELSE f.away_club_short_name END,
    greatest(f.home_goals, f.away_goals)::int,
    format('%s %s–%s %s', f.home_club_short_name, f.home_goals, f.away_goals, f.away_club_short_name),
    f.season_id,
    cs.label
  INTO v_club, v_val, v_ctx, v_sid, v_label
  FROM public.competition_fixtures f
  LEFT JOIN public.competition_seasons cs ON cs.id = f.season_id
  WHERE f.competition_type = 'league' AND f.status = 'played'
    AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL
  ORDER BY greatest(f.home_goals, f.away_goals) DESC
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_goals_one_team_match',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' goals', coalesce(v_label, v_ctx),
      jsonb_build_object('season_id', v_sid, 'season_label', v_label, 'match', v_ctx)
    );
    v_n := v_n + 1;
  END IF;

  -- Streaks (order by matchday, id)
  SELECT club, n INTO v_club, v_val
  FROM (
    WITH base AS (
      SELECT f.id, coalesce(f.matchday, 0) AS md,
             f.home_club_short_name AS club,
             (f.home_goals > f.away_goals) AS won,
             (f.home_goals >= f.away_goals) AS unbeaten
      FROM public.competition_fixtures f
      WHERE f.competition_type = 'league' AND f.status = 'played'
        AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL
      UNION ALL
      SELECT f.id, coalesce(f.matchday, 0), f.away_club_short_name,
             (f.away_goals > f.home_goals),
             (f.away_goals >= f.home_goals)
      FROM public.competition_fixtures f
      WHERE f.competition_type = 'league' AND f.status = 'played'
        AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL
    ),
    tagged AS (
      SELECT *,
        row_number() OVER (PARTITION BY club ORDER BY md, id)
          - row_number() OVER (PARTITION BY club, won ORDER BY md, id) AS wg,
        row_number() OVER (PARTITION BY club ORDER BY md, id)
          - row_number() OVER (PARTITION BY club, unbeaten ORDER BY md, id) AS ug
      FROM base
    )
    SELECT club, count(*)::int AS n FROM tagged WHERE won GROUP BY club, wg
  ) s
  ORDER BY n DESC, club LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_consecutive_wins',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' in a row', 'League', '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT club, n INTO v_club, v_val
  FROM (
    WITH base AS (
      SELECT f.id, coalesce(f.matchday, 0) AS md,
             f.home_club_short_name AS club,
             (f.home_goals >= f.away_goals) AS unbeaten
      FROM public.competition_fixtures f
      WHERE f.competition_type = 'league' AND f.status = 'played'
        AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL
      UNION ALL
      SELECT f.id, coalesce(f.matchday, 0), f.away_club_short_name,
             (f.away_goals >= f.home_goals)
      FROM public.competition_fixtures f
      WHERE f.competition_type = 'league' AND f.status = 'played'
        AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL
    ),
    tagged AS (
      SELECT *,
        row_number() OVER (PARTITION BY club ORDER BY md, id)
          - row_number() OVER (PARTITION BY club, unbeaten ORDER BY md, id) AS ug
      FROM base
    )
    SELECT club, count(*)::int AS n FROM tagged WHERE unbeaten GROUP BY club, ug
  ) s
  ORDER BY n DESC, club LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'longest_unbeaten_run',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' unbeaten', 'League', '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  -- Players (league)
  IF to_regclass('public.competition_match_player_stats') IS NOT NULL THEN
    SELECT m.player_id, count(*) FILTER (WHERE coalesce(m.appeared, false))::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
    GROUP BY m.player_id
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND AND v_val > 0 THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_league_apps',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' apps', 'All-time league', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, coalesce(sum(m.goals), 0)::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
    GROUP BY m.player_id
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND AND v_val > 0 THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_league_goals',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' goals', 'All-time league', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, coalesce(sum(m.goals), 0)::int, coalesce(cs.label, m.season_id::text)
    INTO v_key, v_val, v_ctx
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    LEFT JOIN public.competition_seasons cs ON cs.id = m.season_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
    GROUP BY m.player_id, coalesce(cs.label, m.season_id::text)
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND AND v_val > 0 THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_goals_season',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' goals', v_ctx, '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, coalesce(sum(m.assists), 0)::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
    GROUP BY m.player_id
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND AND v_val > 0 THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_assists',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' assists', 'All-time league', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, count(*)::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played' AND coalesce(m.goals, 0) >= 3
    GROUP BY m.player_id
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_hat_tricks',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' hat-trick(s)', 'All-time league', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, count(*) FILTER (WHERE coalesce(m.is_player_of_match, false))::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
    GROUP BY m.player_id
    HAVING count(*) FILTER (WHERE coalesce(m.is_player_of_match, false)) > 0
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_potm',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' PoTM', 'League', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, m.goals::int, m.club_short_name
    INTO v_key, v_val, v_club
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played' AND coalesce(m.goals, 0) > 0
    ORDER BY m.goals DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_goals_single_match',
        public.gpsl_records_player_name(v_key), v_club, v_key,
        v_val, v_val::text || ' goals', public.gpsl_records_club_name(v_club), '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, count(*) FILTER (WHERE coalesce(m.yellow_card, false))::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
    GROUP BY m.player_id
    HAVING count(*) FILTER (WHERE coalesce(m.yellow_card, false)) > 0
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_yellow_cards',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' yellows', 'All-time league', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, count(*) FILTER (WHERE coalesce(m.red_card, false))::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
    GROUP BY m.player_id
    HAVING count(*) FILTER (WHERE coalesce(m.red_card, false)) > 0
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_red_cards',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' reds', 'All-time league', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;
  END IF;

  -- CUP: wins (finals via cup_round_stage when available)
  IF to_regprocedure('public.competition_cup_round_stage(text,integer,integer)') IS NOT NULL THEN
    SELECT w.club, count(*)::int
    INTO v_club, v_val
    FROM (
      SELECT
        CASE
          WHEN f.home_goals > f.away_goals THEN f.home_club_short_name
          WHEN f.away_goals > f.home_goals THEN f.away_club_short_name
          ELSE NULL
        END AS club
      FROM public.competition_fixtures f
      WHERE f.competition_type = 'cup' AND f.status = 'played'
        AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL
        AND public.competition_cup_round_stage(
          f.cup_code, f.cup_round,
          (SELECT max(f2.cup_round) FROM public.competition_fixtures f2
           WHERE f2.season_id = f.season_id AND f2.cup_code = f.cup_code AND f2.competition_type = 'cup')
        ) = 'final'
    ) w
    WHERE w.club IS NOT NULL
    GROUP BY w.club
    ORDER BY count(*) DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'cup', 'most_cup_wins',
        public.gpsl_records_club_name(v_club), v_club, v_club,
        v_val, v_val::text || ' cup(s)', 'All cups', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;
  END IF;

  SELECT
    CASE WHEN f.home_goals >= f.away_goals THEN f.home_club_short_name ELSE f.away_club_short_name END,
    abs(f.home_goals - f.away_goals)::int,
    format('%s %s–%s %s (%s)', f.home_club_short_name, f.home_goals, f.away_goals, f.away_club_short_name, coalesce(f.cup_code, 'cup')),
    f.season_id,
    cs.label
  INTO v_club, v_val, v_ctx, v_sid, v_label
  FROM public.competition_fixtures f
  LEFT JOIN public.competition_seasons cs ON cs.id = f.season_id
  WHERE f.competition_type = 'cup' AND f.status = 'played'
    AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL AND f.home_goals <> f.away_goals
  ORDER BY abs(f.home_goals - f.away_goals) DESC LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'cup', 'biggest_cup_match_victory',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' goal margin', coalesce(v_label, v_ctx),
      jsonb_build_object('season_id', v_sid, 'season_label', v_label, 'match', v_ctx)
    );
    v_n := v_n + 1;
  END IF;

  SELECT club, count(*)::int INTO v_club, v_val
  FROM (
    SELECT home_club_short_name AS club FROM public.competition_fixtures
    WHERE competition_type = 'cup' AND status = 'played' AND home_goals > away_goals
    UNION ALL
    SELECT away_club_short_name FROM public.competition_fixtures
    WHERE competition_type = 'cup' AND status = 'played' AND away_goals > home_goals
  ) x
  GROUP BY club ORDER BY count(*) DESC LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'cup', 'most_cup_matches_won',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' wins', 'All cups', '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  IF to_regclass('public.competition_match_player_stats') IS NOT NULL THEN
    SELECT m.player_id, count(*) FILTER (WHERE coalesce(m.appeared, false))::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'cup' AND f.status = 'played'
    GROUP BY m.player_id ORDER BY 2 DESC LIMIT 1;
    IF FOUND AND v_val > 0 THEN
      PERFORM public.gpsl_records_upsert(
        'cup', 'most_cup_apps',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' apps', 'All cups', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, coalesce(sum(m.goals), 0)::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'cup' AND f.status = 'played'
    GROUP BY m.player_id ORDER BY 2 DESC LIMIT 1;
    IF FOUND AND v_val > 0 THEN
      PERFORM public.gpsl_records_upsert(
        'cup', 'most_cup_goals',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' goals', 'All cups', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, coalesce(sum(m.assists), 0)::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'cup' AND f.status = 'played'
    GROUP BY m.player_id ORDER BY 2 DESC LIMIT 1;
    IF FOUND AND v_val > 0 THEN
      PERFORM public.gpsl_records_upsert(
        'cup', 'most_cup_assists',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' assists', 'All cups', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, m.goals::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'cup' AND f.status = 'played' AND coalesce(m.goals, 0) > 0
    ORDER BY m.goals DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'cup', 'most_goals_single_cup_match',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' goals', 'Cup match', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;
  END IF;

  -- FUN
  IF to_regclass('public."Club_Finances"') IS NOT NULL THEN
    SELECT club_name, balance INTO v_club, v_val
    FROM public."Club_Finances"
    WHERE upper(club_name) <> 'FOREIGN' AND balance IS NOT NULL
    ORDER BY balance DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'fun', 'richest_club_ever',
        public.gpsl_records_club_name(v_club), v_club, v_club,
        v_val, to_char(v_val, 'FM999G999G999G999'), 'Current balance', '{}'::jsonb
      );
      v_n := v_n + 1;
    END IF;
  END IF;

  SELECT club_short_name, season_label, division
  INTO v_club, v_ctx, v_label
  FROM public.competition_club_season_archive
  WHERE final_position = 1 AND division IN ('championship_a', 'championship_b')
  ORDER BY season_label DESC LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'fun', 'lowest_ranked_league_winner',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      1, 'Championship champions', v_ctx || ' · ' || v_label, '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, final_position
  INTO v_club, v_ctx, v_val
  FROM public.competition_club_season_archive
  WHERE division = 'superleague' AND final_position >= 17
  ORDER BY final_position ASC, season_label LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'fun', 'highest_ranked_relegated',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, 'Finished ' || v_val::text || 'th', v_ctx || ' Super League', '{}'::jsonb
    );
    v_n := v_n + 1;
  END IF;

  SELECT
    CASE WHEN h.division LIKE 'championship%' THEN f.home_club_short_name ELSE f.away_club_short_name END,
    abs(f.home_goals - f.away_goals)::int,
    format('%s %s–%s %s', f.home_club_short_name, f.home_goals, f.away_goals, f.away_club_short_name),
    f.season_id,
    cs.label
  INTO v_club, v_val, v_ctx, v_sid, v_label
  FROM public.competition_fixtures f
  JOIN public.competition_club_seasons h
    ON h.season_id = f.season_id AND h.club_short_name = f.home_club_short_name
  JOIN public.competition_club_seasons a
    ON a.season_id = f.season_id AND a.club_short_name = f.away_club_short_name
  LEFT JOIN public.competition_seasons cs ON cs.id = f.season_id
  WHERE f.competition_type = 'cup' AND f.status = 'played'
    AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL
    AND (
      (h.division LIKE 'championship%' AND a.division = 'superleague' AND f.home_goals > f.away_goals)
      OR (a.division LIKE 'championship%' AND h.division = 'superleague' AND f.away_goals > f.home_goals)
    )
  ORDER BY abs(f.home_goals - f.away_goals) DESC
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'fun', 'biggest_giant_killing',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, 'Champ beat Super League', coalesce(v_label, v_ctx),
      jsonb_build_object('season_id', v_sid, 'season_label', v_label, 'match', v_ctx)
    );
    v_n := v_n + 1;
  END IF;

  UPDATE public.gpsl_alltime_records_meta
  SET last_refresh_at = now(),
      last_refresh_ok = true,
      last_refresh_detail = jsonb_build_object(
        'updated_records', v_n,
        'duration_ms', round(extract(epoch FROM (clock_timestamp() - v_started)) * 1000)
      )
  WHERE id = 1;

  RETURN jsonb_build_object('ok', true, 'updated_records', v_n,
    'duration_ms', round(extract(epoch FROM (clock_timestamp() - v_started)) * 1000));
EXCEPTION WHEN OTHERS THEN
  UPDATE public.gpsl_alltime_records_meta
  SET last_refresh_at = now(), last_refresh_ok = false,
      last_refresh_detail = jsonb_build_object('error', SQLERRM)
  WHERE id = 1;
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_records_refresh() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_records_refresh() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_records_get(p_catalog text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $function$
DECLARE
  v_cat text := nullif(lower(btrim(coalesce(p_catalog, ''))), '');
  v_meta jsonb;
  v_rows jsonb;
BEGIN
  SELECT to_jsonb(m) - 'id' INTO v_meta
  FROM public.gpsl_alltime_records_meta m WHERE id = 1;

  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.catalog, r.record_id), '[]'::jsonb)
  INTO v_rows
  FROM public.gpsl_alltime_records r
  WHERE v_cat IS NULL OR r.catalog = v_cat;

  RETURN jsonb_build_object('ok', true, 'catalog', v_cat, 'meta', v_meta, 'records', v_rows);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_records_get(text) TO authenticated, anon;

CREATE OR REPLACE FUNCTION public.admin_gpsl_records_refresh()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.gpsl_records_refresh();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_gpsl_records_refresh() TO authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'gpsl_alltime_records_weekly';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    PERFORM cron.schedule(
      'gpsl_alltime_records_weekly',
      '0 6 * * 1',
      $cmd$SELECT public.gpsl_records_refresh();$cmd$
    );
  ELSE
    RAISE NOTICE 'pg_cron missing — run SELECT public.gpsl_records_refresh(); weekly.';
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron schedule skipped: %', SQLERRM;
END;
$cron$;

SELECT public.gpsl_records_refresh() AS initial_refresh;
NOTIFY pgrst, 'reload schema';
