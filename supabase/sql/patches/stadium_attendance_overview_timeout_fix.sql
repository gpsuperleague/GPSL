-- =============================================================================
-- Club attendance overview timeout fix
--
-- Symptom: competition_club_stadium_overview_list → statement timeout / 500
-- Cause: list selected a view that called competition_compute_stadium_fill()
--   + rolling stats per club (~60× heavy work). Page also synced all clubs
--   before listing.
--
-- Fix: fast set-based overview_list (stored fills + prestige; no per-row fill
--   recompute). Live expected/actual metrics stay optional via a second RPC.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_club_stadium_overview_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rows jsonb;
  v_max_cap integer;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Local only; still keep the query under the API gateway (~60s)
  PERFORM set_config('statement_timeout', '55s', true);

  SELECT coalesce(gs.stadium_new_build_max_capacity, 55000)
  INTO v_max_cap
  FROM public.global_settings gs
  WHERE gs.id = 1;

  WITH hist AS (
    SELECT
      r.club_short_name,
      jsonb_agg(
        jsonb_build_object(
          'season_label', r.season_label,
          'season_total', r.season_total,
          'final_position', r.final_position,
          'division', r.division
        )
        ORDER BY r.season_id DESC
      ) AS last_seasons_json
    FROM (
      SELECT
        r.*,
        row_number() OVER (
          PARTITION BY r.club_short_name
          ORDER BY r.season_id DESC
        ) AS rn
      FROM public.competition_club_season_ranking r
      JOIN public.competition_seasons cs
        ON cs.id = r.season_id
       AND cs.status = 'complete'
    ) r
    CROSS JOIN (
      SELECT greatest(coalesce(stadium_rolling_seasons, 5), 1) AS n
      FROM public.global_settings
      WHERE id = 1
    ) cfg
    WHERE r.rn <= cfg.n
    GROUP BY r.club_short_name
  ),
  base AS (
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
      round(
        least(100::numeric, coalesce(c.stadium_display_fill_pct, 75::numeric)),
        1
      ) AS gate_fill_pct,
      round(
        greatest(0::numeric, coalesce(c.stadium_display_fill_pct, 75::numeric) - 100::numeric),
        1
      ) AS cushion_pct,
      NULL::numeric AS expected_points,
      NULL::numeric AS actual_points,
      NULL::numeric AS performance_gap,
      NULL::text AS performance_band,
      public.competition_stadium_prestige_base_fill(p.club_short_name) AS prestige_base_fill_pct,
      NULL::smallint AS expected_position,
      NULL::smallint AS actual_position,
      coalesce(h.last_seasons_json, '[]'::jsonb) AS last_seasons_json,
      public.competition_stadium_projection_note(
        p.club_short_name,
        c.stadium_display_fill_pct,
        p.prestige_rank,
        public.competition_club_tier(p.club_short_name),
        NULL
      ) AS projection_note,
      (p.capacity <= coalesce(v_max_cap, 55000)) AS expansion_eligible
    FROM public.competition_club_prestige_public p
    JOIN public."Clubs" c ON c."ShortName" = p.club_short_name
    LEFT JOIN public.competition_club_tier_override o
      ON o.club_short_name = p.club_short_name
    LEFT JOIN hist h ON h.club_short_name = p.club_short_name
    WHERE p.club_short_name <> 'FOREIGN'
  )
  SELECT coalesce(jsonb_agg(to_jsonb(b) ORDER BY b.prestige_rank), '[]'::jsonb)
  INTO v_rows
  FROM base b;

  RETURN v_rows;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_club_stadium_overview_list() TO authenticated;

-- Optional: live season metrics (slower). Call from Sync / refresh metrics only.
CREATE OR REPLACE FUNCTION public.competition_club_stadium_overview_live_metrics()
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

  PERFORM set_config('statement_timeout', '55s', true);

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'club_short_name', p.club_short_name,
        'expected_points', CASE
          WHEN fill.d ? 'error' THEN NULL
          ELSE (fill.d ->> 'expected_points')::numeric
        END,
        'actual_points', CASE
          WHEN fill.d ? 'error' THEN NULL
          ELSE (fill.d ->> 'actual_points')::numeric
        END,
        'performance_gap', CASE
          WHEN fill.d ? 'error' THEN NULL
          ELSE (fill.d ->> 'performance_gap')::numeric
        END,
        'performance_band', CASE
          WHEN fill.d ? 'error' THEN NULL
          ELSE fill.d ->> 'performance_band'
        END,
        'prestige_base_fill_pct', CASE
          WHEN fill.d ? 'error' THEN NULL
          ELSE (fill.d ->> 'prestige_base_fill_pct')::numeric
        END,
        'expected_position', CASE
          WHEN fill.d ? 'error' THEN NULL
          WHEN btrim(coalesce(fill.d ->> 'expected_position', '')) ~ '^-?\d+$'
            THEN (fill.d ->> 'expected_position')::smallint
          ELSE NULL
        END,
        'actual_position', CASE
          WHEN fill.d ? 'error' THEN NULL
          WHEN btrim(coalesce(fill.d ->> 'actual_position', '')) ~ '^-?\d+$'
            THEN (fill.d ->> 'actual_position')::smallint
          ELSE NULL
        END,
        'stadium_fill_target_pct', CASE
          WHEN fill.d ? 'error' THEN NULL
          ELSE (fill.d ->> 'season_target_fill_pct')::numeric
        END
      )
      ORDER BY p.prestige_rank
    ),
    '[]'::jsonb
  )
  INTO v_rows
  FROM public.competition_club_prestige_public p
  CROSS JOIN LATERAL (
    SELECT public.competition_compute_stadium_fill(p.club_short_name) AS d
  ) fill
  WHERE p.club_short_name <> 'FOREIGN';

  RETURN v_rows;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_club_stadium_overview_live_metrics()
  TO authenticated;

-- Sync all: skip FOREIGN, raise local timeout (still keep under gateway when possible)
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
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '55s', true);

  FOR v_club IN
    SELECT c."ShortName" AS club_short_name
    FROM public."Clubs" c
    WHERE c."ShortName" <> 'FOREIGN'
    ORDER BY c."ShortName"
  LOOP
    PERFORM public.competition_stadium_sync_fill_state(v_club.club_short_name, p_season_id);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_stadium_sync_all_clubs(bigint)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
