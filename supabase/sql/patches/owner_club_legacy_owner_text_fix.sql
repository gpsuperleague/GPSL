-- =============================================================================
-- Fix stale Clubs.owner text showing wrong owner in admin checklist / manager assign
--
-- Symptom: owner_id is correct (new owner) but UI still shows previous owner's tag
-- Cause: owner_registry_resolve_tag() fell back to legacy Clubs.owner before login email
--        and admin_assign_club_owner kept old owner text via coalesce(v_tag, owner)
--
-- Run once in Supabase SQL Editor.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.owner_registry_resolve_tag(p_owner_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT nullif(btrim(r.owner_tag), '')
      FROM public.gpsl_owner_registry r
      WHERE r.owner_id = p_owner_id
    ),
    (
      SELECT nullif(btrim(x.owner_tag), '')
      FROM public.competition_owner_season_ranking x
      WHERE x.owner_id = p_owner_id
        AND upper(btrim(x.owner_tag)) IS DISTINCT FROM upper(x.club_short_name)
      ORDER BY x.season_id DESC
      LIMIT 1
    ),
    (
      SELECT nullif(split_part(u.email::text, '@', 1), '')
      FROM auth.users u
      WHERE u.id = p_owner_id
    ),
    (
      SELECT nullif(btrim(c.owner), '')
      FROM public."Clubs" c
      WHERE c.owner_id = p_owner_id
        AND upper(btrim(c.owner)) IS DISTINCT FROM upper(c."ShortName")
      LIMIT 1
    )
  );
$$;

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
  v_display_owner text;
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

  SELECT nullif(btrim(r.owner_tag), '')
  INTO v_tag
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  v_display_owner := coalesce(v_tag, split_part(v_email, '@', 1));

  UPDATE public."Clubs"
  SET owner_id = v_user_id,
      owner = v_display_owner
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

-- One-time hygiene: align legacy Clubs.owner with the linked account (registry tag or email prefix)
UPDATE public."Clubs" c
SET owner = coalesce(
  nullif(btrim(r.owner_tag), ''),
  nullif(split_part(u.email::text, '@', 1), '')
)
FROM auth.users u
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = u.id
WHERE c.owner_id = u.id
  AND c.owner_id IS NOT NULL
  AND upper(btrim(coalesce(c.owner, ''))) IS DISTINCT FROM upper(coalesce(nullif(btrim(r.owner_tag), ''), split_part(u.email::text, '@', 1), ''));

GRANT EXECUTE ON FUNCTION public.owner_registry_resolve_tag(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_assign_club_owner(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
