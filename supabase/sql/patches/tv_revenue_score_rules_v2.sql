-- TV scoring rules v2
-- • Title race: SL top 4 (was 3)
-- • Remove Super8-zone boost (redundant with top-8 clash)
-- • SL relegation battle: 16–20 if still able to avoid the drop
-- • Promotion race: CH top 6 (was 2)
-- • Remove CH relegation boost
-- • Add excellent recent form + goals scored boosts

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS tv_weight_form smallint NOT NULL DEFAULT 70,
  ADD COLUMN IF NOT EXISTS tv_weight_goals smallint NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS tv_cup_per_match_amount numeric(14, 2),
  ADD COLUMN IF NOT EXISTS tv_cup_matches_per_month smallint NOT NULL DEFAULT 2,
  ADD COLUMN IF NOT EXISTS tv_weight_cup_final smallint NOT NULL DEFAULT 120,
  ADD COLUMN IF NOT EXISTS tv_weight_cup_sf smallint NOT NULL DEFAULT 80,
  ADD COLUMN IF NOT EXISTS tv_weight_cup_qf smallint NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS tv_weight_cup_r2 smallint NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS tv_weight_cup_r1 smallint NOT NULL DEFAULT 30;

UPDATE public.global_settings
SET tv_cup_per_match_amount = coalesce(tv_cup_per_match_amount, tv_per_match_amount, 1000000)
WHERE id = 1;

ALTER TABLE public.global_settings
  ALTER COLUMN tv_cup_per_match_amount SET DEFAULT 1000000;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'global_settings'
      AND column_name = 'tv_cup_per_match_amount' AND is_nullable = 'YES'
  ) THEN
    ALTER TABLE public.global_settings
      ALTER COLUMN tv_cup_per_match_amount SET NOT NULL;
  END IF;
END $$;

-- Recent league form / goals as-of a matchday (last N played league games)
CREATE OR REPLACE FUNCTION public.competition_tv_club_recent_form(
  p_season_id bigint,
  p_division text,
  p_club_short_name text,
  p_before_matchday int,
  p_last_n int DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_games int := 0;
  v_pts int := 0;
  v_wins int := 0;
  v_gf int := 0;
  r record;
BEGIN
  FOR r IN
    SELECT
      CASE
        WHEN f.home_club_short_name = p_club_short_name THEN f.home_goals
        ELSE f.away_goals
      END AS gf,
      CASE
        WHEN f.home_club_short_name = p_club_short_name THEN f.away_goals
        ELSE f.home_goals
      END AS ga
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.division = p_division
      AND f.competition_type = 'league'
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND f.matchday < greatest(coalesce(p_before_matchday, 1), 1)
      AND (
        f.home_club_short_name = p_club_short_name
        OR f.away_club_short_name = p_club_short_name
      )
    ORDER BY f.matchday DESC
    LIMIT greatest(coalesce(p_last_n, 5), 1)
  LOOP
    v_games := v_games + 1;
    v_gf := v_gf + coalesce(r.gf, 0);
    IF r.gf > r.ga THEN
      v_wins := v_wins + 1;
      v_pts := v_pts + 3;
    ELSIF r.gf = r.ga THEN
      v_pts := v_pts + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'games', v_games,
    'pts', v_pts,
    'wins', v_wins,
    'gf', v_gf
  );
END;
$function$;

