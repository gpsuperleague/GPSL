-- =============================================================================
-- Club kits — home / away / third choice images for Club Details
-- Run once in Supabase SQL Editor.
-- UI: club_details.html (owners), admin_club_kits.html (admin)
--
-- Image URLs in club_kits are optional metadata; the site always serves
-- images/clubs_kits/{ShortName}_home.png from GitHub (COF sync or manual).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.club_kits (
  club_short_name text NOT NULL PRIMARY KEY
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  home_image_url text,
  away_image_url text,
  third_image_url text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.club_kits IS
  'Kit image paths or URLs per club (home, away, third).';

ALTER TABLE public.club_kits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_kits_select ON public.club_kits;
CREATE POLICY club_kits_select ON public.club_kits
  FOR SELECT TO authenticated
  USING (
    club_short_name = public.my_club_shortname()
    OR public.is_gpsl_admin()
  );

GRANT SELECT ON public.club_kits TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_club_kits_list()
RETURNS TABLE (
  club_short_name text,
  club_name text,
  home_image_url text,
  away_image_url text,
  third_image_url text,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN QUERY
  SELECT
    c."ShortName"::text,
    c."Club"::text,
    k.home_image_url,
    k.away_image_url,
    k.third_image_url,
    k.updated_at
  FROM public."Clubs" c
  LEFT JOIN public.club_kits k ON k.club_short_name = c."ShortName"
  WHERE c."ShortName" <> 'FOREIGN'
  ORDER BY c."Club";
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_kits_upsert(
  p_club_short_name text,
  p_home_image_url text DEFAULT NULL,
  p_away_image_url text DEFAULT NULL,
  p_third_image_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(btrim(p_club_short_name));
  v_home text := nullif(btrim(p_home_image_url), '');
  v_away text := nullif(btrim(p_away_image_url), '');
  v_third text := nullif(btrim(p_third_image_url), '');
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_short IS NULL OR v_short = '' THEN
    RAISE EXCEPTION 'Club ShortName is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_short
  ) THEN
    RAISE EXCEPTION 'Club % not found', v_short;
  END IF;

  INSERT INTO public.club_kits (
    club_short_name,
    home_image_url,
    away_image_url,
    third_image_url,
    updated_at
  )
  VALUES (v_short, v_home, v_away, v_third, now())
  ON CONFLICT (club_short_name) DO UPDATE
  SET home_image_url = excluded.home_image_url,
      away_image_url = excluded.away_image_url,
      third_image_url = excluded.third_image_url,
      updated_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_short,
    'home_image_url', v_home,
    'away_image_url', v_away,
    'third_image_url', v_third
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_club_kits_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_kits_upsert(text, text, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
