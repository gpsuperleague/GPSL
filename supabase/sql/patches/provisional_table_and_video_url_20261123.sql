-- First entered league score shows on the live table at once.
-- A rejection drops it. Confirm, deadlines, stats, and payouts stay as they are.
-- Owners can save their video url so the Discord copy line is complete.

CREATE OR REPLACE FUNCTION public.competition_fixture_month_is_open(p_fixture_id bigint)
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_fixture.season_id
  ) THEN
    RETURN true;
  END IF;

  v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());

  IF v_active IS NULL THEN
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

GRANT EXECUTE ON FUNCTION public.competition_fixture_month_is_open(bigint) TO authenticated, anon;

CREATE OR REPLACE VIEW public.competition_standings_live
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
  SELECT
    f.season_id,
    f.division,
    f.matchday,
    f.home_club_short_name,
    f.away_club_short_name,
    f.is_void,
    f.home_goals,
    f.away_goals
  FROM public.competition_fixtures f
  JOIN active_season s ON s.id = f.season_id
  WHERE f.competition_type = 'league'
    AND f.status = 'played'
    AND (f.is_void OR (f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL))
    AND public.competition_fixture_counts_in_tables(f.id)
  UNION ALL
  SELECT
    f.season_id,
    f.division,
    f.matchday,
    f.home_club_short_name,
    f.away_club_short_name,
    false AS is_void,
    sub.home_goals,
    sub.away_goals
  FROM public.competition_fixtures f
  JOIN active_season s ON s.id = f.season_id
  JOIN LATERAL (
    SELECT s2.home_goals, s2.away_goals
    FROM public.competition_result_submissions s2
    WHERE s2.fixture_id = f.id
      AND s2.status = 'pending'
    ORDER BY s2.id DESC
    LIMIT 1
  ) sub ON true
  WHERE f.competition_type = 'league'
    AND f.status = 'scheduled'
    AND coalesce(f.is_void, false) = false
    AND sub.home_goals IS NOT NULL
    AND sub.away_goals IS NOT NULL
    AND public.competition_fixture_month_is_open(f.id)
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
      CASE WHEN is_vacant THEN 1 ELSE 0 END ASC,
      CASE WHEN is_vacant THEN club_name ELSE NULL END ASC NULLS LAST,
      CASE WHEN NOT is_vacant THEN pts ELSE NULL END DESC NULLS LAST,
      CASE WHEN NOT is_vacant THEN gd ELSE NULL END DESC NULLS LAST,
      CASE WHEN NOT is_vacant THEN gf ELSE NULL END DESC NULLS LAST,
      club_name ASC
  )::int AS table_position,
  mp, w, d, l, gf, ga, gd, pts, form_last10
FROM combined;

GRANT SELECT ON public.competition_standings_live TO authenticated, anon;

CREATE OR REPLACE VIEW public.competition_standings_prizes_live
WITH (security_invoker = false)
AS
SELECT
  s.season_id,
  s.division,
  s.club_short_name,
  s.club_name,
  s.table_position,
  s.mp,
  s.w,
  s.d,
  s.l,
  s.gf,
  s.ga,
  s.gd,
  s.pts,
  s.form_last10,
  coalesce(pc.amount, 0)::numeric(14, 2) AS league_prize_amount,
  (pp.club_short_name IS NOT NULL) AS league_prize_paid
FROM public.competition_standings_live s
LEFT JOIN public.competition_league_prize_config pc
  ON pc.season_id = s.season_id
 AND pc.division = s.division
 AND pc.position = s.table_position
LEFT JOIN public.competition_league_prize_paid pp
  ON pp.season_id = s.season_id
 AND pp.division = s.division
 AND pp.club_short_name = s.club_short_name;

GRANT SELECT ON public.competition_standings_prizes_live TO authenticated, anon;

CREATE TABLE IF NOT EXISTS public.fixture_video_link_drafts (
  fixture_id bigint NOT NULL REFERENCES public.competition_fixtures (id) ON DELETE CASCADE,
  club_short_name text NOT NULL,
  video_url text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (fixture_id, club_short_name)
);

