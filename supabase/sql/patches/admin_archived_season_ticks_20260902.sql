-- =============================================================================
-- Archived owners list: include Test / Live season confirmation flags
-- Safe re-run.
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
      'account_created_at', u.created_at,
      'confirmed_test_season', coalesce(r.confirmed_test_season, false),
      'confirmed_live_season', coalesce(r.confirmed_live_season, false)
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

GRANT EXECUTE ON FUNCTION public.admin_list_archived_owners() TO authenticated;

NOTIFY pgrst, 'reload schema';
