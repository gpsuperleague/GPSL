-- =============================================================================
-- Club preference marks: allow club owners (and waiting / auction-invited)
--
-- Previously only waiting-list / awaiting_club_auction owners without a club
-- could mark interest + backup. Club owners (e.g. Barcelona) could view but
-- not set preferred clubs.
--
-- Now: any authenticated owner with an owner tag can mark 1 interest + 1 backup
-- on any club (except while frozen), including current club owners.
-- Safe re-run. Apply after club_auction_interest_backup_20260921.sql.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_auction_interest_can_mark()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text;
  v_tag text;
  v_eligible boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;

  IF public.club_auction_interests_frozen_now() THEN
    RETURN false;
  END IF;

  SELECT r.status INTO v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = auth.uid();

  v_status := coalesce(v_status, '');
  IF v_status = 'archived' THEN
    RETURN false;
  END IF;

  -- Club owners, waiting-list members, and auction-invitees may mark.
  v_eligible :=
    EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = auth.uid())
    OR v_status = 'awaiting_club_auction'
    OR public.waiting_list_on_list_status(v_status);

  IF NOT v_eligible THEN
    RETURN false;
  END IF;

  v_tag := public.owner_registry_resolve_tag(auth.uid());
  IF v_tag IS NULL OR btrim(v_tag) = '' THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_auction_interest_can_view()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = auth.uid()) THEN
    RETURN true;
  END IF;

  SELECT r.status INTO v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = auth.uid();

  v_status := coalesce(v_status, '');
  IF v_status = 'archived' THEN
    RETURN false;
  END IF;

  RETURN
    v_status = 'awaiting_club_auction'
    OR public.waiting_list_on_list_status(v_status);
END;
$function$;

-- clear() previously hard-blocked club owners even if can_mark was updated
CREATE OR REPLACE FUNCTION public.club_auction_interest_clear(
  p_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_owner_id uuid := auth.uid();
BEGIN
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF public.club_auction_interests_frozen_now() THEN
    RAISE EXCEPTION 'Club interests are frozen while bidding is open';
  END IF;

  IF NOT public.club_auction_interest_can_mark() THEN
    RAISE EXCEPTION 'You cannot change club preference marks';
  END IF;

  v_club := nullif(btrim(coalesce(p_club_short_name, '')), '');
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club short name is required';
  END IF;

  DELETE FROM public.club_auction_interests
  WHERE owner_id = v_owner_id
    AND club_short_name = v_club;

  RETURN public.club_auction_interest_list();
END;
$function$;

-- Friendlier error when can_mark fails
CREATE OR REPLACE FUNCTION public.club_auction_interest_set(
  p_club_short_name text,
  p_note text DEFAULT NULL,
  p_mark_kind text DEFAULT 'interest'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_note text;
  v_kind text;
  v_owner_id uuid := auth.uid();
BEGIN
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.club_auction_interest_can_mark() THEN
    IF public.club_auction_interests_frozen_now() THEN
      RAISE EXCEPTION 'Club interests are frozen while bidding is open';
    END IF;
    RAISE EXCEPTION 'You need an owner tag to mark preferred clubs';
  END IF;

  v_kind := lower(nullif(btrim(coalesce(p_mark_kind, 'interest')), ''));
  IF v_kind IS NULL OR v_kind NOT IN ('interest', 'backup') THEN
    RAISE EXCEPTION 'mark_kind must be interest or backup';
  END IF;

  v_club := nullif(btrim(coalesce(p_club_short_name, '')), '');
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club short name is required';
  END IF;

  IF upper(v_club) = 'FOREIGN' THEN
    RAISE EXCEPTION 'Invalid club';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club
  ) THEN
    RAISE EXCEPTION 'Club not found';
  END IF;

  v_note := nullif(btrim(coalesce(p_note, '')), '');
  IF v_note IS NOT NULL AND char_length(v_note) > 280 THEN
    RAISE EXCEPTION 'Note must be 280 characters or fewer';
  END IF;

  DELETE FROM public.club_auction_interests
  WHERE owner_id = v_owner_id
    AND mark_kind = v_kind
    AND club_short_name IS DISTINCT FROM v_club;

  DELETE FROM public.club_auction_interests
  WHERE owner_id = v_owner_id
    AND club_short_name = v_club
    AND mark_kind IS DISTINCT FROM v_kind;

  INSERT INTO public.club_auction_interests (owner_id, club_short_name, note, mark_kind)
  VALUES (v_owner_id, v_club, v_note, v_kind)
  ON CONFLICT (owner_id, club_short_name) DO UPDATE
  SET note = excluded.note,
      mark_kind = excluded.mark_kind,
      updated_at = now();

  RETURN public.club_auction_interest_list();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_auction_interest_can_mark() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_can_view() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_set(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_clear(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
