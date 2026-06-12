-- =============================================================================
-- Continental weather, pitch & eFootball kit season (GPSL Aug–May)
-- Home club continent + GPSL month → meteorological season → weighted roll.
-- Admin: admin_weather.html
-- Run after competition_phase1_fixtures.sql + competition_phase3_matchday.sql
-- =============================================================================

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS continent text CHECK (
    continent IS NULL OR continent IN (
      'south_america', 'north_america', 'northern_europe',
      'southern_europe', 'western_europe', 'asia'
    )
  );

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS pitch_condition text CHECK (
    pitch_condition IS NULL OR pitch_condition IN ('normal', 'dry', 'wet')
  ),
  ADD COLUMN IF NOT EXISTS kit_season text CHECK (
    kit_season IS NULL OR kit_season IN ('summer', 'winter')
  );

COMMENT ON COLUMN public.competition_fixtures.weather IS
  'eFootball weather at home venue: fine, rain, or snow.';
COMMENT ON COLUMN public.competition_fixtures.pitch_condition IS
  'eFootball pitch: normal, dry, or wet.';
COMMENT ON COLUMN public.competition_fixtures.kit_season IS
  'eFootball kit season at home venue: summer (short sleeves) or winter (long sleeves).';

CREATE TABLE IF NOT EXISTS public.competition_continental_condition_config (
  continent text NOT NULL CHECK (
    continent IN (
      'south_america', 'north_america', 'northern_europe',
      'southern_europe', 'western_europe', 'asia'
    )
  ),
  meteorological_season text NOT NULL CHECK (
    meteorological_season IN ('spring', 'summer', 'autumn', 'winter')
  ),
  weather_fine_pct numeric(5, 2) NOT NULL DEFAULT 60 CHECK (weather_fine_pct >= 0 AND weather_fine_pct <= 100),
  weather_rain_pct numeric(5, 2) NOT NULL DEFAULT 30 CHECK (weather_rain_pct >= 0 AND weather_rain_pct <= 100),
  weather_snow_pct numeric(5, 2) NOT NULL DEFAULT 10 CHECK (weather_snow_pct >= 0 AND weather_snow_pct <= 100),
  pitch_normal_pct numeric(5, 2) NOT NULL DEFAULT 50 CHECK (pitch_normal_pct >= 0 AND pitch_normal_pct <= 100),
  pitch_dry_pct numeric(5, 2) NOT NULL DEFAULT 25 CHECK (pitch_dry_pct >= 0 AND pitch_dry_pct <= 100),
  pitch_wet_pct numeric(5, 2) NOT NULL DEFAULT 25 CHECK (pitch_wet_pct >= 0 AND pitch_wet_pct <= 100),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (continent, meteorological_season),
  CONSTRAINT competition_continental_weather_pct_sum CHECK (
    round(weather_fine_pct + weather_rain_pct + weather_snow_pct, 2) = 100
  ),
  CONSTRAINT competition_continental_pitch_pct_sum CHECK (
    round(pitch_normal_pct + pitch_dry_pct + pitch_wet_pct, 2) = 100
  )
);

