-- =============================================================================
-- Admin: move an owner from one club to another (history retained)
-- Run after owner_detach_archive.sql (needs gpsl_owner_registry)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_club_vacate(p_club_short text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(btrim(p_club_short));
BEGIN
  IF v_short IS NULL OR v_short = '' THEN
    RETURN;
  END IF;

  UPDATE public.international_owner_nations
  SET is_active = false,
      released_at = now()
  WHERE club_short_name = v_short
    AND is_active = true;

  UPDATE public."Clubs"
  SET owner_id = NULL,
      owner = NULL
  WHERE "ShortName" = v_short;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_owner_change_club(
  p_owner_email text,
  p_new_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(btrim(p_owner_email));
  v_to text := upper(btrim(p_new_club_short_name));
  v_user_id uuid;
  v_from text;
  v_from_name text;
  v_to_name text;
  v_tag text;
  v_nation_from text;
  v_displaced uuid;
  v_displaced_email text;
  v_registry_status text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'Owner email is required';
  END IF;

  IF v_to IS NULL OR v_to = '' THEN
    RAISE EXCEPTION 'New club ShortName is required';
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
    RAISE EXCEPTION 'Owner is archived — unarchive before changing club';
  END IF;

  SELECT c."ShortName", c."Club", nullif(btrim(c.owner), '')
  INTO v_from, v_from_name, v_tag
  FROM public."Clubs" c
  WHERE c.owner_id = v_user_id
  LIMIT 1;

  IF v_from IS NULL THEN
    RAISE EXCEPTION 'Owner has no club — use Link existing login to club instead';
  END IF;

  IF v_from = v_to THEN
    RAISE EXCEPTION 'Owner is already on club %', v_to;
  END IF;

  SELECT c."Club" INTO v_to_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_to;

  IF v_to_name IS NULL THEN
    RAISE EXCEPTION 'Club ShortName % not found', v_to;
  END IF;

  SELECT ion.nation_code INTO v_nation_from
  FROM public.international_owner_nations ion
  WHERE ion.club_short_name = v_from
    AND ion.is_active = true
  LIMIT 1;

  SELECT c.owner_id INTO v_displaced
  FROM public."Clubs" c
  WHERE c."ShortName" = v_to
    AND c.owner_id IS NOT NULL
    AND c.owner_id <> v_user_id
  LIMIT 1;

  IF v_displaced IS NOT NULL THEN
    PERFORM public.admin_owner_detach_core(
      v_displaced,
      'on_break',
      'Displaced by admin club change'
    );
    SELECT u.email INTO v_displaced_email
    FROM auth.users u
    WHERE u.id = v_displaced;
  END IF;

  PERFORM public.admin_club_vacate(v_from);

  UPDATE public."Clubs"
  SET owner_id = v_user_id,
      owner = coalesce(v_tag, owner)
  WHERE "ShortName" = v_to;

  INSERT INTO public.gpsl_owner_registry (owner_id, status, owner_tag, last_club_short_name, status_changed_at)
  VALUES (v_user_id, 'active', v_tag, v_to, now())
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'active',
      owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
      last_club_short_name = v_to,
      status_note = NULL,
      status_changed_at = now();

  RETURN jsonb_build_object(
    'owner_id', v_user_id,
    'email', p_owner_email,
    'from_club_short_name', v_from,
    'from_club_name', v_from_name,
    'to_club_short_name', v_to,
    'to_club_name', v_to_name,
    'released_nation', v_nation_from,
    'displaced_owner_email', v_displaced_email
  );
END;
$function$;

-- Link / assign: vacate displaced club + release nation on vacated clubs
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
  v_displaced uuid;
  v_old_club text;
  v_tag text;
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

  SELECT c.owner_id INTO v_displaced
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short
    AND c.owner_id IS NOT NULL
    AND c.owner_id <> v_user_id
  LIMIT 1;

  IF v_displaced IS NOT NULL THEN
    v_replaced_previous := true;
    PERFORM public.admin_owner_detach_core(v_displaced, 'on_break', 'Displaced by admin club link');
  END IF;

  SELECT c."ShortName", nullif(btrim(c.owner), '')
  INTO v_old_club, v_tag
  FROM public."Clubs" c
  WHERE c.owner_id = v_user_id
    AND c."ShortName" <> v_short
  LIMIT 1;

  IF v_old_club IS NOT NULL THEN
    PERFORM public.admin_club_vacate(v_old_club);
  END IF;

  UPDATE public."Clubs"
  SET owner_id = v_user_id,
      owner = coalesce(v_tag, owner)
  WHERE "ShortName" = v_short;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Failed to update club %', v_short;
  END IF;

  INSERT INTO public.gpsl_owner_registry (owner_id, status, owner_tag, last_club_short_name, status_changed_at)
  VALUES (v_user_id, 'active', v_tag, v_short, now())
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'active',
      owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
      last_club_short_name = v_short,
      status_note = NULL,
      status_changed_at = now();

  RETURN jsonb_build_object(
    'user_id', v_user_id,
    'email', p_owner_email,
    'club_short_name', v_short,
    'club_name', v_club_name,
    'replaced_previous_owner', v_replaced_previous,
    'from_club_short_name', v_old_club
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_owner_change_club(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_assign_club_owner(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
