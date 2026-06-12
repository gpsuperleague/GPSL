-- Prestige rank locked for the active season; recomputed from complete seasons only
-- when a new season is activated (after prior season archived).
-- Run after competition_club_stadium_attendance.sql + stadium_attendance_prestige_seed.sql (optional).

CREATE TABLE IF NOT EXISTS public.competition_club_prestige_seed (
  club_short_name text PRIMARY KEY
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  seed_rank smallint NOT NULL CHECK (seed_rank >= 1 AND seed_rank <= 99),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS competition_club_prestige_seed_rank_uidx
  ON public.competition_club_prestige_seed (seed_rank);

CREATE TABLE IF NOT EXISTS public.competition_club_prestige_snapshot (
  season_id bigint NOT NULL
    REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  club_short_name text NOT NULL
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  prestige_rank smallint NOT NULL CHECK (prestige_rank >= 1),
  composite_score numeric(12, 2) NOT NULL DEFAULT 0,
  rolling_points numeric(12, 2) NOT NULL DEFAULT 0,
  seasons_count integer NOT NULL DEFAULT 0,
  prestige_seed_rank smallint,
  locked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, club_short_name)
);

CREATE UNIQUE INDEX IF NOT EXISTS competition_club_prestige_snapshot_rank_uidx
  ON public.competition_club_prestige_snapshot (season_id, prestige_rank);

COMMENT ON TABLE public.competition_club_prestige_snapshot IS
  'Frozen club prestige rank for an active GPSL season. Set on season activate from completed seasons only.';

-- ---------------------------------------------------------------------------
-- Computed prestige (complete seasons in rolling window + manual seed fallback)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_club_prestige_computed()
RETURNS TABLE (
  club_short_name text,
  club_name text,
  capacity integer,
  rolling_points numeric,
  seasons_count integer,
  composite_score numeric,
  prestige_seed_rank smallint,
  prestige_rank smallint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH cfg AS (
    SELECT * FROM public.global_settings WHERE id = 1
  ),
  last_n AS (
    SELECT s.season_id AS id
    FROM (
      SELECT DISTINCT r.season_id
      FROM public.competition_club_season_ranking r
      JOIN public.competition_seasons cs ON cs.id = r.season_id
      WHERE cs.status = 'complete'
      ORDER BY r.season_id DESC
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
    s.club_short_name,
    s.club_name,
    s.capacity,
    s.rolling_points,
    s.seasons_count,
    s.composite_score,
    s.prestige_seed_rank,
    row_number() OVER (ORDER BY s.composite_score DESC, s.club_short_name)::smallint AS prestige_rank
  FROM scored s;
$$;

CREATE OR REPLACE FUNCTION public.competition_club_prestige_lock_season(p_season_id bigint)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_seasons s WHERE s.id = p_season_id
  ) THEN
    RAISE EXCEPTION 'Season not found';
  END IF;

  DELETE FROM public.competition_club_prestige_snapshot
  WHERE season_id = p_season_id;

  INSERT INTO public.competition_club_prestige_snapshot (
    season_id,
    club_short_name,
    prestige_rank,
    composite_score,
    rolling_points,
    seasons_count,
    prestige_seed_rank,
    locked_at
  )
  SELECT
    p_season_id,
    c.club_short_name,
    c.prestige_rank,
    c.composite_score,
    c.rolling_points,
    c.seasons_count,
    c.prestige_seed_rank,
    now()
  FROM public.competition_club_prestige_computed() c;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_club_prestige_lock_current_season()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_count int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true AND s.status = 'active'
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No active current season to lock prestige for';
  END IF;

  v_count := public.competition_club_prestige_lock_season(v_season_id);

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'clubs_locked', v_count
  );
END;
$function$;

-- Only recompute ranking rows for finished seasons (not the live table mid-season).
CREATE OR REPLACE FUNCTION public.competition_club_ranking_recompute_all()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  r record;
  v_total int := 0;
  v_n int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR r IN
    SELECT id FROM public.competition_seasons
    WHERE status = 'complete'
    ORDER BY id
  LOOP
    v_n := public.competition_club_ranking_recompute_season(r.id);
    v_total := v_total + coalesce(v_n, 0);
  END LOOP;

  RETURN v_total;
END;
$function$;

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
    JOIN public.competition_seasons cs ON cs.id = r.season_id AND cs.status = 'complete'
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

-- ---------------------------------------------------------------------------
-- Public prestige view — snapshot while season active, else live computed
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.competition_club_attendance_admin_public;
DROP VIEW IF EXISTS public.competition_club_stadium_overview_public;
DROP VIEW IF EXISTS public.competition_club_prestige_public;

CREATE VIEW public.competition_club_prestige_public
WITH (security_invoker = false)
AS
WITH active_season AS (
  SELECT s.id AS season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true AND s.status = 'active'
  LIMIT 1
),
computed AS (
  SELECT * FROM public.competition_club_prestige_computed()
),
merged AS (
  SELECT
    c.club_short_name,
    c.club_name,
    c.capacity,
    coalesce(snap.rolling_points, c.rolling_points) AS rolling_points,
    coalesce(snap.seasons_count, c.seasons_count) AS seasons_count,
    coalesce(snap.composite_score, c.composite_score) AS composite_score,
    coalesce(snap.prestige_seed_rank, c.prestige_seed_rank) AS prestige_seed_rank,
    coalesce(snap.prestige_rank, c.prestige_rank) AS prestige_rank,
    snap.season_id IS NOT NULL AS prestige_rank_locked
  FROM computed c
  LEFT JOIN active_season a ON true
  LEFT JOIN public.competition_club_prestige_snapshot snap
    ON snap.season_id = a.season_id
   AND snap.club_short_name = c.club_short_name
)
SELECT
  m.prestige_rank,
  m.club_short_name,
  m.club_name,
  m.capacity,
  m.rolling_points,
  m.seasons_count,
  m.composite_score,
  m.prestige_seed_rank,
  m.prestige_rank_locked
FROM merged m
ORDER BY m.prestige_rank;

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
  o.prestige_rank_locked,
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

-- Lock prestige when a season goes live (uses all complete seasons before this one).
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

  PERFORM public.competition_club_prestige_lock_season(p_season_id);
END;
$function$;

GRANT SELECT ON public.competition_club_prestige_public TO authenticated;
GRANT SELECT ON public.competition_club_stadium_overview_public TO authenticated;
GRANT SELECT ON public.competition_club_attendance_admin_public TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_prestige_computed() TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_prestige_lock_season(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_prestige_lock_current_season() TO authenticated;

NOTIFY pgrst, 'reload schema';