-- Club still able to finish 15th or better (avoid SL drop), as-of matchday.
-- Also false if auto_relegation already clinched.
CREATE OR REPLACE FUNCTION public.competition_tv_club_can_avoid_sl_drop(
  p_season_id bigint,
  p_club_short_name text,
  p_before_matchday int
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pts int := 0;
  v_mp int := 0;
  v_games_left int;
  v_max_pts int;
  v_safety_pts int := 0;
BEGIN
  IF to_regclass('public.competition_league_clinches') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.competition_league_clinches c
      WHERE c.season_id = p_season_id
        AND c.division = 'superleague'
        AND c.club_short_name = p_club_short_name
        AND c.clinch_type = 'auto_relegation'
    ) THEN
      RETURN false;
    END IF;
  END IF;

  WITH played AS (
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.division = 'superleague'
      AND f.competition_type = 'league'
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND f.matchday < greatest(coalesce(p_before_matchday, 1), 1)
  ),
  apps AS (
    SELECT
      home_club_short_name AS club_short_name,
      CASE WHEN home_goals > away_goals THEN 3 WHEN home_goals = away_goals THEN 1 ELSE 0 END AS pts
    FROM played
    UNION ALL
    SELECT
      away_club_short_name,
      CASE WHEN away_goals > home_goals THEN 3 WHEN away_goals = home_goals THEN 1 ELSE 0 END
    FROM played
  ),
  totals AS (
    SELECT club_short_name, sum(pts)::int AS pts, count(*)::int AS mp
    FROM apps
    GROUP BY club_short_name
  ),
  registered AS (
    SELECT ccs.club_short_name, c."Club" AS club_name
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
    WHERE ccs.season_id = p_season_id
      AND ccs.division = 'superleague'
  ),
  ranked AS (
    SELECT
      r.club_short_name,
      coalesce(t.pts, 0) AS pts,
      coalesce(t.mp, 0) AS mp,
      row_number() OVER (
        ORDER BY coalesce(t.pts, 0) DESC, r.club_name ASC
      )::int AS table_position
    FROM registered r
    LEFT JOIN totals t ON t.club_short_name = r.club_short_name
  )
  SELECT
    c.pts,
    c.mp,
    coalesce(
      (SELECT s.pts FROM ranked s WHERE s.table_position = 15 LIMIT 1),
      0
    )
  INTO v_pts, v_mp, v_safety_pts
  FROM ranked c
  WHERE c.club_short_name = p_club_short_name;

  IF NOT FOUND THEN
    RETURN true;
  END IF;

  v_games_left := greatest(38 - coalesce(v_mp, 0), 0);
  v_max_pts := coalesce(v_pts, 0) + (3 * v_games_left);

  RETURN v_max_pts >= coalesce(v_safety_pts, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_tv_score_fixture(
  p_fixture_id bigint,
  p_before_matchday int,
  p_home_tv_count int,
  p_away_tv_count int,
  p_home_dry_months int,
  p_away_dry_months int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_s public.global_settings;
  v_home_div text;
  v_away_div text;
  v_home_before_md int;
  v_away_before_md int;
  v_home_pos int;
  v_away_pos int;
  v_score numeric := 0;
  v_reasons jsonb := '[]'::jsonb;
  v_cup jsonb;
  v_home_form jsonb;
  v_away_form jsonb;
  v_form_w int;
  v_goals_w int;
  v_home_in_sl_rel boolean;
  v_away_in_sl_rel boolean;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status = 'cancelled' THEN
    RETURN jsonb_build_object('score', 0, 'reasons', '[]'::jsonb);
  END IF;

  IF v_fixture.competition_type NOT IN ('league', 'cup') THEN
    RETURN jsonb_build_object('score', 0, 'reasons', '[]'::jsonb);
  END IF;

  v_s := public.tv_revenue_settings();
  v_form_w := coalesce(v_s.tv_weight_form, 70);
  v_goals_w := coalesce(v_s.tv_weight_goals, 60);

  IF v_fixture.competition_type = 'cup' THEN
    v_cup := public.competition_tv_cup_stage_bonus(v_fixture, v_s);
    v_score := coalesce((v_cup ->> 'score')::numeric, 0);
    v_reasons := coalesce(v_cup -> 'reasons', '[]'::jsonb);
  END IF;

  v_home_div := coalesce(
    public.competition_club_division_season(v_fixture.season_id, v_fixture.home_club_short_name),
    CASE WHEN v_fixture.competition_type = 'league' THEN v_fixture.division ELSE 'superleague' END
  );
  v_away_div := coalesce(
    public.competition_club_division_season(v_fixture.season_id, v_fixture.away_club_short_name),
    CASE WHEN v_fixture.competition_type = 'league' THEN v_fixture.division ELSE 'superleague' END
  );

  v_home_before_md := coalesce(
    p_before_matchday,
    public.competition_tv_division_as_of_matchday(v_fixture.season_id, v_home_div, v_fixture.gpsl_month)
  );
  v_away_before_md := coalesce(
    p_before_matchday,
    public.competition_tv_division_as_of_matchday(v_fixture.season_id, v_away_div, v_fixture.gpsl_month)
  );

  v_home_pos := public.competition_club_table_position_as_of(
    v_fixture.season_id, v_home_div, v_fixture.home_club_short_name, v_home_before_md
  );
  v_away_pos := public.competition_club_table_position_as_of(
    v_fixture.season_id, v_away_div, v_fixture.away_club_short_name, v_away_before_md
  );

  -- Super League storylines
  IF v_home_div = 'superleague' OR v_away_div = 'superleague' THEN
    IF v_home_div = 'superleague' AND v_away_div = 'superleague'
       AND v_home_pos <= 8 AND v_away_pos <= 8 THEN
      v_score := v_score + v_s.tv_weight_top8_clash;
      v_reasons := v_reasons || jsonb_build_array('top8_clash');
    END IF;

    IF (v_home_div = 'superleague' AND v_home_pos <= 4)
       OR (v_away_div = 'superleague' AND v_away_pos <= 4) THEN
      v_score := v_score + v_s.tv_weight_title_race;
      v_reasons := v_reasons || jsonb_build_array('title_race');
    END IF;

    v_home_in_sl_rel := (
      v_home_div = 'superleague'
      AND v_home_pos BETWEEN 16 AND 20
      AND public.competition_tv_club_can_avoid_sl_drop(
        v_fixture.season_id, v_fixture.home_club_short_name, v_home_before_md
      )
    );
    v_away_in_sl_rel := (
      v_away_div = 'superleague'
      AND v_away_pos BETWEEN 16 AND 20
      AND public.competition_tv_club_can_avoid_sl_drop(
        v_fixture.season_id, v_fixture.away_club_short_name, v_away_before_md
      )
    );

    IF v_home_in_sl_rel OR v_away_in_sl_rel THEN
      v_score := v_score + v_s.tv_weight_relegation;
      v_reasons := v_reasons || jsonb_build_array('sl_relegation_battle');
    END IF;
  END IF;

  -- Championship promotion race (top 6)
  IF v_home_div IN ('championship_a', 'championship_b')
     OR v_away_div IN ('championship_a', 'championship_b') THEN
    IF (v_home_div IN ('championship_a', 'championship_b') AND v_home_pos <= 6)
       OR (v_away_div IN ('championship_a', 'championship_b') AND v_away_pos <= 6) THEN
      v_score := v_score + v_s.tv_weight_promotion;
      v_reasons := v_reasons || jsonb_build_array('promotion_race');
    END IF;
  END IF;

  -- Excellent recent form / goals (league divisions only)
  IF v_home_div IN ('superleague', 'championship_a', 'championship_b') THEN
    v_home_form := public.competition_tv_club_recent_form(
      v_fixture.season_id, v_home_div, v_fixture.home_club_short_name, v_home_before_md, 5
    );
    IF coalesce((v_home_form->>'games')::int, 0) >= 3
       AND (
         coalesce((v_home_form->>'pts')::int, 0) >= 12
         OR coalesce((v_home_form->>'wins')::int, 0) >= 4
       ) THEN
      v_score := v_score + v_form_w;
      v_reasons := v_reasons || jsonb_build_array('home_excellent_form');
    END IF;
    IF coalesce((v_home_form->>'games')::int, 0) >= 3
       AND coalesce((v_home_form->>'gf')::int, 0) >= 10 THEN
      v_score := v_score + v_goals_w;
      v_reasons := v_reasons || jsonb_build_array('home_goals_spree');
    END IF;
  END IF;

  IF v_away_div IN ('superleague', 'championship_a', 'championship_b') THEN
    v_away_form := public.competition_tv_club_recent_form(
      v_fixture.season_id, v_away_div, v_fixture.away_club_short_name, v_away_before_md, 5
    );
    IF coalesce((v_away_form->>'games')::int, 0) >= 3
       AND (
         coalesce((v_away_form->>'pts')::int, 0) >= 12
         OR coalesce((v_away_form->>'wins')::int, 0) >= 4
       ) THEN
      v_score := v_score + v_form_w;
      v_reasons := v_reasons || jsonb_build_array('away_excellent_form');
    END IF;
    IF coalesce((v_away_form->>'games')::int, 0) >= 3
       AND coalesce((v_away_form->>'gf')::int, 0) >= 10 THEN
      v_score := v_score + v_goals_w;
      v_reasons := v_reasons || jsonb_build_array('away_goals_spree');
    END IF;
  END IF;

  IF p_home_dry_months >= 2 THEN
    v_score := v_score + v_s.tv_weight_dry_spell * least(p_home_dry_months, 6);
    v_reasons := v_reasons || jsonb_build_array(format('home_dry_%s_mo', p_home_dry_months));
  END IF;
  IF p_away_dry_months >= 2 THEN
    v_score := v_score + v_s.tv_weight_dry_spell * least(p_away_dry_months, 6);
    v_reasons := v_reasons || jsonb_build_array(format('away_dry_%s_mo', p_away_dry_months));
  END IF;

  IF p_home_tv_count < v_s.tv_club_min_season THEN
    v_score := v_score + v_s.tv_weight_below_min * (v_s.tv_club_min_season - p_home_tv_count);
    v_reasons := v_reasons || jsonb_build_array('home_below_min');
  END IF;
  IF p_away_tv_count < v_s.tv_club_min_season THEN
    v_score := v_score + v_s.tv_weight_below_min * (v_s.tv_club_min_season - p_away_tv_count);
    v_reasons := v_reasons || jsonb_build_array('away_below_min');
  END IF;

  IF p_home_tv_count >= v_s.tv_club_max_season THEN
    v_score := v_score - 5000;
    v_reasons := v_reasons || jsonb_build_array('home_at_max');
  END IF;
  IF p_away_tv_count >= v_s.tv_club_max_season THEN
    v_score := v_score - 5000;
    v_reasons := v_reasons || jsonb_build_array('away_at_max');
  END IF;

  RETURN jsonb_build_object(
    'score', v_score,
    'reasons', v_reasons,
    'home_position', v_home_pos,
    'away_position', v_away_pos,
    'competition_type', v_fixture.competition_type,
    'cup_code', v_fixture.cup_code
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_update_tv_settings(p_settings jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RAISE EXCEPTION 'settings must be a JSON object';
  END IF;

  UPDATE public.global_settings
  SET
    tv_per_match_amount = coalesce((p_settings->>'tv_per_match_amount')::numeric, tv_per_match_amount),
    tv_matches_per_month = coalesce((p_settings->>'tv_matches_per_month')::smallint, tv_matches_per_month),
    tv_club_min_season = coalesce((p_settings->>'tv_club_min_season')::smallint, tv_club_min_season),
    tv_club_max_season = coalesce((p_settings->>'tv_club_max_season')::smallint, tv_club_max_season),
    tv_cup_per_match_amount = coalesce((p_settings->>'tv_cup_per_match_amount')::numeric, tv_cup_per_match_amount),
    tv_cup_matches_per_month = coalesce((p_settings->>'tv_cup_matches_per_month')::smallint, tv_cup_matches_per_month),
    tv_weight_top8_clash = coalesce((p_settings->>'tv_weight_top8_clash')::smallint, tv_weight_top8_clash),
    tv_weight_title_race = coalesce((p_settings->>'tv_weight_title_race')::smallint, tv_weight_title_race),
    tv_weight_promotion = coalesce((p_settings->>'tv_weight_promotion')::smallint, tv_weight_promotion),
    tv_weight_relegation = coalesce((p_settings->>'tv_weight_relegation')::smallint, tv_weight_relegation),
    tv_weight_super8 = coalesce((p_settings->>'tv_weight_super8')::smallint, tv_weight_super8),
    tv_weight_playoff = coalesce((p_settings->>'tv_weight_playoff')::smallint, tv_weight_playoff),
    tv_weight_dry_spell = coalesce((p_settings->>'tv_weight_dry_spell')::smallint, tv_weight_dry_spell),
    tv_weight_below_min = coalesce((p_settings->>'tv_weight_below_min')::smallint, tv_weight_below_min),
    tv_weight_form = coalesce((p_settings->>'tv_weight_form')::smallint, tv_weight_form),
    tv_weight_goals = coalesce((p_settings->>'tv_weight_goals')::smallint, tv_weight_goals),
    tv_weight_cup_final = coalesce((p_settings->>'tv_weight_cup_final')::smallint, tv_weight_cup_final),
    tv_weight_cup_sf = coalesce((p_settings->>'tv_weight_cup_sf')::smallint, tv_weight_cup_sf),
    tv_weight_cup_qf = coalesce((p_settings->>'tv_weight_cup_qf')::smallint, tv_weight_cup_qf),
    tv_weight_cup_r2 = coalesce((p_settings->>'tv_weight_cup_r2')::smallint, tv_weight_cup_r2),
    tv_weight_cup_r1 = coalesce((p_settings->>'tv_weight_cup_r1')::smallint, tv_weight_cup_r1),
    updated_at = now()
  WHERE id = 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_tv_club_recent_form(bigint, text, text, int, int)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.competition_tv_club_can_avoid_sl_drop(bigint, text, int)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.competition_tv_score_fixture(bigint, int, int, int, int, int)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_tv_settings(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
