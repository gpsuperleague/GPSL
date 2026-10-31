-- Archived clubless members can return themselves to the waiting list
-- (same outcome as admin_owner_unarchive → returning tier).
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.waiting_list_self_unarchive_to_list()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_has_club boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_on_registry');
  END IF;

  IF coalesce(v_row.status, '') IS DISTINCT FROM 'archived' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_archived',
      'status', v_row.status
    );
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public."Clubs" c
    WHERE c.owner_id = v_uid
      AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
      AND coalesce(c.is_archived, false) = false
  ) INTO v_has_club;

  IF v_has_club THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'still_has_club',
      'detail', 'Leave or transfer your club before rejoining the waiting list.'
    );
  END IF;

  PERFORM public.waiting_list_enqueue_returning(v_uid);

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'member',
    'tier', 'returning',
    'owner_tag', v_row.owner_tag,
    'last_club_short_name', v_row.last_club_short_name,
    'redirect', 'waiting_list.html'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.waiting_list_self_unarchive_to_list()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.waiting_list_self_unarchive_to_list()
  TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT to_regprocedure('public.waiting_list_self_unarchive_to_list()') IS NOT NULL AS rpc_ok;
