-- League records are stored once per division.
-- Championship covers both Championship groups.
-- Cup and fun marks stay shared. Safe re-run.

SET statement_timeout = '180s';

ALTER TABLE public.gpsl_alltime_records
  ADD COLUMN IF NOT EXISTS tier text;

UPDATE public.gpsl_alltime_records
SET tier = 'shared'
WHERE catalog <> 'league'
  AND tier IS NULL;

DELETE FROM public.gpsl_alltime_records
WHERE catalog = 'league';

UPDATE public.gpsl_alltime_records
SET tier = 'shared'
WHERE tier IS NULL;

ALTER TABLE public.gpsl_alltime_records
  ALTER COLUMN tier SET DEFAULT 'shared';

ALTER TABLE public.gpsl_alltime_records
  ALTER COLUMN tier SET NOT NULL;

ALTER TABLE public.gpsl_alltime_records
  DROP CONSTRAINT IF EXISTS gpsl_alltime_records_pkey;

ALTER TABLE public.gpsl_alltime_records
  DROP CONSTRAINT IF EXISTS gpsl_alltime_records_tier_check;

ALTER TABLE public.gpsl_alltime_records
  ADD CONSTRAINT gpsl_alltime_records_tier_check
  CHECK (tier IN ('superleague', 'championship', 'shared'));

ALTER TABLE public.gpsl_alltime_records
  ADD CONSTRAINT gpsl_alltime_records_pkey
  PRIMARY KEY (catalog, record_id, tier);

