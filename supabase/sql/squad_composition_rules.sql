-- =============================================================================
-- Squad composition + home-grown definition (Nation match)
-- Run once in Supabase SQL Editor.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.normalize_nation_key(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT upper(trim(coalesce(p_value, '')));
$$;

CREATE OR REPLACE FUNCTION public.is_player_homegrown(
  p_player_id text,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
    AND public.normalize_nation_key(p."Nation") <> ''
  FROM public."Players" p
  JOIN public."Clubs" c ON c."ShortName" = p_club_short_name
  WHERE p."Konami_ID"::text = p_player_id
    AND p."Contracted_Team" = p_club_short_name;
$$;

CREATE OR REPLACE FUNCTION public.check_club_squad_composition(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club_nation text;
  v_total int;
  v_hg int;
  v_u21 int;
  v_issues text[] := ARRAY[]::text[];
BEGIN
  SELECT c."Nation" INTO v_club_nation
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  SELECT
    count(*)::int,
    count(*) FILTER (
      WHERE public.normalize_nation_key(p."Nation") = public.normalize_nation_key(v_club_nation)
        AND public.normalize_nation_key(p."Nation") <> ''
    )::int,
    count(*) FILTER (
      WHERE p."Age" IS NOT NULL AND p."Age" <= 21
    )::int
  INTO v_total, v_hg, v_u21
  FROM public."Players" p
  WHERE p."Contracted_Team" = p_club_short_name;

  IF v_total > 28 THEN
    v_issues := array_append(v_issues, format('Squad has %s players (max 28)', v_total));
  END IF;

  IF v_hg < 8 THEN
    v_issues := array_append(
      v_issues,
      format('Home-grown %s/8 (player Nation must match club Nation %s)', v_hg, coalesce(v_club_nation, '?'))
    );
  END IF;

  IF v_u21 < 5 THEN
    v_issues := array_append(v_issues, format('Under-21 %s/5 (age 21 or younger)', v_u21));
  END IF;

  RETURN jsonb_build_object(
    'club_short_name', p_club_short_name,
    'club_nation', v_club_nation,
    'total', coalesce(v_total, 0),
    'home_grown', coalesce(v_hg, 0),
    'under_21', coalesce(v_u21, 0),
    'min_home_grown', 8,
    'min_under_21', 5,
    'max_squad', 28,
    'compliant', coalesce(array_length(v_issues, 1), 0) = 0,
    'issues', to_jsonb(v_issues)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.is_player_homegrown(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_club_squad_composition(text) TO authenticated;
