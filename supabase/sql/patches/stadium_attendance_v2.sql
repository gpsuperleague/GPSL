-- =============================================================================
-- GPSL — Stadium attendance v2
-- Run after competition_club_stadium_attendance.sql
--
-- Changes:
--   • Min gate fill 75% (was 60%); prestige maps clubs between 75–100%
--   • Display fill can exceed 100% (cushion); gate revenue capped at 100%
--   • Gradual monthly drift toward season target (not sudden jumps)
--   • Performance bands: slight −10%, bad −20%, abysmal −25%
--   • Two on-target seasons ≈ +12.5%/season → 100% gate from floor
--   • 5-year prestige underpins base fill (±5% steps)
--   • Admin overview view with 5-season stats + projection notes
--   • Stadium expansion only when current capacity ≤ 55,000
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Schema: persisted fill state on clubs
-- ---------------------------------------------------------------------------

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS stadium_display_fill_pct numeric(5, 2),
  ADD COLUMN IF NOT EXISTS stadium_season_start_fill_pct numeric(5, 2),
  ADD COLUMN IF NOT EXISTS stadium_fill_target_pct numeric(5, 2),
  ADD COLUMN IF NOT EXISTS stadium_fill_last_month smallint,
  ADD COLUMN IF NOT EXISTS stadium_fill_season_id bigint REFERENCES public.competition_seasons (id),
  ADD COLUMN IF NOT EXISTS stadium_fill_updated_at timestamptz;

COMMENT ON COLUMN public."Clubs".stadium_display_fill_pct IS
  'Tracked fill % including cushion above 100%. Gate revenue uses min(this, 100).';
COMMENT ON COLUMN public."Clubs".stadium_season_start_fill_pct IS
  'Display fill snapshot at season activation.';
COMMENT ON COLUMN public."Clubs".stadium_fill_target_pct IS
  'Season drift target from prestige + current performance band.';

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS stadium_max_display_fill_pct numeric(5, 2) NOT NULL DEFAULT 115.00,
  ADD COLUMN IF NOT EXISTS stadium_target_fill_pct numeric(5, 2) NOT NULL DEFAULT 100.00,
  ADD COLUMN IF NOT EXISTS stadium_monthly_drift_pct numeric(5, 2) NOT NULL DEFAULT 2.00,
  ADD COLUMN IF NOT EXISTS stadium_prestige_fill_step_pct numeric(5, 2) NOT NULL DEFAULT 5.00,
  ADD COLUMN IF NOT EXISTS stadium_under_slight_penalty_pct numeric(5, 2) NOT NULL DEFAULT 10.00,
  ADD COLUMN IF NOT EXISTS stadium_under_bad_penalty_pct numeric(5, 2) NOT NULL DEFAULT 20.00,
  ADD COLUMN IF NOT EXISTS stadium_under_abysmal_penalty_pct numeric(5, 2) NOT NULL DEFAULT 25.00,
  ADD COLUMN IF NOT EXISTS stadium_season_gain_on_target_pct numeric(5, 2) NOT NULL DEFAULT 12.50,
  ADD COLUMN IF NOT EXISTS stadium_new_build_max_capacity integer NOT NULL DEFAULT 55000,
  ADD COLUMN IF NOT EXISTS stadium_under_slight_gap_ratio numeric(5, 3) NOT NULL DEFAULT 0.100,
  ADD COLUMN IF NOT EXISTS stadium_under_bad_gap_ratio numeric(5, 3) NOT NULL DEFAULT 0.250;

-- Raise default floor to 75% for new installs; update existing rows still at 60
UPDATE public.global_settings
SET stadium_min_fill_pct = 75.00
WHERE id = 1 AND stadium_min_fill_pct < 75;

UPDATE public.global_settings
SET stadium_neutral_fill_pct = 75.00
WHERE id = 1 AND stadium_neutral_fill_pct < 75;

-- ---------------------------------------------------------------------------
-- Prestige base fill (5-year rolling underpins stature)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_stadium_prestige_base_fill(p_club_short_name text)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.global_settings;
  v_rank smallint;
  v_club_count smallint;
  v_pctile numeric;
  v_base numeric;
  v_step int;