ALTER TABLE public.fixture_video_link_drafts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fixture_video_link_drafts FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.matchday_checklist_video_filename(p_fixture_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_club text := public.my_club_shortname();
  v_side text;
  v_url text;
  v_home int;
  v_away int;
  v_tag_comp text;
  v_tag_round text;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_home := v_f.home_goals;
  v_away := v_f.away_goals;
  IF v_home IS NULL OR v_away IS NULL THEN
    SELECT s.home_goals, s.away_goals
    INTO v_home, v_away
    FROM public.competition_result_submissions s
    WHERE s.fixture_id = p_fixture_id
      AND s.status = 'pending'
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  IF upper(btrim(coalesce(v_club, ''))) = upper(btrim(v_f.home_club_short_name)) THEN
    v_side := 'home';
  ELSIF upper(btrim(coalesce(v_club, ''))) = upper(btrim(v_f.away_club_short_name)) THEN
    v_side := 'away';
  END IF;

  IF v_side IS NOT NULL THEN
    SELECT d.video_url INTO v_url
    FROM public.fixture_video_link_drafts d
    WHERE d.fixture_id = p_fixture_id
      AND upper(btrim(d.club_short_name)) = upper(btrim(v_club))
    LIMIT 1;

    IF v_url IS NULL OR NOT public.match_video_url_allowed(v_url) THEN
      SELECT v.video_url INTO v_url
      FROM public.fixture_match_videos v
      WHERE v.fixture_id = p_fixture_id
        AND v.side = v_side
      ORDER BY v.id DESC
      LIMIT 1;
    END IF;
  END IF;

  IF v_url IS NULL OR NOT public.match_video_url_allowed(v_url) OR position(')' IN v_url) > 0 THEN
    v_url := 'https://youtu.be/PASTE_YOUR_LINK';
  END IF;

  v_tag_comp := CASE
    WHEN coalesce(v_f.competition_type, 'league') = 'cup' THEN
      CASE lower(coalesce(v_f.cup_code, ''))
        WHEN 'super8' THEN 'S8'
        WHEN 'plate' THEN 'PL'
        WHEN 'shield' THEN 'SH'
        WHEN 'bowl' THEN 'BO'
        WHEN 'league_cup' THEN 'LC'
        ELSE upper(coalesce(v_f.cup_code, 'CUP'))
      END
    ELSE
      CASE v_f.division
        WHEN 'superleague' THEN 'SL'
        WHEN 'championship_a' THEN 'CA'
        WHEN 'championship_b' THEN 'CB'
        ELSE 'SL'
      END
  END;

  v_tag_round := CASE
    WHEN coalesce(v_f.competition_type, 'league') = 'cup'
      THEN 'R' || coalesce(v_f.cup_round::text, '?')
    ELSE 'MD' || coalesce(v_f.matchday::text, '?')
  END;

  RETURN format(
    '[%s %s-%s %s [%s-%s]](%s)',
    upper(btrim(v_f.home_club_short_name)),
    coalesce(v_home::text, 'H'),
    coalesce(v_away::text, 'A'),
    upper(btrim(v_f.away_club_short_name)),
    v_tag_comp,
    v_tag_round,
    v_url
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_video_save_discord_link(
  p_fixture_id bigint,
  p_url text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_f public.competition_fixtures;
  v_url text := btrim(coalesce(p_url, ''));
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF upper(btrim(v_club)) NOT IN (
    upper(btrim(v_f.home_club_short_name)),
    upper(btrim(v_f.away_club_short_name))
  ) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  IF v_url = '' THEN
    DELETE FROM public.fixture_video_link_drafts
    WHERE fixture_id = p_fixture_id
      AND upper(btrim(club_short_name)) = upper(btrim(v_club));
    RETURN public.matchday_checklist_video_filename(p_fixture_id);
  END IF;

  IF NOT public.match_video_url_allowed(v_url) OR position(')' IN v_url) > 0 THEN
    RAISE EXCEPTION 'Use an https YouTube or MEGA link';
  END IF;

  INSERT INTO public.fixture_video_link_drafts (fixture_id, club_short_name, video_url, updated_at)
  VALUES (p_fixture_id, upper(btrim(v_club)), v_url, now())
  ON CONFLICT (fixture_id, club_short_name)
  DO UPDATE SET video_url = EXCLUDED.video_url, updated_at = now();

  RETURN public.matchday_checklist_video_filename(p_fixture_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_save_discord_link(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_video_save_discord_link(bigint, text) TO authenticated;

SELECT jsonb_build_object(
  'live', to_regclass('public.competition_standings_live') IS NOT NULL,
  'prizes_live', to_regclass('public.competition_standings_prizes_live') IS NOT NULL,
  'save', to_regprocedure('public.match_video_save_discord_link(bigint,text)') IS NOT NULL,
  'sample', public.matchday_checklist_video_filename(8996)
) AS ready;
