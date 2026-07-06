-- =============================================================================
-- TV revenue: combined league + cup pool (5 total per division/month),
-- auto-select for next month when a GPSL month locks.
-- Run after tv_revenue_home_away_split.sql and tv_revenue_split_backfill.sql
--
-- Backfill legacy payouts (if not done):
--   SELECT public.competition_admin_backfill_tv_revenue_split(NULL::bigint, false);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_gpsl_month_next(p_month text)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT CASE public.competition_gpsl_month_sort(p_month)
    WHEN 1 THEN 'september'
    WHEN 2 THEN 'october'
    WHEN 3 THEN 'november'
    WHEN 4 THEN 'december'
    WHEN 5 THEN 'january'
    WHEN 6 THEN 'february'
    WHEN 7 THEN 'march'
    WHEN 8 THEN 'april'
    WHEN 9 THEN 'may'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_club_division_season(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT ccs.division
  FROM public.competition_club_seasons ccs
  WHERE ccs.season_id = p_season_id
    AND ccs.club_short_name = btrim(p_club_short_name)
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.competition_tv_fixture_effective_division(
  p_fixture public.competition_fixtures
)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $function$
DECLARE
  v_home_div text;
BEGIN
  IF p_fixture.competition_type = 'league' THEN
    RETURN p_fixture.division;
  END IF;

  IF p_fixture.cup_code = 'super8' THEN
    RETURN 'superleague';
  END IF;

  v_home_div := public.competition_club_division_season(
    p_fixture.season_id,
    p_fixture.home_club_short_name
  );

  RETURN coalesce(v_home_div, 'superleague');
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_tv_division_as_of_matchday(
  p_season_id bigint,
  p_division text,
  p_gpsl_month text
)
RETURNS int
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT min(f.matchday)::int
      FROM public.competition_fixtures f
      WHERE f.season_id = p_season_id
        AND f.division = p_division
        AND f.competition_type = 'league'
        AND f.gpsl_month = p_gpsl_month
        AND f.status <> 'cancelled'
    ),
    (
      SELECT coalesce(max(f.matchday), 0)::int + 1
      FROM public.competition_fixtures f
      WHERE f.season_id = p_season_id
        AND f.division = p_division
        AND f.competition_type = 'league'
        AND public.competition_gpsl_month_sort(f.gpsl_month)
          < public.competition_gpsl_month_sort(p_gpsl_month)
        AND f.status = 'played'
    ),
    1
  );
$$;

