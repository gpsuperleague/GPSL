-- =============================================================================
-- GPFL fantasy prices: full ladder ₿4.0m–₿15.0m (spread by within-group rank)
--
-- Why prices stuck ~₿7.5–10m: form/GPFL-history default to neutral 50 when
-- there is little data, so linear composite/100 never reached the floor/ceiling.
--
-- Fix:
--   • Settings floor ₿4m · ceiling ₿15m · round ₿0.5m
--   • Final list price = percentile rank of composite within position group
--     → cheapest ~₿4.0m, dearest ~₿15.0m in each bank (gk/def/mid/fwd)
--
-- Safe re-run. After apply: Open/refresh GPFL season (refresh prices).
-- =============================================================================

UPDATE public.gpfl_settings
SET
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
    greatest(coalesce(p_floor, 4000000), coalesce(p_ceiling, 15000000)),
    greatest(
      coalesce(p_floor, 4000000),
      round(coalesce(p_raw, p_floor) / nullif(greatest(coalesce(p_round_to, 500000), 1), 0))
        * greatest(coalesce(p_round_to, 500000), 1)
    )
  );
$$;

-- Rating → 0–100 (widen: 62≈0, 92≈100 so card quality spreads more)
CREATE OR REPLACE FUNCTION public.gpfl_rating_score_0_100(p_rating numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT round(
    least(100, greatest(0, (coalesce(p_rating, 72) - 62) / 30.0 * 100)),
    2
  );
$$;

-- Single-player helper: still linear on composite (diagnostics / ad-hoc)
CREATE OR REPLACE FUNCTION public.gpfl_compute_fantasy_price(
  p_player_id text,
  p_competition_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_comp_id bigint := p_competition_season_id;
  v_cfg public.gpfl_settings%rowtype;
  v_club text;
  v_pos text;
  v_pos_group text;
  v_rating numeric;
  v_rating_s numeric;
  v_apps int := 0;
  v_goals int := 0;
  v_assists int := 0;
  v_potm int := 0;
  v_form_raw numeric := 0;
  v_form_s numeric := 50;
  v_hist_pts numeric := 0;
  v_hist_s numeric := 50;
  v_owner_s numeric := 50;
  v_composite numeric;
  v_raw_price numeric;
  v_price numeric;
  v_form_max numeric;
  v_hist_max numeric;
  v_floor numeric;
  v_ceil numeric;
BEGIN
  IF v_pid = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_player');
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  v_floor := coalesce(v_cfg.price_floor, 4000000);
  v_ceil := coalesce(v_cfg.price_ceiling, 15000000);

  IF v_comp_id IS NULL THEN
    SELECT id INTO v_comp_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  SELECT
    nullif(btrim(p."Contracted_Team"), ''),
    p."Position"::text,
    public.gpfl_position_group(p."Position"::text),
    nullif(btrim(p."Rating"::text), '')::numeric
  INTO v_club, v_pos, v_pos_group, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'player_not_found');
  END IF;

  v_rating_s := public.gpfl_rating_score_0_100(v_rating);
  v_owner_s := public.gpfl_club_strength_score_0_100(v_club);

  IF v_comp_id IS NOT NULL THEN
    SELECT
      coalesce(sum(CASE WHEN m.appeared THEN 1 ELSE 0 END), 0),
      coalesce(sum(m.goals), 0),
      coalesce(sum(m.assists), 0),
      coalesce(sum(CASE WHEN m.is_player_of_match THEN 1 ELSE 0 END), 0)
    INTO v_apps, v_goals, v_assists, v_potm
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE m.player_id = v_pid
      AND m.season_id = v_comp_id
      AND f.status = 'played'
      AND (
        v_cfg.competition_types IS NULL
        OR f.competition_type = ANY (v_cfg.competition_types)
      );
  END IF;

  v_form_raw := (v_apps * 1.0) + (v_goals * 5.0) + (v_assists * 3.0) + (v_potm * 2.0);

  IF v_comp_id IS NOT NULL THEN
    SELECT max(x.form_raw) INTO v_form_max
    FROM (
      SELECT
        (coalesce(sum(CASE WHEN m.appeared THEN 1 ELSE 0 END), 0) * 1.0
          + coalesce(sum(m.goals), 0) * 5.0
          + coalesce(sum(m.assists), 0) * 3.0
          + coalesce(sum(CASE WHEN m.is_player_of_match THEN 1 ELSE 0 END), 0) * 2.0
        ) AS form_raw
      FROM public.competition_match_player_stats m
      JOIN public.competition_fixtures f ON f.id = m.fixture_id
      JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
      WHERE m.season_id = v_comp_id
        AND f.status = 'played'
        AND public.gpfl_position_group(p."Position"::text) = v_pos_group
        AND (
          v_cfg.competition_types IS NULL
          OR f.competition_type = ANY (v_cfg.competition_types)
        )
      GROUP BY m.player_id
    ) x;
  END IF;

  IF coalesce(v_form_max, 0) <= 0 THEN
    v_form_s := 50;
  ELSE
    v_form_s := round(least(100, greatest(0, (v_form_raw / v_form_max) * 100)), 2);
  END IF;

  SELECT coalesce(sum(pfp.points), 0) INTO v_hist_pts
  FROM public.gpfl_player_fixture_points pfp
  WHERE pfp.player_id = v_pid;

  SELECT max(x.pts) INTO v_hist_max
  FROM (
    SELECT sum(pfp.points) AS pts
    FROM public.gpfl_player_fixture_points pfp
    JOIN public."Players" p ON p."Konami_ID"::text = pfp.player_id
    WHERE public.gpfl_position_group(p."Position"::text) = v_pos_group
    GROUP BY pfp.player_id
  ) x;

  IF coalesce(v_hist_max, 0) <= 0 THEN
    v_hist_s := 50;
  ELSE
    v_hist_s := round(least(100, greatest(0, (v_hist_pts / v_hist_max) * 100)), 2);
  END IF;

  v_composite := round(
    (0.40 * v_rating_s) + (0.30 * v_form_s) + (0.20 * v_hist_s) + (0.10 * v_owner_s),
    2
  );

  -- Note: pool refresh uses within-group percent_rank for full 4–15 spread.
  v_raw_price := v_floor + ((v_ceil - v_floor) * (v_composite / 100.0));
  v_price := public.gpfl_snap_fantasy_price(
    v_raw_price, v_floor, v_ceil, v_cfg.price_round_to
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'price', v_price,
    'price_model', 'fantasy_v1',
    'composite', v_composite,
    'rating', v_rating,
    'rating_score', v_rating_s,
    'form_raw', v_form_raw,
    'form_score', v_form_s,
    'apps', v_apps,
    'goals', v_goals,
    'assists', v_assists,
    'potm', v_potm,
    'gpfl_hist_points', v_hist_pts,
    'gpfl_hist_score', v_hist_s,
    'owner_score', v_owner_s,
    'club_short_name', v_club,
    'position_group', v_pos_group,
    'price_floor', v_floor,
    'price_ceiling', v_ceil,
    'uses_gpsl_market_value', false,
    'note', 'Pool open/refresh maps by within-group rank onto floor–ceiling'
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Open / refresh — price by percent_rank within position group
-- ---------------------------------------------------------------------------
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

  v_floor := coalesce(v_cfg.price_floor, 4000000);
  v_ceil := coalesce(v_cfg.price_ceiling, 15000000);

  IF v_comp_id IS NULL THEN
    SELECT id INTO v_comp_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_comp_id IS NULL THEN
    RAISE EXCEPTION 'No active competition season';
  END IF;

  INSERT INTO public.gpfl_seasons (competition_season_id, status, budget_snapshot, settings_snapshot)
  VALUES (v_comp_id, 'open', v_cfg.budget, to_jsonb(v_cfg))
  ON CONFLICT (competition_season_id) DO UPDATE
  SET status = CASE
        WHEN public.gpfl_seasons.status = 'closed' THEN public.gpfl_seasons.status
        ELSE 'open'
      END,
      budget_snapshot = EXCLUDED.budget_snapshot,
      settings_snapshot = to_jsonb(v_cfg),
      updated_at = now()
  RETURNING id INTO v_gs_id;

  IF v_gs_id IS NULL THEN
    SELECT id INTO v_gs_id
    FROM public.gpfl_seasons
    WHERE competition_season_id = v_comp_id
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  WITH pool AS (
    SELECT
      p."Konami_ID"::text AS player_id,
      coalesce(nullif(btrim(p."Name"), ''), p."Konami_ID"::text) AS player_name,
      nullif(btrim(p."Contracted_Team"), '') AS club_short_name,
      ccs.division,
      public.gpfl_normalize_card_pos(p."Position"::text) AS position,
      public.gpfl_position_group(p."Position"::text) AS position_group,
      nullif(btrim(p."Rating"::text), '')::numeric AS rating
    FROM public."Players" p
    JOIN public."Clubs" c
      ON c."ShortName" = p."Contracted_Team"
     AND c.owner_id IS NOT NULL
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = p."Contracted_Team"
     AND ccs.season_id = v_comp_id
     AND ccs.division = ANY (v_cfg.divisions)
    WHERE p."Contracted_Team" IS NOT NULL
      AND btrim(p."Contracted_Team") <> ''
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
      -- 0 = cheapest in group, 1 = dearest → full floor–ceiling span
      percent_rank() OVER (
        PARTITION BY p.position_group
        ORDER BY
          (0.40 * p.rating_score)
          + (0.30 * p.form_score)
          + (0.20 * p.hist_score)
          + (0.10 * p.owner_score),
          p.rating NULLS LAST,
          p.player_id
      ) AS group_pct
    FROM priced p
  ),
  final AS (
    SELECT
      r.*,
      public.gpfl_snap_fantasy_price(
        v_floor + ((v_ceil - v_floor) * coalesce(r.group_pct, 0.5)),
        v_floor,
        v_ceil,
        v_cfg.price_round_to
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
      'pricing', 'within_group_percent_rank',
      'composite', f.composite,
      'group_pct', round(f.group_pct::numeric, 4),
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

  IF to_regprocedure('public.gpfl_rebase_entry_budgets(bigint)') IS NOT NULL THEN
    PERFORM public.gpfl_rebase_entry_budgets(v_gs_id);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'gpfl_season_id', v_gs_id,
    'competition_season_id', v_comp_id,
    'price_model', 'fantasy_v1',
    'pricing', 'within_group_percent_rank',
    'budget', v_cfg.budget,
    'price_floor', v_floor,
    'price_ceiling', v_ceil,
    'price_round_to', v_cfg.price_round_to,
    'price_rows_touched', v_touched,
    'marked_ineligible', v_ineligible,
    'refreshed_prices', coalesce(p_refresh_prices, true),
    'uses_gpsl_market_value', false
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_snap_fantasy_price(numeric, numeric, numeric, numeric) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_compute_fantasy_price(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpfl_open_season(bigint, boolean) TO authenticated;

DO $reprice$
DECLARE
  v_out jsonb;
BEGIN
  BEGIN
    v_out := public.admin_gpfl_open_season(NULL, true);
    RAISE NOTICE 'GPFL 4–15m reprice: %', v_out;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'GPFL 4–15m installed. Open/refresh on fantasy.html as admin to reprice. (%)', SQLERRM;
  END;
END;
$reprice$;
