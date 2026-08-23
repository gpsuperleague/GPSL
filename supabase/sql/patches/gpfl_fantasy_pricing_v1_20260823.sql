-- =============================================================================
-- GPFL fantasy pricing v1 — separate from GPSL market values
--
-- Prices are play-money only. NEVER reads/writes club MV, wages, or ledgers.
--
-- Model (FPL-style band):
--   Budget default ₿100m · ladder ₿4.5m–₿14.0m in ₿0.5m steps
--   Score = 35% rating + 35% current GPSL season form (G/A/apps/POTM)
--         + 20% past GPFL fixture points + 10% club/owner strength
--
-- Safe re-run. After apply: Open/refresh GPFL season (refreshes prices) + rebase.
-- If mid-season squads were bought on old MV prices, prefer Reset GPFL then re-join.
-- =============================================================================

ALTER TABLE public.gpfl_settings
  ADD COLUMN IF NOT EXISTS price_ceiling numeric NOT NULL DEFAULT 14000000,
  ADD COLUMN IF NOT EXISTS price_model text NOT NULL DEFAULT 'fantasy_v1';

COMMENT ON COLUMN public.gpfl_settings.price_ceiling IS
  'GPFL fantasy price cap (play-money). Independent of GPSL market value.';
COMMENT ON COLUMN public.gpfl_settings.price_model IS
  'fantasy_v1 = rating+form+GPFL history+owner strength. Never GPSL MV.';
COMMENT ON COLUMN public.gpfl_settings.budget IS
  'GPFL play-money bank per entry. Not club finances / owner wallet.';
COMMENT ON COLUMN public.gpfl_settings.price_floor IS
  'GPFL fantasy price floor (play-money). Not GPSL MV.';

ALTER TABLE public.gpfl_player_prices
  ADD COLUMN IF NOT EXISTS price_meta jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.gpfl_player_prices.market_value_raw IS
  'Unused by fantasy_v1 pricing (kept for compatibility). Do not treat as GPSL MV.';
COMMENT ON COLUMN public.gpfl_player_prices.price IS
  'GPFL fantasy play-money price. Independent of GPSL market value.';
COMMENT ON COLUMN public.gpfl_player_prices.price_meta IS
  'Breakdown of fantasy price components (rating/form/history/owner).';

-- Switch live settings onto the fantasy scale (idempotent target values)
UPDATE public.gpfl_settings
SET
  budget = 100000000,
  price_round_to = 500000,
  price_floor = 4500000,
  price_ceiling = 14000000,
  price_model = 'fantasy_v1',
  updated_at = now()
WHERE id = 1;

