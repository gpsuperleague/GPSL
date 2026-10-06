-- =============================================================================
-- STEP 2 — fix player / manager names with HTML codes (N&apos;Golo → N'Golo)
-- Run player_names_html_entities_fix_20261006.sql first (creates
-- gpsl_decode_html_entities). Run THIS whole file as-is. Safe re-run.
-- =============================================================================

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

-- Check
SELECT
  (SELECT count(*) FROM public."Players" WHERE "Name" ~ '&[#a-zA-Z0-9]+;') AS players_still_encoded,
  (SELECT count(*) FROM public."Managers" WHERE name ~ '&[#a-zA-Z0-9]+;') AS managers_still_encoded,
  (SELECT "Name" FROM public."Players" WHERE "Konami_ID"::text = '101334') AS kante_now,
  (SELECT count(*) FROM pg_trigger WHERE tgname IN ('players_decode_name', 'managers_decode_name')) AS triggers_installed;