-- ---------------------------------------------------------------------------
-- Nation → continent (Clubs.continent overrides when set)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_normalize_nation_key(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(regexp_replace(btrim(coalesce(p_value, '')), '\s+', ' ', 'g'));
$$;

CREATE OR REPLACE FUNCTION public.competition_nation_to_continent(p_nation text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := public.competition_normalize_nation_key(p_nation);
BEGIN
  IF v = '' THEN
    RETURN 'western_europe';
  END IF;

  IF v = ANY (ARRAY[
    'brazil', 'argentina', 'chile', 'colombia', 'uruguay', 'paraguay', 'peru',
    'ecuador', 'bolivia', 'venezuela'
  ]) THEN
    RETURN 'south_america';
  END IF;

  IF v = ANY (ARRAY[
    'usa', 'united states', 'canada', 'mexico'
  ]) THEN
    RETURN 'north_america';
  END IF;

  IF v = ANY (ARRAY[
    'sweden', 'norway', 'finland', 'denmark', 'scotland', 'russia',
    'iceland', 'estonia', 'latvia', 'lithuania', 'belarus', 'ukraine'
  ]) OR v LIKE '%russia%' THEN
    RETURN 'northern_europe';
  END IF;

  IF v = ANY (ARRAY[
    'spain', 'italy', 'portugal', 'greece', 'croatia', 'serbia', 'romania',
    'bulgaria', 'turkey', 'cyprus', 'malta', 'israel', 'slovenia', 'bosnia'
  ]) THEN
    RETURN 'southern_europe';
  END IF;

  IF v = ANY (ARRAY[
    'japan', 'korea', 'south korea', 'north korea', 'china', 'saudi arabia',
    'uae', 'united arab emirates', 'qatar', 'australia', 'thailand',
    'indonesia', 'malaysia', 'singapore', 'india', 'iran', 'iraq'
  ]) THEN
    RETURN 'asia';
  END IF;

  IF v = ANY (ARRAY[
    'england', 'france', 'germany', 'netherlands', 'belgium', 'switzerland',
    'austria', 'wales', 'ireland', 'republic of ireland', 'northern ireland',
    'luxembourg', 'poland', 'czech republic', 'czechia', 'hungary'
  ]) THEN
    RETURN 'western_europe';
  END IF;

  RETURN 'western_europe';
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_club_continent(p_club_short_name text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    nullif(btrim(c.continent), ''),
    public.competition_nation_to_continent(c."Nation"),
    'western_europe'
  )
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;
$$;

-- GPSL month → meteorological season per continent (Aug–May season)
CREATE OR REPLACE FUNCTION public.competition_gpsl_meteorological_season(
  p_continent text,
  p_gpsl_month text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE coalesce(p_continent, 'western_europe')
    WHEN 'south_america' THEN CASE p_gpsl_month
      WHEN 'august' THEN 'winter'
      WHEN 'september' THEN 'spring'
      WHEN 'october' THEN 'spring'
      WHEN 'november' THEN 'spring'
      WHEN 'december' THEN 'summer'
      WHEN 'january' THEN 'summer'
      WHEN 'february' THEN 'summer'
      WHEN 'march' THEN 'autumn'
      WHEN 'april' THEN 'autumn'
      WHEN 'may' THEN 'autumn'
      ELSE 'spring'
    END
    WHEN 'asia' THEN CASE p_gpsl_month
      WHEN 'march' THEN 'spring'
      WHEN 'april' THEN 'spring'
      WHEN 'may' THEN 'spring'
      WHEN 'august' THEN 'summer'
      WHEN 'september' THEN 'autumn'
      WHEN 'october' THEN 'autumn'
      WHEN 'november' THEN 'autumn'
      WHEN 'december' THEN 'winter'
      WHEN 'january' THEN 'winter'
      WHEN 'february' THEN 'winter'
      ELSE 'spring'
    END
    WHEN 'north_america' THEN CASE p_gpsl_month
      WHEN 'march' THEN 'spring'
      WHEN 'april' THEN 'spring'
      WHEN 'may' THEN 'spring'
      WHEN 'august' THEN 'summer'
      WHEN 'september' THEN 'autumn'
      WHEN 'october' THEN 'autumn'
      WHEN 'november' THEN 'autumn'
      WHEN 'december' THEN 'winter'
      WHEN 'january' THEN 'winter'
      WHEN 'february' THEN 'winter'
      ELSE 'spring'
    END
    ELSE CASE p_gpsl_month
      WHEN 'march' THEN 'spring'
      WHEN 'april' THEN 'spring'
      WHEN 'may' THEN 'spring'
      WHEN 'august' THEN 'summer'
      WHEN 'september' THEN 'autumn'
      WHEN 'october' THEN 'autumn'
      WHEN 'november' THEN 'winter'
      WHEN 'december' THEN 'winter'
      WHEN 'january' THEN 'winter'
      WHEN 'february' THEN 'winter'
      ELSE 'spring'
    END
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_efootball_kit_season(p_meteorological_season text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE coalesce(p_meteorological_season, 'spring')
    WHEN 'summer' THEN 'summer'
    WHEN 'spring' THEN 'summer'
    ELSE 'winter'
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_weighted_pick_3(
  p_a text,
  p_a_pct numeric,
  p_b text,
  p_b_pct numeric,
  p_c text,
  p_c_pct numeric
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
  v_total numeric;
  v_r numeric;
BEGIN
  v_total := greatest(coalesce(p_a_pct, 0), 0)
    + greatest(coalesce(p_b_pct, 0), 0)
    + greatest(coalesce(p_c_pct, 0), 0);

  IF v_total <= 0 THEN
    RETURN p_a;
  END IF;

  v_r := random() * v_total;

  IF v_r < p_a_pct THEN
    RETURN p_a;
  ELSIF v_r < p_a_pct + p_b_pct THEN
    RETURN p_b;
  END IF;

  RETURN p_c;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_roll_home_match_conditions(
  p_home_club_short_name text,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_continent text;
  v_season text;
  v_cfg public.competition_continental_condition_config%rowtype;
  v_weather text;
  v_pitch text;
  v_kit text;
BEGIN
  v_continent := public.competition_club_continent(p_home_club_short_name);
  v_season := public.competition_gpsl_meteorological_season(v_continent, p_gpsl_month);
  v_kit := public.competition_efootball_kit_season(v_season);

  SELECT * INTO v_cfg
  FROM public.competition_continental_condition_config c
  WHERE c.continent = v_continent
    AND c.meteorological_season = v_season;

  IF NOT FOUND THEN
    v_weather := 'fine';
    v_pitch := 'normal';
  ELSE
    v_weather := public.competition_weighted_pick_3(
      'fine', v_cfg.weather_fine_pct,
      'rain', v_cfg.weather_rain_pct,
      'snow', v_cfg.weather_snow_pct
    );
    v_pitch := public.competition_weighted_pick_3(
      'normal', v_cfg.pitch_normal_pct,
      'dry', v_cfg.pitch_dry_pct,
      'wet', v_cfg.pitch_wet_pct
    );
  END IF;

  RETURN jsonb_build_object(
    'continent', v_continent,
    'meteorological_season', v_season,
    'weather', v_weather,
    'pitch_condition', v_pitch,
    'kit_season', v_kit
  );
END;
$function$;

-- Default probability tables (admin-editable)
INSERT INTO public.competition_continental_condition_config (
  continent, meteorological_season,
  weather_fine_pct, weather_rain_pct, weather_snow_pct,
  pitch_normal_pct, pitch_dry_pct, pitch_wet_pct
)
VALUES
  ('south_america', 'spring', 55, 40, 5, 45, 30, 25),
  ('south_america', 'summer', 65, 30, 5, 40, 40, 20),
  ('south_america', 'autumn', 50, 45, 5, 45, 25, 30),
  ('south_america', 'winter', 45, 45, 10, 40, 25, 35),
  ('north_america', 'spring', 55, 40, 5, 45, 30, 25),
  ('north_america', 'summer', 70, 25, 5, 35, 45, 20),
  ('north_america', 'autumn', 50, 45, 5, 40, 25, 35),
  ('north_america', 'winter', 40, 45, 15, 45, 20, 35),
  ('northern_europe', 'spring', 45, 50, 5, 45, 25, 30),
  ('northern_europe', 'summer', 55, 40, 5, 40, 35, 25),
  ('northern_europe', 'autumn', 40, 50, 10, 40, 20, 40),
  ('northern_europe', 'winter', 30, 45, 25, 35, 15, 50),
  ('southern_europe', 'spring', 60, 35, 5, 40, 35, 25),
  ('southern_europe', 'summer', 80, 15, 5, 30, 50, 20),
  ('southern_europe', 'autumn', 55, 40, 5, 40, 30, 30),
  ('southern_europe', 'winter', 50, 45, 5, 45, 25, 30),
  ('western_europe', 'spring', 50, 45, 5, 45, 30, 25),
  ('western_europe', 'summer', 60, 35, 5, 40, 35, 25),
  ('western_europe', 'autumn', 45, 50, 5, 40, 25, 35),
  ('western_europe', 'winter', 35, 50, 15, 40, 20, 40),
  ('asia', 'spring', 55, 40, 5, 45, 30, 25),
  ('asia', 'summer', 65, 30, 5, 35, 40, 25),
  ('asia', 'autumn', 50, 45, 5, 40, 30, 30),
  ('asia', 'winter', 40, 45, 15, 45, 20, 35)
ON CONFLICT (continent, meteorological_season) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Admin RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_continental_conditions_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_agg(to_jsonb(c) ORDER BY c.continent, c.meteorological_season)
      FROM public.competition_continental_condition_config c
    ),
    '[]'::jsonb
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_save_continental_conditions(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row jsonb;
  v_weather_sum numeric;
  v_pitch_sum numeric;
  v_count int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'Expected JSON array of config rows';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    v_weather_sum :=
      coalesce((v_row ->> 'weather_fine_pct')::numeric, 0)
      + coalesce((v_row ->> 'weather_rain_pct')::numeric, 0)
      + coalesce((v_row ->> 'weather_snow_pct')::numeric, 0);
    v_pitch_sum :=
      coalesce((v_row ->> 'pitch_normal_pct')::numeric, 0)
      + coalesce((v_row ->> 'pitch_dry_pct')::numeric, 0)
      + coalesce((v_row ->> 'pitch_wet_pct')::numeric, 0);

    IF round(v_weather_sum, 2) <> 100 OR round(v_pitch_sum, 2) <> 100 THEN
      RAISE EXCEPTION 'Weather and pitch percentages must each sum to 100 (got weather %, pitch %)',
        v_weather_sum, v_pitch_sum;
    END IF;

    INSERT INTO public.competition_continental_condition_config (
      continent, meteorological_season,
      weather_fine_pct, weather_rain_pct, weather_snow_pct,
      pitch_normal_pct, pitch_dry_pct, pitch_wet_pct,
      updated_at
    )
    VALUES (
      v_row ->> 'continent',
      v_row ->> 'meteorological_season',
      (v_row ->> 'weather_fine_pct')::numeric,
      (v_row ->> 'weather_rain_pct')::numeric,
      (v_row ->> 'weather_snow_pct')::numeric,
      (v_row ->> 'pitch_normal_pct')::numeric,
      (v_row ->> 'pitch_dry_pct')::numeric,
      (v_row ->> 'pitch_wet_pct')::numeric,
      now()
    )
    ON CONFLICT (continent, meteorological_season) DO UPDATE
    SET weather_fine_pct = excluded.weather_fine_pct,
        weather_rain_pct = excluded.weather_rain_pct,
        weather_snow_pct = excluded.weather_snow_pct,
        pitch_normal_pct = excluded.pitch_normal_pct,
        pitch_dry_pct = excluded.pitch_dry_pct,
        pitch_wet_pct = excluded.pitch_wet_pct,
        updated_at = now();

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'rows_saved', v_count);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_reapply_fixture_conditions(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_row record;
  v_cond jsonb;
  v_count int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No season to reapply conditions for';
  END IF;

  FOR v_row IN
    SELECT id, home_club_short_name, gpsl_month
    FROM public.competition_fixtures
    WHERE season_id = v_season_id
      AND status = 'scheduled'
  LOOP
    v_cond := public.competition_roll_home_match_conditions(
      v_row.home_club_short_name,
      v_row.gpsl_month
    );

    UPDATE public.competition_fixtures f
    SET
      weather = v_cond ->> 'weather',
      pitch_condition = v_cond ->> 'pitch_condition',
      kit_season = v_cond ->> 'kit_season'
    WHERE f.id = v_row.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'fixtures_updated', v_count, 'season_id', v_season_id);
END;
$function$;

-- Patch league fixture generator to roll home conditions
CREATE OR REPLACE FUNCTION public.competition_generate_league_fixtures(
  p_season_id bigint,
  p_division text,
  p_shuffle_slots boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_teams text[];
  v_round int;
  v_matchday int;
  v_i int;
  v_home text;
  v_away text;
  v_cal record;
  v_cond jsonb;
  v_inserted bigint := 0;
BEGIN
  PERFORM public.competition_assert_fixture_season(p_season_id);
  PERFORM public.competition_assert_league_division(p_division);

  IF p_shuffle_slots THEN
    PERFORM public.competition_shuffle_division_slots(p_season_id, p_division);
  END IF;

  SELECT count(*) INTO v_i
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id
    AND division = p_division
    AND league_position BETWEEN 1 AND 20;

  IF v_i <> 20 THEN
    RAISE EXCEPTION 'Assign all 20 table slots before generating (have %)', v_i;
  END IF;

  SELECT array_agg(club_short_name ORDER BY league_position)
  INTO v_teams
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id
    AND division = p_division;

  DELETE FROM public.competition_fixtures
  WHERE season_id = p_season_id
    AND division = p_division
    AND competition_type = 'league';

  FOR v_round IN 1..19
  LOOP
    v_matchday := v_round;
    SELECT * INTO v_cal FROM public.competition_matchday_calendar(v_matchday);

    FOR v_i IN 1..10
    LOOP
      IF v_i = 1 THEN
        v_home := v_teams[1];
        v_away := v_teams[20];
      ELSE
        v_home := v_teams[v_i];
        v_away := v_teams[21 - v_i];
      END IF;

      v_cond := public.competition_roll_home_match_conditions(v_home, v_cal.gpsl_month);

      INSERT INTO public.competition_fixtures (
        season_id, division, competition_type, matchday,
        gpsl_month, week_in_month,
        home_club_short_name, away_club_short_name,
        weather, pitch_condition, kit_season
      )
      VALUES (
        p_season_id, p_division, 'league', v_matchday,
        v_cal.gpsl_month, v_cal.week_in_month,
        v_home, v_away,
        v_cond ->> 'weather',
        v_cond ->> 'pitch_condition',
        v_cond ->> 'kit_season'
      );

      v_inserted := v_inserted + 1;
    END LOOP;

    v_teams := ARRAY[v_teams[1], v_teams[20]] || v_teams[2:19];
  END LOOP;

  v_teams := NULL;
  SELECT array_agg(club_short_name ORDER BY league_position)
  INTO v_teams
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id
    AND division = p_division;

  FOR v_round IN 1..19
  LOOP
    v_matchday := v_round + 19;
    SELECT * INTO v_cal FROM public.competition_matchday_calendar(v_matchday);

    FOR v_i IN 1..10
    LOOP
      IF v_i = 1 THEN
        v_home := v_teams[20];
        v_away := v_teams[1];
      ELSE
        v_home := v_teams[21 - v_i];
        v_away := v_teams[v_i];
      END IF;

      v_cond := public.competition_roll_home_match_conditions(v_home, v_cal.gpsl_month);

      INSERT INTO public.competition_fixtures (
        season_id, division, competition_type, matchday,
        gpsl_month, week_in_month,
        home_club_short_name, away_club_short_name,
        weather, pitch_condition, kit_season
      )
      VALUES (
        p_season_id, p_division, 'league', v_matchday,
        v_cal.gpsl_month, v_cal.week_in_month,
        v_home, v_away,
        v_cond ->> 'weather',
        v_cond ->> 'pitch_condition',
        v_cond ->> 'kit_season'
      );

      v_inserted := v_inserted + 1;
    END LOOP;

    v_teams := ARRAY[v_teams[1], v_teams[20]] || v_teams[2:19];
  END LOOP;

  RETURN jsonb_build_object(
    'division', p_division,
    'fixtures_created', v_inserted,
    'matchdays', 38
  );
END;
$function$;

-- Cup fixtures: roll conditions from home club (requires competition_cup_schedule.sql)
CREATE OR REPLACE FUNCTION public.competition_create_cup_fixture_for_node(p_node_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_node public.competition_cup_bracket_nodes;
  v_sched public.competition_cup_round_schedule;
  v_fixture_id bigint;
  v_cond jsonb;
BEGIN
  SELECT * INTO v_node FROM public.competition_cup_bracket_nodes WHERE id = p_node_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Bracket node not found';
  END IF;

  IF v_node.home_club_short_name IS NULL OR v_node.away_club_short_name IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_node.fixture_id IS NOT NULL THEN
    RETURN v_node.fixture_id;
  END IF;

  SELECT * INTO v_sched
  FROM public.competition_cup_round_schedule s
  WHERE s.cup_code = v_node.cup_code
    AND s.round_no = v_node.round_no
    AND s.cup_leg = coalesce(v_node.cup_leg, 1);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No cup schedule for % round % leg %',
      v_node.cup_code, v_node.round_no, v_node.cup_leg;
  END IF;

  v_cond := public.competition_roll_home_match_conditions(
    v_node.home_club_short_name,
    v_sched.gpsl_month
  );

  INSERT INTO public.competition_fixtures (
    season_id,
    division,
    competition_type,
    matchday,
    gpsl_month,
    week_in_month,
    home_club_short_name,
    away_club_short_name,
    weather,
    pitch_condition,
    kit_season,
    cup_code,
    cup_round,
    cup_match,
    cup_leg
  )
  VALUES (
    v_node.season_id,
    'cup',
    'cup',
    v_node.round_no,
    v_sched.gpsl_month,
    1,
    v_node.home_club_short_name,
    v_node.away_club_short_name,
    v_cond ->> 'weather',
    v_cond ->> 'pitch_condition',
    v_cond ->> 'kit_season',
    v_node.cup_code,
    v_node.round_no,
    v_node.match_no,
    coalesce(v_node.cup_leg, 1)
  )
  RETURNING id INTO v_fixture_id;

  UPDATE public.competition_cup_bracket_nodes
  SET fixture_id = v_fixture_id
  WHERE id = p_node_id;

  RETURN v_fixture_id;
END;
$function$;

CREATE OR REPLACE VIEW public.competition_fixtures_public
WITH (security_invoker = false)
AS
SELECT
  f.id,
  f.season_id,
  f.division,
  f.competition_type,
  f.matchday,
  f.gpsl_month,
  f.week_in_month,
  f.home_club_short_name,
  hc."Club" AS home_club_name,
  f.away_club_short_name,
  ac."Club" AS away_club_name,
  f.weather,
  f.pitch_condition,
  f.kit_season,
  public.competition_club_continent(f.home_club_short_name) AS home_continent,
  f.home_goals,
  f.away_goals,
  f.status,
  sub.submission_id,
  sub.submission_status,
  sub.submitted_by_club,
  sub.proposed_home_goals,
  sub.proposed_away_goals
FROM public.competition_fixtures f
JOIN public.competition_seasons s ON s.id = f.season_id
JOIN public."Clubs" hc ON hc."ShortName" = f.home_club_short_name
JOIN public."Clubs" ac ON ac."ShortName" = f.away_club_short_name
LEFT JOIN LATERAL (
  SELECT
    rs.id AS submission_id,
    rs.status AS submission_status,
    rs.submitted_by_club,
    rs.home_goals AS proposed_home_goals,
    rs.away_goals AS proposed_away_goals
  FROM public.competition_result_submissions rs
  WHERE rs.fixture_id = f.id
    AND rs.status = 'pending'
  LIMIT 1
) sub ON true
WHERE s.status = 'active' AND s.is_current = true;

GRANT EXECUTE ON FUNCTION public.competition_admin_continental_conditions_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_save_continental_conditions(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_reapply_fixture_conditions(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_continent(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_roll_home_match_conditions(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