-- ---------------------------------------------------------------------------
-- Snap to fantasy ladder
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_snap_fantasy_price(
  p_raw numeric,
  p_floor numeric DEFAULT 4500000,
  p_ceiling numeric DEFAULT 14000000,
  p_round_to numeric DEFAULT 500000
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT least(
    greatest(coalesce(p_floor, 4500000), coalesce(p_ceiling, 14000000)),
    greatest(
      coalesce(p_floor, 4500000),
      round(coalesce(p_raw, p_floor) / nullif(greatest(coalesce(p_round_to, 500000), 1), 0))
        * greatest(coalesce(p_round_to, 500000), 1)
    )
  );
$$;

-- Club/owner strength 0–100 (higher = stronger → more expensive)
CREATE OR REPLACE FUNCTION public.gpfl_club_strength_score_0_100(p_club_short_name text)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner_rank int;
  v_seasons int;
  v_club_rank int;
  v_n int := 40;
  v_owner_str numeric;
  v_club_str numeric;
  v_str numeric;
BEGIN
  IF p_club_short_name IS NULL OR btrim(p_club_short_name) = '' THEN
    RETURN 50;
  END IF;

  SELECT r.rank_position::int, coalesce(r.seasons_count, 0)
  INTO v_owner_rank, v_seasons
  FROM public.competition_owner_ranking_rolling4_public r
  WHERE r.club_short_name = p_club_short_name
  ORDER BY r.rank_position
  LIMIT 1;

  SELECT p.prestige_rank::int INTO v_club_rank
  FROM public.competition_club_prestige_public p
  WHERE p.club_short_name = p_club_short_name
  LIMIT 1;

  SELECT greatest(coalesce(max(prestige_rank), 40), 10)::int INTO v_n
  FROM public.competition_club_prestige_public;

  v_club_rank := coalesce(v_club_rank, greatest(v_n / 2, 10));
  v_club_str := (v_n + 1 - least(v_club_rank, v_n))::numeric;

  IF v_owner_rank IS NOT NULL AND v_seasons > 0 THEN
    v_owner_str := (v_n + 1 - least(v_owner_rank, v_n))::numeric;
    v_str := (0.75 * v_owner_str) + (0.25 * v_club_str);
  ELSE
    v_str := v_club_str;
  END IF;

  -- v_str in ~1..v_n → map to 0..100
  RETURN round(least(100, greatest(0, (v_str / greatest(v_n, 1)::numeric) * 100)), 2);
END;
$function$;

-- Rating → 0–100 (65≈0, 90≈100)
CREATE OR REPLACE FUNCTION public.gpfl_rating_score_0_100(p_rating numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT round(
    least(100, greatest(0, (coalesce(p_rating, 70) - 65) / 25.0 * 100)),
    2
  );
$$;

-- ---------------------------------------------------------------------------
-- Compute one player's fantasy price (no GPSL MV)
-- ---------------------------------------------------------------------------
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
BEGIN
  IF v_pid = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_player');
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;

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

  -- Current GPSL season form (league + configured types when season known)
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

  -- Soft normalize vs best form in same position group this season
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
    v_form_s := 50; -- preseason / no stats yet
  ELSE
    v_form_s := round(least(100, greatest(0, (v_form_raw / v_form_max) * 100)), 2);
  END IF;

  -- Past GPFL fantasy points (all scored fixtures on record)
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
    (0.35 * v_rating_s) + (0.35 * v_form_s) + (0.20 * v_hist_s) + (0.10 * v_owner_s),
    2
  );

  v_raw_price :=
    coalesce(v_cfg.price_floor, 4500000)
    + (
        (coalesce(v_cfg.price_ceiling, 14000000) - coalesce(v_cfg.price_floor, 4500000))
        * (v_composite / 100.0)
      );

  v_price := public.gpfl_snap_fantasy_price(
    v_raw_price,
    v_cfg.price_floor,
    v_cfg.price_ceiling,
    v_cfg.price_round_to
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
    'uses_gpsl_market_value', false
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Open / refresh season — fantasy prices only (owned clubs pool)
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
      p."Name" AS player_name,
      p."Contracted_Team" AS club_short_name,
      ccs.division,
      p."Position"::text AS position,
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
  final AS (
    SELECT
      p.*,
      round(
        (0.35 * p.rating_score)
        + (0.35 * p.form_score)
        + (0.20 * p.hist_score)
        + (0.10 * p.owner_score),
        2
      ) AS composite,
      public.gpfl_snap_fantasy_price(
        coalesce(v_cfg.price_floor, 4500000)
          + (
              (coalesce(v_cfg.price_ceiling, 14000000) - coalesce(v_cfg.price_floor, 4500000))
              * (
                  (
                    (0.35 * p.rating_score)
                    + (0.35 * p.form_score)
                    + (0.20 * p.hist_score)
                    + (0.10 * p.owner_score)
                  ) / 100.0
                )
            ),
        v_cfg.price_floor,
        v_cfg.price_ceiling,
        v_cfg.price_round_to
      ) AS fantasy_price
    FROM priced p
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
      'composite', f.composite,
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
      'owner_score', f.owner_score
    )
  FROM final f
  ON CONFLICT (gpfl_season_id, player_id) DO UPDATE
    SET player_name = EXCLUDED.player_name,
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
        became_fa_at = NULL;

  GET DIAGNOSTICS v_touched = ROW_COUNT;

  UPDATE public.gpfl_player_prices pp
  SET eligible = false,
      became_fa_at = coalesce(pp.became_fa_at, now())
  WHERE pp.gpfl_season_id = v_gs_id
    AND pp.eligible = true
    AND NOT EXISTS (
      SELECT 1
      FROM public."Players" p
      JOIN public.competition_club_seasons ccs
        ON ccs.club_short_name = p."Contracted_Team"
       AND ccs.season_id = v_comp_id
      JOIN public."Clubs" c
        ON c."ShortName" = p."Contracted_Team"
       AND c.owner_id IS NOT NULL
      WHERE p."Konami_ID"::text = pp.player_id
        AND p."Contracted_Team" IS NOT NULL
        AND ccs.division = ANY (v_cfg.divisions)
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
    'budget', v_cfg.budget,
    'price_floor', v_cfg.price_floor,
    'price_ceiling', v_cfg.price_ceiling,
    'price_round_to', v_cfg.price_round_to,
    'price_rows_touched', v_touched,
    'marked_ineligible', v_ineligible,
    'refreshed_prices', coalesce(p_refresh_prices, true),
    'uses_gpsl_market_value', false
  );
END;
$function$;

-- Settings setter: fantasy ceiling + never imply GPSL MV
CREATE OR REPLACE FUNCTION public.admin_gpfl_settings_set(p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_div text[];
  v_ctypes text[];
  v_old_budget numeric;
  v_new_budget numeric;
  v_mode text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RAISE EXCEPTION 'p_settings must be a JSON object';
  END IF;

  SELECT budget INTO v_old_budget FROM public.gpfl_settings WHERE id = 1;

  IF p_settings ? 'divisions' AND jsonb_typeof(p_settings->'divisions') = 'array' THEN
    SELECT array_agg(x) INTO v_div
    FROM jsonb_array_elements_text(p_settings->'divisions') t(x);
  END IF;
  IF p_settings ? 'competition_types' AND jsonb_typeof(p_settings->'competition_types') = 'array' THEN
    SELECT array_agg(x) INTO v_ctypes
    FROM jsonb_array_elements_text(p_settings->'competition_types') t(x);
  END IF;

  v_mode := lower(btrim(coalesce(p_settings->>'deadline_mode', '')));
  IF v_mode NOT IN ('month_unlock', 'none') THEN
    v_mode := NULL;
  END IF;

  UPDATE public.gpfl_settings SET
    enabled = coalesce((p_settings->>'enabled')::boolean, enabled),
    opt_in_only = coalesce((p_settings->>'opt_in_only')::boolean, opt_in_only),
    budget = greatest(1000000, coalesce((p_settings->>'budget')::numeric, budget)),
    squad_size = greatest(11, least(20, coalesce((p_settings->>'squad_size')::int, squad_size))),
    starters = greatest(11, least(11, coalesce((p_settings->>'starters')::int, starters))),
    max_per_club = greatest(1, least(5, coalesce((p_settings->>'max_per_club')::int, max_per_club))),
    slot_gk = greatest(1, least(3, coalesce((p_settings->>'slot_gk')::int, slot_gk))),
    slot_def = greatest(3, least(6, coalesce((p_settings->>'slot_def')::int, slot_def))),
    slot_mid = greatest(3, least(6, coalesce((p_settings->>'slot_mid')::int, slot_mid))),
    slot_fwd = greatest(1, least(4, coalesce((p_settings->>'slot_fwd')::int, slot_fwd))),
    price_round_to = greatest(100000, coalesce((p_settings->>'price_round_to')::numeric, price_round_to)),
    price_floor = greatest(0, coalesce((p_settings->>'price_floor')::numeric, price_floor)),
    price_ceiling = greatest(
      coalesce(price_floor, 4500000),
      coalesce((p_settings->>'price_ceiling')::numeric, price_ceiling)
    ),
    price_model = coalesce(nullif(btrim(p_settings->>'price_model'), ''), price_model),
    free_transfers_per_month = greatest(0, least(15, coalesce((p_settings->>'free_transfers_per_month')::int, free_transfers_per_month))),
    divisions = coalesce(v_div, divisions),
    competition_types = coalesce(v_ctypes, competition_types),
    require_stats_to_score = coalesce((p_settings->>'require_stats_to_score')::boolean, require_stats_to_score),
    pts_appear = coalesce((p_settings->>'pts_appear')::numeric, pts_appear),
    pts_goal_gk = coalesce((p_settings->>'pts_goal_gk')::numeric, pts_goal_gk),
    pts_goal_def = coalesce((p_settings->>'pts_goal_def')::numeric, pts_goal_def),
    pts_goal_mid = coalesce((p_settings->>'pts_goal_mid')::numeric, pts_goal_mid),
    pts_goal_fwd = coalesce((p_settings->>'pts_goal_fwd')::numeric, pts_goal_fwd),
    pts_assist = coalesce((p_settings->>'pts_assist')::numeric, pts_assist),
    pts_cs_gk = coalesce((p_settings->>'pts_cs_gk')::numeric, pts_cs_gk),
    pts_cs_def = coalesce((p_settings->>'pts_cs_def')::numeric, pts_cs_def),
    pts_cs_mid = coalesce((p_settings->>'pts_cs_mid')::numeric, pts_cs_mid),
    pts_cs_fwd = coalesce((p_settings->>'pts_cs_fwd')::numeric, pts_cs_fwd),
    pts_yellow = coalesce((p_settings->>'pts_yellow')::numeric, pts_yellow),
    pts_red = coalesce((p_settings->>'pts_red')::numeric, pts_red),
    pts_potm = coalesce((p_settings->>'pts_potm')::numeric, pts_potm),
    captain_multiplier = greatest(1, coalesce((p_settings->>'captain_multiplier')::numeric, captain_multiplier)),
    transfer_hit_points = CASE
      WHEN p_settings ? 'transfer_hit_points'
        THEN -abs(coalesce((p_settings->>'transfer_hit_points')::numeric, transfer_hit_points))
      ELSE transfer_hit_points
    END,
    deadline_mode = coalesce(v_mode, deadline_mode),
    chips_enabled = coalesce((p_settings->>'chips_enabled')::boolean, chips_enabled),
    chip_wildcard_enabled = coalesce((p_settings->>'chip_wildcard_enabled')::boolean, chip_wildcard_enabled),
    chip_triple_captain_enabled = coalesce((p_settings->>'chip_triple_captain_enabled')::boolean, chip_triple_captain_enabled),
    chip_bench_boost_enabled = coalesce((p_settings->>'chip_bench_boost_enabled')::boolean, chip_bench_boost_enabled),
    cash_prizes_enabled = coalesce((p_settings->>'cash_prizes_enabled')::boolean, cash_prizes_enabled),
    prize_season_1 = greatest(0, coalesce((p_settings->>'prize_season_1')::numeric, prize_season_1)),
    prize_season_2 = greatest(0, coalesce((p_settings->>'prize_season_2')::numeric, prize_season_2)),
    prize_season_3 = greatest(0, coalesce((p_settings->>'prize_season_3')::numeric, prize_season_3)),
    prize_month_1 = greatest(0, coalesce((p_settings->>'prize_month_1')::numeric, prize_month_1)),
    prize_month_2 = greatest(0, coalesce((p_settings->>'prize_month_2')::numeric, prize_month_2)),
    prize_month_3 = greatest(0, coalesce((p_settings->>'prize_month_3')::numeric, prize_month_3)),
    updated_at = now(),
    updated_by = auth.uid()
  WHERE id = 1;

  UPDATE public.gpfl_settings
  SET squad_size = slot_gk + slot_def + slot_mid + slot_fwd,
      price_ceiling = greatest(price_floor, price_ceiling)
  WHERE id = 1;

  SELECT budget INTO v_new_budget FROM public.gpfl_settings WHERE id = 1;

  IF v_new_budget IS DISTINCT FROM v_old_budget
     AND to_regprocedure('public.gpfl_rebase_entry_budgets(bigint)') IS NOT NULL THEN
    PERFORM public.gpfl_rebase_entry_budgets(NULL);
  END IF;

  RETURN public.gpfl_settings_get();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_snap_fantasy_price(numeric, numeric, numeric, numeric) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_club_strength_score_0_100(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_rating_score_0_100(numeric) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_compute_fantasy_price(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpfl_open_season(bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpfl_settings_set(jsonb) TO authenticated;

-- Reprice current season now when run from SQL editor (postgres / service_role)
DO $$
DECLARE
  v_out jsonb;
BEGIN
  BEGIN
    v_out := public.admin_gpfl_open_season(NULL, true);
    RAISE NOTICE 'GPFL fantasy_v1 reprice: %', v_out;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'GPFL fantasy_v1 installed. Open/refresh on fantasy.html as admin to reprice. (%)', SQLERRM;
  END;
END $$;

NOTIFY pgrst, 'reload schema';
