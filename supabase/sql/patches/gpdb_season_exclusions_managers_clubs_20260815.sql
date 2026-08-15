-- =============================================================================
-- Season exclusions: also apply to managers & clubs of excluded nations
--
-- When a nation is season-excluded:
--   • Managers of that nationality hidden from MGDB / FA board; cannot be bid on
--   • Clubs of that nation hidden from Club Database browse
--   • Admin exclusions page lists affected managers & clubs
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpdb_text_matches_excluded_nation(
  p_nation_text text,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_key text := public.normalize_nation_key(p_nation_text);
  v_raw text := upper(btrim(coalesce(p_nation_text, '')));
  v_norm text := NULL;
BEGIN
  IF v_raw = '' THEN
    RETURN false;
  END IF;

  IF to_regprocedure('public.international_normalize_nation_label(text)') IS NOT NULL THEN
    v_norm := public.international_normalize_nation_label(p_nation_text);
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.gpdb_season_excluded_nations en
    JOIN public.competition_seasons s ON s.id = en.season_id
    JOIN public.international_nations n ON n.code = en.nation_code
    WHERE CASE
      WHEN p_season_id IS NOT NULL THEN en.season_id = p_season_id
      ELSE s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
    END
      AND (
        v_raw = en.nation_code
        OR v_key = public.normalize_nation_key(n.name)
        OR v_key = public.normalize_nation_key(n.code)
        OR (
          v_norm IS NOT NULL
          AND to_regclass('public.international_gpdb_label_map') IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM public.international_gpdb_label_map m
            WHERE m.nation_code = en.nation_code
              AND m.norm_label = v_norm
          )
        )
      )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_manager_is_season_excluded(
  p_manager_id bigint,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public."Managers" m
    WHERE m.id = p_manager_id
      AND public.gpdb_text_matches_excluded_nation(m.nation, p_season_id)
  );
$$;

CREATE OR REPLACE FUNCTION public.gpdb_club_is_season_excluded(
  p_club_short_name text,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public."Clubs" c
    WHERE c."ShortName" = btrim(p_club_short_name)
      AND public.gpdb_text_matches_excluded_nation(c."Nation", p_season_id)
  );
$$;

