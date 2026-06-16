-- =============================================================================
-- International nation GPDB player pool report (admin)
-- Run after competition_international.sql + international_callup_gpdb.sql
-- After international_sync_gpdb_nations.sql
-- Powers nation_player_pool.html — pool counts by rating band, U21, position
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.international_gpdb_label_map (
  norm_label text PRIMARY KEY,
  nation_code text NOT NULL
);

CREATE INDEX IF NOT EXISTS international_gpdb_label_map_code_idx
  ON public.international_gpdb_label_map (nation_code);

CREATE INDEX IF NOT EXISTS players_nation_norm_idx
  ON public."Players" (public.international_normalize_nation_label("Nation"));

CREATE INDEX IF NOT EXISTS clubs_nation_norm_idx
  ON public."Clubs" (public.international_normalize_nation_label("Nation"));

CREATE OR REPLACE FUNCTION public.international_refresh_gpdb_label_map()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count integer := 0;
BEGIN
  TRUNCATE public.international_gpdb_label_map;

  INSERT INTO public.international_gpdb_label_map (norm_label, nation_code)
  SELECT DISTINCT ON (src.norm_label)
    src.norm_label,
    src.code
  FROM (
    SELECT
      public.international_normalize_nation_label(n.name) AS norm_label,
      n.code,
      1 AS pri
    FROM public.international_nations n
    WHERE n.active = true
    UNION ALL
    SELECT upper(n.code), n.code, 2
    FROM public.international_nations n
    WHERE n.active = true
    UNION ALL
    SELECT
      public.international_normalize_nation_label(a),
      c.code,
      3
    FROM public.international_nation_catalog c
    CROSS JOIN unnest(c.aliases) AS a
    INNER JOIN public.international_nations n ON n.code = c.code AND n.active = true
  ) src
  WHERE src.norm_label IS NOT NULL AND src.norm_label <> ''
  ORDER BY src.norm_label, src.pri;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_gpdb_label_map_rows()
RETURNS TABLE (norm_label text, nation_code text)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT m.norm_label, m.nation_code
  FROM public.international_gpdb_label_map m;
$$;

