-- TV revenue: league picks spread across matchdays; separate cup TV pool/quota;
-- expose cup amount + cup matches/month + existing league-position weights.
--
-- League: tv_matches_per_month per division/month, shared as evenly as possible
--   across that month's league matchdays (Aug/May → 3 MDs, Sep–Apr → 4 MDs).
-- Cup: tv_cup_matches_per_month scored non-finals; finals always on TV.
-- Payout: league uses tv_per_match_amount; cups use tv_cup_per_match_amount.

ALTER TABLE public.global_settings
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
  ALTER COLUMN tv_cup_per_match_amount SET DEFAULT 1000000,
  ALTER COLUMN tv_cup_per_match_amount SET NOT NULL;

-- Even split helper: e.g. 12 across 3 → {4,4,4}; 12 across 4 → {3,3,3,3}
CREATE OR REPLACE FUNCTION public.competition_tv_even_quotas(
  p_total int,
  p_buckets int
)
RETURNS int[]
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_total int := greatest(coalesce(p_total, 0), 0);
  v_buckets int := greatest(coalesce(p_buckets, 0), 0);
  v_base int;
  v_rem int;
  v_out int[] := ARRAY[]::int[];
  v_i int;
BEGIN
  IF v_buckets < 1 THEN
    RETURN ARRAY[]::int[];
  END IF;

  v_base := v_total / v_buckets;
  v_rem := v_total % v_buckets;

  FOR v_i IN 1..v_buckets LOOP
    v_out := array_append(v_out, v_base + CASE WHEN v_i <= v_rem THEN 1 ELSE 0 END);
  END LOOP;

  RETURN v_out;
END;
$function$;

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
      v_score := v_score + coalesce(p_settings.tv_weight_cup_final, p_settings.tv_weight_title_race);
      v_reasons := v_reasons || jsonb_build_array('cup_final');
    WHEN 'sf' THEN
      v_score := v_score + coalesce(p_settings.tv_weight_cup_sf, p_settings.tv_weight_title_race);
      v_reasons := v_reasons || jsonb_build_array('cup_sf');
    WHEN 'qf' THEN
      v_score := v_score + coalesce(p_settings.tv_weight_cup_qf, p_settings.tv_weight_top8_clash);
      v_reasons := v_reasons || jsonb_build_array('cup_qf');
    WHEN 'r2' THEN
      v_score := v_score + coalesce(p_settings.tv_weight_cup_r2, p_settings.tv_weight_super8);
      v_reasons := v_reasons || jsonb_build_array('cup_r2');
    ELSE
      v_score := v_score + coalesce(p_settings.tv_weight_cup_r1, round(p_settings.tv_weight_super8 * 0.5, 2)::int);
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
  v_league_pick int;
  v_cup_pick int;
  v_selected int := 0;
  v_league_selected int := 0;
  v_cup_selected int := 0;
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
  v_finals int := 0;
  v_mds int[];
  v_quotas int[];
  v_md int;
  v_qi int;
  v_md_quota int;
  v_md_picked int;
