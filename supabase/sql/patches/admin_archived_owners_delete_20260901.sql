-- =============================================================================
-- Archived owners on season board + hard-delete guard
--
-- - admin_list_archived_owners(): tag/email/note for archived registry rows
-- - admin_owner_assert_deletable_archived(uuid): admin-only; must be archived,
--   not linked to a club; returns identity for the edge delete function
--
-- Hard delete of auth.users is done by edge function delete-archived-owner
-- (service role). Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_list_archived_owners()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'owner_id', r.owner_id,
      'email', u.email,
      'owner_tag', coalesce(
        nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''),
        nullif(btrim(r.owner_tag), ''),
        '—'
      ),
      'status', r.status,
      'last_club_short_name', r.last_club_short_name,
      'status_note', r.status_note,
      'status_changed_at', r.status_changed_at,
      'account_created_at', u.created_at
    )
    ORDER BY lower(coalesce(u.email, '')), r.owner_id
  ), '[]'::jsonb)
  INTO v_rows
  FROM public.gpsl_owner_registry r
  JOIN auth.users u ON u.id = r.owner_id
  WHERE r.status = 'archived'
    AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id);

  RETURN jsonb_build_object('archived', v_rows, 'total', jsonb_array_length(v_rows));
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_owner_assert_deletable_archived(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.gpsl_owner_registry%rowtype;
  v_email text;
  v_tag text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'owner_id required';
  END IF;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = p_owner_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Owner not found in registry';
  END IF;

  IF v_row.status IS DISTINCT FROM 'archived' THEN
    RAISE EXCEPTION 'Only archived owners can be deleted from GPSL (status=%)', v_row.status;
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = p_owner_id) THEN
    RAISE EXCEPTION 'Owner is still linked to a club — remove from club / archive first';
  END IF;

  SELECT u.email INTO v_email
  FROM auth.users u
  WHERE u.id = p_owner_id;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'Auth user missing for this owner';
  END IF;

  -- Never allow deleting the primary league admin login via this tool.
  IF lower(v_email) = 'rotavator66@outlook.com' THEN
    RAISE EXCEPTION 'Cannot delete the primary admin account';
  END IF;

  v_tag := coalesce(
    nullif(btrim(public.owner_registry_resolve_tag(p_owner_id)), ''),
    nullif(btrim(v_row.owner_tag), ''),
    null
  );

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'email', v_email,
    'owner_tag', v_tag,
    'last_club_short_name', v_row.last_club_short_name,
    'status', 'archived'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_list_archived_owners() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_assert_deletable_archived(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
