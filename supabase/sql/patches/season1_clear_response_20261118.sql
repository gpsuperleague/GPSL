-- Clear an owner's Season 1 accepted / rejected mark.
-- Queue number, lane, and the invite itself stay.

CREATE OR REPLACE FUNCTION public.admin_season1_invite_clear_response(
  p_owner_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_prev_response text;
  v_prev_status text;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;
  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'owner_id required';
  END IF;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = p_owner_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No registry row for owner %', p_owner_id;
  END IF;

  v_prev_response := v_row.season1_invite_response;
  v_prev_status := v_row.season1_invite_status;

  IF v_prev_response IS NULL
     AND coalesce(v_prev_status, '') NOT IN ('accepted', 'declined') THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already', true,
      'owner_id', p_owner_id,
      'queue_num', v_row.season1_invite_queue_num
    );
  END IF;

  UPDATE public.gpsl_owner_registry
  SET season1_invite_response = NULL,
      season1_invite_responded_at = NULL,
      season1_invite_status = CASE
        WHEN season1_invite_status IN ('accepted', 'declined') THEN NULL
        ELSE season1_invite_status
      END
  WHERE owner_id = p_owner_id
  RETURNING * INTO v_row;

  BEGIN
    PERFORM public.season1_invite_log_event(
      v_row.owner_id,
      'invite_response_cleared',
      v_row.season1_invite_queue_num,
      jsonb_build_object(
        'via', 'admin',
        'actor_id', auth.uid(),
        'prev_status', v_prev_status,
        'prev_response', v_prev_response
      )
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'already', false,
    'owner_id', v_row.owner_id,
    'queue_num', v_row.season1_invite_queue_num,
    'prev_response', v_prev_response,
    'prev_status', v_prev_status
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.admin_season1_invite_clear_response(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_season1_invite_clear_response(uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

SELECT to_regprocedure('public.admin_season1_invite_clear_response(uuid)') IS NOT NULL AS ready;
