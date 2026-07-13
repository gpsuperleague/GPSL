-- =============================================================================
-- Auction exclusion search (fixed)
-- Age / Rating / market_value are text in "Players" — cast before compare.
-- One PostgREST-friendly signature: (text, int, jsonb). Safe re-run.
-- =============================================================================

DROP FUNCTION IF EXISTS public.admin_auction_search_players_for_exclusion(text, int);
DROP FUNCTION IF EXISTS public.admin_auction_search_players_for_exclusion(text, int, text[], text[], text[], int, int, int, int, numeric, numeric);
DROP FUNCTION IF EXISTS public.admin_auction_search_players_for_exclusion(text, int, jsonb);

CREATE OR REPLACE FUNCTION public.admin_auction_search_players_for_exclusion(
  p_query text,
  p_limit int,
  p_filters jsonb
)
RETURNS TABLE (
  player_id text,
  player_name text,
  player_position text,
  nation text,
  age int,
  playstyle text,
  rating int,
  market_value numeric,
  already_excluded boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_q text := btrim(coalesce(p_query, ''));
  v_f jsonb := coalesce(p_filters, '{}'::jsonb);
  v_positions text[] := CASE
    WHEN jsonb_typeof(v_f->'positions') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(v_f->'positions'))
    ELSE NULL
  END;
  v_nations text[] := CASE
    WHEN jsonb_typeof(v_f->'nations') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(v_f->'nations'))
    ELSE NULL
  END;
  v_playstyles text[] := CASE
    WHEN jsonb_typeof(v_f->'playstyles') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(v_f->'playstyles'))
    ELSE NULL
  END;
  v_age_min int := NULLIF(v_f->>'age_min', '')::int;
  v_age_max int := NULLIF(v_f->>'age_max', '')::int;
  v_rating_min int := NULLIF(v_f->>'rating_min', '')::int;
  v_rating_max int := NULLIF(v_f->>'rating_max', '')::int;
  v_mv_min numeric := NULLIF(v_f->>'mv_min', '')::numeric;
  v_mv_max numeric := NULLIF(v_f->>'mv_max', '')::numeric;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN QUERY
  SELECT
    p."Konami_ID"::text AS player_id,
    p."Name"::text AS player_name,
    p."Position"::text AS player_position,
    p."Nation"::text AS nation,
    CASE
      WHEN nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
      THEN nullif(btrim(p."Age"::text), '')::int
      ELSE NULL
    END AS age,
    p."Playstyle"::text AS playstyle,
    CASE
      WHEN nullif(btrim(p."Rating"::text), '') ~ '^[0-9]+$'
      THEN nullif(btrim(p."Rating"::text), '')::int
      ELSE NULL
    END AS rating,
    nullif(btrim(p.market_value::text), '')::numeric AS market_value,
    EXISTS (
      SELECT 1 FROM public.auction_exclusion_players e WHERE e.player_id = p."Konami_ID"::text
    ) AS already_excluded
  FROM public."Players" p
  WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
    AND (
      v_q = ''
      OR p."Konami_ID"::text ILIKE '%' || v_q || '%'
      OR p."Name" ILIKE '%' || v_q || '%'
    )
    AND (
      v_positions IS NULL OR cardinality(v_positions) = 0
      OR p."Position"::text = ANY (v_positions)
    )
    AND (
      v_nations IS NULL OR cardinality(v_nations) = 0
      OR p."Nation"::text = ANY (v_nations)
    )
    AND (
      v_playstyles IS NULL OR cardinality(v_playstyles) = 0
      OR p."Playstyle"::text = ANY (v_playstyles)
    )
    AND (
      v_age_min IS NULL
      OR (
        nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
        AND nullif(btrim(p."Age"::text), '')::int >= v_age_min
      )
    )
    AND (
      v_age_max IS NULL
      OR (
        nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
        AND nullif(btrim(p."Age"::text), '')::int <= v_age_max
      )
    )
    AND (
      v_rating_min IS NULL
      OR (
        nullif(btrim(p."Rating"::text), '') ~ '^[0-9]+$'
        AND nullif(btrim(p."Rating"::text), '')::int >= v_rating_min
      )
    )
    AND (
      v_rating_max IS NULL
      OR (
        nullif(btrim(p."Rating"::text), '') ~ '^[0-9]+$'
        AND nullif(btrim(p."Rating"::text), '')::int <= v_rating_max
      )
    )
    AND (
      v_mv_min IS NULL
      OR nullif(btrim(p.market_value::text), '')::numeric >= v_mv_min
    )
    AND (
      v_mv_max IS NULL
      OR nullif(btrim(p.market_value::text), '')::numeric <= v_mv_max
    )
  ORDER BY
    CASE
      WHEN nullif(btrim(p."Rating"::text), '') ~ '^[0-9]+$'
      THEN nullif(btrim(p."Rating"::text), '')::int
      ELSE NULL
    END DESC NULLS LAST,
    p."Name"
  LIMIT greatest(1, least(coalesce(p_limit, 40), 80));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_auction_search_players_for_exclusion(text, int, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
