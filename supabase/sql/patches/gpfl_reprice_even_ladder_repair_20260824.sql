-- =============================================================================
-- GPFL HARD repair: even ₿4.0m–₿15.0m ladder (per category)
--
-- If Forwards still show ~₿7–10m, the previous open-season reprice did not land.
-- This patch:
--   1) Forces settings floor/ceiling
--   2) Rewrites EVERY eligible price with even ladder buckets (by composite rank)
--   3) Replaces admin_gpfl_open_season to always use that reprice
--
-- After apply, check NOTICE lines: fwd/def/mid/gk should show min≈4m max≈15m.
-- Then hard-refresh fantasy.html (Open/refresh again if needed).
-- =============================================================================

UPDATE public.gpfl_settings
SET
  budget = 100000000,
  price_floor = 4000000,
  price_ceiling = 15000000,
  price_round_to = 500000,
  price_model = 'fantasy_v1',
  updated_at = now()
WHERE id = 1;

CREATE OR REPLACE FUNCTION public.gpfl_snap_fantasy_price(
  p_raw numeric,
  p_floor numeric DEFAULT 4000000,
  p_ceiling numeric DEFAULT 15000000,
  p_round_to numeric DEFAULT 500000
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT least(
    coalesce(p_ceiling, 15000000),
    greatest(
      coalesce(p_floor, 4000000),
      round(coalesce(p_raw, p_floor) / nullif(greatest(coalesce(p_round_to, 500000), 1), 0))
        * greatest(coalesce(p_round_to, 500000), 1)
    )
  );
$$;

CREATE OR REPLACE FUNCTION public.gpfl_even_ladder_bucket(
  p_rank int,
  p_group_n int,
  p_n_steps int
)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  -- Spread ranks 1..n across buckets 0..n_steps as evenly as possible
  SELECT CASE
    WHEN coalesce(p_group_n, 0) <= 1 OR coalesce(p_n_steps, 0) <= 0 THEN 0
    WHEN p_rank >= p_group_n THEN p_n_steps
    ELSE least(
      p_n_steps,
      floor(((greatest(p_rank, 1) - 1)::numeric / (p_group_n - 1)::numeric) * p_n_steps)::int
    )
  END;
$$;

-- Standalone reprice of current GPFL season pool (no formation / season create noise)
CREATE OR REPLACE FUNCTION public.gpfl_reprice_even_ladder(
  p_gpfl_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := p_gpfl_season_id;
  v_comp_id bigint;
  v_cfg public.gpfl_settings%rowtype;
  v_floor numeric := 4000000;
  v_ceil numeric := 15000000;
  v_round numeric := 500000;
  v_n_steps int;
  v_updated int := 0;
  v_by_group jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  v_round := greatest(coalesce(v_cfg.price_round_to, 500000), 100000);
  v_n_steps := greatest(1, round((v_ceil - v_floor) / v_round)::int);

  UPDATE public.gpfl_settings
  SET price_floor = v_floor,
      price_ceiling = v_ceil,
      price_round_to = v_round,
      price_model = 'fantasy_v1',
      updated_at = now()
  WHERE id = 1;

  IF v_gs_id IS NULL THEN
    v_gs_id := public.gpfl_current_season_id();
  END IF;
  IF v_gs_id IS NULL THEN
    RAISE EXCEPTION 'No GPFL season — open a season first';
  END IF;

  SELECT competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons WHERE id = v_gs_id;

  -- Ensure position_group is current (DMF/LWF/RWF → mid, SS/CF → fwd, etc.)
  UPDATE public.gpfl_player_prices pp
  SET
    position = coalesce(
      CASE
        WHEN to_regprocedure('public.gpfl_normalize_card_pos(text)') IS NOT NULL
          THEN public.gpfl_normalize_card_pos(p."Position"::text)
        ELSE upper(btrim(p."Position"::text))
      END,
      pp.position
    ),
    position_group = public.gpfl_position_group(p."Position"::text)
  FROM public."Players" p
  WHERE pp.gpfl_season_id = v_gs_id
    AND p."Konami_ID"::text = pp.player_id;

  WITH base AS (
    SELECT
      pp.player_id,
      pp.position_group,
      public.gpfl_rating_score_0_100(
        nullif(btrim(p."Rating"::text), '')::numeric
      ) AS rating_score,
      public.gpfl_club_strength_score_0_100(pp.club_short_name) AS owner_score,
      coalesce(form.form_raw, 0) AS form_raw,
      coalesce(hist.hist_pts, 0) AS hist_pts,
      max(coalesce(form.form_raw, 0)) OVER (PARTITION BY pp.position_group) AS form_max,
      max(coalesce(hist.hist_pts, 0)) OVER (PARTITION BY pp.position_group) AS hist_max,
      nullif(btrim(p."Rating"::text), '')::numeric AS rating
    FROM public.gpfl_player_prices pp
    JOIN public."Players" p ON p."Konami_ID"::text = pp.player_id
    LEFT JOIN LATERAL (
      SELECT
        (
          coalesce(sum(CASE WHEN m.appeared THEN 1 ELSE 0 END), 0) * 1.0
          + coalesce(sum(m.goals), 0) * 5.0
          + coalesce(sum(m.assists), 0) * 3.0
          + coalesce(sum(CASE WHEN m.is_player_of_match THEN 1 ELSE 0 END), 0) * 2.0
        ) AS form_raw
      FROM public.competition_match_player_stats m
      JOIN public.competition_fixtures f ON f.id = m.fixture_id
      WHERE m.player_id = pp.player_id
        AND m.season_id = v_comp_id
        AND f.status = 'played'
        AND (
          v_cfg.competition_types IS NULL
          OR f.competition_type = ANY (v_cfg.competition_types)
        )
    ) form ON true
    LEFT JOIN LATERAL (
      SELECT coalesce(sum(pfp.points), 0)::numeric AS hist_pts
      FROM public.gpfl_player_fixture_points pfp
      WHERE pfp.player_id = pp.player_id
    ) hist ON true
    WHERE pp.gpfl_season_id = v_gs_id
      AND pp.eligible = true
  ),
  scored AS (
    SELECT
      b.*,
      CASE
        WHEN b.form_max <= 0 THEN 50::numeric
        ELSE round(least(100, greatest(0, (b.form_raw / b.form_max) * 100)), 2)
      END AS form_score,
      CASE
        WHEN b.hist_max <= 0 THEN 50::numeric
        ELSE round(least(100, greatest(0, (b.hist_pts / b.hist_max) * 100)), 2)
      END AS hist_score
    FROM base b
  ),
  ranked AS (
    SELECT
      s.*,
      round(
        (0.40 * s.rating_score)
        + (0.30 * s.form_score)
        + (0.20 * s.hist_score)
        + (0.10 * s.owner_score),
        2
      ) AS composite,
      row_number() OVER (
        PARTITION BY s.position_group
        ORDER BY
          (0.40 * s.rating_score)
          + (0.30 * s.form_score)
          + (0.20 * s.hist_score)
          + (0.10 * s.owner_score),
          s.rating NULLS FIRST,
          s.player_id
      ) AS grp_rank,
      count(*) OVER (PARTITION BY s.position_group) AS grp_n
    FROM scored s
  ),
  priced AS (
    SELECT
      r.player_id,
      r.position_group,
      r.composite,
      r.grp_rank,
      r.grp_n,
      public.gpfl_even_ladder_bucket(r.grp_rank::int, r.grp_n::int, v_n_steps) AS ladder_bucket,
      public.gpfl_snap_fantasy_price(
        v_floor
          + public.gpfl_even_ladder_bucket(r.grp_rank::int, r.grp_n::int, v_n_steps) * v_round,
        v_floor,
        v_ceil,
        v_round
      ) AS fantasy_price,
      r.rating,
      r.rating_score,
      r.form_raw,
      r.form_score,
      r.hist_pts,
      r.hist_score,
      r.owner_score
    FROM ranked r
  )
  UPDATE public.gpfl_player_prices pp
  SET
    price = priced.fantasy_price,
    market_value_raw = NULL,
    price_meta = jsonb_build_object(
      'price_model', 'fantasy_v1',
      'uses_gpsl_market_value', false,
      'pricing', 'even_ladder_within_group',
      'composite', priced.composite,
      'grp_rank', priced.grp_rank,
      'grp_n', priced.grp_n,
      'ladder_bucket', priced.ladder_bucket,
      'ladder_steps', v_n_steps,
      'rating', priced.rating,
      'rating_score', priced.rating_score,
      'form_raw', priced.form_raw,
      'form_score', priced.form_score,
      'gpfl_hist_points', priced.hist_pts,
      'gpfl_hist_score', priced.hist_score,
      'owner_score', priced.owner_score,
      'price_floor', v_floor,
      'price_ceiling', v_ceil
    )
  FROM priced
  WHERE pp.gpfl_season_id = v_gs_id
    AND pp.player_id = priced.player_id;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  SELECT coalesce(jsonb_object_agg(g.position_group, g.stats), '{}'::jsonb)
  INTO v_by_group
  FROM (
    SELECT
      position_group,
      jsonb_build_object(
        'n', count(*),
        'min', min(price),
        'max', max(price)
      ) AS stats
    FROM public.gpfl_player_prices
    WHERE gpfl_season_id = v_gs_id AND eligible = true
    GROUP BY position_group
  ) g;

  RETURN jsonb_build_object(
    'ok', true,
    'gpfl_season_id', v_gs_id,
    'pricing', 'even_ladder_within_group',
    'price_floor', v_floor,
    'price_ceiling', v_ceil,
    'price_round_to', v_round,
    'ladder_steps', v_n_steps,
    'rows_updated', v_updated,
    'by_group', v_by_group,
    'uses_gpsl_market_value', false
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_reprice_even_ladder(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_even_ladder_bucket(int, int, int) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_snap_fantasy_price(numeric, numeric, numeric, numeric) TO authenticated, anon;

-- Open/refresh always reprice with even ladder after rebuilding pool rows
CREATE OR REPLACE FUNCTION public.admin_gpfl_open_season(
  p_competition_season_id bigint DEFAULT NULL,
  p_refresh_prices boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.gpfl_settings%rowtype;
  v_comp_id bigint := p_competition_season_id;
  v_gs_id bigint;
  v_touched int := 0;
  v_ineligible int := 0;
  v_reprice jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF auth.uid() IS NULL
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role')
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  IF NOT coalesce(v_cfg.enabled, true) THEN
    RAISE EXCEPTION 'GPFL is disabled in settings';
  END IF;

  UPDATE public.gpfl_settings
  SET price_floor = 4000000,
      price_ceiling = 15000000,
      price_round_to = greatest(coalesce(price_round_to, 500000), 100000),
      price_model = 'fantasy_v1',
      updated_at = now()
  WHERE id = 1;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;

  IF v_comp_id IS NULL THEN
    SELECT id INTO v_comp_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_comp_id IS NULL THEN
    RAISE EXCEPTION 'No competition season';
  END IF;

  SELECT id INTO v_gs_id
  FROM public.gpfl_seasons
  WHERE competition_season_id = v_comp_id;

  IF v_gs_id IS NULL THEN
    INSERT INTO public.gpfl_seasons (competition_season_id, status, budget_snapshot, settings_snapshot)
    VALUES (v_comp_id, 'open', v_cfg.budget, to_jsonb(v_cfg))
    RETURNING id INTO v_gs_id;
  ELSE
    UPDATE public.gpfl_seasons
    SET budget_snapshot = v_cfg.budget,
        settings_snapshot = to_jsonb(v_cfg),
        status = CASE WHEN status = 'closed' THEN status ELSE 'open' END
    WHERE id = v_gs_id;
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  -- Upsert pool membership (price filled by reprice next)
  WITH pool AS (
    SELECT
      p."Konami_ID"::text AS player_id,
      coalesce(nullif(btrim(p."Name"), ''), p."Konami_ID"::text) AS player_name,
      nullif(btrim(p."Contracted_Team"), '') AS club_short_name,
      ccs.division,
      CASE
        WHEN to_regprocedure('public.gpfl_normalize_card_pos(text)') IS NOT NULL
          THEN public.gpfl_normalize_card_pos(p."Position"::text)
        ELSE upper(btrim(p."Position"::text))
      END AS position,
      public.gpfl_position_group(p."Position"::text) AS position_group
    FROM public."Players" p
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = p."Contracted_Team"
     AND ccs.season_id = v_comp_id
    JOIN public."Clubs" c
      ON c."ShortName" = p."Contracted_Team"
     AND c.owner_id IS NOT NULL
    WHERE p."Contracted_Team" IS NOT NULL
      AND btrim(p."Contracted_Team") <> ''
      AND ccs.division = ANY (v_cfg.divisions)
  )
  INSERT INTO public.gpfl_player_prices AS t (
    gpfl_season_id, player_id, player_name, club_short_name, division,
    position, position_group, market_value_raw, price, eligible, price_meta
  )
  SELECT
    v_gs_id,
    pool.player_id,
    pool.player_name,
    pool.club_short_name,
    pool.division,
    pool.position,
    pool.position_group,
    NULL,
    4000000,
    true,
    jsonb_build_object('price_model', 'fantasy_v1', 'pending_reprice', true)
  FROM pool
  ON CONFLICT (gpfl_season_id, player_id) DO UPDATE
  SET
    player_name = EXCLUDED.player_name,
    club_short_name = EXCLUDED.club_short_name,
    division = EXCLUDED.division,
    position = EXCLUDED.position,
    position_group = EXCLUDED.position_group,
    market_value_raw = NULL,
    eligible = true;

  GET DIAGNOSTICS v_touched = ROW_COUNT;

  UPDATE public.gpfl_player_prices pp
  SET eligible = false
  WHERE pp.gpfl_season_id = v_gs_id
    AND pp.eligible = true
    AND NOT EXISTS (
      SELECT 1
      FROM public."Players" p
      JOIN public."Clubs" c
        ON c."ShortName" = p."Contracted_Team"
       AND c.owner_id IS NOT NULL
      JOIN public.competition_club_seasons ccs
        ON ccs.club_short_name = p."Contracted_Team"
       AND ccs.season_id = v_comp_id
       AND ccs.division = ANY (v_cfg.divisions)
      WHERE p."Konami_ID"::text = pp.player_id
        AND p."Contracted_Team" IS NOT NULL
    );

  GET DIAGNOSTICS v_ineligible = ROW_COUNT;

  IF coalesce(p_refresh_prices, true) THEN
    v_reprice := public.gpfl_reprice_even_ladder(v_gs_id);
  END IF;

  IF to_regprocedure('public.gpfl_rebase_entry_budgets(bigint)') IS NOT NULL THEN
    PERFORM public.gpfl_rebase_entry_budgets(v_gs_id);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'gpfl_season_id', v_gs_id,
    'competition_season_id', v_comp_id,
    'price_model', 'fantasy_v1',
    'pricing', 'even_ladder_within_group',
    'budget', v_cfg.budget,
    'price_floor', 4000000,
    'price_ceiling', 15000000,
    'price_round_to', v_cfg.price_round_to,
    'price_rows_touched', v_touched,
    'marked_ineligible', v_ineligible,
    'refreshed_prices', coalesce(p_refresh_prices, true),
    'reprice', v_reprice,
    'uses_gpsl_market_value', false
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_gpfl_open_season(bigint, boolean) TO authenticated;

DO $run$
DECLARE
  v_out jsonb;
  v_fwd jsonb;
BEGIN
  v_out := public.gpfl_reprice_even_ladder(NULL);
  v_fwd := v_out -> 'by_group' -> 'fwd';
  RAISE NOTICE 'GPFL even-ladder repair: %', v_out;
  RAISE NOTICE 'Forwards min/max should be ~4000000 / ~15000000 → %', v_fwd;

  IF v_fwd IS NOT NULL
     AND (
       coalesce((v_fwd ->> 'min')::numeric, 0) > 4500000
       OR coalesce((v_fwd ->> 'max')::numeric, 0) < 14000000
     )
  THEN
    RAISE WARNING 'Forwards still not spanning 4–15m after repair: %', v_fwd;
  END IF;
END;
$run$;

NOTIFY pgrst, 'reload schema';