CREATE OR REPLACE FUNCTION public.competition_tv_fixture_settle_label(
  p_fixture public.competition_fixtures
)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_fixture.competition_type = 'cup'
      AND to_regprocedure('public.competition_cup_fixture_label(public.competition_fixtures)') IS NOT NULL
      THEN public.competition_cup_fixture_label(p_fixture)
    WHEN p_fixture.competition_type = 'cup' THEN
      upper(replace(coalesce(p_fixture.cup_code, 'cup'), '_', ' '))
        || format(' R%s', coalesce(p_fixture.cup_round, 0))
    ELSE format('MD%s', coalesce(p_fixture.matchday, 0))
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_tv_cup_stage_bonus(
  p_fixture public.competition_fixtures,
  p_settings public.global_settings
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $function$
DECLARE
  v_max_round int;
  v_stage text;
  v_score numeric := 0;
  v_reasons jsonb := '[]'::jsonb;
BEGIN
  SELECT max(n.round_no)
  INTO v_max_round
  FROM public.competition_cup_bracket_nodes n
  WHERE n.season_id = p_fixture.season_id
    AND n.cup_code = p_fixture.cup_code;

  IF v_max_round IS NULL OR p_fixture.cup_round IS NULL THEN
    RETURN jsonb_build_object('score', 0, 'reasons', '[]'::jsonb);
  END IF;

  v_stage := public.competition_cup_round_stage(
    p_fixture.cup_code,
    p_fixture.cup_round,
    v_max_round
  );

  CASE v_stage
    WHEN 'final' THEN
      v_score := v_score + round(p_settings.tv_weight_title_race * 1.5, 2);
      v_reasons := v_reasons || jsonb_build_array('cup_final');
    WHEN 'sf' THEN
      v_score := v_score + p_settings.tv_weight_title_race;
      v_reasons := v_reasons || jsonb_build_array('cup_sf');
    WHEN 'qf' THEN
      v_score := v_score + p_settings.tv_weight_top8_clash;
      v_reasons := v_reasons || jsonb_build_array('cup_qf');
    WHEN 'r2' THEN
      v_score := v_score + p_settings.tv_weight_super8;
      v_reasons := v_reasons || jsonb_build_array('cup_r2');
    ELSE
      v_score := v_score + round(p_settings.tv_weight_super8 * 0.5, 2);
      v_reasons := v_reasons || jsonb_build_array('cup_r1');
  END CASE;

  CASE p_fixture.cup_code
    WHEN 'super8' THEN
      v_score := v_score + p_settings.tv_weight_top8_clash;
      v_reasons := v_reasons || jsonb_build_array('super8_cup');
    WHEN 'league_cup' THEN
      v_score := v_score + p_settings.tv_weight_promotion;
      v_reasons := v_reasons || jsonb_build_array('league_cup');
    WHEN 'plate' THEN
      v_score := v_score + p_settings.tv_weight_playoff;
      v_reasons := v_reasons || jsonb_build_array('plate_cup');
    WHEN 'shield' THEN
      v_score := v_score + p_settings.tv_weight_relegation;
      v_reasons := v_reasons || jsonb_build_array('shield_cup');
    WHEN 'spoon', 'bowl' THEN
      v_score := v_score + p_settings.tv_weight_relegation;
      v_reasons := v_reasons || jsonb_build_array('bowl_cup');
    ELSE
      NULL;
  END CASE;

  RETURN jsonb_build_object('score', v_score, 'reasons', v_reasons);
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
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status = 'cancelled' THEN
    RETURN jsonb_build_object('score', 0, 'reasons', '[]'::jsonb);
  END IF;

  IF v_fixture.competition_type NOT IN ('league', 'cup') THEN
    RETURN jsonb_build_object('score', 0, 'reasons', '[]'::jsonb);
  END IF;

  v_s := public.tv_revenue_settings();

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

  IF v_home_div = 'superleague' OR v_away_div = 'superleague' THEN
    IF v_home_pos <= 8 AND v_away_pos <= 8 THEN
      v_score := v_score + v_s.tv_weight_top8_clash;
      v_reasons := v_reasons || jsonb_build_array('top8_clash');
    END IF;
    IF v_home_pos <= 8 OR v_away_pos <= 8 THEN
      v_score := v_score + v_s.tv_weight_super8;
      v_reasons := v_reasons || jsonb_build_array('super8_zone');
    END IF;
    IF v_home_pos <= 3 OR v_away_pos <= 3 THEN
      v_score := v_score + v_s.tv_weight_title_race;
      v_reasons := v_reasons || jsonb_build_array('title_race');
    END IF;
    IF (v_home_pos >= 16 AND v_home_pos <= 17) OR (v_away_pos >= 16 AND v_away_pos <= 17) THEN
      v_score := v_score + v_s.tv_weight_playoff;
      v_reasons := v_reasons || jsonb_build_array('relegation_playoff');
    END IF;
    IF v_home_pos >= 18 OR v_away_pos >= 18 THEN
      v_score := v_score + v_s.tv_weight_relegation;
      v_reasons := v_reasons || jsonb_build_array('relegation_battle');
    END IF;
  END IF;

  IF v_home_div IN ('championship_a', 'championship_b')
     OR v_away_div IN ('championship_a', 'championship_b') THEN
    IF v_home_pos <= 2 OR v_away_pos <= 2 THEN
      v_score := v_score + v_s.tv_weight_promotion;
      v_reasons := v_reasons || jsonb_build_array('promotion_race');
    END IF;
    IF v_home_pos >= 18 OR v_away_pos >= 18 THEN
      v_score := v_score + v_s.tv_weight_relegation;
      v_reasons := v_reasons || jsonb_build_array('relegation_battle');
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

CREATE OR REPLACE FUNCTION public.competition_tv_select_division_month(
  p_season_id bigint,
  p_division text,
  p_gpsl_month text,
  p_replace boolean DEFAULT false
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s public.global_settings;
  v_before_md int;
  v_pick int;
  v_selected int := 0;
  v_fixture record;
  v_scored record;
  v_home_count int;
  v_away_count int;
  v_home_dry int;
  v_away_dry int;
  v_breakdown jsonb;
  v_running_home int;
  v_running_away int;
  v_full_fixture public.competition_fixtures;
BEGIN
  IF p_season_id IS NULL OR p_division IS NULL OR p_gpsl_month IS NULL THEN
    RETURN 0;
  END IF;

  v_s := public.tv_revenue_settings();
  v_pick := greatest(v_s.tv_matches_per_month, 0);

  IF NOT p_replace AND EXISTS (
    SELECT 1 FROM public.competition_tv_fixture_selection
    WHERE season_id = p_season_id
      AND division = p_division
      AND gpsl_month = p_gpsl_month
  ) THEN
    RETURN 0;
  END IF;

  IF p_replace THEN
    DELETE FROM public.competition_tv_fixture_selection
    WHERE season_id = p_season_id
      AND division = p_division
      AND gpsl_month = p_gpsl_month;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.gpsl_month = p_gpsl_month
      AND f.status <> 'cancelled'
      AND (
        (f.competition_type = 'league' AND f.division = p_division)
        OR (
          f.competition_type = 'cup'
          AND public.competition_tv_fixture_effective_division(f) = p_division
        )
      )
  ) THEN
    RETURN 0;
  END IF;

  v_before_md := public.competition_tv_division_as_of_matchday(p_season_id, p_division, p_gpsl_month);

  CREATE TEMP TABLE IF NOT EXISTS tv_month_candidates (
    fixture_id bigint PRIMARY KEY,
    home_club text NOT NULL,
    away_club text NOT NULL,
    tv_score numeric NOT NULL,
    reasons jsonb NOT NULL,
    home_tv_count int NOT NULL,
    away_tv_count int NOT NULL
  ) ON COMMIT DROP;

  TRUNCATE tv_month_candidates;

  FOR v_fixture IN
    SELECT f.id, f.home_club_short_name, f.away_club_short_name
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.gpsl_month = p_gpsl_month
      AND f.status <> 'cancelled'
      AND (
        (f.competition_type = 'league' AND f.division = p_division)
        OR (
          f.competition_type = 'cup'
          AND public.competition_tv_fixture_effective_division(f) = p_division
        )
      )
  LOOP
    v_home_count := public.competition_tv_club_count_before_month(
      p_season_id, p_division, v_fixture.home_club_short_name, p_gpsl_month
    );
    v_away_count := public.competition_tv_club_count_before_month(
      p_season_id, p_division, v_fixture.away_club_short_name, p_gpsl_month
    );
    v_home_dry := public.competition_tv_months_since_last(
      p_season_id, p_division, v_fixture.home_club_short_name, p_gpsl_month
    );
    v_away_dry := public.competition_tv_months_since_last(
      p_season_id, p_division, v_fixture.away_club_short_name, p_gpsl_month
    );

    v_breakdown := public.competition_tv_score_fixture(
      v_fixture.id,
      v_before_md,
      v_home_count,
      v_away_count,
      v_home_dry,
      v_away_dry
    );

    IF coalesce((v_breakdown ->> 'score')::numeric, 0) <= 0 THEN
      CONTINUE;
    END IF;

    INSERT INTO tv_month_candidates (
      fixture_id, home_club, away_club, tv_score, reasons, home_tv_count, away_tv_count
    )
    VALUES (
      v_fixture.id,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name,
      (v_breakdown ->> 'score')::numeric,
      coalesce(v_breakdown -> 'reasons', '[]'::jsonb),
      v_home_count,
      v_away_count
    );
  END LOOP;

  FOR v_scored IN
    SELECT *
    FROM tv_month_candidates
    ORDER BY tv_score DESC, fixture_id ASC
  LOOP
    EXIT WHEN v_selected >= v_pick;

    IF EXISTS (
      SELECT 1
      FROM public.competition_tv_fixture_selection s
      WHERE s.season_id = p_season_id
        AND s.fixture_id = v_scored.fixture_id
    ) THEN
      CONTINUE;
    END IF;

    v_running_home := v_scored.home_tv_count + (
      SELECT count(*)::int
      FROM public.competition_tv_fixture_selection s
      JOIN public.competition_fixtures f ON f.id = s.fixture_id
      WHERE s.season_id = p_season_id
        AND s.division = p_division
        AND s.gpsl_month = p_gpsl_month
        AND (f.home_club_short_name = v_scored.home_club OR f.away_club_short_name = v_scored.home_club)
    );
    v_running_away := v_scored.away_tv_count + (
      SELECT count(*)::int
      FROM public.competition_tv_fixture_selection s
      JOIN public.competition_fixtures f ON f.id = s.fixture_id
      WHERE s.season_id = p_season_id
        AND s.division = p_division
        AND s.gpsl_month = p_gpsl_month
        AND (f.home_club_short_name = v_scored.away_club OR f.away_club_short_name = v_scored.away_club)
    );

    IF v_running_home >= v_s.tv_club_max_season AND v_running_away >= v_s.tv_club_max_season THEN
      CONTINUE;
    END IF;

    INSERT INTO public.competition_tv_fixture_selection (
      season_id, fixture_id, division, gpsl_month, tv_score, reasons
    )
    VALUES (
      p_season_id,
      v_scored.fixture_id,
      p_division,
      p_gpsl_month,
      v_scored.tv_score,
      v_scored.reasons
    )
    ON CONFLICT ON CONSTRAINT competition_tv_fixture_selection_unique DO NOTHING;

    IF FOUND THEN
      v_selected := v_selected + 1;
    END IF;
  END LOOP;

  RETURN v_selected;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_tv_settle_fixture(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_pool numeric;
  v_home_amount numeric;
  v_away_amount numeric;
  v_desc text;
  v_label text;
  v_meta jsonb;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_tv_fixture_selection WHERE fixture_id = p_fixture_id
  ) THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
    AND competition_type IN ('league', 'cup')
    AND status = 'played'
    AND home_goals IS NOT NULL
    AND away_goals IS NOT NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_pool := (SELECT tv_per_match_amount FROM public.global_settings WHERE id = 1);

  IF v_pool IS NULL OR v_pool <= 0 THEN
    RETURN;
  END IF;

  v_home_amount := public.competition_tv_home_share(v_pool);
  v_away_amount := public.competition_tv_away_share(v_pool);
  v_label := public.competition_tv_fixture_settle_label(v_fixture);

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_fixture.home_club_short_name
      AND entry_type = 'tv_revenue'
  ) THEN
    v_desc := format(
      'TV revenue (home 80%%) %s — %s vs %s',
      v_label,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object(
      'gpsl_month', v_fixture.gpsl_month,
      'role', 'home',
      'tv_share_pct', 80,
      'tv_match_pool', v_pool,
      'competition_type', v_fixture.competition_type,
      'cup_code', v_fixture.cup_code
    );
    IF to_regprocedure('public.post_club_ledger(text,text,numeric,text,jsonb,bigint,bigint,boolean,boolean)') IS NOT NULL THEN
      PERFORM public.post_club_ledger(
        v_fixture.home_club_short_name,
        'tv_revenue',
        v_home_amount,
        v_desc,
        v_meta,
        v_fixture.season_id,
        p_fixture_id,
        true,
        true
      );
    ELSE
      PERFORM public.competition_credit_club_balance(v_fixture.home_club_short_name, v_home_amount);
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
      )
      VALUES (
        v_fixture.season_id,
        p_fixture_id,
        v_fixture.home_club_short_name,
        'tv_revenue',
        v_home_amount,
        v_desc,
        v_meta
      );
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_fixture.away_club_short_name
      AND entry_type = 'tv_revenue'
  ) THEN
    v_desc := format(
      'TV revenue (away 20%%) %s — %s vs %s',
      v_label,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object(
      'gpsl_month', v_fixture.gpsl_month,
      'role', 'away',
      'tv_share_pct', 20,
      'tv_match_pool', v_pool,
      'competition_type', v_fixture.competition_type,
      'cup_code', v_fixture.cup_code
    );
    IF to_regprocedure('public.post_club_ledger(text,text,numeric,text,jsonb,bigint,bigint,boolean,boolean)') IS NOT NULL THEN
      PERFORM public.post_club_ledger(
        v_fixture.away_club_short_name,
        'tv_revenue',
        v_away_amount,
        v_desc,
        v_meta,
        v_fixture.season_id,
        p_fixture_id,
        true,
        true
      );
    ELSE
      PERFORM public.competition_credit_club_balance(v_fixture.away_club_short_name, v_away_amount);
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
      )
      VALUES (
        v_fixture.season_id,
        p_fixture_id,
        v_fixture.away_club_short_name,
        'tv_revenue',
        v_away_amount,
        v_desc,
        v_meta
      );
    END IF;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_tv_process_month_lock_selections(
  p_season_id bigint,
  p_locked_gpsl_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_locked text;
  v_next text;
  v_div text;
  v_n int;
  v_month_total int;
  v_results jsonb := '[]'::jsonb;
  v_job_key text;
  v_div_result jsonb;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_locked IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
      AND (p_locked_gpsl_month IS NULL OR c.gpsl_month = p_locked_gpsl_month)
    ORDER BY c.sort_order
  LOOP
    v_job_key := 'tv_select_next:' || v_locked;

    IF EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id
        AND j.job_key = v_job_key
    ) THEN
      CONTINUE;
    END IF;

    SELECT c2.gpsl_month
    INTO v_next
    FROM public.competition_season_calendar c2
    WHERE c2.season_id = p_season_id
      AND c2.sort_order > (
        SELECT c0.sort_order
        FROM public.competition_season_calendar c0
        WHERE c0.season_id = p_season_id
          AND c0.gpsl_month = v_locked
      )
    ORDER BY c2.sort_order
    LIMIT 1;

    v_div_result := '{}'::jsonb;
    v_month_total := 0;

    IF v_next IS NOT NULL THEN
      FOREACH v_div IN ARRAY ARRAY['superleague', 'championship_a', 'championship_b']
      LOOP
        v_n := public.competition_tv_select_division_month(p_season_id, v_div, v_next, false);
        v_div_result := v_div_result || jsonb_build_object(v_div, v_n);
        v_month_total := v_month_total + v_n;
      END LOOP;
    END IF;

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      p_season_id,
      v_job_key,
      v_locked,
      jsonb_build_object(
        'ok', true,
        'locked_month', v_locked,
        'target_month', v_next,
        'selected_by_division', v_div_result,
        'fixtures_selected', v_month_total
      )
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();

    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'locked_month', v_locked,
        'target_month', v_next,
        'selected_by_division', v_div_result
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'processed', v_results
  );
