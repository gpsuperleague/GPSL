-- =============================================================================
-- Fix player / manager names saved with HTML codes, e.g.
--   N&apos;Golo Kanté  →  N'Golo Kanté
-- Decodes &apos; &#39; &#039; &#x27; &quot; &amp; &nbsp; numeric codes (&#233; → é)
-- and common accented names (&eacute; …). Also handles double-encoding (&amp;apos;).
-- Adds a trigger so Players."Name" / Managers.name can't be saved encoded again.
--
-- STEP 1 = preview (read-only). STEP 2 = fix. Run each step on its own
-- (the SQL Editor only shows the last result). Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_decode_html_entities(p_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := p_text;
  m text[];
  n int;
  i int;
  pass int;
BEGIN
  IF v IS NULL OR position('&' IN v) = 0 THEN
    RETURN v;
  END IF;

  FOR pass IN 1..3 LOOP
    v := replace(v, '&apos;', '''');
    v := replace(v, '&quot;', '"');
    v := replace(v, '&lt;', '<');
    v := replace(v, '&gt;', '>');
    v := replace(v, '&nbsp;', ' ');
    v := replace(v, '&rsquo;', '’');
    v := replace(v, '&lsquo;', '‘');
    v := replace(v, '&ndash;', '–');
    v := replace(v, '&eacute;', 'é'); v := replace(v, '&Eacute;', 'É');
    v := replace(v, '&egrave;', 'è'); v := replace(v, '&Egrave;', 'È');
    v := replace(v, '&aacute;', 'á'); v := replace(v, '&Aacute;', 'Á');
    v := replace(v, '&agrave;', 'à'); v := replace(v, '&iacute;', 'í');
    v := replace(v, '&Iacute;', 'Í'); v := replace(v, '&oacute;', 'ó');
    v := replace(v, '&Oacute;', 'Ó'); v := replace(v, '&uacute;', 'ú');
    v := replace(v, '&Uacute;', 'Ú'); v := replace(v, '&ntilde;', 'ñ');
    v := replace(v, '&Ntilde;', 'Ñ'); v := replace(v, '&ccedil;', 'ç');
    v := replace(v, '&Ccedil;', 'Ç'); v := replace(v, '&uuml;', 'ü');
    v := replace(v, '&Uuml;', 'Ü'); v := replace(v, '&ouml;', 'ö');
    v := replace(v, '&Ouml;', 'Ö'); v := replace(v, '&auml;', 'ä');
    v := replace(v, '&Auml;', 'Ä'); v := replace(v, '&atilde;', 'ã');
    v := replace(v, '&otilde;', 'õ'); v := replace(v, '&ecirc;', 'ê');
    v := replace(v, '&ocirc;', 'ô'); v := replace(v, '&acirc;', 'â');
    v := replace(v, '&oslash;', 'ø'); v := replace(v, '&Oslash;', 'Ø');
    v := replace(v, '&aring;', 'å'); v := replace(v, '&Aring;', 'Å');
    v := replace(v, '&szlig;', 'ß'); v := replace(v, '&euml;', 'ë');
    v := replace(v, '&iuml;', 'ï');

    i := 0;
    LOOP
      m := regexp_match(v, '&#([0-9]{1,7});');
      EXIT WHEN m IS NULL;
      i := i + 1;
      EXIT WHEN i > 200;
      n := m[1]::int;
      v := replace(v, '&#' || m[1] || ';', CASE WHEN n > 0 AND n <= 1114111 THEN chr(n) ELSE '' END);
    END LOOP;

    i := 0;
    LOOP
      m := regexp_match(v, '&#[xX]([0-9a-fA-F]{1,6});');
      EXIT WHEN m IS NULL;
      i := i + 1;
      EXIT WHEN i > 200;
      n := ('x' || lpad(m[1], 8, '0'))::bit(32)::int;
      v := regexp_replace(v, '&#[xX]' || m[1] || ';', CASE WHEN n > 0 AND n <= 1114111 THEN chr(n) ELSE '' END);
    END LOOP;

    v := replace(v, '&amp;', '&');
    EXIT WHEN position('&' IN v) = 0;
  END LOOP;

  RETURN v;
END;
$function$;

-- -----------------------------------------------------------------------------
-- STEP 1 — PREVIEW (read-only): names that will change
-- -----------------------------------------------------------------------------
SELECT 'Players' AS source, p."Konami_ID"::text AS id, p."Name" AS current_name,
       public.gpsl_decode_html_entities(p."Name") AS fixed_name
FROM public."Players" p
WHERE p."Name" ~ '&[#a-zA-Z0-9]+;'
UNION ALL
SELECT 'Managers', m.id::text, m.name, public.gpsl_decode_html_entities(m.name)
FROM public."Managers" m
WHERE m.name ~ '&[#a-zA-Z0-9]+;'
ORDER BY 1, 3;

-- -----------------------------------------------------------------------------
-- STEP 2 — FIX + guard trigger (run on its own after reviewing STEP 1)
-- -----------------------------------------------------------------------------
/*
UPDATE public."Players"
SET "Name" = public.gpsl_decode_html_entities("Name")
WHERE "Name" ~ '&[#a-zA-Z0-9]+;';

UPDATE public."Managers"
SET name = public.gpsl_decode_html_entities(name)
WHERE name ~ '&[#a-zA-Z0-9]+;';

CREATE OR REPLACE FUNCTION public.trg_players_decode_name()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW."Name" IS NOT NULL AND NEW."Name" ~ '&[#a-zA-Z0-9]+;' THEN
    NEW."Name" := public.gpsl_decode_html_entities(NEW."Name");
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS players_decode_name ON public."Players";
CREATE TRIGGER players_decode_name
  BEFORE INSERT OR UPDATE OF "Name" ON public."Players"
  FOR EACH ROW EXECUTE FUNCTION public.trg_players_decode_name();

CREATE OR REPLACE FUNCTION public.trg_managers_decode_name()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.name IS NOT NULL AND NEW.name ~ '&[#a-zA-Z0-9]+;' THEN
    NEW.name := public.gpsl_decode_html_entities(NEW.name);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS managers_decode_name ON public."Managers";
CREATE TRIGGER managers_decode_name
  BEFORE INSERT OR UPDATE OF name ON public."Managers"
  FOR EACH ROW EXECUTE FUNCTION public.trg_managers_decode_name();

-- Check: should return 0 rows
SELECT 'Players' AS source, "Konami_ID"::text AS id, "Name"
FROM public."Players" WHERE "Name" ~ '&[#a-zA-Z0-9]+;'
UNION ALL
SELECT 'Managers', id::text, name
FROM public."Managers" WHERE name ~ '&[#a-zA-Z0-9]+;';
*/
