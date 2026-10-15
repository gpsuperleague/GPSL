-- =============================================================================
-- Discord translation: link owners whose Discord id isn't stored yet (2026-10-15)
--
-- Translate / /language look owners up by Discord user id. Owners who never went
-- through the Discord join flow have no id on gpsl_owner_registry, so their site
-- language wasn't found. The edge function now passes the caller's Discord names
-- (server nickname, display name, username); if exactly one unlinked owner's
-- owner_tag matches, the id is saved on their registry row and their language used.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_link_owner_by_names(
  p_discord_user_id text,
  p_names text[]
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_names text[];
  v_owner uuid;
  v_count int;
  v_lang text;
BEGIN
  IF nullif(btrim(coalesce(p_discord_user_id, '')), '') IS NULL THEN
    RETURN NULL;
  END IF;

  -- Already linked: just return the language
  SELECT g.preferred_language INTO v_lang
  FROM public.gpsl_owner_registry g
  WHERE g.discord_user_id = p_discord_user_id
  LIMIT 1;
  IF FOUND THEN
    RETURN v_lang;
  END IF;

  SELECT array_agg(DISTINCT lower(btrim(regexp_replace(n, '^@+', ''))))
  INTO v_names
  FROM unnest(coalesce(p_names, ARRAY[]::text[])) n
  WHERE nullif(btrim(coalesce(n, '')), '') IS NOT NULL;

  IF v_names IS NULL OR cardinality(v_names) = 0 THEN
    RETURN NULL;
  END IF;

  SELECT count(*)::int, min(g.owner_id::text)::uuid
  INTO v_count, v_owner
  FROM public.gpsl_owner_registry g
  WHERE g.discord_user_id IS NULL
    AND lower(btrim(regexp_replace(coalesce(g.owner_tag, ''), '^@+', ''))) = ANY (v_names);

  IF v_count <> 1 THEN
    RETURN NULL;
  END IF;

  UPDATE public.gpsl_owner_registry
  SET discord_user_id = p_discord_user_id
  WHERE owner_id = v_owner
    AND discord_user_id IS NULL
  RETURNING preferred_language INTO v_lang;

  IF v_lang IS NOT NULL THEN
    INSERT INTO public.gpsl_discord_language_pref (discord_user_id, language, updated_at)
    VALUES (p_discord_user_id, v_lang, now())
    ON CONFLICT (discord_user_id) DO UPDATE
      SET language = EXCLUDED.language, updated_at = now();
  END IF;

  RETURN v_lang;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_link_owner_by_names(text, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_link_owner_by_names(text, text[]) TO service_role;

NOTIFY pgrst, 'reload schema';

-- Report: owners with a language set, and whether their Discord id is linked
SELECT g.owner_tag,
       g.preferred_language,
       g.discord_user_id IS NOT NULL AS discord_linked
FROM public.gpsl_owner_registry g
WHERE g.preferred_language IS NOT NULL
ORDER BY g.owner_tag;
