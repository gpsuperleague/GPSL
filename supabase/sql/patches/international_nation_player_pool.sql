-- =============================================================================
-- International nation GPDB player pool report (admin)
-- Run after international_callup_gpdb.sql
-- Powers nation_player_pool.html — pool counts by rating band, U21, position
-- Readable by any signed-in user (aggregates only; no player PII)
-- =============================================================================

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
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_rating numeric;
BEGIN
  v_rating := nullif(
    regexp_replace(coalesce(btrim(p_rating), ''), '[^0-9.]', '', 'g'),
    ''
  )::numeric;

  IF v_rating IS NULL THEN
    RETURN NULL;
  ELSIF v_rating <= 65 THEN
    RETURN 'le_65';
  ELSIF v_rating <= 69 THEN
    RETURN 'r66_69';
  ELSIF v_rating <= 72 THEN
    RETURN 'r70_72';
  ELSIF v_rating <= 75 THEN
    RETURN 'r73_75';
  ELSIF v_rating <= 78 THEN
    RETURN 'r76_78';
  ELSE
    RETURN 'r79_plus';
  END IF;
END;
$function$;

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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in required';
  END IF;

  RETURN QUERY
  WITH player_rows AS (
    SELECT
      n.code AS nation_code,
      public.international_player_pool_position_group(p."Position") AS pos_group,
      public.international_player_pool_rating_band(p."Rating"::text) AS rating_band,
      (
        p."Age" IS NOT NULL
        AND btrim(p."Age"::text) <> ''
        AND btrim(p."Age"::text)::numeric <= 21
      ) AS is_u21
    FROM public.international_nations n
    JOIN public."Players" p ON (
      public.international_normalize_nation_label(p."Nation")
        = public.international_normalize_nation_label(n.name)
      OR public.international_normalize_nation_label(p."Nation")
        = upper(n.code)
    )
    WHERE n.active = true
  ),
  agg AS (
    SELECT
      pr.nation_code,
      public.international_player_pool_section_json(
        count(*)::bigint,
        count(*) FILTER (WHERE pr.pos_group = 'gk')::bigint,
        count(*) FILTER (WHERE pr.pos_group = 'def')::bigint,
        count(*) FILTER (WHERE pr.pos_group = 'mid')::bigint,
        count(*) FILTER (WHERE pr.pos_group = 'fwd')::bigint
      ) AS all_players,
      public.international_player_pool_section_json(
        count(*) FILTER (WHERE pr.rating_band = 'le_65')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'le_65' AND pr.pos_group = 'gk')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'le_65' AND pr.pos_group = 'def')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'le_65' AND pr.pos_group = 'mid')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'le_65' AND pr.pos_group = 'fwd')::bigint
      ) AS le_65,
      public.international_player_pool_section_json(
        count(*) FILTER (WHERE pr.rating_band = 'r66_69')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r66_69' AND pr.pos_group = 'gk')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r66_69' AND pr.pos_group = 'def')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r66_69' AND pr.pos_group = 'mid')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r66_69' AND pr.pos_group = 'fwd')::bigint
      ) AS r66_69,
      public.international_player_pool_section_json(
        count(*) FILTER (WHERE pr.rating_band = 'r70_72')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r70_72' AND pr.pos_group = 'gk')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r70_72' AND pr.pos_group = 'def')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r70_72' AND pr.pos_group = 'mid')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r70_72' AND pr.pos_group = 'fwd')::bigint
      ) AS r70_72,
      public.international_player_pool_section_json(
        count(*) FILTER (WHERE pr.rating_band = 'r73_75')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r73_75' AND pr.pos_group = 'gk')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r73_75' AND pr.pos_group = 'def')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r73_75' AND pr.pos_group = 'mid')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r73_75' AND pr.pos_group = 'fwd')::bigint
      ) AS r73_75,
      public.international_player_pool_section_json(
        count(*) FILTER (WHERE pr.rating_band = 'r76_78')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r76_78' AND pr.pos_group = 'gk')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r76_78' AND pr.pos_group = 'def')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r76_78' AND pr.pos_group = 'mid')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r76_78' AND pr.pos_group = 'fwd')::bigint
      ) AS r76_78,
      public.international_player_pool_section_json(
        count(*) FILTER (WHERE pr.rating_band = 'r79_plus')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r79_plus' AND pr.pos_group = 'gk')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r79_plus' AND pr.pos_group = 'def')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r79_plus' AND pr.pos_group = 'mid')::bigint,
        count(*) FILTER (WHERE pr.rating_band = 'r79_plus' AND pr.pos_group = 'fwd')::bigint
      ) AS r79_plus,
      public.international_player_pool_section_json(
        count(*) FILTER (WHERE pr.is_u21)::bigint,
        count(*) FILTER (WHERE pr.is_u21 AND pr.pos_group = 'gk')::bigint,
        count(*) FILTER (WHERE pr.is_u21 AND pr.pos_group = 'def')::bigint,
        count(*) FILTER (WHERE pr.is_u21 AND pr.pos_group = 'mid')::bigint,
        count(*) FILTER (WHERE pr.is_u21 AND pr.pos_group = 'fwd')::bigint
      ) AS u21
    FROM player_rows pr
    GROUP BY pr.nation_code
  ),
  empty_pool AS (
    SELECT public.international_player_pool_section_json(0, 0, 0, 0, 0) AS section
  ),
  owned_clubs AS (
    SELECT
      n.code AS nation_code,
      count(*)::integer AS owned_clubs_count
    FROM public.international_nations n
    JOIN public."Clubs" c ON (
      public.international_normalize_nation_label(c."Nation")
        = public.international_normalize_nation_label(n.name)
      OR public.international_normalize_nation_label(c."Nation")
        = upper(n.code)
    )
    WHERE n.active = true
      AND c.owner_id IS NOT NULL
    GROUP BY n.code
  )
  SELECT
    n.code,
    n.name,
    n.seed_rank,
    ion.club_short_name,
    coalesce(nullif(btrim(c.owner), ''), c."ShortName"),
    (ion.id IS NOT NULL),
    coalesce(oc.owned_clubs_count, 0),
    jsonb_build_object(
      'all', coalesce(a.all_players, ep.section),
      'le_65', coalesce(a.le_65, ep.section),
      'r66_69', coalesce(a.r66_69, ep.section),
      'r70_72', coalesce(a.r70_72, ep.section),
      'r73_75', coalesce(a.r73_75, ep.section),
      'r76_78', coalesce(a.r76_78, ep.section),
      'r79_plus', coalesce(a.r79_plus, ep.section),
      'u21', coalesce(a.u21, ep.section)
    )
  FROM public.international_nations n
  CROSS JOIN empty_pool ep
  LEFT JOIN agg a ON a.nation_code = n.code
  LEFT JOIN public.international_owner_nations ion
    ON ion.nation_code = n.code AND ion.is_active = true
  LEFT JOIN public."Clubs" c ON c."ShortName" = ion.club_short_name
  LEFT JOIN owned_clubs oc ON oc.nation_code = n.code
  WHERE n.active = true
  ORDER BY n.seed_rank;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_nation_player_pool_report() TO authenticated;

NOTIFY pgrst, 'reload schema';
