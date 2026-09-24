-- =============================================================================
-- Harden normalize_nation_key + fix literal HTML &apos; in Nation
-- =============================================================================
-- Root cause (SOA): 15 players stored as Côte d&apos;Ivoire (HTML entity),
-- club as Côte d'Ivoire (real apostrophe) → HG count 1 instead of 16.
--
-- Does NOT change when August fines/loans run (still GPSL month ≥ August).
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
  v := btrim(coalesce(p_value, ''));
  -- Literal HTML entities leaked into Players.Nation
  v := regexp_replace(v, '&apos;', '''', 'gi');
  v := regexp_replace(v, '&#0*39;', '''', 'g');
  v := regexp_replace(v, '&#x0*27;', '''', 'gi');
  v := regexp_replace(v, '&(rsquo|lsquo|prime);', '''', 'gi');

  v := translate(
    v,
    'ÜüÖöÔôÄäÉéÈèÊêËëÍíÓóÚúÇçÀàÂâÃãÑñ',
    'UuOoOoAaEeEeEeIiOoUuCcAaAaAaNn'
  );
  v := replace(v, chr(8203), '');
  v := replace(v, chr(8204), '');
  v := replace(v, chr(8205), '');
  v := replace(v, chr(65279), '');
  v := replace(v, chr(160), ' ');
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

  -- d'Ivoire → dIvoire → camelCase → "COTE D IVOIRE"
  IF v IN (
    'IVORY COAST',
    'COTE DIVOIRE',
    'COTE D IVOIRE',
    'REPUBLIC OF COTE DIVOIRE',
    'REPUBLIC OF COTE D IVOIRE',
    'CIV'
  ) THEN
    RETURN 'COTE DIVOIRE';
  END IF;

  RETURN v;
END;
$fn$;

COMMENT ON FUNCTION public.normalize_nation_key(text) IS
  'Nation compare key for HG: strips accents/apostrophes/HTML entities; aliases Ivory Coast ↔ Côte d''Ivoire.';

-- Fix stored HTML entities (display + future imports)
UPDATE public."Players"
SET "Nation" = regexp_replace(
  regexp_replace(
    regexp_replace("Nation", '&apos;', '''', 'gi'),
    '&#0*39;', '''', 'g'
  ),
  '&#x0*27;', '''', 'gi'
)
WHERE "Nation" ~* '&(apos|#0*39|#x0*27);';

UPDATE public."Clubs"
SET "Nation" = regexp_replace(
  regexp_replace(
    regexp_replace("Nation", '&apos;', '''', 'gi'),
    '&#0*39;', '''', 'g'
  ),
  '&#x0*27;', '''', 'gi'
)
WHERE "Nation" ~* '&(apos|#0*39|#x0*27);';

-- Expect hg_count ≈ 16 for SOA
SELECT
  c."Nation" AS club_nation,
  public.normalize_nation_key(c."Nation") AS club_key,
  public.club_hg_count('SOA') AS hg_count
FROM public."Clubs" c
WHERE c."ShortName" = 'SOA';

SELECT
  p."Nation" AS player_nation,
  public.normalize_nation_key(p."Nation") AS player_key,
  count(*)::int AS players,
  (public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")) AS counts_as_hg
FROM public."Players" p
CROSS JOIN public."Clubs" c
WHERE p."Contracted_Team" = 'SOA'
  AND c."ShortName" = 'SOA'
GROUP BY p."Nation", c."Nation"
ORDER BY players DESC;
