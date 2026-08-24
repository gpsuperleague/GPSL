-- =============================================================================
-- GPFL even ladder pricing — guarantee cheap players in every category
--
-- Maps composite (same rules: rating/form/GPFL hist/owner) onto an EVEN
-- ₿4.0m–₿15.0m ladder within each position group.
--
-- Example: 57 FWDs → roughly equal counts on each ₿0.5m rung from 4.0 → 15.0
-- so a full 15-man squad is affordable on the ₿100m bank.
--
-- Safe re-run. After apply: Open/refresh GPFL season.
-- =============================================================================

UPDATE public.gpfl_settings
SET
  budget = greatest(coalesce(budget, 100000000), 100000000),
  price_floor = 4000000,
  price_ceiling = 15000000,
  price_round_to = 500000,
  price_model = 'fantasy_v1',
  updated_at = now()
WHERE id = 1;

-- Even bucket index 0..n_steps from rank 1..n within a group
CREATE OR REPLACE FUNCTION public.gpfl_even_ladder_bucket(
  p_rank int,
  p_group_n int,
  p_n_steps int
)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_group_n, 0) <= 1 OR coalesce(p_n_steps, 0) <= 0 THEN 0
    ELSE least(
      p_n_steps,
      greatest(
        0,
        floor(
          ((greatest(p_rank, 1) - 1)::numeric / p_group_n::numeric) * (p_n_steps + 1)
        )::int
      )
    )
  END;
