-- =============================================================================
-- Harden normalize_nation_key for home-grown matching
-- =============================================================================
-- Symptom: SOA (Côte d'Ivoire) Registration HG showed 1 instead of ~16.
-- Cause: Clubs.Nation / Players.Nation Unicode mismatch (ô, curly apostrophe,
--        or "Ivory Coast" vs "Côte d'Ivoire"). Old normalize only uppercased.
--
-- August HG fines / forced loans call club_hg_count → this function. Mid-season
-- squad.html was client-side only, so a display mismatch alone does not trigger
-- August enforcement — but SQL must stay aligned so August never false-fires.
--
-- Run once in Supabase SQL Editor.
-- =============================================================================

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

COMMENT ON FUNCTION public.normalize_nation_key(text) IS
  'Nation compare key for HG: strips accents/apostrophes; aliases Ivory Coast ↔ Côte d''Ivoire.';

-- Quick check (expect all = COTE DIVOIRE):
-- SELECT
--   public.normalize_nation_key('Côte d''Ivoire') AS club,
--   public.normalize_nation_key('Cote d''Ivoire') AS ascii,
--   public.normalize_nation_key('Ivory Coast') AS english,
--   public.normalize_nation_key(U&'Côte d\2019Ivoire') AS curly_apos;
--
-- SELECT public.club_hg_count('SOA') AS soa_hg;
