-- =============================================================================
-- Hide stadium performance Status until the first GPSL month's league fixtures
-- are all played. Before then (preseason / Summer Break / early August): null.
-- Safe to re-run. Run after stadium_attendance_admin_summer_break.sql.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_stadium_performance_status_ready(
  p_season_id bigint
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text;
  v_first_month text;
  v_total int;
  v_played int;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT s.status INTO v_status
  FROM public.competition_seasons s
  WHERE s.id = p_season_id;

  -- Only meaningful once a season is live
  IF v_status IS DISTINCT FROM 'active' THEN
    RETURN false;
  END IF;

  SELECT f.gpsl_month INTO v_first_month
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.competition_type = 'league'
    AND f.gpsl_month IS NOT NULL
    AND btrim(f.gpsl_month) <> ''
  ORDER BY public.competition_gpsl_month_sort(f.gpsl_month) NULLS LAST, f.id
  LIMIT 1;

  IF v_first_month IS NULL THEN
    RETURN false;
  END IF;

  SELECT
    count(*)::int,
    count(*) FILTER (WHERE f.status = 'played')::int
  INTO v_total, v_played
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.competition_type = 'league'
    AND f.gpsl_month = v_first_month;

  RETURN v_total > 0 AND v_played >= v_total;
END;
$function$;

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
  v_status_ready boolean := false;
BEGIN
  SELECT * INTO v_cfg FROM public.global_settings WHERE id = 1;

  v_season_id := public.competition_stadium_resolve_season_id(p_season_id);

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('error', 'No competition season');
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

  SELECT count(*)::smallint INTO v_club_count
  FROM public."Clubs"
  WHERE "ShortName" <> 'FOREIGN';

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
  v_status_ready := public.competition_stadium_performance_status_ready(v_season_id);

  IF v_status_ready THEN
    v_band := public.competition_stadium_performance_band(v_gap, v_expected_pts, v_cfg);
    v_penalty := public.competition_stadium_performance_penalty(v_band, v_cfg);
  ELSE
    v_band := NULL;
    v_penalty := 0;
    v_gap := NULL;
  END IF;

  v_season_target := v_prestige_base;

  IF v_band = 'on_target' THEN
    v_season_target := least(
      v_cfg.stadium_max_display_fill_pct,
      v_prestige_base + v_cfg.stadium_season_gain_on_target_pct
    );
  ELSIF v_band IS NOT NULL THEN
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
    'actual_position', CASE WHEN v_status_ready THEN v_actual_pos ELSE NULL END,
    'league_expected_points', round(v_league_expected, 2),
    'league_actual_points', round(v_league_actual, 2),
    'cup_expected_points', round(v_cup_expected, 2),
    'cup_actual_points', round(v_cup_actual, 2),
    'expected_points', round(v_expected_pts, 2),
    'actual_points', CASE WHEN v_status_ready THEN round(v_actual_pts, 2) ELSE NULL END,
    'performance_gap', CASE WHEN v_status_ready THEN round(v_gap, 2) ELSE NULL END,
    'performance_band', v_band,
    'performance_status_ready', v_status_ready,
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

GRANT EXECUTE ON FUNCTION public.competition_stadium_performance_status_ready(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_stadium_season_metrics(text, bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
