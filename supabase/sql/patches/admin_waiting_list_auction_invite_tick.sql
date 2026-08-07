-- =============================================================================
-- Waiting list: tick invite / uninvite to club auction (by owner_id)
-- Run after gpsl_waiting_list.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_waiting_list_set_auction_invite(
  p_owner_id uuid,
  p_invited boolean,
  p_starting_balance numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text;
  v_starting numeric;
  v_email text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'Owner id required';
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = p_owner_id) THEN
    RAISE EXCEPTION 'Owner already has a club';
  END IF;

  SELECT r.status INTO v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = p_owner_id;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Owner is not in the registry';
  END IF;

  IF v_status = 'archived' THEN
    RAISE EXCEPTION 'Owner is archived';
  END IF;

  SELECT u.email INTO v_email
  FROM auth.users u
  WHERE u.id = p_owner_id;

  IF coalesce(p_invited, false) THEN
    IF v_status = 'awaiting_club_auction' THEN
      RETURN jsonb_build_object(
        'ok', true,
        'owner_id', p_owner_id,
        'email', v_email,
        'status', 'awaiting_club_auction',
        'invited', true,
        'unchanged', true
      );
    END IF;

    IF NOT public.waiting_list_on_list_status(v_status) THEN
      RAISE EXCEPTION 'Owner is not on the waiting list (status %)', v_status;
    END IF;

    v_starting := greatest(
      coalesce(p_starting_balance, public.club_auction_default_starting_balance()),
      0
    );

    UPDATE public.gpsl_owner_registry
    SET status = 'awaiting_club_auction',
        pending_starting_balance = v_starting,
        waiting_list_tier = NULL,
        waiting_list_admin_sort = NULL,
        waiting_list_use_admin_sort = false,
        absence_note = NULL,
        status_changed_at = now()
    WHERE owner_id = p_owner_id;

    RETURN jsonb_build_object(
      'ok', true,
      'owner_id', p_owner_id,
      'email', v_email,
      'status', 'awaiting_club_auction',
      'invited', true,
      'pending_starting_balance', v_starting
    );
  END IF;

  -- Uninvite → back on waiting list
  IF v_status IS DISTINCT FROM 'awaiting_club_auction' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'owner_id', p_owner_id,
      'email', v_email,
      'status', v_status,
      'invited', false,
      'unchanged', true
    );
  END IF;

  -- Prefer returning placement if they had a club before; else rejoin as new.
  IF EXISTS (
    SELECT 1
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = p_owner_id
      AND nullif(btrim(coalesce(r.last_club_short_name, '')), '') IS NOT NULL
  ) THEN
    PERFORM public.waiting_list_enqueue_returning(p_owner_id);
  ELSE
    PERFORM public.waiting_list_enqueue_new(p_owner_id);
  END IF;

  SELECT r.status INTO v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = p_owner_id;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'email', v_email,
    'status', v_status,
    'invited', false
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_waiting_list_set_auction_invite(uuid, boolean, numeric)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
