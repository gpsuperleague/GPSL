-- =============================================================================
-- Repair club stadium overview (400 on REST select)
-- Run if competition_club_stadium_overview_public fails to load.
-- =============================================================================

-- Ensure v2 columns exist
ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS stadium_display_fill_pct numeric(5, 2),
  ADD COLUMN IF NOT EXISTS stadium_season_start_fill_pct numeric(5, 2),
  ADD COLUMN IF NOT EXISTS stadium_fill_target_pct numeric(5, 2),
  ADD COLUMN IF NOT EXISTS stadium_fill_last_month smallint,
  ADD COLUMN IF NOT EXISTS stadium_fill_season_id bigint REFERENCES public.competition_seasons (id),
  ADD COLUMN IF NOT EXISTS stadium_fill_updated_at timestamptz;

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS stadium_new_build_max_capacity integer NOT NULL DEFAULT 55000;

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
  round(least(100::numeric, coalesce(c.stadium_display_fill_pct, 75::numeric)), 1) AS gate_fill_pct,
  round(greatest(0::numeric, coalesce(c.stadium_display_fill_pct, 75::numeric) - 100::numeric), 1) AS cushion_pct,
  (fill.d ->> 'expected_points')::numeric AS expected_points,
  (fill.d ->> 'actual_points')::numeric AS actual_points,
  (fill.d ->> 'performance_gap')::numeric AS performance_gap,
  fill.d ->> 'performance_band' AS performance_band,
  (fill.d ->> 'prestige_base_fill_pct')::numeric AS prestige_base_fill_pct,
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
  public.competition_stadium_projection_note(
    p.club_short_name,
    c.stadium_display_fill_pct,
    p.prestige_rank,
    public.competition_club_tier(p.club_short_name),
    fill.d ->> 'performance_band'
  ) AS projection_note,
  (p.capacity <= coalesce(gs.stadium_new_build_max_capacity, 55000)) AS expansion_eligible
FROM public.competition_club_prestige_public p
JOIN public."Clubs" c ON c."ShortName" = p.club_short_name
CROSS JOIN (SELECT stadium_new_build_max_capacity FROM public.global_settings WHERE id = 1) gs
LEFT JOIN public.competition_club_tier_override o ON o.club_short_name = p.club_short_name
CROSS JOIN LATERAL (
  SELECT public.competition_compute_stadium_fill(p.club_short_name) AS d
) fill
WHERE NOT (fill.d ? 'error');

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

-- RPC fallback (admin) — avoids PostgREST edge cases on complex views
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

GRANT SELECT ON public.competition_club_stadium_overview_public TO authenticated;
GRANT SELECT ON public.competition_club_attendance_admin_public TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_stadium_overview_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_stadium_projection_note(text, numeric, smallint, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_rolling_season_stats(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