BEGIN
  IF p_season_id IS NULL OR p_division IS NULL OR p_gpsl_month IS NULL THEN
    RETURN 0;
  END IF;

  v_s := public.tv_revenue_settings();
  v_league_pick := greatest(coalesce(v_s.tv_matches_per_month, 0), 0);
  v_cup_pick := greatest(coalesce(v_s.tv_cup_matches_per_month, 0), 0);

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

  -- Cup finals always get TV (do not consume league or scored-cup quota)
  FOR v_full_fixture IN
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.gpsl_month = p_gpsl_month
      AND f.status <> 'cancelled'
      AND f.competition_type = 'cup'
      AND public.competition_tv_fixture_effective_division(f) = p_division
      AND public.competition_fixture_is_cup_final(f)
  LOOP
    IF public.competition_tv_ensure_cup_final_selected(v_full_fixture.id) THEN
      v_finals := v_finals + 1;
      v_selected := v_selected + 1;
    END IF;
  END LOOP;

  v_before_md := public.competition_tv_division_as_of_matchday(p_season_id, p_division, p_gpsl_month);

  DROP TABLE IF EXISTS tv_month_candidates;
  CREATE TEMP TABLE tv_month_candidates (
    fixture_id bigint PRIMARY KEY,
    home_club text NOT NULL,
    away_club text NOT NULL,
    competition_type text NOT NULL,
    matchday int,
    tv_score numeric NOT NULL,
    reasons jsonb NOT NULL,
    home_tv_count int NOT NULL,
    away_tv_count int NOT NULL,
    is_cup_final boolean NOT NULL DEFAULT false
  ) ON COMMIT DROP;

  FOR v_fixture IN
    SELECT
      f.id,
      f.home_club_short_name,
      f.away_club_short_name,
      f.competition_type,
      f.matchday,
      public.competition_fixture_is_cup_final(f) AS is_cup_final
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
    IF v_fixture.is_cup_final THEN
      CONTINUE;
    END IF;

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
      fixture_id, home_club, away_club, competition_type, matchday,
      tv_score, reasons, home_tv_count, away_tv_count, is_cup_final
    )
    VALUES (
      v_fixture.id,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name,
      v_fixture.competition_type,
      v_fixture.matchday,
      (v_breakdown ->> 'score')::numeric,
      coalesce(v_breakdown -> 'reasons', '[]'::jsonb),
      v_home_count,
      v_away_count,
      false
    );
  END LOOP;

  -- League: distribute monthly quota across distinct league matchdays
  SELECT coalesce(array_agg(md ORDER BY md), ARRAY[]::int[])
  INTO v_mds
  FROM (
    SELECT DISTINCT c.matchday AS md
    FROM tv_month_candidates c
    WHERE c.competition_type = 'league'
      AND c.matchday IS NOT NULL
  ) x;

  v_quotas := public.competition_tv_even_quotas(v_league_pick, coalesce(array_length(v_mds, 1), 0));

  IF coalesce(array_length(v_mds, 1), 0) > 0 THEN
    FOR v_qi IN 1..array_length(v_mds, 1) LOOP
      v_md := v_mds[v_qi];
      v_md_quota := v_quotas[v_qi];
      v_md_picked := 0;

      FOR v_scored IN
        SELECT *
        FROM tv_month_candidates c
        WHERE c.competition_type = 'league'
          AND c.matchday = v_md
        ORDER BY c.tv_score DESC, c.fixture_id ASC
      LOOP
        EXIT WHEN v_md_picked >= v_md_quota;
        EXIT WHEN v_league_selected >= v_league_pick;

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
            AND (
              f.home_club_short_name = v_scored.home_club
              OR f.away_club_short_name = v_scored.home_club
            )
        );
        v_running_away := v_scored.away_tv_count + (
          SELECT count(*)::int
          FROM public.competition_tv_fixture_selection s
          JOIN public.competition_fixtures f ON f.id = s.fixture_id
          WHERE s.season_id = p_season_id
            AND s.division = p_division
            AND s.gpsl_month = p_gpsl_month
            AND (
              f.home_club_short_name = v_scored.away_club
              OR f.away_club_short_name = v_scored.away_club
            )
        );

        IF v_running_home >= v_s.tv_club_max_season
           AND v_running_away >= v_s.tv_club_max_season THEN
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
          coalesce(v_scored.reasons, '[]'::jsonb)
            || jsonb_build_array(format('league_md_%s_slot', v_md))
        );

        v_md_picked := v_md_picked + 1;
        v_league_selected := v_league_selected + 1;
        v_selected := v_selected + 1;
      END LOOP;
    END LOOP;
  END IF;

  -- Fill any leftover league slots from remaining league fixtures (any matchday)
  IF v_league_selected < v_league_pick THEN
    FOR v_scored IN
      SELECT *
      FROM tv_month_candidates c
      WHERE c.competition_type = 'league'
      ORDER BY c.tv_score DESC, c.fixture_id ASC
    LOOP
      EXIT WHEN v_league_selected >= v_league_pick;

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
          AND (
            f.home_club_short_name = v_scored.home_club
            OR f.away_club_short_name = v_scored.home_club
          )
      );
      v_running_away := v_scored.away_tv_count + (
        SELECT count(*)::int
        FROM public.competition_tv_fixture_selection s
        JOIN public.competition_fixtures f ON f.id = s.fixture_id
        WHERE s.season_id = p_season_id
          AND s.division = p_division
          AND s.gpsl_month = p_gpsl_month
          AND (
            f.home_club_short_name = v_scored.away_club
            OR f.away_club_short_name = v_scored.away_club
          )
      );

      IF v_running_home >= v_s.tv_club_max_season
         AND v_running_away >= v_s.tv_club_max_season THEN
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
        coalesce(v_scored.reasons, '[]'::jsonb) || jsonb_build_array('league_fill')
      );

      v_league_selected := v_league_selected + 1;
      v_selected := v_selected + 1;
    END LOOP;
  END IF;

  -- Cup non-finals: separate monthly quota
  FOR v_scored IN
    SELECT *
    FROM tv_month_candidates c
    WHERE c.competition_type = 'cup'
    ORDER BY c.tv_score DESC, c.fixture_id ASC
  LOOP
    EXIT WHEN v_cup_selected >= v_cup_pick;

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
        AND (
          f.home_club_short_name = v_scored.home_club
          OR f.away_club_short_name = v_scored.home_club
        )
    );
    v_running_away := v_scored.away_tv_count + (
      SELECT count(*)::int
      FROM public.competition_tv_fixture_selection s
      JOIN public.competition_fixtures f ON f.id = s.fixture_id
      WHERE s.season_id = p_season_id
        AND s.division = p_division
        AND s.gpsl_month = p_gpsl_month
        AND (
          f.home_club_short_name = v_scored.away_club
          OR f.away_club_short_name = v_scored.away_club
        )
    );

    IF v_running_home >= v_s.tv_club_max_season
       AND v_running_away >= v_s.tv_club_max_season THEN
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
      coalesce(v_scored.reasons, '[]'::jsonb) || jsonb_build_array('cup_slot')
    );

    v_cup_selected := v_cup_selected + 1;
    v_selected := v_selected + 1;
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
  v_is_final boolean := false;
  v_home_pct int;
  v_away_pct int;