END;
$function$;

DROP VIEW IF EXISTS public.competition_tv_fixtures_public;

CREATE VIEW public.competition_tv_fixtures_public
WITH (security_invoker = false)
AS
SELECT
  s.season_id,
  s.fixture_id,
  s.division,
  s.gpsl_month,
  public.competition_gpsl_month_label(s.gpsl_month) AS gpsl_month_label,
  s.tv_score,
  s.reasons,
  s.selected_at,
  f.matchday,
  f.competition_type,
  f.cup_code,
  f.cup_round,
  f.home_club_short_name,
  f.away_club_short_name,
  f.status,
  f.home_goals,
  f.away_goals,
  gs.tv_per_match_amount AS tv_match_pool,
  public.competition_tv_home_share(gs.tv_per_match_amount) AS home_tv_amount,
  public.competition_tv_away_share(gs.tv_per_match_amount) AS away_tv_amount,
  gs.tv_per_match_amount AS amount_per_club
FROM public.competition_tv_fixture_selection s
JOIN public.competition_fixtures f ON f.id = s.fixture_id
CROSS JOIN public.global_settings gs
WHERE gs.id = 1;

GRANT SELECT ON public.competition_tv_fixtures_public TO authenticated;
GRANT SELECT ON public.competition_tv_fixtures_public TO anon;

