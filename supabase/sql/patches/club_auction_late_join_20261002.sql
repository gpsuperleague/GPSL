-- =============================================================================
-- Club auction: let late owners join an auction that is already running
--
-- Bidding needs status awaiting_club_auction (admin invite — already allowed
-- mid-auction) AND both preference marks (interest + backup). Marks froze for
-- everyone when bidding opened, so an owner without marks could never become
-- eligible.
--
-- Now, while bidding is open:
--   * An owner (no club, invited or on the waiting list) who is MISSING a mark
--     may ADD that missing mark (interest and/or backup).
--   * Existing marks stay frozen: no changing, moving or clearing them.
--   * Season 1 confirmed + owner tag rules are unchanged.
--
-- Run after club_auction_interest_season1_confirmed_only_20260924.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_auction_interest_late_mark_allowed(
  p_owner_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_owner_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = p_owner_id)
    AND EXISTS (
      SELECT 1 FROM public.gpsl_owner_registry r
      WHERE r.owner_id = p_owner_id
        AND (
          r.status = 'awaiting_club_auction'
          OR public.waiting_list_on_list_status(r.status)
        )
    )
    AND NOT public.owner_onboarding_has_club_interest_marks(p_owner_id);
$$;

COMMENT ON FUNCTION public.club_auction_interest_late_mark_allowed(uuid) IS
  'True when a no-club owner is missing an interest/backup mark and may add it while bidding is open.';

-- Owner-aware: not frozen for an owner who still needs to add a missing mark.
CREATE OR REPLACE FUNCTION public.club_auction_interests_frozen_now()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.club_auction_bidding_open_now()
    AND NOT public.club_auction_interest_late_mark_allowed(auth.uid());
$$;

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
    IF NOT public.club_auction_interest_is_season1_confirmed(v_owner_id) THEN
      RAISE EXCEPTION 'Only Season 1 confirmed owners can mark club preferences';
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

  -- Late join during bidding: only add a missing mark, never change existing ones
  IF public.club_auction_bidding_open_now() THEN
    IF EXISTS (
      SELECT 1 FROM public.club_auction_interests i
      WHERE i.owner_id = v_owner_id AND i.mark_kind = v_kind
    ) THEN
      RAISE EXCEPTION 'Your % mark is frozen while bidding is open — you can only add a missing mark', v_kind;
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.club_auction_interests i
      WHERE i.owner_id = v_owner_id AND i.club_short_name = v_club
    ) THEN
      RAISE EXCEPTION 'You already marked this club — pick a different club for your % mark', v_kind;
    END IF;
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

  -- Clearing is never allowed while bidding is open (late joiners can only add)
  IF public.club_auction_bidding_open_now() THEN
    RAISE EXCEPTION 'Club interests are frozen while bidding is open';
  END IF;

  IF NOT public.club_auction_interest_can_mark() THEN
    IF NOT public.club_auction_interest_is_season1_confirmed(v_owner_id) THEN
      RAISE EXCEPTION 'Only Season 1 confirmed owners can change club preferences';
    END IF;
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

GRANT EXECUTE ON FUNCTION public.club_auction_interest_late_mark_allowed(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interests_frozen_now() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_set(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_clear(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
