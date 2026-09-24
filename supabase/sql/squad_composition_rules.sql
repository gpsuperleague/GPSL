-- =============================================================================
-- Squad composition + home-grown definition (Nation match)
-- Run once in Supabase SQL Editor.
-- =============================================================================

-- Accent/apostrophe-safe nation key (HG, August enforcement, checklists).
-- "Côte d'Ivoire" / "Cote d'Ivoire" / "Ivory Coast" → COTE DIVOIRE.
CREATE OR REPLACE FUNCTION public.normalize_nation_key(p_value text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
  v text;
BEGIN
  -- Same accent map as competition_normalize_nation_key (Ôô → Oo for Côte)
  v := translate(
    btrim(coalesce(p_value, '')),
    'ÜüÖöÔôÄäÉéÈèÊêËëÍíÓóÚúÇçÀàÂâÃãÑñ',
    'UuOoOoAaEeEeEeIiOoUuCcAaAaAaNn'
  );
  v := replace(v, chr(8203), '');
  v := replace(v, chr(8204), '');
  v := replace(v, chr(8205), '');
  v := replace(v, chr(65279), '');
  v := replace(v, chr(160), ' ');
  -- Strip apostrophe-like chars so d'Ivoire ≡ dIvoire
  v := regexp_replace(
    v,
    '[' || chr(39) || chr(96) || chr(180) || chr(8216) || chr(8217) || chr(8218) || chr(8242) || chr(700) || ']',
    '',
    'g'
  );
  v := regexp_replace(v, '([a-z])([A-Z])', '\1 \2', 'g');
  v := regexp_replace(v, '[_-]+', ' ', 'g');
  v := regexp_replace(v, '\s+', ' ', 'g');
  v := upper(btrim(v));

  IF v IN (
    'IVORY COAST',
    'COTE DIVOIRE',
    'REPUBLIC OF COTE DIVOIRE',
    'CIV'
  ) THEN
    RETURN 'COTE DIVOIRE';
  END IF;

  RETURN v;
END;
$fn$;

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
      WHERE p."Age" IS NOT NULL
        AND btrim(p."Age"::text) <> ''
        AND btrim(p."Age"::text)::numeric <= 21
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
      format('Home-grown %s — minimum 8 required (Nation must match club %s; more allowed)', v_hg, coalesce(v_club_nation, '?'))
    );
  END IF;

  IF v_u21 < 5 THEN
    v_issues := array_append(v_issues, format('Under-21 %s — minimum 5 required (age 21 or younger; more allowed)', v_u21));
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
