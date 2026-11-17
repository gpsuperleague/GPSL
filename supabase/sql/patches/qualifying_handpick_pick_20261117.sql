-- Mid-season handpick, once the qualifying film is approved:
-- the member picks an empty club that is in a division.
-- Between seasons the auction door stays shut to self-pick.
-- A club staff are holding stays off the pick.

CREATE OR REPLACE FUNCTION public.owner_qualifying_claim_block(
  p_owner_id uuid,
  p_club text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(btrim(coalesce(p_club, '')));
BEGIN
  IF NOT public.owner_qualifying_is_subject(p_owner_id) THEN
    RETURN NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.gpsl_qualifying_video v
    WHERE v.owner_id = p_owner_id
      AND v.status = 'approved'
  ) THEN
    RETURN 'Finish the qualifying steps and have the video approved before taking a club.';
  END IF;

  IF public.gpsl_owner_intake_mode() IS DISTINCT FROM 'mid_season' THEN
    RETURN 'Between seasons the club comes through the auction.';
  END IF;

  IF v_short <> '' AND EXISTS (
    SELECT 1
    FROM public."Clubs" c
    WHERE upper(c."ShortName") = v_short
      AND coalesce(c.assignment_reserved, false) = true
  ) THEN
    RETURN 'That club is held by staff.';
  END IF;

  RETURN NULL;
END;
$function$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'block', position(
    'empty club' IN pg_get_functiondef('public.owner_qualifying_claim_block(uuid,text)'::regprocedure)
  ) = 0
    AND position(
      'gpsl_owner_intake_mode' IN pg_get_functiondef('public.owner_qualifying_claim_block(uuid,text)'::regprocedure)
    ) > 0,
  'named_club_lock', position(
    'You can handpick'
    IN pg_get_functiondef('public.owner_qualifying_claim_block(uuid,text)'::regprocedure)
  ) > 0
) AS info;
