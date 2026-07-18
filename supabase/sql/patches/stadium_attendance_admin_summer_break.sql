-- =============================================================================
-- Club attendance admin blank during Summer Break / no active season.
--
-- Root cause: competition_stadium_season_metrics required is_current + active,
-- and competition_club_stadium_overview_public dropped rows with fill errors.
--
-- Safe to re-run.
-- =============================================================================

-- Drop mistaken helper from earlier draft of this patch (if present)
DROP FUNCTION IF EXISTS public.competition_club_season_metrics(text, bigint, text);

CREATE OR REPLACE FUNCTION public.competition_stadium_resolve_season_id(
  p_season_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    p_season_id,
    (
      SELECT s.id
      FROM public.competition_seasons s
      WHERE s.is_current = true AND s.status = 'active'
      ORDER BY s.id DESC
      LIMIT 1
    ),
    (
      SELECT s.id
      FROM public.competition_seasons s
      WHERE s.is_current = true
      ORDER BY s.id DESC
      LIMIT 1
    ),
    (
      SELECT s.id
      FROM public.competition_seasons s
      WHERE s.status = 'complete'
      ORDER BY s.id DESC
      LIMIT 1
    ),
    (
      SELECT s.id
      FROM public.competition_seasons s
      ORDER BY s.id DESC
      LIMIT 1
    )
  );
$$;

-- Soften season resolution only (rest of function matches stadium_attendance_v2)
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

-- Keep clubs visible even if fill metrics fail for any reason
DROP VIEW IF EXISTS public.competition_club_attendance_admin_public;
DROP VIEW IF EXISTS public.competition_club_stadium_overview_public;

CREATE VIEW public.competition_club_stadium_overview_public
WITH (security_invoker = false)
AS
SELECT
  p.prestige_rank,
  p.prestige_seed_rank,
  p.prestige_rank_locked,
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
  round(least(100::numeric, coalesce(c.stadium_display_fill_pct, 75::numeric)), 1) AS gate_fill_pct,
  round(greatest(0::numeric, coalesce(c.stadium_display_fill_pct, 75::numeric) - 100::numeric), 1) AS cushion_pct,
  CASE
    WHEN fill.d ? 'error' THEN NULL::numeric
    ELSE (fill.d ->> 'expected_points')::numeric
  END AS expected_points,
  CASE
    WHEN fill.d ? 'error' THEN NULL::numeric
    ELSE (fill.d ->> 'actual_points')::numeric
  END AS actual_points,
  CASE
    WHEN fill.d ? 'error' THEN NULL::numeric
    ELSE (fill.d ->> 'performance_gap')::numeric
  END AS performance_gap,
  CASE
    WHEN fill.d ? 'error' THEN NULL::text
    ELSE fill.d ->> 'performance_band'
  END AS performance_band,
  coalesce(
    NULLIF(fill.d ->> 'prestige_base_fill_pct', '')::numeric,
    public.competition_stadium_prestige_base_fill(p.club_short_name)
  ) AS prestige_base_fill_pct,
  CASE
    WHEN fill.d ? 'error' THEN NULL::smallint
    WHEN btrim(coalesce(fill.d ->> 'expected_position', '')) ~ '^-?\d+$'
      THEN (fill.d ->> 'expected_position')::smallint
    ELSE NULL::smallint
  END AS expected_position,
  CASE
    WHEN fill.d ? 'error' THEN NULL::smallint
    WHEN btrim(coalesce(fill.d ->> 'actual_position', '')) ~ '^-?\d+$'
      THEN (fill.d ->> 'actual_position')::smallint
    ELSE NULL::smallint
  END AS actual_position,
  coalesce(public.competition_club_rolling_season_stats(p.club_short_name), '[]'::jsonb) AS last_seasons_json,
  CASE
    WHEN fill.d ? 'error' THEN
      'No live season metrics — prestige & fill still shown.'
    ELSE public.competition_stadium_projection_note(
      p.club_short_name,
      c.stadium_display_fill_pct,
      p.prestige_rank,
      public.competition_club_tier(p.club_short_name),
      fill.d ->> 'performance_band'
    )
  END AS projection_note,
  (p.capacity <= coalesce(gs.stadium_new_build_max_capacity, 55000)) AS expansion_eligible
FROM public.competition_club_prestige_public p
JOIN public."Clubs" c ON c."ShortName" = p.club_short_name
CROSS JOIN (SELECT stadium_new_build_max_capacity FROM public.global_settings WHERE id = 1) gs
LEFT JOIN public.competition_club_tier_override o ON o.club_short_name = p.club_short_name
CROSS JOIN LATERAL (
  SELECT public.competition_compute_stadium_fill(p.club_short_name) AS d
) fill
WHERE p.club_short_name <> 'FOREIGN';

CREATE VIEW public.competition_club_attendance_admin_public
WITH (security_invoker = false)
AS
SELECT
  o.prestige_rank,
  o.prestige_seed_rank,
  o.prestige_rank_locked,
  o.club_short_name,
  o.club_name,
  o.capacity,
  o.rolling_points,
  o.rolling_seasons_count,
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

GRANT SELECT ON public.competition_club_stadium_overview_public TO authenticated;
GRANT SELECT ON public.competition_club_attendance_admin_public TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_stadium_resolve_season_id(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_stadium_season_metrics(text, bigint, text) TO authenticated;

-- Refresh list RPC to use updated view
CREATE OR REPLACE FUNCTION public.competition_club_stadium_overview_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(
    jsonb_agg(to_jsonb(v) ORDER BY v.prestige_rank),
    '[]'::jsonb
  )
  INTO v_rows
  FROM public.competition_club_stadium_overview_public v;

  RETURN v_rows;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_club_stadium_overview_list() TO authenticated;

NOTIFY pgrst, 'reload schema';
