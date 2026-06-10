-- =============================================================================
-- Owner detach (short break) vs archive (left GPSL) — keep all season history
-- Run after admin_assign_club_owner.sql, competition_international.sql
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_owner_registry (
  owner_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'on_break'
    CHECK (status IN ('active', 'on_break', 'archived')),
  owner_tag text,
  last_club_short_name text REFERENCES public."Clubs" ("ShortName") ON DELETE SET NULL,
  last_nation_code text REFERENCES public.international_nations (code) ON DELETE SET NULL,
  status_note text,
  status_changed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS gpsl_owner_registry_status_idx
  ON public.gpsl_owner_registry (status);

ALTER TABLE public.gpsl_owner_registry ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_owner_registry_admin ON public.gpsl_owner_registry;
CREATE POLICY gpsl_owner_registry_admin ON public.gpsl_owner_registry
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

-- ---------------------------------------------------------------------------
-- Shared: detach owner from club + nation (history tables unchanged)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_owner_detach_core(
  p_owner_id uuid,
  p_status text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_club_name text;
  v_tag text;
  v_nation text;
  v_email text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_status NOT IN ('on_break', 'archived') THEN
    RAISE EXCEPTION 'Invalid detach status %', p_status;
  END IF;

  SELECT c."ShortName", c."Club", nullif(btrim(c.owner), '')
  INTO v_club, v_club_name, v_tag
  FROM public."Clubs" c
  WHERE c.owner_id = p_owner_id
  LIMIT 1;

  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Owner is not linked to any club';
  END IF;

  SELECT ion.nation_code INTO v_nation
  FROM public.international_owner_nations ion
  WHERE ion.club_short_name = v_club
    AND ion.is_active = true
  LIMIT 1;

  IF v_tag IS NULL THEN
    SELECT coalesce(nullif(btrim(r.owner_tag), ''), v_club)
    INTO v_tag
    FROM public.competition_owner_season_ranking r
    WHERE r.owner_id = p_owner_id
    ORDER BY r.season_id DESC
    LIMIT 1;
  END IF;

  SELECT u.email INTO v_email
  FROM auth.users u
  WHERE u.id = p_owner_id;

  UPDATE public."Clubs"
  SET owner_id = NULL,
      owner = NULL
  WHERE owner_id = p_owner_id;

  UPDATE public.international_owner_nations
  SET is_active = false,
      released_at = now()
  WHERE club_short_name = v_club
    AND is_active = true;

  INSERT INTO public.gpsl_owner_registry (
    owner_id,
    status,
    owner_tag,
    last_club_short_name,
    last_nation_code,
    status_note,
    status_changed_at
  )
  VALUES (
    p_owner_id,
    p_status,
    v_tag,
    v_club,
    v_nation,
    nullif(btrim(p_note), ''),
    now()
  )
  ON CONFLICT (owner_id) DO UPDATE
  SET status = excluded.status,
      owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
      last_club_short_name = excluded.last_club_short_name,
      last_nation_code = excluded.last_nation_code,
      status_note = coalesce(excluded.status_note, gpsl_owner_registry.status_note),
      status_changed_at = now();

  RETURN jsonb_build_object(
    'owner_id', p_owner_id,
    'email', v_email,
    'status', p_status,
    'club_short_name', v_club,
    'club_name', v_club_name,
    'owner_tag', v_tag,
    'nation_code', v_nation
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_owner_remove_from_club(p_owner_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id uuid;
BEGIN
  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = lower(btrim(p_owner_email))
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %', p_owner_email;
  END IF;

  RETURN public.admin_owner_detach_core(v_user_id, 'on_break', NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_owner_archive(
  p_owner_email text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id uuid;
BEGIN
  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = lower(btrim(p_owner_email))
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %', p_owner_email;
  END IF;

  RETURN public.admin_owner_detach_core(v_user_id, 'archived', p_note);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_owner_unarchive(p_owner_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id uuid;
  v_row public.gpsl_owner_registry%rowtype;
  v_email text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = lower(btrim(p_owner_email))
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %', p_owner_email;
  END IF;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = v_user_id;

  IF NOT FOUND OR v_row.status <> 'archived' THEN
    RAISE EXCEPTION 'Owner is not archived';
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_user_id) THEN
    RAISE EXCEPTION 'Owner is still linked to a club';
  END IF;

  UPDATE public.gpsl_owner_registry
  SET status = 'on_break',
      status_note = NULL,
      status_changed_at = now()
  WHERE owner_id = v_user_id;

  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_user_id;

  RETURN jsonb_build_object(
    'owner_id', v_user_id,
    'email', v_email,
    'status', 'on_break',
    'owner_tag', v_row.owner_tag,
    'last_club_short_name', v_row.last_club_short_name
  );
END;
$function$;

-- Linking a club clears break and blocks archived owners
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

-- Show saved tag on rankings/history after detach
CREATE OR REPLACE FUNCTION public.competition_owner_display_name(p_owner_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    nullif(btrim((
      SELECT c.owner
      FROM public."Clubs" c
      WHERE c.owner_id = p_owner_id
        AND nullif(btrim(c.owner), '') IS NOT NULL
      LIMIT 1
    )), ''),
    nullif(btrim((
      SELECT g.owner_tag
      FROM public.gpsl_owner_registry g
      WHERE g.owner_id = p_owner_id
        AND nullif(btrim(g.owner_tag), '') IS NOT NULL
      LIMIT 1
    )), ''),
    nullif(btrim((
      SELECT r.owner_tag
      FROM public.competition_owner_season_ranking r
      WHERE r.owner_id = p_owner_id
        AND nullif(btrim(r.owner_tag), '') IS NOT NULL
      ORDER BY r.season_id DESC
      LIMIT 1
    )), ''),
    'Former owner'
  );
$$;

GRANT EXECUTE ON FUNCTION public.admin_owner_remove_from_club(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_archive(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_unarchive(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_assign_club_owner(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