CREATE OR REPLACE FUNCTION public.international_resolve_gpdb_nation_code(p_label text)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT m.nation_code
  FROM public.international_gpdb_label_map m
  WHERE m.norm_label = public.international_normalize_nation_label(p_label)
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.international_gpdb_matches_nation(
  p_gpdb_label text,
  p_nation_code text
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT public.international_resolve_gpdb_nation_code(p_gpdb_label)
    = upper(btrim(p_nation_code));
$$;

CREATE OR REPLACE FUNCTION public.international_player_matches_nation(
  p_player_id text,
  p_nation_code text
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public."Players" p
    WHERE p."Konami_ID"::text = btrim(p_player_id)
      AND public.international_resolve_gpdb_nation_code(p."Nation")
        = upper(btrim(p_nation_code))
  );
$$;

CREATE OR REPLACE FUNCTION public.international_player_pool_position_group(p_position text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE upper(btrim(coalesce(p_position, '')))
    WHEN 'GK' THEN 'gk'
    WHEN 'LB' THEN 'def'
    WHEN 'CB' THEN 'def'
    WHEN 'RB' THEN 'def'
    WHEN 'LWB' THEN 'def'
    WHEN 'RWB' THEN 'def'
    WHEN 'DMF' THEN 'mid'
    WHEN 'LMF' THEN 'mid'
    WHEN 'CMF' THEN 'mid'
    WHEN 'RMF' THEN 'mid'
    WHEN 'AMF' THEN 'mid'
    WHEN 'LW' THEN 'fwd'
    WHEN 'LWF' THEN 'fwd'
    WHEN 'SS' THEN 'fwd'
    WHEN 'RW' THEN 'fwd'
    WHEN 'RWF' THEN 'fwd'
    WHEN 'CF' THEN 'fwd'
    WHEN 'WG' THEN 'fwd'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.international_player_pool_rating_band(p_rating text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  WITH r AS (
    SELECT nullif(
      regexp_replace(coalesce(btrim(p_rating), ''), '[^0-9.]', '', 'g'),
      ''
    )::numeric AS v
  )
  SELECT CASE
    WHEN (SELECT v FROM r) IS NULL THEN NULL
    WHEN (SELECT v FROM r) <= 65 THEN 'le_65'
    WHEN (SELECT v FROM r) <= 69 THEN 'r66_69'
    WHEN (SELECT v FROM r) <= 72 THEN 'r70_72'
    WHEN (SELECT v FROM r) <= 75 THEN 'r73_75'
    WHEN (SELECT v FROM r) <= 78 THEN 'r76_78'
    ELSE 'r79_plus'
  END;
$$;

CREATE OR REPLACE FUNCTION public.international_player_pool_section_json(
  p_total bigint,
  p_gk bigint,
  p_def bigint,
  p_mid bigint,
  p_fwd bigint
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'total', coalesce(p_total, 0),
    'gk', coalesce(p_gk, 0),
    'def', coalesce(p_def, 0),
    'mid', coalesce(p_mid, 0),
    'fwd', coalesce(p_fwd, 0)
  );
$$;

CREATE OR REPLACE FUNCTION public.international_player_pool_empty_json()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'all', public.international_player_pool_section_json(0, 0, 0, 0, 0),
    'le_65', public.international_player_pool_section_json(0, 0, 0, 0, 0),
    'r66_69', public.international_player_pool_section_json(0, 0, 0, 0, 0),
    'r70_72', public.international_player_pool_section_json(0, 0, 0, 0, 0),
    'r73_75', public.international_player_pool_section_json(0, 0, 0, 0, 0),
    'r76_78', public.international_player_pool_section_json(0, 0, 0, 0, 0),
    'r79_plus', public.international_player_pool_section_json(0, 0, 0, 0, 0),
    'u21', public.international_player_pool_section_json(0, 0, 0, 0, 0)
  );
$$;

CREATE TABLE IF NOT EXISTS public.international_nation_player_pool_cache (
  nation_code text PRIMARY KEY,
  pool jsonb NOT NULL,
  refreshed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.international_nation_player_pool_meta (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  refreshed_at timestamptz,
  nation_count integer NOT NULL DEFAULT 0
);

INSERT INTO public.international_nation_player_pool_meta (id, refreshed_at, nation_count)
VALUES (1, NULL, 0)
ON CONFLICT (id) DO NOTHING;

DROP FUNCTION IF EXISTS public.international_refresh_nation_player_pool_cache();
DROP FUNCTION IF EXISTS public.international_nation_player_pool_cache_meta();

CREATE OR REPLACE FUNCTION public.international_refresh_nation_player_pool_cache()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count integer := 0;
  v_at timestamptz := now();
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM public.international_refresh_gpdb_label_map();
  PERFORM set_config('statement_timeout', '120000', true);

  TRUNCATE public.international_nation_player_pool_cache;

  INSERT INTO public.international_nation_player_pool_cache (nation_code, pool, refreshed_at)
  WITH player_rows AS (
    SELECT
      m.nation_code,
      public.international_player_pool_position_group(p."Position") AS pos_group,
      public.international_player_pool_rating_band(p."Rating"::text) AS rating_band,
      (
        p."Age" IS NOT NULL
        AND btrim(p."Age"::text) <> ''
        AND btrim(p."Age"::text)::numeric <= 21
      ) AS is_u21
    FROM public."Players" p
    INNER JOIN public.international_gpdb_label_map m
      ON m.norm_label = public.international_normalize_nation_label(p."Nation")
    WHERE btrim(coalesce(p."Nation", '')) <> ''
  ),
  agg AS (
    SELECT
      pr.nation_code,
      count(*)::bigint AS all_total,
      count(*) FILTER (WHERE pr.pos_group = 'gk')::bigint AS all_gk,
      count(*) FILTER (WHERE pr.pos_group = 'def')::bigint AS all_def,
      count(*) FILTER (WHERE pr.pos_group = 'mid')::bigint AS all_mid,
      count(*) FILTER (WHERE pr.pos_group = 'fwd')::bigint AS all_fwd,
      count(*) FILTER (WHERE pr.rating_band = 'le_65')::bigint AS le_65_total,
      count(*) FILTER (WHERE pr.rating_band = 'le_65' AND pr.pos_group = 'gk')::bigint AS le_65_gk,
      count(*) FILTER (WHERE pr.rating_band = 'le_65' AND pr.pos_group = 'def')::bigint AS le_65_def,
      count(*) FILTER (WHERE pr.rating_band = 'le_65' AND pr.pos_group = 'mid')::bigint AS le_65_mid,
      count(*) FILTER (WHERE pr.rating_band = 'le_65' AND pr.pos_group = 'fwd')::bigint AS le_65_fwd,
      count(*) FILTER (WHERE pr.rating_band = 'r66_69')::bigint AS r66_69_total,
      count(*) FILTER (WHERE pr.rating_band = 'r66_69' AND pr.pos_group = 'gk')::bigint AS r66_69_gk,
      count(*) FILTER (WHERE pr.rating_band = 'r66_69' AND pr.pos_group = 'def')::bigint AS r66_69_def,
      count(*) FILTER (WHERE pr.rating_band = 'r66_69' AND pr.pos_group = 'mid')::bigint AS r66_69_mid,
      count(*) FILTER (WHERE pr.rating_band = 'r66_69' AND pr.pos_group = 'fwd')::bigint AS r66_69_fwd,
      count(*) FILTER (WHERE pr.rating_band = 'r70_72')::bigint AS r70_72_total,
      count(*) FILTER (WHERE pr.rating_band = 'r70_72' AND pr.pos_group = 'gk')::bigint AS r70_72_gk,
      count(*) FILTER (WHERE pr.rating_band = 'r70_72' AND pr.pos_group = 'def')::bigint AS r70_72_def,
      count(*) FILTER (WHERE pr.rating_band = 'r70_72' AND pr.pos_group = 'mid')::bigint AS r70_72_mid,
      count(*) FILTER (WHERE pr.rating_band = 'r70_72' AND pr.pos_group = 'fwd')::bigint AS r70_72_fwd,
      count(*) FILTER (WHERE pr.rating_band = 'r73_75')::bigint AS r73_75_total,
      count(*) FILTER (WHERE pr.rating_band = 'r73_75' AND pr.pos_group = 'gk')::bigint AS r73_75_gk,
      count(*) FILTER (WHERE pr.rating_band = 'r73_75' AND pr.pos_group = 'def')::bigint AS r73_75_def,
      count(*) FILTER (WHERE pr.rating_band = 'r73_75' AND pr.pos_group = 'mid')::bigint AS r73_75_mid,
      count(*) FILTER (WHERE pr.rating_band = 'r73_75' AND pr.pos_group = 'fwd')::bigint AS r73_75_fwd,
      count(*) FILTER (WHERE pr.rating_band = 'r76_78')::bigint AS r76_78_total,
      count(*) FILTER (WHERE pr.rating_band = 'r76_78' AND pr.pos_group = 'gk')::bigint AS r76_78_gk,
      count(*) FILTER (WHERE pr.rating_band = 'r76_78' AND pr.pos_group = 'def')::bigint AS r76_78_def,
      count(*) FILTER (WHERE pr.rating_band = 'r76_78' AND pr.pos_group = 'mid')::bigint AS r76_78_mid,
      count(*) FILTER (WHERE pr.rating_band = 'r76_78' AND pr.pos_group = 'fwd')::bigint AS r76_78_fwd,
      count(*) FILTER (WHERE pr.rating_band = 'r79_plus')::bigint AS r79_plus_total,
      count(*) FILTER (WHERE pr.rating_band = 'r79_plus' AND pr.pos_group = 'gk')::bigint AS r79_plus_gk,
      count(*) FILTER (WHERE pr.rating_band = 'r79_plus' AND pr.pos_group = 'def')::bigint AS r79_plus_def,
      count(*) FILTER (WHERE pr.rating_band = 'r79_plus' AND pr.pos_group = 'mid')::bigint AS r79_plus_mid,
      count(*) FILTER (WHERE pr.rating_band = 'r79_plus' AND pr.pos_group = 'fwd')::bigint AS r79_plus_fwd,
      count(*) FILTER (WHERE pr.is_u21)::bigint AS u21_total,
      count(*) FILTER (WHERE pr.is_u21 AND pr.pos_group = 'gk')::bigint AS u21_gk,
      count(*) FILTER (WHERE pr.is_u21 AND pr.pos_group = 'def')::bigint AS u21_def,
      count(*) FILTER (WHERE pr.is_u21 AND pr.pos_group = 'mid')::bigint AS u21_mid,
      count(*) FILTER (WHERE pr.is_u21 AND pr.pos_group = 'fwd')::bigint AS u21_fwd
    FROM player_rows pr
    GROUP BY pr.nation_code
  )
  SELECT
    n.code,
    jsonb_build_object(
      'all', public.international_player_pool_section_json(
        coalesce(a.all_total, 0), coalesce(a.all_gk, 0), coalesce(a.all_def, 0), coalesce(a.all_mid, 0), coalesce(a.all_fwd, 0)
      ),
      'le_65', public.international_player_pool_section_json(
        coalesce(a.le_65_total, 0), coalesce(a.le_65_gk, 0), coalesce(a.le_65_def, 0), coalesce(a.le_65_mid, 0), coalesce(a.le_65_fwd, 0)
      ),
      'r66_69', public.international_player_pool_section_json(
        coalesce(a.r66_69_total, 0), coalesce(a.r66_69_gk, 0), coalesce(a.r66_69_def, 0), coalesce(a.r66_69_mid, 0), coalesce(a.r66_69_fwd, 0)
      ),
      'r70_72', public.international_player_pool_section_json(
        coalesce(a.r70_72_total, 0), coalesce(a.r70_72_gk, 0), coalesce(a.r70_72_def, 0), coalesce(a.r70_72_mid, 0), coalesce(a.r70_72_fwd, 0)
      ),
      'r73_75', public.international_player_pool_section_json(
        coalesce(a.r73_75_total, 0), coalesce(a.r73_75_gk, 0), coalesce(a.r73_75_def, 0), coalesce(a.r73_75_mid, 0), coalesce(a.r73_75_fwd, 0)
      ),
      'r76_78', public.international_player_pool_section_json(
        coalesce(a.r76_78_total, 0), coalesce(a.r76_78_gk, 0), coalesce(a.r76_78_def, 0), coalesce(a.r76_78_mid, 0), coalesce(a.r76_78_fwd, 0)
      ),
      'r79_plus', public.international_player_pool_section_json(
        coalesce(a.r79_plus_total, 0), coalesce(a.r79_plus_gk, 0), coalesce(a.r79_plus_def, 0), coalesce(a.r79_plus_mid, 0), coalesce(a.r79_plus_fwd, 0)
      ),
      'u21', public.international_player_pool_section_json(
        coalesce(a.u21_total, 0), coalesce(a.u21_gk, 0), coalesce(a.u21_def, 0), coalesce(a.u21_mid, 0), coalesce(a.u21_fwd, 0)
      )
    ),
    v_at
  FROM public.international_nations n
  LEFT JOIN agg a ON a.nation_code = n.code
  WHERE n.active = true;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  UPDATE public.international_nation_player_pool_meta
  SET refreshed_at = v_at,
      nation_count = v_count
  WHERE id = 1;

  RETURN jsonb_build_object(
    'nations_cached', v_count,
    'refreshed_at', v_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_nation_player_pool_cache_meta()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'refreshed_at', m.refreshed_at,
    'nation_count', m.nation_count,
    'cache_ready', m.refreshed_at IS NOT NULL
  )
  FROM public.international_nation_player_pool_meta m
  WHERE m.id = 1;
$$;

DROP FUNCTION IF EXISTS public.international_nation_player_pool_report();

CREATE OR REPLACE FUNCTION public.international_nation_player_pool_report()
RETURNS TABLE (
  nation_code text,
  nation_name text,
  seed_rank smallint,
  owner_club text,
  owner_tag text,
  is_taken boolean,
  owned_clubs_count integer,
  pool jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_empty jsonb := public.international_player_pool_empty_json();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in required';
  END IF;

  RETURN QUERY
  WITH owned_clubs AS (
    SELECT
      m.nation_code,
      count(*)::integer AS owned_clubs_count
    FROM public."Clubs" c
    INNER JOIN public.international_gpdb_label_map m
      ON m.norm_label = public.international_normalize_nation_label(c."Nation")
    WHERE c.owner_id IS NOT NULL
    GROUP BY m.nation_code
  )
  SELECT
    n.code,
    n.name,
    n.seed_rank,
    ion.club_short_name,
    coalesce(nullif(btrim(c.owner), ''), c."ShortName"),
    (ion.id IS NOT NULL),
    coalesce(oc.owned_clubs_count, 0),
    coalesce(cache.pool, v_empty)
  FROM public.international_nations n
  LEFT JOIN public.international_nation_player_pool_cache cache
    ON cache.nation_code = n.code
  LEFT JOIN public.international_owner_nations ion
    ON ion.nation_code = n.code AND ion.is_active = true
  LEFT JOIN public."Clubs" c ON c."ShortName" = ion.club_short_name
  LEFT JOIN owned_clubs oc ON oc.nation_code = n.code
  WHERE n.active = true
  ORDER BY n.seed_rank;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_nation_pool_is_selectable(p_nation_code text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $function$
DECLARE
  v_pool jsonb;
  v_all jsonb;
  v_total integer;
  v_gk integer;
  v_cap integer;
  v_band record;
  v_avail integer;
  v_band_cap integer;
BEGIN
  SELECT cache.pool INTO v_pool
  FROM public.international_nation_player_pool_cache cache
  WHERE cache.nation_code = upper(btrim(p_nation_code));

  IF v_pool IS NULL THEN
    RETURN false;
  END IF;

  v_all := v_pool->'all';
  v_total := coalesce((v_all->>'total')::integer, 0);
  v_gk := coalesce((v_all->>'gk')::integer, 0);

  IF v_total < 24 OR v_gk < 2 THEN
    RETURN false;
  END IF;

  v_cap := NULL;
  FOR v_band IN
    SELECT *
    FROM (
      VALUES
        ('r79_plus', 1),
        ('r76_78', 1),
        ('r73_75', 5),
        ('r70_72', 10),
        ('r66_69', 10),
        ('le_65', 5),
        ('u21', 8)
    ) AS bands(key, min_players)
  LOOP
    v_avail := coalesce((v_pool->v_band.key->>'total')::integer, 0);
    v_band_cap := v_avail / v_band.min_players;
    IF v_cap IS NULL OR v_band_cap < v_cap THEN
      v_cap := v_band_cap;
    END IF;
  END LOOP;

  RETURN coalesce(v_cap, 0) > 0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_claim_nation(p_nation_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_window record;
  v_my_pick smallint;
  v_current_pick smallint;
  v_nation text := btrim(upper(p_nation_code));
  v_cycle_id bigint;
  v_next_pick smallint;
  v_nation_name text;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_window
  FROM public.international_selection_windows
  WHERE is_open = true
  ORDER BY id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nation selection is not open';
  END IF;

  SELECT pick_order INTO v_my_pick
  FROM public.international_owner_draft_order()
  WHERE club_short_name = v_club;

  IF v_my_pick IS NULL THEN
    RAISE EXCEPTION 'Your club is not in the owner draft order';
  END IF;

  v_current_pick := v_window.current_pick_rank;

  IF v_my_pick <> v_current_pick THEN
    RAISE EXCEPTION 'Not your pick yet (currently pick #% — you are #%).', v_current_pick, v_my_pick;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.international_nations n
    WHERE n.code = v_nation AND n.active = true
  ) THEN
    RAISE EXCEPTION 'Nation not found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.international_owner_nations ion
    WHERE ion.nation_code = v_nation AND ion.is_active = true
  ) THEN
    RAISE EXCEPTION 'Nation already taken';
  END IF;

  IF NOT public.international_nation_pool_is_selectable(v_nation) THEN
    RAISE EXCEPTION 'This nation cannot be selected — GPDB pool too small for a squad or GPSL club';
  END IF;

  SELECT n.name INTO v_nation_name FROM public.international_nations n WHERE n.code = v_nation;

  SELECT id INTO v_cycle_id FROM public.international_wc_cycles ORDER BY cycle_no DESC LIMIT 1;

  UPDATE public.international_owner_nations
  SET is_active = false, released_at = now()
  WHERE club_short_name = v_club AND is_active = true;

  INSERT INTO public.international_owner_nations (
    club_short_name, nation_code, cycle_id, selection_phase, is_active, locked_until_cycle_id
  )
  VALUES (v_club, v_nation, v_cycle_id, v_window.phase, true, v_cycle_id);

  SELECT coalesce(min(pick_order), 61)::smallint INTO v_next_pick
  FROM public.international_owner_draft_order() d
  WHERE NOT EXISTS (
    SELECT 1 FROM public.international_owner_nations ion
    WHERE ion.club_short_name = d.club_short_name AND ion.is_active = true
  );

  IF v_next_pick >= 61 THEN
    UPDATE public.international_selection_windows
    SET is_open = false, closes_at = now()
    WHERE id = v_window.id;
  ELSE
    UPDATE public.international_selection_windows
    SET current_pick_rank = v_next_pick
    WHERE id = v_window.id;
    IF to_regprocedure('public.owner_inbox_notify_nation_pick_turn(smallint)') IS NOT NULL THEN
      PERFORM public.owner_inbox_notify_nation_pick_turn(v_next_pick);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'club', v_club,
    'nation', v_nation,
    'nation_name', v_nation_name,
    'pick', v_my_pick,
    'next_pick', v_next_pick
  );
END;
$function$;

SELECT public.international_refresh_gpdb_label_map();
SELECT public.international_refresh_nation_player_pool_cache();

GRANT SELECT ON public.international_gpdb_label_map TO authenticated;
GRANT SELECT ON public.international_nation_player_pool_cache TO authenticated;
GRANT SELECT ON public.international_nation_player_pool_meta TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_refresh_gpdb_label_map() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_refresh_nation_player_pool_cache() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_nation_player_pool_cache_meta() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_gpdb_label_map_rows() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_resolve_gpdb_nation_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_gpdb_matches_nation(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_player_matches_nation(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_nation_pool_is_selectable(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_nation_player_pool_report() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_claim_nation(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