CREATE OR REPLACE FUNCTION public.assert_manager_not_season_excluded(p_manager_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF public.gpdb_manager_is_season_excluded(p_manager_id) THEN
    RAISE EXCEPTION
      'This manager is excluded from GPSL for the current season (nation exclusion).';
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- MGDB: hide managers from excluded nations (+ archived)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.managers_gpdb_public;

CREATE VIEW public.managers_gpdb_public
WITH (security_invoker = true)
AS
SELECT
  m.id,
  m.slug,
  m.name,
  m.nation,
  m.possession,
  m.quick_counter,
  m.long_ball_counter,
  m.out_wide,
  m.long_ball,
  coalesce(m.overload, 0) AS overload,
  m.age,
  m.rating,
  m.market_value,
  m.contracted_club,
  m.contract_seasons_remaining,
  m.weekly_wage,
  CASE
    WHEN m.contracted_club IS NULL OR btrim(m.contracted_club) = '' THEN 'FREE AGENT'
    ELSE m.contracted_club
  END AS contracted_display,
  public.manager_boost_band_label(1, e.boost1_min, e.boost1_max) AS boost1_label,
  public.manager_boost_band_label(2, e.boost2_min, e.boost2_max) AS boost2_label,
  public.manager_boost_band_label(3, e.boost3_min, e.boost3_max) AS boost3_label,
  (SELECT tf.label FROM public.manager_target_for(m.rating, 'superleague') tf) AS target_superleague,
  (SELECT tf.label FROM public.manager_target_for(m.rating, 'championship_a') tf) AS target_championship_a,
  (SELECT tf.label FROM public.manager_target_for(m.rating, 'championship_b') tf) AS target_championship_b
FROM public."Managers" m
LEFT JOIN public.manager_proficiency_expectancy e
  ON e.proficiency = public.manager_proficiency_clamp(m.rating)
WHERE coalesce(m.archived, false) = false
  AND NOT public.gpdb_manager_is_season_excluded(m.id, NULL);

GRANT SELECT ON public.managers_gpdb_public TO authenticated;
GRANT SELECT ON public.managers_gpdb_public TO anon;

-- ---------------------------------------------------------------------------
-- Club Database: hide clubs of excluded nations
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_club_expectation_label(p_position smallint)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_position IS NULL THEN NULL
    WHEN p_position <= 1 THEN 'Win the league'
    WHEN p_position <= 2 THEN 'Finish top 2'
    WHEN p_position <= 4 THEN 'Finish top 4'
    WHEN p_position <= 6 THEN 'Finish top 6'
    WHEN p_position <= 10 THEN 'Finish top 10'
    WHEN p_position <= 14 THEN 'Mid-table finish'
    WHEN p_position <= 17 THEN 'Lower mid-table'
    ELSE 'Avoid relegation'
  END;
$$;

GRANT EXECUTE ON FUNCTION public.competition_club_expectation_label(smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_expectation_label(smallint) TO anon;

DROP VIEW IF EXISTS public.clubs_database_public;

CREATE VIEW public.clubs_database_public
WITH (security_invoker = false)
AS
WITH club_n AS (
  SELECT count(*)::smallint AS n
  FROM public."Clubs" c
  WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
    AND NOT public.gpdb_club_is_season_excluded(c."ShortName", NULL)
),
squad_mv AS (
  SELECT
    nullif(btrim(p."Contracted_Team"), '') AS club_short_name,
    coalesce(
      sum(
        coalesce(
          nullif(regexp_replace(btrim(p.market_value::text), '[^0-9.\-]', '', 'g'), '')::numeric,
          0
        )
      ),
      0
    ) AS club_market_value
  FROM public."Players" p
  WHERE nullif(btrim(p."Contracted_Team"), '') IS NOT NULL
  GROUP BY 1
),
prestige AS (
  SELECT
    p.club_short_name,
    p.prestige_rank,
    p.prestige_seed_rank
  FROM public.competition_club_prestige_public p
),
base AS (
  SELECT
    c."ShortName" AS club_short_name,
    c."Club" AS club_name,
    nullif(btrim(c."Nation"), '') AS nation,
    nullif(btrim(c."Stadium"), '') AS stadium_name,
    coalesce(c."Capacity", 0)::int AS stadium_capacity,
    coalesce(c.base_capacity, c."Capacity", 0)::int AS base_capacity,
    public.stadium_max_capacity(
      coalesce(c.base_capacity, c."Capacity", 0)::int
    ) AS stadium_max_capacity,
    greatest(
      public.stadium_max_capacity(
        coalesce(c.base_capacity, c."Capacity", 0)::int
      ) - coalesce(c."Capacity", 0)::int,
      0
    ) AS stadium_expansion_potential,
    pr.prestige_rank,
    public.competition_club_baseline_expected_position(
      coalesce(pr.prestige_rank, cn.n)::smallint,
      cn.n
    )::smallint AS club_expectation,
    coalesce(sm.club_market_value, 0)::numeric AS club_market_value,
    round(coalesce(c."Capacity", 0)::numeric * 1500) AS stadium_value,
    round(coalesce(c."Capacity", 0)::numeric * 1500 * 0.125) AS stadium_maintenance_cost,
    round(coalesce(c."Capacity", 0)::numeric * 20) AS gate_money_full,
    round(coalesce(c."Capacity", 0)::numeric * 20 * 0.8) AS gate_money_80,
    nullif(btrim(c.owner), '') AS owner_tag,
    c.owner_id,
    m.name AS manager_name,
    m.rating AS manager_rating
  FROM public."Clubs" c
  CROSS JOIN club_n cn
  LEFT JOIN prestige pr ON pr.club_short_name = c."ShortName"
  LEFT JOIN squad_mv sm ON sm.club_short_name = c."ShortName"
  LEFT JOIN public."Managers" m ON m.id = c.manager_id
  WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
    AND NOT public.gpdb_club_is_season_excluded(c."ShortName", NULL)
)
SELECT
  b.*,
  public.competition_club_expectation_label(b.club_expectation::smallint) AS club_expectation_label
FROM base b;

GRANT SELECT ON public.clubs_database_public TO authenticated;
GRANT SELECT ON public.clubs_database_public TO anon;

-- ---------------------------------------------------------------------------
-- FA board: never pick excluded-nation managers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.manager_window_fa_pick_ids(
  p_season_id bigint,
  p_limit int DEFAULT 10
)
RETURNS bigint[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_limit int := greatest(0, least(coalesce(p_limit, 10), 20));
  v_ids bigint[] := ARRAY[]::bigint[];
  v_id bigint;
  v_band text;
  v_need int;
  v_bands text[] := ARRAY['low', 'mid', 'upper', 'elite'];
  v_quotas_full int[] := ARRAY[2, 3, 3, 2];
  v_quotas int[] := ARRAY[0, 0, 0, 0];
  v_i int;
  v_sum int := 0;
  v_have int;
BEGIN
  IF v_limit <= 0 THEN
    RETURN v_ids;
  END IF;

  FOR v_i IN 1..4 LOOP
    v_quotas[v_i] := greatest(
      0,
      round((v_quotas_full[v_i]::numeric / 10.0) * v_limit)::int
    );
    v_sum := v_sum + v_quotas[v_i];
  END LOOP;
  IF v_sum > v_limit THEN
    v_quotas[2] := greatest(0, v_quotas[2] - (v_sum - v_limit));
  END IF;

  FOR v_i IN 1..4 LOOP
    v_band := v_bands[v_i];
    v_have := coalesce(array_length(v_ids, 1), 0);
    EXIT WHEN v_have >= v_limit;

    v_need := least(v_quotas[v_i], v_limit - v_have);
    IF v_need <= 0 THEN CONTINUE; END IF;

    FOR v_id IN
      SELECT m.id
      FROM public."Managers" m
      WHERE coalesce(m.archived, false) = false
        AND NOT public.gpdb_manager_is_season_excluded(m.id, p_season_id)
        AND (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
        AND NOT EXISTS (
          SELECT 1
          FROM public."Manager_Transfer_Listings" l
          WHERE l.manager_id = m.id
            AND l.status = 'Active'
            AND l.listing_type IN ('window_fa', 'standard', 'direct')
        )
        AND NOT (m.id = ANY (v_ids))
        AND (
          (v_band = 'low' AND coalesce(m.rating, 0) <= 65)
          OR (v_band = 'mid' AND coalesce(m.rating, 0) BETWEEN 66 AND 72)
          OR (v_band = 'upper' AND coalesce(m.rating, 0) BETWEEN 73 AND 78)
          OR (v_band = 'elite' AND coalesce(m.rating, 0) >= 79)
        )
      ORDER BY random()
      LIMIT v_need
    LOOP
      v_ids := array_append(v_ids, v_id);
      EXIT WHEN coalesce(array_length(v_ids, 1), 0) >= v_limit;
    END LOOP;
  END LOOP;

  WHILE coalesce(array_length(v_ids, 1), 0) < v_limit LOOP
    SELECT m.id INTO v_id
    FROM public."Managers" m
    WHERE coalesce(m.archived, false) = false
      AND NOT public.gpdb_manager_is_season_excluded(m.id, p_season_id)
      AND (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
      AND NOT EXISTS (
        SELECT 1
        FROM public."Manager_Transfer_Listings" l
        WHERE l.manager_id = m.id
          AND l.status = 'Active'
          AND l.listing_type IN ('window_fa', 'standard', 'direct')
      )
      AND NOT (m.id = ANY (v_ids))
    ORDER BY random()
    LIMIT 1;

    EXIT WHEN v_id IS NULL;
    v_ids := array_append(v_ids, v_id);
  END LOOP;

  RETURN v_ids;
END;
$function$;

-- Block bids on excluded-nation managers
CREATE OR REPLACE FUNCTION public.manager_place_bid(
  p_listing_id bigint,
  p_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_listing public."Manager_Transfer_Listings"%rowtype;
  v_mgr public."Managers"%rowtype;
  v_min numeric;
  v_high numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_listing
  FROM public."Manager_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND OR v_listing.status <> 'Active' THEN
    RAISE EXCEPTION 'Listing not active';
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = v_listing.manager_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  PERFORM public.assert_manager_not_season_excluded(v_listing.manager_id);

  IF to_regprocedure('public.manager_assert_not_sack_blocked(text,bigint)') IS NOT NULL THEN
    PERFORM public.manager_assert_not_sack_blocked(v_club, v_listing.manager_id);
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Managers" m WHERE m.contracted_club = v_club
  ) THEN
    RAISE EXCEPTION 'Your club already has a manager';
  END IF;

  v_high := coalesce(v_listing.current_highest_bid, 0);
  v_min := greatest(v_listing.market_value::numeric, v_high + 500000);

  IF p_amount < v_min THEN
    RAISE EXCEPTION 'Bid must be at least %', v_min;
  END IF;

  INSERT INTO public."Manager_Transfer_Bids" (
    listing_id, manager_id, bidder_club_id, bid_amount, is_direct
  )
  VALUES (p_listing_id, v_listing.manager_id, v_club, p_amount, true);

  UPDATE public."Manager_Transfer_Listings"
  SET current_highest_bid = p_amount,
      current_highest_bidder = v_club,
      updated_at = now()
  WHERE id = p_listing_id;

  RETURN jsonb_build_object('ok', true, 'bid', p_amount, 'listing_id', p_listing_id);
END;
$function$;

-- When excluding a nation: cancel open manager market listings for matching managers
CREATE OR REPLACE FUNCTION public.admin_gpdb_exclude_nation(
  p_nation_code text,
  p_reason text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.gpdb_exclusion_season_id(p_season_id);
  v_code text := upper(btrim(p_nation_code));
  v_name text;
  v_mgr_cancelled int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_season IS NULL THEN
    RAISE EXCEPTION 'No competition season found';
  END IF;
  IF v_code IS NULL OR v_code = '' THEN
    RAISE EXCEPTION 'nation_code required';
  END IF;

  SELECT n.name INTO v_name
  FROM public.international_nations n
  WHERE n.code = v_code;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Nation not found';
  END IF;

  INSERT INTO public.gpdb_season_excluded_nations (
    season_id, nation_code, reason, excluded_by
  )
  VALUES (v_season, v_code, nullif(btrim(p_reason), ''), auth.uid())
  ON CONFLICT (season_id, nation_code) DO UPDATE
  SET reason = excluded.reason,
      excluded_at = now(),
      excluded_by = auth.uid();

  UPDATE public.international_nations
  SET active = false
  WHERE code = v_code;

  UPDATE public.international_squad_callups
  SET is_active = false,
      released_at = now()
  WHERE nation_code = v_code
    AND is_active = true;

  UPDATE public."Manager_Transfer_Listings" l
  SET status = 'Cancelled',
      updated_at = now(),
      metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object(
        'cancelled_nation_exclusion', true,
        'nation_code', v_code
      )
  WHERE l.status = 'Active'
    AND EXISTS (
      SELECT 1 FROM public."Managers" m
      WHERE m.id = l.manager_id
        AND public.gpdb_manager_is_season_excluded(m.id, v_season)
    );

  GET DIAGNOSTICS v_mgr_cancelled = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'nation_code', v_code,
    'nation_name', v_name,
    'manager_listings_cancelled', v_mgr_cancelled
  );
END;
$function$;

-- Admin list: include affected managers & clubs
CREATE OR REPLACE FUNCTION public.admin_gpdb_exclusions_list(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.gpdb_exclusion_season_id(p_season_id);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN jsonb_build_object(
    'season_id', v_season,
    'season_label', (SELECT label FROM public.competition_seasons WHERE id = v_season),
    'players', coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'player_id', ep.player_id,
            'player_name', p."Name",
            'nation', p."Nation",
            'position', p."Position",
            'rating', p."Rating",
            'club', p."Contracted_Team",
            'reason', ep.reason,
            'excluded_at', ep.excluded_at
          )
          ORDER BY p."Name" NULLS LAST, ep.player_id
        )
        FROM public.gpdb_season_excluded_players ep
        LEFT JOIN public."Players" p ON p."Konami_ID"::text = ep.player_id
        WHERE ep.season_id = v_season
      ),
      '[]'::jsonb
    ),
    'nations', coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'nation_code', en.nation_code,
            'nation_name', n.name,
            'reason', en.reason,
            'excluded_at', en.excluded_at
          )
          ORDER BY n.name NULLS LAST, en.nation_code
        )
        FROM public.gpdb_season_excluded_nations en
        LEFT JOIN public.international_nations n ON n.code = en.nation_code
        WHERE en.season_id = v_season
      ),
      '[]'::jsonb
    ),
    'managers_from_nations', coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'manager_id', m.id,
            'manager_name', m.name,
            'nation', m.nation,
            'rating', m.rating,
            'club', m.contracted_club,
            'archived', coalesce(m.archived, false)
          )
          ORDER BY m.name NULLS LAST, m.id
        )
        FROM public."Managers" m
        WHERE public.gpdb_manager_is_season_excluded(m.id, v_season)
      ),
      '[]'::jsonb
    ),
    'clubs_from_nations', coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'club_short_name', c."ShortName",
            'club_name', c."Club",
            'nation', c."Nation",
            'owner_id', c.owner_id,
            'has_owner', c.owner_id IS NOT NULL
          )
          ORDER BY c."Club" NULLS LAST, c."ShortName"
        )
        FROM public."Clubs" c
        WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
          AND public.gpdb_club_is_season_excluded(c."ShortName", v_season)
      ),
      '[]'::jsonb
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpdb_text_matches_excluded_nation(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_manager_is_season_excluded(bigint, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_club_is_season_excluded(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_manager_not_season_excluded(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpdb_exclusions_list(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpdb_exclude_nation(text, text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_place_bid(bigint, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_pick_ids(bigint, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