BEGIN
  SELECT * INTO v_cfg FROM public.global_settings WHERE id = 1;

  SELECT count(*)::smallint INTO v_club_count FROM public."Clubs";

  SELECT p.prestige_rank INTO v_rank
  FROM public.competition_club_prestige_public p
  WHERE p.club_short_name = p_club_short_name;

  v_rank := coalesce(v_rank, v_club_count);

  IF v_club_count <= 1 THEN
    v_pctile := 1;
  ELSE
    v_pctile := (v_club_count - v_rank)::numeric / (v_club_count - 1)::numeric;
  END IF;

  v_base := v_cfg.stadium_min_fill_pct
    + v_pctile * (v_cfg.stadium_target_fill_pct - v_cfg.stadium_min_fill_pct);

  -- 5-year prestige steps: top third +step, bottom third −step (±5% default)
  v_step := CASE
    WHEN v_pctile >= 0.67 THEN 1
    WHEN v_pctile <= 0.33 THEN -1
    ELSE 0
  END;

  v_base := v_base + v_step * v_cfg.stadium_prestige_fill_step_pct;

  RETURN greatest(
    v_cfg.stadium_min_fill_pct,
    least(v_cfg.stadium_max_display_fill_pct, round(v_base, 2))
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Performance band penalty (slight / bad / abysmal)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_stadium_performance_band(
  p_gap numeric,
  p_expected_pts numeric,
  p_cfg public.global_settings DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.global_settings;
  v_ratio numeric;
BEGIN
  IF p_cfg IS NULL THEN
    SELECT * INTO v_cfg FROM public.global_settings WHERE id = 1;
  ELSE
    v_cfg := p_cfg;
  END IF;

  IF coalesce(p_expected_pts, 0) <= 0 THEN
    RETURN CASE WHEN coalesce(p_gap, 0) >= 0 THEN 'on_target' ELSE 'slight' END;
  END IF;

  v_ratio := coalesce(p_gap, 0) / p_expected_pts;

  IF v_ratio >= 0 THEN
    RETURN 'on_target';
  ELSIF v_ratio >= -v_cfg.stadium_under_slight_gap_ratio THEN
    RETURN 'slight';
  ELSIF v_ratio >= -v_cfg.stadium_under_bad_gap_ratio THEN
    RETURN 'bad';
  END IF;

  RETURN 'abysmal';
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_stadium_performance_penalty(
  p_band text,
  p_cfg public.global_settings DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.global_settings;
BEGIN
  IF p_cfg IS NULL THEN
    SELECT * INTO v_cfg FROM public.global_settings WHERE id = 1;
  ELSE
    v_cfg := p_cfg;
  END IF;

  RETURN CASE coalesce(p_band, 'slight')
    WHEN 'on_target' THEN 0
    WHEN 'slight' THEN v_cfg.stadium_under_slight_penalty_pct
    WHEN 'bad' THEN v_cfg.stadium_under_bad_penalty_pct
    ELSE v_cfg.stadium_under_abysmal_penalty_pct
  END;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Season performance metrics (shared by fill + overview)
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Monthly drift + persisted display fill
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_stadium_sync_fill_state(
  p_club_short_name text,
  p_season_id bigint DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.global_settings;
  v_season_id bigint;
  v_metrics jsonb;
  v_display numeric;
  v_target numeric;
  v_prestige_base numeric;
  v_active_month_name text;
  v_active_month smallint;
  v_last_month smallint;
  v_stored_season bigint;
  v_drift numeric;
  v_steps int;
  v_i int;
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
    RETURN NULL;
  END IF;

  v_metrics := public.competition_stadium_season_metrics(p_club_short_name, v_season_id);

  IF v_metrics ? 'error' THEN
    RETURN NULL;
  END IF;

  v_target := (v_metrics ->> 'season_target_fill_pct')::numeric;
  v_prestige_base := (v_metrics ->> 'prestige_base_fill_pct')::numeric;
  v_active_month_name := public.competition_active_gpsl_month(v_season_id, now());
  v_active_month := public.competition_gpsl_month_sort(v_active_month_name);
  v_drift := v_cfg.stadium_monthly_drift_pct;

  SELECT
    c.stadium_display_fill_pct,
    c.stadium_fill_last_month,
    c.stadium_fill_season_id
  INTO v_display, v_last_month, v_stored_season
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  IF v_display IS NULL THEN
    v_display := v_prestige_base;
  END IF;

  IF v_stored_season IS DISTINCT FROM v_season_id THEN
    UPDATE public."Clubs"
    SET
      stadium_season_start_fill_pct = round(v_display, 2),
      stadium_fill_season_id = v_season_id,
      stadium_fill_last_month = v_active_month
    WHERE "ShortName" = p_club_short_name;

    v_last_month := v_active_month;
    v_stored_season := v_season_id;
  END IF;

  IF v_last_month IS NULL AND v_active_month IS NOT NULL THEN
    v_last_month := v_active_month;
  END IF;

  v_steps := CASE
    WHEN v_active_month IS NULL OR v_last_month IS NULL THEN 0
    ELSE greatest(v_active_month - v_last_month, 0)
  END;

  FOR v_i IN 1..v_steps LOOP
    IF v_display < v_target THEN
      v_display := least(v_target, v_display + v_drift);
    ELSIF v_display > v_target THEN
      v_display := greatest(v_target, v_display - v_drift);
    END IF;
  END LOOP;

  v_display := greatest(
    v_cfg.stadium_min_fill_pct,
    least(v_cfg.stadium_max_display_fill_pct, round(v_display, 2))
  );

  UPDATE public."Clubs"
  SET
    stadium_display_fill_pct = v_display,
    stadium_fill_target_pct = round(v_target, 2),
    stadium_fill_last_month = coalesce(v_active_month, stadium_fill_last_month),
    stadium_fill_season_id = v_season_id,
    stadium_fill_updated_at = now()
  WHERE "ShortName" = p_club_short_name;

  RETURN v_display;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_stadium_sync_all_clubs(p_season_id bigint DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_count int := 0;
BEGIN
  FOR v_club IN SELECT c."ShortName" AS club_short_name FROM public."Clubs" c
  LOOP
    PERFORM public.competition_stadium_sync_fill_state(v_club.club_short_name, p_season_id);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_stadium_snapshot_season_start(p_season_id bigint)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_display numeric;
  v_count int := 0;
BEGIN
  FOR v_club IN SELECT c."ShortName" AS club_short_name FROM public."Clubs" c
  LOOP
    v_display := public.competition_stadium_sync_fill_state(v_club.club_short_name, p_season_id);

    UPDATE public."Clubs"
    SET stadium_season_start_fill_pct = coalesce(v_display, stadium_display_fill_pct, stadium_season_start_fill_pct)
    WHERE "ShortName" = v_club.club_short_name;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Stadium fill (read persisted state + metrics)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_compute_stadium_fill(
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
  v_metrics jsonb;
  v_display numeric;
  v_gate numeric;
  v_cushion numeric;
  v_season_start numeric;
  v_target numeric;
BEGIN
  SELECT * INTO v_cfg FROM public.global_settings WHERE id = 1;

  v_metrics := public.competition_stadium_season_metrics(
    p_club_short_name,
    p_season_id,
    p_division
  );

  IF v_metrics ? 'error' THEN
    RETURN v_metrics;
  END IF;

  SELECT
    coalesce(c.stadium_display_fill_pct, (v_metrics ->> 'prestige_base_fill_pct')::numeric),
    c.stadium_season_start_fill_pct,
    coalesce(c.stadium_fill_target_pct, (v_metrics ->> 'season_target_fill_pct')::numeric)
  INTO v_display, v_season_start, v_target
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  v_gate := least(v_cfg.stadium_target_fill_pct, v_display) / 100.0;
  v_cushion := greatest(0, v_display - v_cfg.stadium_target_fill_pct);

  RETURN v_metrics || jsonb_build_object(
    'display_fill_pct', round(v_display, 2),
    'gate_fill_pct', round(least(v_cfg.stadium_target_fill_pct, v_display), 2),
    'cushion_pct', round(v_cushion, 2),
    'season_start_fill_pct', round(coalesce(v_season_start, v_display), 2),
    'season_target_fill_pct', round(v_target, 2),
    'attendance_rate', round(v_gate, 4),
    'gate_attendance_rate', round(v_gate, 4),
    'display_attendance_rate', round(v_display / 100.0, 4),
    'max_fill_pct', v_cfg.stadium_target_fill_pct,
    'neutral_fill_pct', v_cfg.stadium_neutral_fill_pct
  );
END;
$function$;

-- Gate uses capped rate; sync before estimate/settle
CREATE OR REPLACE FUNCTION public.competition_compute_gate_total(
  p_capacity int,
  p_table_position int,
  p_history_avg_position numeric,
  p_club_short_name text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL,
  p_division text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_capacity int := greatest(coalesce(p_capacity, 0), 0);
  v_price_per_seat numeric := 20;
  v_total numeric;
  v_fill jsonb;
  v_rate numeric;
BEGIN
  IF p_club_short_name IS NOT NULL AND btrim(p_club_short_name) <> '' THEN
    PERFORM public.competition_stadium_sync_fill_state(p_club_short_name, p_season_id);

    v_fill := public.competition_compute_stadium_fill(
      p_club_short_name,
      p_season_id,
      p_division
    );

    IF v_fill ? 'error' THEN
      v_rate := 0.55
        + 0.35 * ((21 - least(greatest(coalesce(p_table_position, 10), 1), 20))::numeric / 20.0)
        + 0.05 * ((21 - least(greatest(coalesce(p_history_avg_position, 10), 1), 20)) / 20.0);
      v_rate := least(v_rate, 0.95);

      RETURN jsonb_build_object(
        'capacity', v_capacity,
        'table_position', p_table_position,
        'history_avg_position', round(coalesce(p_history_avg_position, 10), 2),
        'attendance_rate', round(v_rate, 4),
        'price_per_seat', v_price_per_seat,
        'total_gate', round(v_capacity * v_rate * v_price_per_seat),
        'legacy_fallback', true
      );
    END IF;

    v_rate := (v_fill ->> 'attendance_rate')::numeric;
    v_total := round(v_capacity * v_rate * v_price_per_seat);

    RETURN v_fill || jsonb_build_object(
      'table_position', (v_fill ->> 'actual_position')::int,
      'price_per_seat', v_price_per_seat,
      'total_gate', v_total
    );
  END IF;

  v_rate := 0.55
    + 0.35 * ((21 - least(greatest(coalesce(p_table_position, 10), 1), 20))::numeric / 20.0)
    + 0.05 * ((21 - least(greatest(coalesce(p_history_avg_position, 10), 1), 20)) / 20.0);
  v_rate := least(v_rate, 0.95);
  v_total := round(v_capacity * v_rate * v_price_per_seat);

  RETURN jsonb_build_object(
    'capacity', v_capacity,
    'table_position', p_table_position,
    'history_avg_position', round(coalesce(p_history_avg_position, 10), 2),
    'attendance_rate', round(v_rate, 4),
    'price_per_seat', v_price_per_seat,
    'total_gate', v_total,
    'legacy_fallback', true
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_estimate_gate_for_club(
  p_club_short_name text,
  p_season_id bigint DEFAULT NULL,
  p_division text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_division text;
  v_capacity int;
  v_pos int;
  v_hist numeric;
BEGIN
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

  PERFORM public.competition_stadium_sync_fill_state(p_club_short_name, v_season_id);

  IF p_division IS NULL THEN
    SELECT ccs.division INTO v_division
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND ccs.club_short_name = p_club_short_name
    LIMIT 1;
  ELSE
    v_division := p_division;
  END IF;

  SELECT coalesce(c."Capacity", 0)::int INTO v_capacity
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  v_pos := public.competition_club_table_position(
    v_season_id,
    coalesce(v_division, 'superleague'),
    p_club_short_name
  );
  v_hist := public.competition_club_history_avg_position(p_club_short_name, 5);

  RETURN public.competition_compute_gate_total(
    v_capacity,
    v_pos,
    v_hist,
    p_club_short_name,
    v_season_id,
    v_division
  ) || jsonb_build_object(
    'club_short_name', p_club_short_name,
    'season_id', v_season_id,
    'division', v_division,
    'history_avg_position', round(v_hist, 2)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5-season history + projection note
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_club_rolling_season_stats(p_club_short_name text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH cfg AS (
    SELECT greatest(stadium_rolling_seasons, 1) AS n FROM public.global_settings WHERE id = 1
  ),
  last_n AS (
    SELECT r.season_id, r.season_label, r.season_total, r.final_position, r.division
    FROM public.competition_club_season_ranking r
    WHERE r.club_short_name = p_club_short_name
    ORDER BY r.season_id DESC
    LIMIT (SELECT n FROM cfg)
  )
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'season_label', season_label,
        'season_total', season_total,
        'final_position', final_position,
        'division', division
      )
      ORDER BY season_id DESC
    ),
    '[]'::jsonb
  )
  FROM last_n;
$$;

CREATE OR REPLACE FUNCTION public.competition_stadium_projection_note(
  p_club_short_name text,
  p_display_fill numeric,
  p_prestige_rank smallint,
  p_tier text,
  p_band text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.global_settings;
  v_seasons_to_full numeric;
  v_gap numeric;
BEGIN
  SELECT * INTO v_cfg FROM public.global_settings WHERE id = 1;

  v_gap := greatest(0, v_cfg.stadium_target_fill_pct - coalesce(p_display_fill, v_cfg.stadium_min_fill_pct));

  IF v_gap <= 0 THEN
    IF coalesce(p_display_fill, 0) > v_cfg.stadium_target_fill_pct THEN
      RETURN format(
        'Cushion %s%% above full gate — absorbs %s%% of a bad season before gate revenue drops.',
        round(p_display_fill - v_cfg.stadium_target_fill_pct, 1),
        round(least(p_display_fill - v_cfg.stadium_target_fill_pct, v_cfg.stadium_under_bad_penalty_pct), 1)
      );
    END IF;
    RETURN 'At full gate — maintain on-target seasons to keep cushion.';
  END IF;

  v_seasons_to_full := ceil(v_gap / greatest(v_cfg.stadium_season_gain_on_target_pct, 0.01));

  IF p_tier = 'low' OR p_tier = 'medium' THEN
    RETURN format(
      'Rank %s %s club: ~%s on-target season(s) to reach %s%% gate from %s%%. Strong manager + overperformance speeds this.',
      coalesce(p_prestige_rank, '?'),
      coalesce(p_tier, 'club'),
      v_seasons_to_full::int,
      v_cfg.stadium_target_fill_pct::int,
      round(coalesce(p_display_fill, v_cfg.stadium_min_fill_pct), 1)
    );
  END IF;

  RETURN format(
    'Big club held to high standards — band %s. ~%s strong season(s) to restore %s%% gate.',
    coalesce(p_band, 'on_target'),
    v_seasons_to_full::int,
    v_cfg.stadium_target_fill_pct::int
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin overview view (all clubs)
-- ---------------------------------------------------------------------------

-- Admin view depends on overview — drop dependent first
DROP VIEW IF EXISTS public.competition_club_attendance_admin_public;
DROP VIEW IF EXISTS public.competition_club_stadium_overview_public;
CREATE VIEW public.competition_club_stadium_overview_public
WITH (security_invoker = false)
AS
SELECT
  p.prestige_rank,
  p.club_short_name,
  p.club_name,
  p.capacity,
  p.rolling_points,
  p.seasons_count AS rolling_seasons_count,
  p.composite_score,
  public.competition_club_tier(p.club_short_name) AS effective_tier,
  o.tier_override,
  c.manager_rating,
  c.stadium_season_start_fill_pct,
  c.stadium_display_fill_pct,
  c.stadium_fill_target_pct,
  round(least(100, coalesce(c.stadium_display_fill_pct, 75)), 1) AS gate_fill_pct,
  round(greatest(0, coalesce(c.stadium_display_fill_pct, 75) - 100), 1) AS cushion_pct,
  (fill.d ->> 'expected_points')::numeric AS expected_points,
  (fill.d ->> 'actual_points')::numeric AS actual_points,
  (fill.d ->> 'performance_gap')::numeric AS performance_gap,
  fill.d ->> 'performance_band' AS performance_band,
  (fill.d ->> 'prestige_base_fill_pct')::numeric AS prestige_base_fill_pct,
  (fill.d ->> 'expected_position')::smallint AS expected_position,
  (fill.d ->> 'actual_position')::smallint AS actual_position,
  public.competition_club_rolling_season_stats(p.club_short_name) AS last_seasons_json,
  public.competition_stadium_projection_note(
    p.club_short_name,
    c.stadium_display_fill_pct,
    p.prestige_rank,
    public.competition_club_tier(p.club_short_name),
    fill.d ->> 'performance_band'
  ) AS projection_note,
  p.capacity <= (SELECT stadium_new_build_max_capacity FROM public.global_settings WHERE id = 1) AS expansion_eligible
FROM public.competition_club_prestige_public p
JOIN public."Clubs" c ON c."ShortName" = p.club_short_name
LEFT JOIN public.competition_club_tier_override o ON o.club_short_name = p.club_short_name
CROSS JOIN LATERAL (
  SELECT public.competition_compute_stadium_fill(p.club_short_name) AS d
) fill
ORDER BY p.prestige_rank;

-- Keep legacy admin view in sync (adds v2 columns)
CREATE VIEW public.competition_club_attendance_admin_public
WITH (security_invoker = false)
AS
SELECT
  o.prestige_rank,
  o.club_short_name,
  o.club_name,
  o.capacity,
  o.rolling_points,
  o.composite_score,
  o.effective_tier,
  o.tier_override,
  o.manager_rating,
  o.expected_points,
  o.actual_points,
  o.performance_gap,
  o.performance_band,
  o.prestige_base_fill_pct,
  o.stadium_season_start_fill_pct AS season_start_fill_pct,
  o.stadium_display_fill_pct AS display_fill_pct,
  o.gate_fill_pct AS fill_pct,
  o.cushion_pct,
  o.stadium_fill_target_pct AS season_target_fill_pct,
  o.projection_note
FROM public.competition_club_stadium_overview_public o;

-- ---------------------------------------------------------------------------
-- Admin settings RPC (v2 knobs)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_update_stadium_attendance_settings(p_settings jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.global_settings
  SET
    stadium_min_fill_pct = coalesce((p_settings ->> 'stadium_min_fill_pct')::numeric, stadium_min_fill_pct),
    stadium_max_fill_pct = coalesce((p_settings ->> 'stadium_max_fill_pct')::numeric, stadium_max_fill_pct),
    stadium_neutral_fill_pct = coalesce((p_settings ->> 'stadium_neutral_fill_pct')::numeric, stadium_neutral_fill_pct),
    stadium_rolling_seasons = coalesce((p_settings ->> 'stadium_rolling_seasons')::smallint, stadium_rolling_seasons),
    stadium_big_club_max_rank = coalesce((p_settings ->> 'stadium_big_club_max_rank')::smallint, stadium_big_club_max_rank),
    stadium_medium_club_max_rank = coalesce((p_settings ->> 'stadium_medium_club_max_rank')::smallint, stadium_medium_club_max_rank),
    stadium_capacity_prestige_weight = coalesce((p_settings ->> 'stadium_capacity_prestige_weight')::numeric, stadium_capacity_prestige_weight),
    stadium_capacity_prestige_ref = coalesce((p_settings ->> 'stadium_capacity_prestige_ref')::integer, stadium_capacity_prestige_ref),
    stadium_big_club_sensitivity = coalesce((p_settings ->> 'stadium_big_club_sensitivity')::numeric, stadium_big_club_sensitivity),
    stadium_medium_club_sensitivity = coalesce((p_settings ->> 'stadium_medium_club_sensitivity')::numeric, stadium_medium_club_sensitivity),
    stadium_low_club_sensitivity = coalesce((p_settings ->> 'stadium_low_club_sensitivity')::numeric, stadium_low_club_sensitivity),
    stadium_overperform_cap = coalesce((p_settings ->> 'stadium_overperform_cap')::numeric, stadium_overperform_cap),
    stadium_points_gap_scale = coalesce((p_settings ->> 'stadium_points_gap_scale')::numeric, stadium_points_gap_scale),
    stadium_league_expect_weight = coalesce((p_settings ->> 'stadium_league_expect_weight')::numeric, stadium_league_expect_weight),
    stadium_cup_expect_weight = coalesce((p_settings ->> 'stadium_cup_expect_weight')::numeric, stadium_cup_expect_weight),
    stadium_league_perf_weight = coalesce((p_settings ->> 'stadium_league_perf_weight')::numeric, stadium_league_perf_weight),
    stadium_cup_perf_weight = coalesce((p_settings ->> 'stadium_cup_perf_weight')::numeric, stadium_cup_perf_weight),
    stadium_manager_lift_threshold = coalesce((p_settings ->> 'stadium_manager_lift_threshold')::smallint, stadium_manager_lift_threshold),
    stadium_manager_lift_max_rating = coalesce((p_settings ->> 'stadium_manager_lift_max_rating')::smallint, stadium_manager_lift_max_rating),
    stadium_manager_lift_max_positions_med = coalesce((p_settings ->> 'stadium_manager_lift_max_positions_med')::numeric, stadium_manager_lift_max_positions_med),
    stadium_manager_lift_max_positions_low = coalesce((p_settings ->> 'stadium_manager_lift_max_positions_low')::numeric, stadium_manager_lift_max_positions_low),
    stadium_expected_cup_super8_pts = coalesce((p_settings ->> 'stadium_expected_cup_super8_pts')::numeric, stadium_expected_cup_super8_pts),
    stadium_expected_cup_plate_pts = coalesce((p_settings ->> 'stadium_expected_cup_plate_pts')::numeric, stadium_expected_cup_plate_pts),
    stadium_expected_cup_shield_pts = coalesce((p_settings ->> 'stadium_expected_cup_shield_pts')::numeric, stadium_expected_cup_shield_pts),
    stadium_expected_cup_spoon_pts = coalesce((p_settings ->> 'stadium_expected_cup_spoon_pts')::numeric, stadium_expected_cup_spoon_pts),
    stadium_expected_cup_league_cup_pts = coalesce((p_settings ->> 'stadium_expected_cup_league_cup_pts')::numeric, stadium_expected_cup_league_cup_pts),
    stadium_max_display_fill_pct = coalesce((p_settings ->> 'stadium_max_display_fill_pct')::numeric, stadium_max_display_fill_pct),
    stadium_target_fill_pct = coalesce((p_settings ->> 'stadium_target_fill_pct')::numeric, stadium_target_fill_pct),
    stadium_monthly_drift_pct = coalesce((p_settings ->> 'stadium_monthly_drift_pct')::numeric, stadium_monthly_drift_pct),
    stadium_prestige_fill_step_pct = coalesce((p_settings ->> 'stadium_prestige_fill_step_pct')::numeric, stadium_prestige_fill_step_pct),
    stadium_under_slight_penalty_pct = coalesce((p_settings ->> 'stadium_under_slight_penalty_pct')::numeric, stadium_under_slight_penalty_pct),
    stadium_under_bad_penalty_pct = coalesce((p_settings ->> 'stadium_under_bad_penalty_pct')::numeric, stadium_under_bad_penalty_pct),
    stadium_under_abysmal_penalty_pct = coalesce((p_settings ->> 'stadium_under_abysmal_penalty_pct')::numeric, stadium_under_abysmal_penalty_pct),
    stadium_season_gain_on_target_pct = coalesce((p_settings ->> 'stadium_season_gain_on_target_pct')::numeric, stadium_season_gain_on_target_pct),
    stadium_new_build_max_capacity = coalesce((p_settings ->> 'stadium_new_build_max_capacity')::integer, stadium_new_build_max_capacity),
    stadium_under_slight_gap_ratio = coalesce((p_settings ->> 'stadium_under_slight_gap_ratio')::numeric, stadium_under_slight_gap_ratio),
    stadium_under_bad_gap_ratio = coalesce((p_settings ->> 'stadium_under_bad_gap_ratio')::numeric, stadium_under_bad_gap_ratio),
    updated_at = now()
  WHERE id = 1;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Season activation: snapshot starting fill
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_activate_season(p_season_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sl bigint;
  v_a bigint;
  v_b bigint;
  v_bad bigint;
  v_has_calendar boolean;
BEGIN
  PERFORM public.competition_assert_setup_season(p_season_id);

  SELECT count(*) INTO v_sl
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id AND division = 'superleague';

  SELECT count(*) INTO v_a
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id AND division = 'championship_a';

  SELECT count(*) INTO v_b
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id AND division = 'championship_b';

  SELECT count(*) INTO v_bad
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id
    AND division NOT IN ('superleague', 'championship_a', 'championship_b');

  IF v_sl <> 20 OR v_a <> 20 OR v_b <> 20 OR v_bad > 0 THEN
    RAISE EXCEPTION 'Need 20 SL + 20 CH A + 20 CH B (bad rows: %)', v_bad;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config WHERE season_id = p_season_id
  ) INTO v_has_calendar;

  IF NOT v_has_calendar THEN
    RAISE EXCEPTION 'Set the real-world season calendar (first Friday 19:00 UK) before starting the season';
  END IF;

  UPDATE public.competition_seasons
  SET is_current = false
  WHERE is_current = true;

  UPDATE public.competition_seasons
  SET status = 'active', is_current = true, activated_at = now()
  WHERE id = p_season_id;

  UPDATE public.global_settings
  SET league_phase = NULL, updated_at = now()
  WHERE id = 1;

  PERFORM public.competition_stadium_snapshot_season_start(p_season_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Stadium expansion: only clubs at or below 55k capacity
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.stadium_expansion_create_quote(p_seats integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_current int;
  v_base int;
  v_max int;
  v_headroom int;
  v_cps numeric;
  v_total numeric;
  v_quote_id bigint;
  v_max_build int;
BEGIN
  v_club := public.competition_current_club_short_name();

  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF coalesce(p_seats, 0) <= 0 THEN
    RAISE EXCEPTION 'Seats must be positive';
  END IF;

  PERFORM public.stadium_expansion_sync_progress(v_club);

  SELECT coalesce(c."Capacity", 0)::int, coalesce(c.base_capacity, c."Capacity", 0)::int
  INTO v_current, v_base
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  SELECT coalesce(stadium_new_build_max_capacity, 55000)
  INTO v_max_build
  FROM public.global_settings
  WHERE id = 1;

  IF v_current > v_max_build THEN
    RAISE EXCEPTION 'Stadium expansion is only available for clubs with capacity at or below % seats', v_max_build;
  END IF;

  v_max := public.stadium_max_capacity(v_base);
  v_headroom := public.stadium_expansion_headroom(v_club);

  IF v_headroom <= 0 THEN
    RAISE EXCEPTION 'Stadium is at maximum capacity — expansion not available';
  END IF;

  IF p_seats > v_headroom THEN
    RAISE EXCEPTION 'Cannot add % seats — only % headroom remaining', p_seats, v_headroom;
  END IF;

  v_cps := public.stadium_expansion_cost_per_seat(v_current);
  v_total := round(p_seats * v_cps, 2);

  INSERT INTO public.stadium_expansion_quotes (
    club_short_name, seats, capacity_at_quote, cost_per_seat, total_cost
  )
  VALUES (v_club, p_seats, v_current, v_cps, v_total)
  RETURNING id INTO v_quote_id;

  RETURN jsonb_build_object(
    'quote_id', v_quote_id,
    'seats', p_seats,
    'cost_per_seat', v_cps,
    'total_cost', v_total,
    'capacity_at_quote', v_current,
    'max_capacity', v_max,
    'headroom', v_headroom
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- global_settings_public (preserve all columns + v2)
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.global_settings_public;

CREATE VIEW public.global_settings_public
WITH (security_invoker = false)
AS
SELECT
  id,
  transfer_window_open,
  draft_auction_enabled,
  draft_auction_start_time,
  updated_at,
  league_phase,
  wage_pct_superleague,
  wage_pct_championship,
  stadium_cost_tier1,
  stadium_cost_tier2,
  stadium_cost_tier3,
  stadium_capacity_tier_mid,
  stadium_capacity_tier_high,
  stadium_expansion_cancel_penalty,
  hg_sub_band1_max,
  hg_sub_band1_per_player,
  hg_sub_band2_max,
  hg_sub_band2_per_player,
  hg_sub_band3_per_player,
  youth_sub_band1_max,
  youth_sub_band1_per_player,
  youth_sub_band2_max,
  youth_sub_band2_per_player,
  youth_sub_band3_max,
  youth_sub_band3_per_player,
  youth_sub_band4_per_player,
  bnb_max_rating,
  bnb_min_players,
  bnb_per_player,
  tv_per_match_amount,
  tv_matches_per_month,
  tv_club_min_season,
  tv_club_max_season,
  tv_weight_top8_clash,
  tv_weight_title_race,
  tv_weight_promotion,
  tv_weight_relegation,
  tv_weight_super8,
  tv_weight_playoff,
  tv_weight_dry_spell,
  tv_weight_below_min,
  challenge_default_prize,
  challenge_period_bonus,
  wage_34plus_min_rating,
  wage_34plus_per_player,
  star_tax_min_rating,
  star_tax_per_player,
  emergency_tac_pct,
  emergency_tac_threshold,
  stadium_min_fill_pct,
  stadium_max_fill_pct,
  stadium_neutral_fill_pct,
  stadium_rolling_seasons,
  stadium_big_club_max_rank,
  stadium_medium_club_max_rank,
  stadium_capacity_prestige_weight,
  stadium_capacity_prestige_ref,
  stadium_big_club_sensitivity,
  stadium_medium_club_sensitivity,
  stadium_low_club_sensitivity,
  stadium_overperform_cap,
  stadium_points_gap_scale,
  stadium_league_expect_weight,
  stadium_cup_expect_weight,
  stadium_league_perf_weight,
  stadium_cup_perf_weight,
  stadium_manager_lift_threshold,
  stadium_manager_lift_max_rating,
  stadium_manager_lift_max_positions_med,
  stadium_manager_lift_max_positions_low,
  stadium_expected_cup_super8_pts,
  stadium_expected_cup_plate_pts,
  stadium_expected_cup_shield_pts,
  stadium_expected_cup_spoon_pts,
  stadium_expected_cup_league_cup_pts,
  stadium_max_display_fill_pct,
  stadium_target_fill_pct,
  stadium_monthly_drift_pct,
  stadium_prestige_fill_step_pct,
  stadium_under_slight_penalty_pct,
  stadium_under_bad_penalty_pct,
  stadium_under_abysmal_penalty_pct,
  stadium_season_gain_on_target_pct,
  stadium_new_build_max_capacity,
  stadium_under_slight_gap_ratio,
  stadium_under_bad_gap_ratio,
  (
    COALESCE(draft_auction_enabled, false)
    AND draft_auction_start_time IS NOT NULL
    AND draft_random_finish_time IS NOT NULL
    AND now() >= draft_auction_start_time
    AND now() < draft_random_finish_time
  ) AS draft_bidding_open
FROM public.global_settings;

-- Gate settlement description uses gate fill
CREATE OR REPLACE FUNCTION public.competition_settle_fixture_gates(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_capacity int;
  v_pos int;
  v_hist numeric;
  v_breakdown jsonb;
  v_total numeric;
  v_home_share numeric;
  v_away_share numeric;
  v_desc text;
  v_home_club text;
  v_away_club text;
  v_division text;
  v_gate_pct numeric;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND entry_type IN ('gate_league_home', 'gate_cup_share')
  ) THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
    AND status = 'played'
    AND home_goals IS NOT NULL
    AND away_goals IS NOT NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_home_club := v_fixture.home_club_short_name;
  v_away_club := v_fixture.away_club_short_name;

  IF v_fixture.competition_type = 'cup' THEN
    SELECT ccs.division INTO v_division
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_fixture.season_id
      AND ccs.club_short_name = v_home_club;
  ELSE
    v_division := v_fixture.division;
  END IF;

  v_division := coalesce(v_division, 'superleague');

  SELECT coalesce(c."Capacity", 0)::int INTO v_capacity
  FROM public."Clubs" c
  WHERE c."ShortName" = v_home_club;

  v_pos := public.competition_club_table_position(
    v_fixture.season_id,
    v_division,
    v_home_club
  );
  v_hist := public.competition_club_history_avg_position(v_home_club, 5);
  v_breakdown := public.competition_compute_gate_total(
    v_capacity,
    v_pos,
    v_hist,
    v_home_club,
    v_fixture.season_id,
    v_division
  );
  v_total := (v_breakdown ->> 'total_gate')::numeric;

  IF v_total IS NULL OR v_total <= 0 THEN
    RETURN;
  END IF;

  v_gate_pct := coalesce(
    (v_breakdown ->> 'gate_fill_pct')::numeric,
    round((v_breakdown ->> 'attendance_rate')::numeric * 100, 1)
  );

  IF v_fixture.competition_type = 'league' THEN
    v_desc := format(
      'Gate MD%s — %s vs %s (home 100%%) · gate fill %s%%',
      v_fixture.matchday,
      v_home_club,
      v_away_club,
      v_gate_pct
    );

    PERFORM public.competition_credit_club_balance(v_home_club, v_total);

    INSERT INTO public.competition_finance_ledger (
      season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
    )
    VALUES (
      v_fixture.season_id,
      p_fixture_id,
      v_home_club,
      'gate_league_home',
      v_total,
      v_desc,
      v_breakdown
    );
  ELSIF v_fixture.competition_type = 'cup' THEN
    v_home_share := round(v_total / 2.0, 2);
    v_away_share := v_total - v_home_share;

    v_desc := format(
      '%s R%s — %s vs %s (50/50 gate)',
      upper(v_fixture.cup_code),
      v_fixture.cup_round,
      v_home_club,
      v_away_club
    );

    PERFORM public.competition_credit_club_balance(v_home_club, v_home_share);
    PERFORM public.competition_credit_club_balance(v_away_club, v_away_share);

    INSERT INTO public.competition_finance_ledger (
      season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
    )
    VALUES
      (
        v_fixture.season_id,
        p_fixture_id,
        v_home_club,
        'gate_cup_share',
        v_home_share,
        v_desc || ' (home)',
        v_breakdown
      ),
      (
        v_fixture.season_id,
        p_fixture_id,
        v_away_club,
        'gate_cup_share',
        v_away_share,
        v_desc || ' (away)',
        v_breakdown
      );
  END IF;
END;
$function$;

-- Initial backfill display fill from prestige
UPDATE public."Clubs" c
SET stadium_display_fill_pct = public.competition_stadium_prestige_base_fill(c."ShortName"),
    stadium_season_start_fill_pct = public.competition_stadium_prestige_base_fill(c."ShortName")
WHERE c.stadium_display_fill_pct IS NULL;

-- Grants
GRANT SELECT ON public.competition_club_stadium_overview_public TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_stadium_sync_all_clubs(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_stadium_sync_fill_state(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_stadium_season_metrics(text, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_rolling_season_stats(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
