-- Manager impact chart (reference for scaling) + restore club contract-target system.
-- Does NOT change GPDB player stats. Does NOT replace manager_rating_targets.
-- Run after managers_system.sql and stadium_attendance_v2.sql. Safe to re-run.

-- ---------------------------------------------------------------------------
-- Impact chart table (player rating bands per +1 / +2 / +3 reference tier)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.manager_proficiency_expectancy (
  proficiency smallint PRIMARY KEY CHECK (proficiency >= 1 AND proficiency <= 99),
  boost1_min smallint NOT NULL CHECK (boost1_min >= 0),
  boost1_max smallint NOT NULL CHECK (boost1_max >= boost1_min),
  boost2_min smallint CHECK (boost2_min IS NULL OR boost2_min >= 0),
  boost2_max smallint CHECK (boost2_max IS NULL OR boost2_max >= boost2_min),
  boost3_min smallint CHECK (boost3_min IS NULL OR boost3_min >= 0),
  boost3_max smallint CHECK (boost3_max IS NULL OR boost3_max >= boost3_min),
  updated_at timestamptz NOT NULL DEFAULT now()
);

DO $rename_boost_cols$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'manager_proficiency_expectancy'
      AND column_name = 'tier1_min'
  ) THEN
    ALTER TABLE public.manager_proficiency_expectancy RENAME COLUMN tier1_min TO boost1_min;
    ALTER TABLE public.manager_proficiency_expectancy RENAME COLUMN tier1_max TO boost1_max;
    ALTER TABLE public.manager_proficiency_expectancy RENAME COLUMN tier2_min TO boost2_min;
    ALTER TABLE public.manager_proficiency_expectancy RENAME COLUMN tier2_max TO boost2_max;
    ALTER TABLE public.manager_proficiency_expectancy RENAME COLUMN tier3_min TO boost3_min;
    ALTER TABLE public.manager_proficiency_expectancy RENAME COLUMN tier3_max TO boost3_max;
  END IF;
END;
$rename_boost_cols$;

COMMENT ON TABLE public.manager_proficiency_expectancy IS
  'Reference chart: manager proficiency → player rating bands (+1/+2/+3). Expectancy scaling only.';

CREATE OR REPLACE FUNCTION public.manager_proficiency_clamp(p_rating smallint)
RETURNS smallint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT LEAST(89, GREATEST(73, coalesce(p_rating, 73)::int))::smallint;
$$;

CREATE OR REPLACE FUNCTION public.manager_expectancy_for(p_rating smallint)
RETURNS public.manager_proficiency_expectancy
LANGUAGE sql
STABLE
AS $$
  SELECT e.*
  FROM public.manager_proficiency_expectancy e
  WHERE e.proficiency = public.manager_proficiency_clamp(p_rating);
$$;

DROP FUNCTION IF EXISTS public.manager_boost_band_label(smallint, smallint, smallint);

