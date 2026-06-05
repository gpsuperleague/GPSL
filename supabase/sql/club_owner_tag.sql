-- =============================================================================
-- Club owner Discord tag (Clubs.Owner) — owners set via Club Details page
-- Run once in Supabase SQL Editor.
-- =============================================================================

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS "Owner" text;

CREATE OR REPLACE FUNCTION public.club_owner_set_tag(p_tag text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text;
  v_tag   text;
BEGIN
  v_tag := nullif(btrim(coalesce(p_tag, '')), '');
  IF v_tag IS NULL THEN
    RAISE EXCEPTION 'Owner tag cannot be empty';
  END IF;
  IF length(v_tag) > 64 THEN
    RAISE EXCEPTION 'Owner tag is too long (max 64 characters)';
  END IF;

  SELECT c."ShortName" INTO v_short
  FROM public."Clubs" c
  WHERE c.owner_id = auth.uid()
  LIMIT 1;

  IF v_short IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  UPDATE public."Clubs"
  SET "Owner" = v_tag
  WHERE "ShortName" = v_short
    AND owner_id = auth.uid();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_owner_set_tag(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