BEGIN
  IF p_fixture_id IS NULL THEN
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

  v_is_final := public.competition_fixture_is_cup_final(v_fixture);
  IF v_is_final THEN
    PERFORM public.competition_tv_ensure_cup_final_selected(p_fixture_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_tv_fixture_selection WHERE fixture_id = p_fixture_id
  ) THEN
    RETURN;
  END IF;

  SELECT
    CASE
      WHEN v_fixture.competition_type = 'cup' THEN
        coalesce(gs.tv_cup_per_match_amount, gs.tv_per_match_amount)
      ELSE gs.tv_per_match_amount
    END
  INTO v_pool
  FROM public.global_settings gs
  WHERE gs.id = 1;

  IF v_pool IS NULL OR v_pool <= 0 THEN
    RETURN;
  END IF;

  IF v_is_final THEN
    v_home_amount := round(v_pool / 2.0, 2);
    v_away_amount := v_pool - v_home_amount;
    v_home_pct := 50;
    v_away_pct := 50;
  ELSE
    v_home_amount := public.competition_tv_home_share(v_pool);
    v_away_amount := public.competition_tv_away_share(v_pool);
    v_home_pct := 80;
    v_away_pct := 20;
  END IF;

  v_label := public.competition_tv_fixture_settle_label(v_fixture);

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_fixture.home_club_short_name
      AND entry_type = 'tv_revenue'
  ) THEN
    v_desc := format(
      'TV revenue (home %s%%) %s — %s vs %s',
      v_home_pct,
      v_label,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object(
      'gpsl_month', v_fixture.gpsl_month,
      'role', 'home',
      'tv_share_pct', v_home_pct,
      'tv_match_pool', v_pool,
      'competition_type', v_fixture.competition_type,
      'cup_code', v_fixture.cup_code,
      'neutral_final', v_is_final
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
      'TV revenue (away %s%%) %s — %s vs %s',
      v_away_pct,
      v_label,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object(
      'gpsl_month', v_fixture.gpsl_month,
      'role', 'away',
      'tv_share_pct', v_away_pct,
      'tv_match_pool', v_pool,
      'competition_type', v_fixture.competition_type,
      'cup_code', v_fixture.cup_code,
      'neutral_final', v_is_final
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
    tv_weight_cup_final = coalesce((p_settings->>'tv_weight_cup_final')::smallint, tv_weight_cup_final),
    tv_weight_cup_sf = coalesce((p_settings->>'tv_weight_cup_sf')::smallint, tv_weight_cup_sf),
    tv_weight_cup_qf = coalesce((p_settings->>'tv_weight_cup_qf')::smallint, tv_weight_cup_qf),
    tv_weight_cup_r2 = coalesce((p_settings->>'tv_weight_cup_r2')::smallint, tv_weight_cup_r2),
    tv_weight_cup_r1 = coalesce((p_settings->>'tv_weight_cup_r1')::smallint, tv_weight_cup_r1),
    updated_at = now()
  WHERE id = 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_tv_even_quotas(int, int) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.competition_tv_select_division_month(bigint, text, text, boolean)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.competition_tv_settle_fixture(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_tv_settings(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
