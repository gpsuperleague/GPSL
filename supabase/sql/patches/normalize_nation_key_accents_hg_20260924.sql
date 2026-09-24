-- =============================================================================
-- Harden normalize_nation_key for home-grown matching
-- =============================================================================
-- Does NOT change when August fines/loans run. Those still require
-- squad_minimum_punishments_active() = GPSL month ≥ August. This patch only
-- makes nation string compares accent/apostrophe-safe so a Unicode mismatch
-- cannot under-count HG at August.
--
-- Run once in Supabase SQL Editor (function + diagnostics below).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.normalize_nation_key(p_value text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
  v text;
BEGIN
  v := translate(
    btrim(coalesce(p_value, '')),
    'ÜüÖöÔôÄäÉéÈèÊêËëÍíÓóÚúÇçÀàÂâÃãÑñ',
    'UuOoOoAaEeEeEeIiOoUuCcAaAaAaNn'
  );
  -- Zero-width / BOM / NBSP
  v := replace(v, chr(8203), ''); -- ZWSP
  v := replace(v, chr(8204), ''); -- ZWNJ
  v := replace(v, chr(8205), ''); -- ZWJ
  v := replace(v, chr(65279), ''); -- BOM
  v := replace(v, chr(160), ' '); -- NBSP
  -- Apostrophe-like chars so d'Ivoire ≡ dIvoire
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

-- ---------------------------------------------------------------------------
-- Diagnostics (SOA): if most players are United States, accent fix cannot
-- restore HG — NMU→SOA kept the squad and only changed Clubs.Nation to CIV.
-- ---------------------------------------------------------------------------

SELECT
  c."ShortName",
  c."Nation" AS club_nation,
  public.normalize_nation_key(c."Nation") AS club_key,
  public.club_hg_count('SOA') AS hg_count,
  (
    SELECT count(*) FROM public."Players" p
    WHERE p."Contracted_Team" = 'SOA'
  ) AS squad_total
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
ORDER BY players DESC, p."Nation";