CREATE OR REPLACE FUNCTION public.gpsl_records_division_in_tier(
  p_division text,
  p_tier text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_tier
    WHEN 'superleague' THEN p_division = 'superleague'
    WHEN 'championship' THEN coalesce(p_division, '') LIKE 'championship%'
    ELSE false
  END;
$$;

DROP FUNCTION IF EXISTS public.gpsl_records_upsert(text, text, text, text, text, numeric, text, text, jsonb);

CREATE OR REPLACE FUNCTION public.gpsl_records_upsert(
  p_catalog text,
  p_record_id text,
  p_holder_name text,
  p_holder_club text,
  p_holder_key text,
  p_value_num numeric,
  p_value_text text,
  p_context text,
  p_meta jsonb DEFAULT '{}'::jsonb,
  p_tier text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner text;
  v_club_key text;
  v_tier text;
BEGIN
  IF p_holder_name IS NULL AND p_value_text IS NULL AND p_value_num IS NULL THEN
    RETURN;
  END IF;

  v_tier := nullif(btrim(coalesce(p_tier, '')), '');
  IF v_tier IS NULL THEN
    IF p_catalog = 'league' THEN
      RETURN;
    END IF;
    v_tier := 'shared';
  END IF;

  v_club_key := nullif(btrim(coalesce(p_holder_club, '')), '');
  IF v_club_key IS NULL THEN
    v_club_key := nullif(btrim(coalesce(p_holder_key, '')), '');
  END IF;
  IF v_club_key IS NOT NULL THEN
    v_owner := public.gpsl_records_owner_tag(v_club_key);
  END IF;

  INSERT INTO public.gpsl_alltime_records (
    catalog, record_id, tier, holder_name, holder_club, holder_key, owner_tag,
    value_num, value_text, context_label, meta, computed_at
  ) VALUES (
    p_catalog, p_record_id, v_tier, p_holder_name, p_holder_club, p_holder_key, v_owner,
    p_value_num, p_value_text, p_context, coalesce(p_meta, '{}'::jsonb), now()
  )
  ON CONFLICT (catalog, record_id, tier) DO UPDATE SET
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

CREATE OR REPLACE FUNCTION public.gpsl_records_refresh_league_tier(p_tier text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '180s'
AS $function$
DECLARE
  v_n int := 0;
  v_club text;
  v_key text;
  v_val numeric;
  v_txt text;
  v_ctx text;
  v_label text;
  v_sid bigint;
  v_name text;
BEGIN
  IF p_tier NOT IN ('superleague', 'championship') THEN
    RAISE EXCEPTION 'tier must be superleague or championship';
  END IF;
  v_name := CASE WHEN p_tier = 'superleague' THEN 'Super League' ELSE 'Championship' END;

  SELECT club_short_name, count(*)::int
  INTO v_club, v_val
  FROM public.competition_club_season_archive
  WHERE final_position = 1
    AND public.gpsl_records_division_in_tier(division, p_tier)
  GROUP BY club_short_name
  ORDER BY count(*) DESC, club_short_name
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_league_titles',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' title(s)', v_name, '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, pts INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE pts IS NOT NULL
    AND public.gpsl_records_division_in_tier(division, p_tier)
  ORDER BY pts DESC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_points_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' pts', v_ctx, '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, pts INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE mp >= 10 AND pts IS NOT NULL
    AND public.gpsl_records_division_in_tier(division, p_tier)
  ORDER BY pts ASC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'fewest_points_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' pts', v_ctx || ' (≥10 matches)', '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, won INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE won IS NOT NULL
    AND public.gpsl_records_division_in_tier(division, p_tier)
  ORDER BY won DESC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_wins_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' wins', v_ctx, '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, won INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE mp >= 10 AND won IS NOT NULL
    AND public.gpsl_records_division_in_tier(division, p_tier)
  ORDER BY won ASC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'fewest_wins_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' wins', v_ctx || ' (≥10 matches)', '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, lost INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE mp >= 10 AND lost IS NOT NULL
    AND public.gpsl_records_division_in_tier(division, p_tier)
  ORDER BY lost ASC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'fewest_defeats_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' defeat(s)', v_ctx || ' (≥10 matches)', '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, drawn INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE drawn IS NOT NULL
    AND public.gpsl_records_division_in_tier(division, p_tier)
  ORDER BY drawn DESC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_draws_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' draws', v_ctx, '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, gf INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE gf IS NOT NULL
    AND public.gpsl_records_division_in_tier(division, p_tier)
  ORDER BY gf DESC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_goals_scored_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' scored', v_ctx, '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, ga INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE mp >= 10 AND ga IS NOT NULL
    AND public.gpsl_records_division_in_tier(division, p_tier)
  ORDER BY ga ASC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'fewest_goals_conceded_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' conceded', v_ctx || ' (≥10 matches)', '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT club_short_name, season_label, gd INTO v_club, v_ctx, v_val
  FROM public.gpsl_records_season_rows()
  WHERE gd IS NOT NULL
    AND public.gpsl_records_division_in_tier(division, p_tier)
  ORDER BY gd DESC NULLS LAST LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'best_goal_difference',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val,
      CASE WHEN v_val > 0 THEN '+' ELSE '' END || v_val::text,
      v_ctx, '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT c.club_short_name, c.season_label || ' · ' || c.division, (c.pts - r.pts2)
  INTO v_club, v_ctx, v_val
  FROM public.competition_club_season_archive c
  JOIN (
    SELECT season_label, division, max(pts) FILTER (WHERE final_position = 2) AS pts2
    FROM public.competition_club_season_archive
    WHERE public.gpsl_records_division_in_tier(division, p_tier)
    GROUP BY season_label, division
  ) r ON r.season_label = c.season_label AND r.division = c.division
  WHERE public.gpsl_records_division_in_tier(c.division, p_tier)
    AND c.final_position = 1 AND r.pts2 IS NOT NULL
  ORDER BY (c.pts - r.pts2) DESC
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'biggest_title_margin',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' pts clear', v_ctx, '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT c.club_short_name, c.season_label || ' · ' || c.division, (c.pts - r.pts2)
  INTO v_club, v_ctx, v_val
  FROM public.competition_club_season_archive c
  JOIN (
    SELECT season_label, division, max(pts) FILTER (WHERE final_position = 2) AS pts2
    FROM public.competition_club_season_archive
    WHERE public.gpsl_records_division_in_tier(division, p_tier)
    GROUP BY season_label, division
  ) r ON r.season_label = c.season_label AND r.division = c.division
  WHERE public.gpsl_records_division_in_tier(c.division, p_tier)
    AND c.final_position = 1 AND r.pts2 IS NOT NULL
  ORDER BY (c.pts - r.pts2) ASC
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'smallest_title_margin',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' pts clear', v_ctx, '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT home_club_short_name, coalesce(cs.label, f.season_id::text), count(*)::int
  INTO v_club, v_ctx, v_val
  FROM public.competition_fixtures f
  LEFT JOIN public.competition_seasons cs ON cs.id = f.season_id
  WHERE f.competition_type = 'league' AND f.status = 'played' AND f.home_goals > f.away_goals
    AND public.gpsl_records_division_in_tier(f.division, p_tier)
  GROUP BY home_club_short_name, coalesce(cs.label, f.season_id::text)
  ORDER BY count(*) DESC LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_home_wins_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' home wins', v_ctx, '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT away_club_short_name, coalesce(cs.label, f.season_id::text), count(*)::int
  INTO v_club, v_ctx, v_val
  FROM public.competition_fixtures f
  LEFT JOIN public.competition_seasons cs ON cs.id = f.season_id
  WHERE f.competition_type = 'league' AND f.status = 'played' AND f.away_goals > f.home_goals
    AND public.gpsl_records_division_in_tier(f.division, p_tier)
  GROUP BY away_club_short_name, coalesce(cs.label, f.season_id::text)
  ORDER BY count(*) DESC LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_away_wins_season',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' away wins', v_ctx, '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

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
    AND public.gpsl_records_division_in_tier(f.division, p_tier)
  ORDER BY abs(f.home_goals - f.away_goals) DESC, (f.home_goals + f.away_goals) DESC
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'biggest_league_win',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' goal margin', coalesce(v_label, v_ctx),
      jsonb_build_object('season_id', v_sid, 'season_label', v_label, 'match', v_ctx),
      p_tier
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
    AND public.gpsl_records_division_in_tier(f.division, p_tier)
  ORDER BY (f.home_goals + f.away_goals) DESC
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'highest_scoring_match',
      v_ctx, v_club, v_club,
      v_val, v_val::text || ' goals', coalesce(v_label, v_ctx),
      jsonb_build_object('season_id', v_sid, 'season_label', v_label, 'match', v_ctx),
      p_tier
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
    AND public.gpsl_records_division_in_tier(f.division, p_tier)
  ORDER BY greatest(f.home_goals, f.away_goals) DESC
  LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_goals_one_team_match',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' goals', coalesce(v_label, v_ctx),
      jsonb_build_object('season_id', v_sid, 'season_label', v_label, 'match', v_ctx),
      p_tier
    );
    v_n := v_n + 1;
  END IF;

  SELECT club, n INTO v_club, v_val
  FROM (
    WITH base AS (
      SELECT f.id, coalesce(f.matchday, 0) AS md,
             f.home_club_short_name AS club,
             (f.home_goals > f.away_goals) AS won
      FROM public.competition_fixtures f
      WHERE f.competition_type = 'league' AND f.status = 'played'
        AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL
        AND public.gpsl_records_division_in_tier(f.division, p_tier)
      UNION ALL
      SELECT f.id, coalesce(f.matchday, 0), f.away_club_short_name,
             (f.away_goals > f.home_goals)
      FROM public.competition_fixtures f
      WHERE f.competition_type = 'league' AND f.status = 'played'
        AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL
        AND public.gpsl_records_division_in_tier(f.division, p_tier)
    ),
    tagged AS (
      SELECT *,
        row_number() OVER (PARTITION BY club ORDER BY md, id)
          - row_number() OVER (PARTITION BY club, won ORDER BY md, id) AS wg
      FROM base
    )
    SELECT club, count(*)::int AS n FROM tagged WHERE won GROUP BY club, wg
  ) s
  ORDER BY n DESC, club LIMIT 1;
  IF FOUND THEN
    PERFORM public.gpsl_records_upsert(
      'league', 'most_consecutive_wins',
      public.gpsl_records_club_name(v_club), v_club, v_club,
      v_val, v_val::text || ' in a row', v_name, '{}'::jsonb, p_tier
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
        AND public.gpsl_records_division_in_tier(f.division, p_tier)
      UNION ALL
      SELECT f.id, coalesce(f.matchday, 0), f.away_club_short_name,
             (f.away_goals >= f.home_goals)
      FROM public.competition_fixtures f
      WHERE f.competition_type = 'league' AND f.status = 'played'
        AND f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL
        AND public.gpsl_records_division_in_tier(f.division, p_tier)
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
      v_val, v_val::text || ' unbeaten', v_name, '{}'::jsonb, p_tier
    );
    v_n := v_n + 1;
  END IF;

  IF to_regclass('public.competition_match_player_stats') IS NOT NULL THEN
    SELECT m.player_id, count(*) FILTER (WHERE coalesce(m.appeared, false))::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
      AND public.gpsl_records_division_in_tier(f.division, p_tier)
    GROUP BY m.player_id
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND AND v_val > 0 THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_league_apps',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' apps', v_name, '{}'::jsonb, p_tier
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, coalesce(sum(m.goals), 0)::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
      AND public.gpsl_records_division_in_tier(f.division, p_tier)
    GROUP BY m.player_id
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND AND v_val > 0 THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_league_goals',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' goals', v_name, '{}'::jsonb, p_tier
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, coalesce(sum(m.goals), 0)::int, coalesce(cs.label, m.season_id::text)
    INTO v_key, v_val, v_ctx
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    LEFT JOIN public.competition_seasons cs ON cs.id = m.season_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
      AND public.gpsl_records_division_in_tier(f.division, p_tier)
    GROUP BY m.player_id, coalesce(cs.label, m.season_id::text)
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND AND v_val > 0 THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_goals_season',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' goals', v_ctx, '{}'::jsonb, p_tier
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, coalesce(sum(m.assists), 0)::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
      AND public.gpsl_records_division_in_tier(f.division, p_tier)
    GROUP BY m.player_id
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND AND v_val > 0 THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_assists',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' assists', v_name, '{}'::jsonb, p_tier
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, count(*)::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played' AND coalesce(m.goals, 0) >= 3
      AND public.gpsl_records_division_in_tier(f.division, p_tier)
    GROUP BY m.player_id
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_hat_tricks',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' hat-trick(s)', v_name, '{}'::jsonb, p_tier
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, count(*) FILTER (WHERE coalesce(m.is_player_of_match, false))::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
      AND public.gpsl_records_division_in_tier(f.division, p_tier)
    GROUP BY m.player_id
    HAVING count(*) FILTER (WHERE coalesce(m.is_player_of_match, false)) > 0
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_potm',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' PoTM', v_name, '{}'::jsonb, p_tier
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, m.goals::int, m.club_short_name
    INTO v_key, v_val, v_club
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played' AND coalesce(m.goals, 0) > 0
      AND public.gpsl_records_division_in_tier(f.division, p_tier)
    ORDER BY m.goals DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_goals_single_match',
        public.gpsl_records_player_name(v_key), v_club, v_key,
        v_val, v_val::text || ' goals', public.gpsl_records_club_name(v_club), '{}'::jsonb, p_tier
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, count(*) FILTER (WHERE coalesce(m.yellow_card, false))::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
      AND public.gpsl_records_division_in_tier(f.division, p_tier)
    GROUP BY m.player_id
    HAVING count(*) FILTER (WHERE coalesce(m.yellow_card, false)) > 0
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_yellow_cards',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' yellows', v_name, '{}'::jsonb, p_tier
      );
      v_n := v_n + 1;
    END IF;

    SELECT m.player_id, count(*) FILTER (WHERE coalesce(m.red_card, false))::int
    INTO v_key, v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.competition_type = 'league' AND f.status = 'played'
      AND public.gpsl_records_division_in_tier(f.division, p_tier)
    GROUP BY m.player_id
    HAVING count(*) FILTER (WHERE coalesce(m.red_card, false)) > 0
    ORDER BY 2 DESC LIMIT 1;
    IF FOUND THEN
      PERFORM public.gpsl_records_upsert(
        'league', 'most_red_cards',
        public.gpsl_records_player_name(v_key), NULL, v_key,
        v_val, v_val::text || ' reds', v_name, '{}'::jsonb, p_tier
      );
      v_n := v_n + 1;
    END IF;
  END IF;

  RETURN v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_records_refresh_league_tier(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_records_refresh_league_tier(text) TO service_role;

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.gpsl_records_refresh()'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('league records are stored per division' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := replace($old$  PERFORM set_config('statement_timeout', '180s', true);

  -- Most Super League titles$old$, E'\r\n', E'\n');
  v_new := replace($new$  PERFORM set_config('statement_timeout', '180s', true);

  -- league records are stored per division
  v_n := v_n + public.gpsl_records_refresh_league_tier('superleague');
  v_n := v_n + public.gpsl_records_refresh_league_tier('championship');
  IF false THEN
  -- Most Super League titles$new$, E'\r\n', E'\n');
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'records refresh start needle not unique';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := replace($old$  -- CUP: wins (finals via cup_round_stage when available)$old$, E'\r\n', E'\n');
  v_new := replace($new$  END IF;

  -- CUP: wins (finals via cup_round_stage when available)$new$, E'\r\n', E'\n');
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'records refresh cup needle not unique';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;

SELECT
  public.gpsl_records_refresh_league_tier('superleague') AS superleague,
  public.gpsl_records_refresh_league_tier('championship') AS championship;