CREATE OR REPLACE FUNCTION public.competition_run_month_lock_jobs(
  p_season_id bigint,
  p_force_scheduling boolean DEFAULT false,
  p_locked_gpsl_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_out jsonb := jsonb_build_object('ok', true, 'season_id', p_season_id);
  v_totm jsonb;
  v_sport jsonb;
  v_tv jsonb;
  v_response_track jsonb;
  v_sched_fines jsonb;
  v_response_fines jsonb;
  v_checkin_fines jsonb;
  v_last_scheduling timestamptz;
  v_run_scheduling boolean := false;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.competition_process_month_team_awards(bigint)') IS NOT NULL THEN
    v_totm := public.competition_process_month_team_awards(p_season_id);
    v_out := v_out || jsonb_build_object('team_of_month', v_totm);
  END IF;

  IF to_regprocedure('public.gpsl_sport_process_pending_editions(bigint)') IS NOT NULL THEN
    BEGIN
      v_sport := public.gpsl_sport_process_pending_editions(p_season_id);
      v_out := v_out || jsonb_build_object('gpsl_sport', v_sport);
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'gpsl_sport', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;
  END IF;

  IF to_regprocedure('public.competition_tv_process_month_lock_selections(bigint,text)') IS NOT NULL THEN
    v_tv := public.competition_tv_process_month_lock_selections(p_season_id, p_locked_gpsl_month);
    v_out := v_out || jsonb_build_object('tv_selection', v_tv);
  END IF;

  IF p_force_scheduling THEN
    v_run_scheduling := true;
  ELSE
    SELECT j.ran_at
    INTO v_last_scheduling
    FROM public.competition_season_calendar_jobs j
    WHERE j.season_id = p_season_id
      AND j.job_key = 'scheduling_enforcement_throttle'
    LIMIT 1;

    v_run_scheduling :=
      v_last_scheduling IS NULL
      OR v_last_scheduling < now() - interval '5 minutes';
  END IF;

  IF v_run_scheduling THEN
    IF to_regprocedure('public.competition_process_scheduling_response_deadlines(bigint)') IS NOT NULL THEN
      v_response_track := public.competition_process_scheduling_response_deadlines(p_season_id);
      v_out := v_out || jsonb_build_object('scheduling_response_deadlines', v_response_track);
    END IF;

    IF to_regprocedure('public.competition_process_scheduling_arrangement_fines(bigint)') IS NOT NULL THEN
      v_sched_fines := public.competition_process_scheduling_arrangement_fines(p_season_id);
      v_out := v_out || jsonb_build_object('scheduling_arrangement_fines', v_sched_fines);
    END IF;

    IF to_regprocedure('public.competition_process_scheduling_response_fines(bigint)') IS NOT NULL THEN
      v_response_fines := public.competition_process_scheduling_response_fines(p_season_id);
      v_out := v_out || jsonb_build_object('scheduling_response_fines', v_response_fines);
    END IF;

    IF to_regprocedure('public.competition_process_scheduling_checkin_fines(bigint)') IS NOT NULL THEN
      v_checkin_fines := public.competition_process_scheduling_checkin_fines(p_season_id);
      v_out := v_out || jsonb_build_object('scheduling_checkin_fines', v_checkin_fines);
    END IF;

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      p_season_id,
      'scheduling_enforcement_throttle',
      coalesce(public.competition_active_gpsl_month(p_season_id, now()), 'none'),
      jsonb_build_object('ok', true, 'ran_at', now(), 'forced', p_force_scheduling)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();
  ELSE
    v_out := v_out || jsonb_build_object(
      'scheduling', jsonb_build_object('skipped', true, 'reason', 'throttled')
    );
  END IF;

  RETURN v_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_tv_process_month_lock_selections(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_run_month_lock_jobs(bigint, boolean, text) TO service_role;

-- Cron path: pick up TV auto-select when calendar months have locked (idempotent job keys)
CREATE OR REPLACE FUNCTION public.competition_calendar_month_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_month_sort smallint;
  v_august_sort constant smallint := public.competition_gpsl_month_sort('august');
  v_job_id bigint;
  v_enforcement jsonb;
  v_totm jsonb;
  v_tv jsonb;
  v_sched_fines jsonb;
  v_response_fines jsonb;
  v_out jsonb;
  v_last_scheduling timestamptz;
  v_run_scheduling boolean := false;
BEGIN
  SELECT id
  INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
    AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_season_id
  ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_calendar',
      'season_id', v_season_id
    );
  END IF;

  v_month := public.competition_active_gpsl_month(v_season_id, now());
  v_month_sort := public.competition_gpsl_month_sort(v_month);

  v_out := jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'calendar_phase', CASE
      WHEN v_month IS NULL THEN 'between_months'
      ELSE 'in_month'
    END
  );

  IF to_regprocedure('public.competition_process_month_team_awards(bigint)') IS NOT NULL THEN
    v_totm := public.competition_process_month_team_awards(v_season_id);
    v_out := v_out || jsonb_build_object('team_of_month', v_totm);
  END IF;

  IF to_regprocedure('public.competition_tv_process_month_lock_selections(bigint,text)') IS NOT NULL THEN
    v_tv := public.competition_tv_process_month_lock_selections(v_season_id, NULL);
    v_out := v_out || jsonb_build_object('tv_selection', v_tv);
  END IF;

  SELECT j.ran_at
  INTO v_last_scheduling
  FROM public.competition_season_calendar_jobs j
  WHERE j.season_id = v_season_id
    AND j.job_key = 'scheduling_enforcement_throttle'
  LIMIT 1;

  v_run_scheduling :=
    v_last_scheduling IS NULL
    OR v_last_scheduling < now() - interval '5 minutes';

  IF v_run_scheduling THEN
    v_response_fines := public.competition_process_scheduling_response_deadlines(v_season_id);
    v_out := v_out || jsonb_build_object('scheduling_response_deadlines', v_response_fines);

    v_sched_fines := public.competition_process_scheduling_arrangement_fines(v_season_id);
    v_out := v_out || jsonb_build_object('scheduling_arrangement_fines', v_sched_fines);

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      v_season_id,
      'scheduling_enforcement_throttle',
      coalesce(v_month, 'none'),
      jsonb_build_object('ok', true, 'ran_at', now())
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();
  ELSE
    v_out := v_out || jsonb_build_object(
      'scheduling_response_deadlines', jsonb_build_object('skipped', true, 'reason', 'throttled'),
      'scheduling_arrangement_fines', jsonb_build_object('skipped', true, 'reason', 'throttled')
    );
  END IF;

  IF v_month IS NULL OR v_month_sort IS NULL OR v_month_sort < v_august_sort THEN
    RETURN v_out || jsonb_build_object(
      'squad_minimum_august', jsonb_build_object('skipped', true, 'reason', 'before_august')
    );
  END IF;

  INSERT INTO public.competition_season_calendar_jobs (
    season_id, job_key, gpsl_month, result
  )
  VALUES (
    v_season_id,
    'squad_minimum_august',
    v_month,
    jsonb_build_object('status', 'running')
  )
  ON CONFLICT (season_id, job_key) DO NOTHING
  RETURNING id INTO v_job_id;

  IF v_job_id IS NULL THEN
    RETURN v_out || jsonb_build_object(
      'squad_minimum_august', jsonb_build_object('skipped', true, 'reason', 'already_ran')
    );
  END IF;

  v_enforcement := public.competition_enforce_squad_minimum_august(v_season_id);

  UPDATE public.competition_season_calendar_jobs
  SET result = v_enforcement,
      gpsl_month = v_month,
      ran_at = now()
  WHERE id = v_job_id;

  RETURN v_out || jsonb_build_object('squad_minimum_august', v_enforcement);
END;
$function$;

NOTIFY pgrst, 'reload schema';
