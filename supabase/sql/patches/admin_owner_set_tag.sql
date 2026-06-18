-- =============================================================================
-- Admin: set an owner's Discord tag (gpsl_owner_registry + Clubs.owner when linked)
-- Run in Supabase SQL Editor. Admin UI: admin_owners.html → Set owner tag
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_owner_set_tag(
  p_owner_email text,
  p_tag text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(trim(p_owner_email));
  v_user_id uuid;
  v_tag text;
  v_club_short text;
  v_club_name text;
  v_registry_status text;
  v_via text := 'registry';
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'Owner email is required';
  END IF;

  v_tag := nullif(btrim(coalesce(p_tag, '')), '');
  IF v_tag IS NULL THEN
    RAISE EXCEPTION 'Owner tag cannot be empty';
  END IF;
  IF length(v_tag) > 64 THEN
    RAISE EXCEPTION 'Owner tag is too long (max 64 characters)';
  END IF;

  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %', p_owner_email;
  END IF;

  SELECT c."ShortName", c."Club"
  INTO v_club_short, v_club_name
  FROM public."Clubs" c
  WHERE c.owner_id = v_user_id
  LIMIT 1;

  IF v_club_short IS NOT NULL THEN
    UPDATE public."Clubs"
    SET owner = v_tag
    WHERE owner_id = v_user_id;

    v_via := 'club';
  END IF;

  SELECT r.status INTO v_registry_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  INSERT INTO public.gpsl_owner_registry (
    owner_id,
    status,
    owner_tag,
    last_club_short_name,
    status_changed_at
  )
  VALUES (
    v_user_id,
    CASE
      WHEN v_club_short IS NOT NULL THEN 'active'
      WHEN v_registry_status IS NOT NULL THEN v_registry_status
      ELSE 'on_break'
    END,
    v_tag,
    v_club_short,
    now()
  )
  ON CONFLICT (owner_id) DO UPDATE
  SET owner_tag = excluded.owner_tag,
      last_club_short_name = coalesce(v_club_short, gpsl_owner_registry.last_club_short_name),
      status = CASE
        WHEN v_club_short IS NOT NULL AND gpsl_owner_registry.status <> 'archived' THEN 'active'
        ELSE gpsl_owner_registry.status
      END,
      status_changed_at = now();

  IF v_club_short IS NOT NULL THEN
    v_via := 'club_and_registry';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', v_user_id,
    'email', p_owner_email,
    'owner_tag', v_tag,
    'club_short_name', v_club_short,
    'club_name', v_club_name,
    'via', v_via
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_owner_set_tag(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
