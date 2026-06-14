-- =============================================================================
-- Owner onboarding — awaiting club auction (no club yet)
-- Phase 1: registry status + owner tag + £600m pending balance
-- Phase 2 (future): club auction UI + settlement → Clubs.owner_id + Club_Finances
-- =============================================================================

ALTER TABLE public.gpsl_owner_registry
  DROP CONSTRAINT IF EXISTS gpsl_owner_registry_status_check;

ALTER TABLE public.gpsl_owner_registry
  ADD CONSTRAINT gpsl_owner_registry_status_check
  CHECK (status IN ('active', 'on_break', 'archived', 'awaiting_club_auction'));

ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS pending_starting_balance numeric(14, 2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.gpsl_owner_registry.pending_starting_balance IS
  'Starting budget (e.g. 600m) held until club auction win; then applied to Club_Finances.balance.';

-- Owner reads own registry row (tag + status only)
DROP POLICY IF EXISTS gpsl_owner_registry_self_select ON public.gpsl_owner_registry;
CREATE POLICY gpsl_owner_registry_self_select ON public.gpsl_owner_registry
  FOR SELECT TO authenticated
  USING (owner_id = auth.uid());

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
      ORDER BY x.season_id DESC
      LIMIT 1
    ),
    (
      SELECT nullif(btrim(c.owner), '')
      FROM public."Clubs" c
      WHERE c.owner_id = p_owner_id
      LIMIT 1
    )
  );
$$;

CREATE OR REPLACE FUNCTION public.owner_registry_get_self()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.gpsl_owner_registry%rowtype;
  v_has_club boolean;
  v_tag text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('authenticated', false);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c.owner_id = auth.uid()
  ) INTO v_has_club;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = auth.uid();

  v_tag := public.owner_registry_resolve_tag(auth.uid());

  RETURN jsonb_build_object(
    'authenticated', true,
    'has_club', v_has_club,
    'status', v_row.status,
    'owner_tag', v_tag,
    'pending_starting_balance', coalesce(v_row.pending_starting_balance, 0),
    'needs_club_auction',
      NOT v_has_club
      AND coalesce(v_row.status, 'awaiting_club_auction') = 'awaiting_club_auction'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_registry_set_tag(p_tag text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tag text;
  v_has_club boolean;
  v_starting numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_starting := public.club_auction_default_starting_balance();

  v_tag := nullif(btrim(coalesce(p_tag, '')), '');
  IF v_tag IS NULL THEN
    RAISE EXCEPTION 'Owner tag cannot be empty';
  END IF;
  IF length(v_tag) > 64 THEN
    RAISE EXCEPTION 'Owner tag is too long (max 64 characters)';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c.owner_id = auth.uid()
  ) INTO v_has_club;

  IF v_has_club THEN
    PERFORM public.club_owner_set_tag(v_tag);
    RETURN jsonb_build_object('ok', true, 'owner_tag', v_tag, 'via', 'club');
  END IF;

  INSERT INTO public.gpsl_owner_registry (
    owner_id,
    status,
    owner_tag,
    pending_starting_balance,
    status_changed_at
  )
  VALUES (
    auth.uid(),
    'awaiting_club_auction',
    v_tag,
    v_starting,
    now()
  )
  ON CONFLICT (owner_id) DO UPDATE
  SET owner_tag = excluded.owner_tag,
      status = CASE
        WHEN gpsl_owner_registry.status = 'archived' THEN gpsl_owner_registry.status
        ELSE 'awaiting_club_auction'
      END,
      pending_starting_balance = CASE
        WHEN coalesce(gpsl_owner_registry.pending_starting_balance, 0) > 0
        THEN gpsl_owner_registry.pending_starting_balance
        ELSE v_starting
      END,
      status_changed_at = now()
  WHERE gpsl_owner_registry.status <> 'archived';

  RETURN jsonb_build_object(
    'ok', true,
    'owner_tag', v_tag,
    'via', 'registry',
    'pending_starting_balance', coalesce(
      (SELECT r.pending_starting_balance FROM public.gpsl_owner_registry r WHERE r.owner_id = auth.uid()),
      v_starting
    )
  );
END;
$function$;

-- Admin: register a new login for club auction (no club yet)
CREATE OR REPLACE FUNCTION public.admin_owner_register_for_club_auction(
  p_owner_email text,
  p_starting_balance numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(trim(p_owner_email));
  v_user_id uuid;
  v_starting numeric;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_starting := greatest(coalesce(p_starting_balance, public.club_auction_default_starting_balance()), 0);

  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %', p_owner_email;
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_user_id) THEN
    RAISE EXCEPTION 'Owner already has a club';
  END IF;

  INSERT INTO public.gpsl_owner_registry (
    owner_id,
    status,
    pending_starting_balance,
    status_changed_at
  )
  VALUES (
    v_user_id,
    'awaiting_club_auction',
    v_starting,
    now()
  )
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'awaiting_club_auction',
      pending_starting_balance = v_starting,
      status_changed_at = now()
  WHERE gpsl_owner_registry.status <> 'archived';

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', v_user_id,
    'email', p_owner_email,
    'status', 'awaiting_club_auction',
    'pending_starting_balance', v_starting
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_registry_get_self() TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_registry_set_tag(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_registry_resolve_tag(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_register_for_club_auction(text, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
