-- Accent-tolerant admin player search (Next Gen match review + GPDB exclusions).
-- Requires gpdb_name_search.sql (name_search_key / gpdb_normalize_search_text).
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.admin_gpdb_search_players_for_exclusion(
  p_query text,
  p_limit integer DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_q text := btrim(coalesce(p_query, ''));
  v_norm text := public.gpdb_normalize_search_text(v_q);
  v_lim integer := greatest(1, least(coalesce(p_limit, 25), 50));
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF length(v_q) < 2 THEN
    RETURN '[]'::jsonb;
  END IF;

  IF v_norm IS NULL OR length(v_norm) < 2 THEN
    v_norm := lower(v_q);
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_agg(row_to_json(x)::jsonb)
      FROM (
        SELECT
          p."Konami_ID"::text AS player_id,
          p."Name" AS player_name,
          p."Nation" AS nation,
          p."Position" AS position,
          p."Rating" AS rating,
          p."Contracted_Team" AS club,
          p."Age" AS age
        FROM public."Players" p
        WHERE p.name_search_key LIKE '%' || v_norm || '%'
           OR p."Name" ILIKE '%' || v_q || '%'
           OR p."Konami_ID"::text ILIKE v_q || '%'
        ORDER BY p."Rating" DESC NULLS LAST, p."Name"
        LIMIT v_lim
      ) x
    ),
    '[]'::jsonb
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_gpdb_search_players_for_exclusion(text, integer) TO authenticated;