CREATE OR REPLACE FUNCTION public.manager_boost_band_label(
  p_boost integer,
  p_min smallint,
  p_max smallint
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_min IS NULL OR p_max IS NULL THEN NULL
    ELSE format('+%s (players %s–%s)', p_boost, p_min, p_max)
  END;
$$;

CREATE OR REPLACE FUNCTION public.admin_upsert_manager_proficiency_expectancy(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  INSERT INTO public.manager_proficiency_expectancy (
    proficiency,
    boost1_min, boost1_max,
    boost2_min, boost2_max,
    boost3_min, boost3_max
  )
  VALUES (
    (p_payload ->> 'proficiency')::smallint,
    coalesce((p_payload ->> 'boost1_min')::smallint, (p_payload ->> 'tier1_min')::smallint),
    coalesce((p_payload ->> 'boost1_max')::smallint, (p_payload ->> 'tier1_max')::smallint),
    nullif(coalesce(p_payload ->> 'boost2_min', p_payload ->> 'tier2_min'), '')::smallint,
    nullif(coalesce(p_payload ->> 'boost2_max', p_payload ->> 'tier2_max'), '')::smallint,
    nullif(coalesce(p_payload ->> 'boost3_min', p_payload ->> 'tier3_min'), '')::smallint,
    nullif(coalesce(p_payload ->> 'boost3_max', p_payload ->> 'tier3_max'), '')::smallint
  )
  ON CONFLICT (proficiency) DO UPDATE SET
    boost1_min = excluded.boost1_min,
    boost1_max = excluded.boost1_max,
    boost2_min = excluded.boost2_min,
    boost2_max = excluded.boost2_max,
    boost3_min = excluded.boost3_min,
    boost3_max = excluded.boost3_max,
    updated_at = now();

  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- Seed 73–89 (edit in Admin). Lower proficiency = broader +1 band in reference chart.
INSERT INTO public.manager_proficiency_expectancy (
  proficiency, boost1_min, boost1_max, boost2_min, boost2_max, boost3_min, boost3_max
)
VALUES
  (73, 40, 78, 79, 93, 94, 97),
  (74, 40, 74, 75, 93, 94, 97),
  (75, 40, 70, 71, 94, 95, 97),
  (76, 40, 66, 67, 94, 95, 97),
  (77, 48, 94, 95, 97, NULL, NULL),
  (78, 44, 87, 88, 97, NULL, NULL),
  (79, 40, 76, 77, 97, NULL, NULL),
  (80, 40, 76, 77, 97, NULL, NULL),
  (81, 40, 69, 70, 97, NULL, NULL),
  (82, 40, 69, 70, 97, NULL, NULL),
  (83, 40, 66, 67, 97, NULL, NULL),
  (84, 40, 61, 62, 92, 93, 96),
  (85, 40, 61, 62, 92, 93, 96),
  (86, 40, 58, 58, 89, 90, 96),
  (87, 40, 58, 59, 87, 88, 96),
  (88, 40, 56, 57, 84, 85, 96),
  (89, 40, 55, 56, 83, 84, 96)
ON CONFLICT (proficiency) DO UPDATE SET
  boost1_min = excluded.boost1_min,
  boost1_max = excluded.boost1_max,
  boost2_min = excluded.boost2_min,
  boost2_max = excluded.boost2_max,
  boost3_min = excluded.boost3_min,
  boost3_max = excluded.boost3_max,
  updated_at = now();

ALTER TABLE public.manager_proficiency_expectancy ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS manager_proficiency_expectancy_select ON public.manager_proficiency_expectancy;
CREATE POLICY manager_proficiency_expectancy_select ON public.manager_proficiency_expectancy
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS manager_proficiency_expectancy_admin ON public.manager_proficiency_expectancy;
CREATE POLICY manager_proficiency_expectancy_admin ON public.manager_proficiency_expectancy
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.manager_proficiency_expectancy TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_manager_proficiency_expectancy(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- Restore manager contract targets (club impact) — from managers_system.sql
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_target_met(
  p_target public.manager_rating_targets,
  p_actual_position smallint,
  p_division text
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $function$
BEGIN
  IF p_target IS NULL OR p_actual_position IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_target.target_kind = 'max_position' THEN
    RETURN p_actual_position <= p_target.target_value;
  END IF;

  IF p_target.target_kind = 'promotion' THEN
    RETURN p_actual_position <= 2;
  END IF;

  IF p_target.target_kind = 'avoid_relegation' THEN
    IF p_division = 'superleague' THEN
      RETURN p_actual_position <= 18;
    END IF;
    RETURN p_actual_position <= 18;
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_process_season_end()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
  v_mgr public."Managers"%rowtype;
  v_division text;
  v_pos smallint;
  v_target public.manager_rating_targets;
  v_met boolean;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
BEGIN
  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  FOR v_mgr IN
    SELECT * FROM public."Managers"
    WHERE contracted_club IS NOT NULL
      AND contract_seasons_remaining > 0
  LOOP
    SELECT cs.division, cs.season_position
    INTO v_division, v_pos
    FROM public.manager_club_season_position(v_season.id, v_mgr.contracted_club) cs;

    v_target := public.manager_target_for(v_mgr.rating, coalesce(v_division, 'championship_a'));
    v_met := public.manager_target_met(v_target, v_pos, v_division);

    IF v_met IS TRUE THEN
      UPDATE public."Managers"
      SET contract_seasons_remaining = 2,
          weekly_wage = public.manager_weekly_wage_for(market_value),
          updated_at = now()
      WHERE id = v_mgr.id;

      v_row := jsonb_build_object(
        'manager_id', v_mgr.id,
        'club', v_mgr.contracted_club,
        'action', 'renewed',
        'position', v_pos
      );
    ELSIF v_met IS FALSE THEN
      PERFORM public.manager_release_from_club(
        v_mgr.id,
        v_mgr.contracted_club,
        v_mgr.market_value::numeric,
        'transfer_sale'
      );

      v_row := jsonb_build_object(
        'manager_id', v_mgr.id,
        'club', v_mgr.contracted_club,
        'action', 'released',
        'position', v_pos,
        'payout', v_mgr.market_value
      );
    ELSE
      UPDATE public."Managers"
      SET contract_seasons_remaining = greatest(contract_seasons_remaining - 1, 0),
          updated_at = now()
      WHERE id = v_mgr.id;

      IF (SELECT contract_seasons_remaining FROM public."Managers" WHERE id = v_mgr.id) = 0 THEN
        PERFORM public.manager_release_from_club(v_mgr.id, NULL, NULL, 'transfer_sale');
        v_row := jsonb_build_object('manager_id', v_mgr.id, 'club', v_mgr.contracted_club, 'action', 'contract_expired');
      ELSE
        v_row := jsonb_build_object('manager_id', v_mgr.id, 'club', v_mgr.contracted_club, 'action', 'season_tick');
      END IF;
    END IF;

    v_results := v_results || jsonb_build_array(v_row);
  END LOOP;

  RETURN jsonb_build_object('season_id', v_season.id, 'results', v_results);
END;
$function$;

DROP VIEW IF EXISTS public.manager_club_status_public;

CREATE VIEW public.manager_club_status_public
WITH (security_invoker = true)
AS
SELECT
  c."ShortName" AS club_short_name,
  m.id AS manager_id,
  m.name AS manager_name,
  m.rating AS manager_rating,
  m.market_value,
  m.contract_seasons_remaining,
  m.weekly_wage,
  c.manager_sacks_remaining,
  coalesce(pos.division, ccs.division) AS division,
  pos.season_position,
  t.target_kind,
  t.target_value,
  t.label AS target_label,
  public.manager_target_met(
    t,
    pos.season_position,
    coalesce(pos.division, ccs.division)
  ) AS target_met,
  public.manager_boost_band_label(1, e.boost1_min, e.boost1_max) AS boost1_label,
  public.manager_boost_band_label(2, e.boost2_min, e.boost2_max) AS boost2_label,
  public.manager_boost_band_label(3, e.boost3_min, e.boost3_max) AS boost3_label
FROM public."Clubs" c
LEFT JOIN public."Managers" m ON m.id = c.manager_id
LEFT JOIN public.competition_seasons s ON s.is_current = true
LEFT JOIN public.competition_club_seasons ccs
  ON ccs.club_short_name = c."ShortName" AND ccs.season_id = s.id
LEFT JOIN LATERAL public.manager_club_season_position(s.id, c."ShortName") pos ON s.id IS NOT NULL
LEFT JOIN public.manager_rating_targets t
  ON m.id IS NOT NULL
  AND coalesce(pos.division, ccs.division) IS NOT NULL
  AND m.rating BETWEEN t.min_rating AND t.max_rating
  AND t.division = coalesce(pos.division, ccs.division)
  AND t.id = (
    SELECT t2.id
    FROM public.manager_rating_targets t2
    WHERE t2.division = coalesce(pos.division, ccs.division)
      AND m.rating BETWEEN t2.min_rating AND t2.max_rating
    ORDER BY t2.sort_order, t2.id
    LIMIT 1
  )
LEFT JOIN public.manager_proficiency_expectancy e
  ON m.id IS NOT NULL
  AND e.proficiency = public.manager_proficiency_clamp(m.rating);

GRANT SELECT ON public.manager_club_status_public TO authenticated;

-- Season expectations inbox — contract targets (not chart-only)
CREATE OR REPLACE FUNCTION public.owner_inbox_notify_season_expectations(p_club_short_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mgr public."Managers"%rowtype;
  v_division text;
  v_target public.manager_rating_targets;
  v_e public.manager_proficiency_expectancy;
  v_fill numeric;
  v_target_fill numeric;
  v_body text;
  v_chart text;
BEGIN
  SELECT * INTO v_mgr
  FROM public."Managers" m
  WHERE m.contracted_club = p_club_short_name
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT ccs.division INTO v_division
  FROM public.competition_club_seasons ccs
  JOIN public.competition_seasons s ON s.id = ccs.season_id AND s.is_current = true
  WHERE ccs.club_short_name = p_club_short_name
  LIMIT 1;

  v_target := public.manager_target_for(v_mgr.rating, coalesce(v_division, 'championship_a'));
  v_e := public.manager_expectancy_for(v_mgr.rating);

  SELECT c.stadium_display_fill_pct, c.stadium_fill_target_pct
  INTO v_fill, v_target_fill
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  v_chart := concat_ws(
    ' · ',
    public.manager_boost_band_label(1, v_e.boost1_min, v_e.boost1_max),
    public.manager_boost_band_label(2, v_e.boost2_min, v_e.boost2_max),
    public.manager_boost_band_label(3, v_e.boost3_min, v_e.boost3_max)
  );

  v_body := concat_ws(
    E'\n',
    format('Manager: %s (rating %s, %s season(s) remaining)', v_mgr.name, v_mgr.rating, v_mgr.contract_seasons_remaining),
    CASE
      WHEN v_target.label IS NOT NULL AND btrim(v_target.label) <> '' THEN
        format('League target: %s — meet this to retain your manager at season end.', v_target.label)
      WHEN v_target.id IS NOT NULL THEN
        format('League target: %s in %s to retain your manager at season end.',
          v_target.target_kind, coalesce(v_division, 'your division'))
      ELSE 'League target: meet your division finish band to retain your manager.'
    END,
    CASE
      WHEN nullif(v_chart, '') IS NOT NULL THEN
        format('Impact chart (reference): %s.', v_chart)
      ELSE NULL
    END,
    format('Stadium: maintain strong attendance — current fill %s%%, season target %s%%.',
      coalesce(round(v_fill)::text, '?'), coalesce(round(v_target_fill)::text, '100')),
    E'See Stadium and Club Details for full expectations.'
  );

  PERFORM public.owner_inbox_send(
    'season_expectations',
    'Season expectations',
    v_body,
    p_club_short_name,
    NULL,
    NULL, NULL, NULL, NULL,
    'club_details.html',
    'season_expectations:' || p_club_short_name || ':' || v_mgr.id::text,
    NULL, NULL
  );
END;
$function$;

-- Restore stadium manager lift (linear rating threshold — not squad-boost replacement)
CREATE OR REPLACE FUNCTION public.competition_stadium_season_metrics(
  p_club_short_name text,
  p_season_id bigint DEFAULT NULL,
  p_division text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.global_settings;
  v_season_id bigint;
  v_division text;
  v_capacity int;
  v_tier text;
  v_prestige_rank smallint;
  v_club_count smallint;
  v_baseline_pos smallint;
  v_expected_pos smallint;
  v_actual_pos smallint;
  v_manager_rating smallint;
  v_lift numeric;
  v_lift_max numeric;
  v_league_expected numeric;
  v_league_actual numeric;
  v_cup_expected numeric;
  v_cup_actual numeric;
  v_expected_pts numeric;
  v_actual_pts numeric;
  v_gap numeric;
  v_band text;
  v_penalty numeric;
  v_prestige_base numeric;
  v_season_target numeric;
  v_rank_row record;
  v_standing_division text;
BEGIN
  SELECT * INTO v_cfg FROM public.global_settings WHERE id = 1;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('error', 'No active season');
  END IF;

  IF p_division IS NULL THEN
    SELECT ccs.division INTO v_division
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND ccs.club_short_name = p_club_short_name
    LIMIT 1;
  ELSE
    v_division := p_division;
  END IF;

  SELECT coalesce(c."Capacity", 0)::int, c.manager_rating
  INTO v_capacity, v_manager_rating
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  v_tier := public.competition_club_tier(p_club_short_name);

  SELECT count(*)::smallint INTO v_club_count FROM public."Clubs";

  SELECT p.prestige_rank, p.rolling_points, p.composite_score, p.seasons_count
  INTO v_rank_row
  FROM public.competition_club_prestige_public p
  WHERE p.club_short_name = p_club_short_name;

  v_prestige_rank := coalesce(v_rank_row.prestige_rank, v_club_count);
  v_prestige_base := public.competition_stadium_prestige_base_fill(p_club_short_name);

  v_baseline_pos := public.competition_club_baseline_expected_position(
    v_prestige_rank,
    v_club_count
  );
  v_expected_pos := v_baseline_pos;

  IF v_tier IN ('medium', 'low')
    AND v_manager_rating IS NOT NULL
    AND v_manager_rating > v_cfg.stadium_manager_lift_threshold
  THEN
    v_lift_max := CASE v_tier
      WHEN 'low' THEN v_cfg.stadium_manager_lift_max_positions_low
      ELSE v_cfg.stadium_manager_lift_max_positions_med
    END;

    v_lift := (
      (v_manager_rating - v_cfg.stadium_manager_lift_threshold)::numeric
      / greatest(v_cfg.stadium_manager_lift_max_rating - v_cfg.stadium_manager_lift_threshold, 1)
    ) * v_lift_max;

    v_expected_pos := greatest(
      1::smallint,
      (v_baseline_pos - round(v_lift))::smallint
    );
  END IF;

  SELECT cs.division, cs.final_position
  INTO v_standing_division, v_actual_pos
  FROM public.competition_club_season_standing(v_season_id, p_club_short_name) cs;

  v_actual_pos := coalesce(v_actual_pos, 10);

  v_league_expected := public.competition_club_league_points(
    coalesce(v_division, v_standing_division, 'superleague'),
    v_expected_pos
  );

  v_cup_expected := public.competition_club_expected_cup_points(
    coalesce(v_division, v_standing_division, 'superleague'),
    v_expected_pos
  );

  SELECT
    (live ->> 'league_points')::numeric,
    (live ->> 'cup_points')::numeric
  INTO v_league_actual, v_cup_actual
  FROM public.competition_club_live_season_points(v_season_id, p_club_short_name) live;

  v_league_actual := coalesce(v_league_actual, 0);
  v_cup_actual := coalesce(v_cup_actual, 0);

  v_expected_pts :=
    v_league_expected * v_cfg.stadium_league_expect_weight
    + v_cup_expected * v_cfg.stadium_cup_expect_weight;

  v_actual_pts :=
    v_league_actual * v_cfg.stadium_league_perf_weight
    + v_cup_actual * v_cfg.stadium_cup_perf_weight;

  v_gap := v_actual_pts - v_expected_pts;
  v_band := public.competition_stadium_performance_band(v_gap, v_expected_pts, v_cfg);
  v_penalty := public.competition_stadium_performance_penalty(v_band, v_cfg);

  v_season_target := v_prestige_base;

  IF v_band = 'on_target' THEN
    v_season_target := least(
      v_cfg.stadium_max_display_fill_pct,
      v_prestige_base + v_cfg.stadium_season_gain_on_target_pct
    );
  ELSE
    v_season_target := greatest(
      v_cfg.stadium_min_fill_pct,
      v_prestige_base - v_penalty
    );
  END IF;

  RETURN jsonb_build_object(
    'club_short_name', p_club_short_name,
    'season_id', v_season_id,
    'division', coalesce(v_division, v_standing_division),
    'capacity', v_capacity,
    'club_tier', v_tier,
    'prestige_rank', v_prestige_rank,
    'rolling_points', coalesce(v_rank_row.rolling_points, 0),
    'seasons_in_roll', coalesce(v_rank_row.seasons_count, 0),
    'composite_score', coalesce(v_rank_row.composite_score, 0),
    'manager_rating', v_manager_rating,
    'baseline_expected_position', v_baseline_pos,
    'expected_position', v_expected_pos,
    'actual_position', v_actual_pos,
    'league_expected_points', round(v_league_expected, 2),
    'league_actual_points', round(v_league_actual, 2),
    'cup_expected_points', round(v_cup_expected, 2),
    'cup_actual_points', round(v_cup_actual, 2),
    'expected_points', round(v_expected_pts, 2),
    'actual_points', round(v_actual_pts, 2),
    'performance_gap', round(v_gap, 2),
    'performance_band', v_band,
    'performance_penalty_pct', v_penalty,
    'prestige_base_fill_pct', v_prestige_base,
    'season_target_fill_pct', round(v_season_target, 2),
    'min_fill_pct', v_cfg.stadium_min_fill_pct,
    'target_fill_pct', v_cfg.stadium_target_fill_pct,
    'max_display_fill_pct', v_cfg.stadium_max_display_fill_pct,
    'monthly_drift_pct', v_cfg.stadium_monthly_drift_pct
  );
END;
$function$;
