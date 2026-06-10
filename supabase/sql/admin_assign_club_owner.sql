-- =============================================================================
-- Admin: link an existing auth user (by email) to a club (by ShortName)
-- Run once in Supabase SQL Editor. Requires is_gpsl_admin() (special_auctions.sql).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_assign_club_owner(
  p_owner_email text,
  p_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(trim(p_owner_email));
  v_short text := upper(trim(p_club_short_name));
  v_user_id uuid;
  v_club_name text;
  v_replaced_previous boolean := false;
  v_registry_status text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'Owner email is required';
  END IF;

  IF v_short IS NULL OR v_short = '' THEN
    RAISE EXCEPTION 'Club ShortName is required';
  END IF;

  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %', p_owner_email;
  END IF;

  SELECT r.status INTO v_registry_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  IF v_registry_status = 'archived' THEN
    RAISE EXCEPTION 'Owner is archived — unarchive before linking to a club';
  END IF;

  SELECT c."Club" INTO v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short;

  IF v_club_name IS NULL THEN
    RAISE EXCEPTION 'Club ShortName % not found', v_short;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public."Clubs" c
    WHERE c."ShortName" = v_short
      AND c.owner_id IS NOT NULL
      AND c.owner_id <> v_user_id
  ) INTO v_replaced_previous;

  -- One club per owner: clear any other club this user already owns
  UPDATE public."Clubs"
  SET owner_id = NULL,
      owner = NULL
  WHERE owner_id = v_user_id
    AND "ShortName" <> v_short;

  UPDATE public."Clubs"
  SET owner_id = v_user_id
  WHERE "ShortName" = v_short;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Failed to update club %', v_short;
  END IF;

  INSERT INTO public.gpsl_owner_registry (owner_id, status, last_club_short_name, status_changed_at)
  VALUES (v_user_id, 'active', v_short, now())
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'active',
      last_club_short_name = v_short,
      status_note = NULL,
      status_changed_at = now();

  RETURN jsonb_build_object(
    'user_id', v_user_id,
    'email', p_owner_email,
    'club_short_name', v_short,
    'club_name', v_club_name,
    'replaced_previous_owner', v_replaced_previous
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_assign_club_owner(text, text) TO authenticated;