$$;

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
  v_floor numeric;
  v_ceil numeric;
  v_round numeric;
  v_n_steps int;
  v_min_price numeric;
  v_max_price numeric;
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

  v_floor := 4000000;
  v_ceil := 15000000;
  v_round := greatest(coalesce(v_cfg.price_round_to, 500000), 100000);
  -- Force live knobs onto the affordable ladder
  UPDATE public.gpfl_settings
  SET price_floor = v_floor,
      price_ceiling = v_ceil,
      price_round_to = v_round,
      updated_at = now()
  WHERE id = 1;

  v_n_steps := greatest(1, round((v_ceil - v_floor) / v_round)::int);

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
      public.gpfl_position_group(p."Position"::text) AS position_group,
      nullif(btrim(p."Rating"::text), '')::numeric AS rating
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
  ),
  form AS (
    SELECT
      m.player_id,
      coalesce(sum(CASE WHEN m.appeared THEN 1 ELSE 0 END), 0)::numeric AS apps,
      coalesce(sum(m.goals), 0)::numeric AS goals,
      coalesce(sum(m.assists), 0)::numeric AS assists,
      coalesce(sum(CASE WHEN m.is_player_of_match THEN 1 ELSE 0 END), 0)::numeric AS potm,
      (
        coalesce(sum(CASE WHEN m.appeared THEN 1 ELSE 0 END), 0) * 1.0
        + coalesce(sum(m.goals), 0) * 5.0
        + coalesce(sum(m.assists), 0) * 3.0
        + coalesce(sum(CASE WHEN m.is_player_of_match THEN 1 ELSE 0 END), 0) * 2.0
      ) AS form_raw
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE m.season_id = v_comp_id
      AND f.status = 'played'
      AND (
        v_cfg.competition_types IS NULL
        OR f.competition_type = ANY (v_cfg.competition_types)
      )
    GROUP BY m.player_id
  ),
  hist AS (
    SELECT pfp.player_id, coalesce(sum(pfp.points), 0)::numeric AS hist_pts
    FROM public.gpfl_player_fixture_points pfp
    GROUP BY pfp.player_id
  ),
  scored AS (
    SELECT
      pool.*,
      public.gpfl_rating_score_0_100(pool.rating) AS rating_score,
      public.gpfl_club_strength_score_0_100(pool.club_short_name) AS owner_score,
      coalesce(form.apps, 0) AS apps,
      coalesce(form.goals, 0) AS goals,
      coalesce(form.assists, 0) AS assists,
      coalesce(form.potm, 0) AS potm,
      coalesce(form.form_raw, 0) AS form_raw,
      coalesce(hist.hist_pts, 0) AS hist_pts,
      max(coalesce(form.form_raw, 0)) OVER (PARTITION BY pool.position_group) AS form_max,
      max(coalesce(hist.hist_pts, 0)) OVER (PARTITION BY pool.position_group) AS hist_max
    FROM pool
    LEFT JOIN form ON form.player_id = pool.player_id
    LEFT JOIN hist ON hist.player_id = pool.player_id
  ),
  priced AS (
    SELECT
      s.*,
      CASE
        WHEN s.form_max <= 0 THEN 50::numeric
        ELSE round(least(100, greatest(0, (s.form_raw / s.form_max) * 100)), 2)
      END AS form_score,
      CASE
        WHEN s.hist_max <= 0 THEN 50::numeric
        ELSE round(least(100, greatest(0, (s.hist_pts / s.hist_max) * 100)), 2)
      END AS hist_score
    FROM scored s
  ),
  ranked AS (
    SELECT
      p.*,
      round(
        (0.40 * p.rating_score)
        + (0.30 * p.form_score)
        + (0.20 * p.hist_score)
        + (0.10 * p.owner_score),
        2
      ) AS composite,
      row_number() OVER (
        PARTITION BY p.position_group
        ORDER BY
          (0.40 * p.rating_score)
          + (0.30 * p.form_score)
          + (0.20 * p.hist_score)
          + (0.10 * p.owner_score),
          p.rating NULLS FIRST,
          p.player_id
      ) AS grp_rank,
      count(*) OVER (PARTITION BY p.position_group) AS grp_n
    FROM priced p
  ),
  final AS (
    SELECT
      r.*,
      public.gpfl_even_ladder_bucket(r.grp_rank::int, r.grp_n::int, v_n_steps) AS ladder_bucket,
      public.gpfl_snap_fantasy_price(
        v_floor
          + (
              public.gpfl_even_ladder_bucket(r.grp_rank::int, r.grp_n::int, v_n_steps)
              * v_round
            ),
        v_floor,
        v_ceil,
        v_round
      ) AS fantasy_price
    FROM ranked r
  )
  INSERT INTO public.gpfl_player_prices AS t (
    gpfl_season_id, player_id, player_name, club_short_name, division,
    position, position_group, market_value_raw, price, eligible, price_meta
  )
  SELECT
    v_gs_id,
    f.player_id,
    f.player_name,
    f.club_short_name,
    f.division,
    f.position,
    f.position_group,
    NULL,
    f.fantasy_price,
    true,
    jsonb_build_object(
      'price_model', 'fantasy_v1',
      'uses_gpsl_market_value', false,
      'pricing', 'even_ladder_within_group',
      'composite', f.composite,
      'grp_rank', f.grp_rank,
      'grp_n', f.grp_n,
      'ladder_bucket', f.ladder_bucket,
      'ladder_steps', v_n_steps,
      'rating', f.rating,
      'rating_score', f.rating_score,
      'form_raw', f.form_raw,
      'form_score', f.form_score,
      'apps', f.apps,
      'goals', f.goals,
      'assists', f.assists,
      'potm', f.potm,
      'gpfl_hist_points', f.hist_pts,
      'gpfl_hist_score', f.hist_score,
      'owner_score', f.owner_score,
      'price_floor', v_floor,
      'price_ceiling', v_ceil
    )
  FROM final f
  ON CONFLICT (gpfl_season_id, player_id) DO UPDATE
  SET
    player_name = EXCLUDED.player_name,
    club_short_name = EXCLUDED.club_short_name,
    division = EXCLUDED.division,
    position = EXCLUDED.position,
    position_group = EXCLUDED.position_group,
    market_value_raw = NULL,
    price = CASE
      WHEN coalesce(p_refresh_prices, true) THEN EXCLUDED.price
      ELSE t.price
    END,
    price_meta = CASE
      WHEN coalesce(p_refresh_prices, true) THEN EXCLUDED.price_meta
      ELSE t.price_meta
    END,
    eligible = true,
    updated_at = now();

  GET DIAGNOSTICS v_touched = ROW_COUNT;

  UPDATE public.gpfl_player_prices pp
  SET eligible = false, updated_at = now()
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

  SELECT min(price), max(price)
  INTO v_min_price, v_max_price
  FROM public.gpfl_player_prices
  WHERE gpfl_season_id = v_gs_id AND eligible = true;

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
    'price_floor', v_floor,
    'price_ceiling', v_ceil,
    'price_round_to', v_round,
    'ladder_steps', v_n_steps,
    'eligible_price_min', v_min_price,
    'eligible_price_max', v_max_price,
    'price_rows_touched', v_touched,
    'marked_ineligible', v_ineligible,
    'refreshed_prices', coalesce(p_refresh_prices, true),
    'uses_gpsl_market_value', false
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_even_ladder_bucket(int, int, int) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_gpfl_open_season(bigint, boolean) TO authenticated;

DO $reprice$
DECLARE
  v_out jsonb;
BEGIN
  BEGIN
    v_out := public.admin_gpfl_open_season(NULL, true);
    RAISE NOTICE 'GPFL even ladder reprice: %', v_out;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'GPFL even ladder installed. Open/refresh on fantasy.html as admin. (%)', SQLERRM;
  END;
END;
$reprice$;
