-- Manual initial prestige order (1–60) before 5-year history drives rank.
-- Run after competition_club_stadium_attendance.sql + stadium_attendance_v2.sql.
--
-- When a club has no rolling season points yet, composite_score uses seed_rank
-- (admin-set). Once rolling_points > 0, normal history + capacity blend wins.

CREATE TABLE IF NOT EXISTS public.competition_club_prestige_seed (
  club_short_name text PRIMARY KEY
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  seed_rank smallint NOT NULL CHECK (seed_rank >= 1 AND seed_rank <= 99),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS competition_club_prestige_seed_rank_uidx
  ON public.competition_club_prestige_seed (seed_rank);

COMMENT ON TABLE public.competition_club_prestige_seed IS
  'Admin manual prestige order used until club has rolling season ranking points.';

-- ---------------------------------------------------------------------------
-- Prestige rank view — seed fallback when rolling_points = 0
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.competition_club_attendance_admin_public;
DROP VIEW IF EXISTS public.competition_club_stadium_overview_public;
DROP VIEW IF EXISTS public.competition_club_prestige_public;

CREATE VIEW public.competition_club_prestige_public
WITH (security_invoker = false)
AS
WITH cfg AS (
  SELECT * FROM public.global_settings WHERE id = 1
),
last_n AS (
  SELECT s.season_id AS id
  FROM (
    SELECT DISTINCT season_id
    FROM public.competition_club_season_ranking
    ORDER BY season_id DESC
    LIMIT (SELECT greatest(stadium_rolling_seasons, 1) FROM cfg)
  ) s
),
rolling AS (
  SELECT
    r.club_short_name,
    sum(r.season_total) AS rolling_points,
    count(*)::integer AS seasons_count
  FROM public.competition_club_season_ranking r
  WHERE r.season_id IN (SELECT id FROM last_n)
  GROUP BY r.club_short_name
),
scored AS (
  SELECT
    c."ShortName" AS club_short_name,
    c."Club" AS club_name,
    coalesce(c."Capacity", 0)::int AS capacity,
    coalesce(r.rolling_points, 0) AS rolling_points,
    coalesce(r.seasons_count, 0) AS seasons_count,
    ps.seed_rank AS prestige_seed_rank,
    round(
      CASE
        WHEN coalesce(r.rolling_points, 0) > 0 THEN
          coalesce(r.rolling_points, 0)
          + (coalesce(c."Capacity", 0)::numeric / greatest(cfg.stadium_capacity_prestige_ref, 1))
            * cfg.stadium_capacity_prestige_weight
            * greatest(coalesce(r.rolling_points, 0), 1)
        WHEN ps.seed_rank IS NOT NULL THEN
          (61 - ps.seed_rank)::numeric * 100000
          + coalesce(c."Capacity", 0)::numeric / 1000
        ELSE
          (coalesce(c."Capacity", 0)::numeric / greatest(cfg.stadium_capacity_prestige_ref, 1))
            * cfg.stadium_capacity_prestige_weight
      END,
      2
    ) AS composite_score
  FROM public."Clubs" c
  CROSS JOIN cfg
  LEFT JOIN rolling r ON r.club_short_name = c."ShortName"
  LEFT JOIN public.competition_club_prestige_seed ps ON ps.club_short_name = c."ShortName"
  WHERE c."ShortName" <> 'FOREIGN'
)
SELECT
  row_number() OVER (ORDER BY s.composite_score DESC, s.club_short_name)::smallint AS prestige_rank,
  s.club_short_name,
  s.club_name,
  s.capacity,
  s.rolling_points,
  s.seasons_count,
  s.composite_score,
  s.prestige_seed_rank
FROM scored s
ORDER BY prestige_rank;

CREATE VIEW public.competition_club_stadium_overview_public
WITH (security_invoker = false)
AS
SELECT
  p.prestige_rank,
  p.prestige_seed_rank,
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
WHERE NOT (fill.d ? 'error')
  AND p.club_short_name <> 'FOREIGN';

CREATE VIEW public.competition_club_attendance_admin_public
WITH (security_invoker = false)
AS
SELECT
  o.prestige_rank,
  o.prestige_seed_rank,
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

CREATE OR REPLACE FUNCTION public.admin_set_club_prestige_seed_ranks(p_ranks jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row jsonb;
  v_club text;
  v_rank int;
  v_count int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_ranks IS NULL OR jsonb_typeof(p_ranks) <> 'array' OR jsonb_array_length(p_ranks) = 0 THEN
    RAISE EXCEPTION 'Provide a JSON array of {club_short_name, seed_rank} objects';
  END IF;

  DELETE FROM public.competition_club_prestige_seed;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_ranks)
  LOOP
    v_club := btrim(v_row ->> 'club_short_name');
    v_rank := (v_row ->> 'seed_rank')::int;

    IF v_club IS NULL OR v_club = '' OR v_rank IS NULL OR v_rank < 1 THEN
      RAISE EXCEPTION 'Invalid seed row: %', v_row;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club) THEN
      RAISE EXCEPTION 'Unknown club: %', v_club;
    END IF;

    INSERT INTO public.competition_club_prestige_seed (club_short_name, seed_rank, updated_at)
    VALUES (v_club, v_rank::smallint, now());

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'clubs_seeded', v_count);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_apply_prestige_seed_to_start_fill()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_fill numeric;
  v_count int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_club IN
    SELECT c."ShortName" AS club_short_name
    FROM public."Clubs" c
    WHERE c."ShortName" <> 'FOREIGN'
  LOOP
    v_fill := public.competition_stadium_prestige_base_fill(v_club.club_short_name);

    UPDATE public."Clubs" c
    SET
      stadium_display_fill_pct = v_fill,
      stadium_season_start_fill_pct = v_fill,
      stadium_fill_target_pct = v_fill,
      stadium_fill_updated_at = now()
    WHERE c."ShortName" = v_club.club_short_name;

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'clubs_updated', v_count);
END;
$function$;

GRANT SELECT ON public.competition_club_prestige_public TO authenticated;
GRANT SELECT ON public.competition_club_stadium_overview_public TO authenticated;
GRANT SELECT ON public.competition_club_attendance_admin_public TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_club_prestige_seed_ranks(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_prestige_seed_to_start_fill() TO authenticated;

NOTIFY pgrst, 'reload schema';
