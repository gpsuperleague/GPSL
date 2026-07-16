-- =============================================================================
-- Admin: remove member from waiting list (archive, keep auth account)
-- Run in Supabase SQL Editor after gpsl_waiting_list.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_waiting_list_remove(
  p_owner_email text DEFAULT NULL,
  p_owner_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id uuid;
  v_email text;
  v_tag text;
  v_status text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_owner_id IS NOT NULL THEN
    v_user_id := p_owner_id;
  ELSIF nullif(btrim(p_owner_email), '') IS NOT NULL THEN
    SELECT u.id INTO v_user_id
    FROM auth.users u
    WHERE lower(u.email) = lower(btrim(p_owner_email))
    LIMIT 1;
  ELSE
    RAISE EXCEPTION 'Provide owner email or owner id';
  END IF;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user found';
  END IF;

  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_user_id;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_user_id) THEN
    RAISE EXCEPTION 'User still has a club — remove from club first';
  END IF;

  SELECT r.status, coalesce(nullif(btrim(r.owner_tag), ''), nullif(btrim(v_email), ''))
  INTO v_status, v_tag
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Owner is not in the registry';
  END IF;

  IF v_status NOT IN ('member', 'on_absence', 'awaiting_club_auction') THEN
    RAISE EXCEPTION 'Owner is not on the waiting list (status=%)', v_status;
  END IF;

  UPDATE public.gpsl_owner_registry
  SET status = 'archived',
      waiting_list_tier = NULL,
      waiting_list_admin_sort = NULL,
      waiting_list_use_admin_sort = false,
      returned_to_list_at = NULL,
      absence_note = NULL,
      pending_starting_balance = NULL,
      status_note = coalesce(status_note, 'Removed from waiting list'),
      status_changed_at = now()
  WHERE owner_id = v_user_id;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', v_user_id,
    'email', v_email,
    'owner_tag', v_tag,
    'previous_status', v_status,
    'status', 'archived'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_waiting_list_remove(text, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
