-- =============================================================================
-- Club GP Saved — owner awareness tracker (in-game eFootball GP → GPSL)
-- Not part of league finances / ledger. Owner can set/update on Finances page.
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS gp_saved bigint;

COMMENT ON COLUMN public."Clubs".gp_saved IS
  'Owner-entered eFootball/in-game GP balance for awareness only (not league money).';

CREATE OR REPLACE FUNCTION public.club_gp_saved_get(p_club_short text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := nullif(btrim(coalesce(p_club_short, '')), '');
  v_row record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_short IS NULL THEN
    SELECT c."ShortName" INTO v_short
    FROM public."Clubs" c
    WHERE c.owner_id = auth.uid()
    LIMIT 1;
  END IF;

  IF v_short IS NULL THEN
    RAISE EXCEPTION 'No club specified';
  END IF;

  -- Own club, or staff preview
  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_short
      AND (
        c.owner_id = auth.uid()
        OR public.is_gpsl_admin()
        OR public.is_gpsl_mod()
      )
  ) THEN
    RAISE EXCEPTION 'Not allowed for this club';
  END IF;

  SELECT c."ShortName" AS club_short_name,
         c.gp_saved,
         (c.owner_id = auth.uid()) AS can_edit
  INTO v_row
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short;

  IF v_row.club_short_name IS NULL THEN
    RAISE EXCEPTION 'Club not found';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_row.club_short_name,
    'gp_saved', v_row.gp_saved,
    'can_edit', v_row.can_edit
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_gp_saved_set(
  p_amount bigint,
  p_club_short text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := nullif(btrim(coalesce(p_club_short, '')), '');
  v_amount bigint := p_amount;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_amount IS NOT NULL AND v_amount < 0 THEN
    RAISE EXCEPTION 'GP amount cannot be negative';
  END IF;

  IF v_amount IS NOT NULL AND v_amount > 999999999999 THEN
    RAISE EXCEPTION 'GP amount is too large';
  END IF;

  -- Owners may only edit their own club (staff cannot write via this RPC).
  IF v_short IS NULL THEN
    SELECT c."ShortName" INTO v_short
    FROM public."Clubs" c
    WHERE c.owner_id = auth.uid()
    LIMIT 1;
  END IF;

  IF v_short IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  UPDATE public."Clubs" c
  SET gp_saved = v_amount
  WHERE c."ShortName" = v_short
    AND c.owner_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'You can only update GP Saved for your own club';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_short,
    'gp_saved', v_amount,
    'can_edit', true
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_gp_saved_get(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_gp_saved_set(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.club_gp_saved_get(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_gp_saved_set(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
