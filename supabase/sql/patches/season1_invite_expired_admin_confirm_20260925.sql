-- =============================================================================
-- Season 1 invites: admin can confirm an expired offer (no member response yet)
-- =============================================================================
-- When the 48h deadline has passed and status is still `offered`, the waiting-
-- list UI shows "Expired Invite" with a highlighted row until an admin either:
--   • Confirm S1 expired  → this RPC (status = expired)
--   • Mark accepted/declined (DM) → existing respond_on_behalf
--   • Member already responded → highlight clears on reload
--
-- Run in Supabase SQL Editor, then hard-refresh admin_owners_waiting_list.html.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.season1_invite_row_json(r public.gpsl_owner_registry)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'queue_num', r.season1_invite_queue_num,
    'status', r.season1_invite_status,
    'response', r.season1_invite_response,
    'offered_at', r.season1_invite_offered_at,
    'deadline_at', r.season1_invite_deadline_at,
    'deadline_label', CASE
      WHEN r.season1_invite_deadline_at IS NULL THEN NULL
      ELSE public.season1_invite_format_deadline_uk(r.season1_invite_deadline_at)
    END,
    'deadline_passed',
      r.season1_invite_deadline_at IS NOT NULL
      AND r.season1_invite_deadline_at < now(),
    'responded_at', r.season1_invite_responded_at,
    'offer_count', coalesce(r.season1_invite_offer_count, 0)
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_season1_invite_mark_expired(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row public.gpsl_owner_registry%ROWTYPE;
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

  v_prev_status := v_row.season1_invite_status;

  IF v_row.season1_invite_response IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already', true,
      'response', v_row.season1_invite_response,
      'status', v_row.season1_invite_status,
      'owner_id', v_row.owner_id,
      'queue_num', v_row.season1_invite_queue_num,
      'season1', public.season1_invite_row_json(v_row),
      'hint', 'Member already recorded a response'
    );
  END IF;

  IF coalesce(v_row.season1_invite_status, '') = 'expired' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already', true,
      'status', 'expired',
      'owner_id', v_row.owner_id,
      'queue_num', v_row.season1_invite_queue_num,
      'season1', public.season1_invite_row_json(v_row)
    );
  END IF;

  IF coalesce(v_row.season1_invite_status, '') <> 'offered' THEN
    RAISE EXCEPTION 'No pending Season 1 invite to expire (status=%)',
      coalesce(v_row.season1_invite_status, 'null');
  END IF;

  UPDATE public.gpsl_owner_registry
  SET season1_invite_status = 'expired'
  WHERE owner_id = p_owner_id
  RETURNING * INTO v_row;

  IF v_row.season1_invite_inbox_id IS NOT NULL THEN
    BEGIN
      UPDATE public.competition_inbox
      SET read_at = coalesce(read_at, now())
      WHERE id = v_row.season1_invite_inbox_id;
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
  END IF;

  PERFORM public.season1_invite_log_event(
    v_row.owner_id,
    'invite_expired_confirmed',
    v_row.season1_invite_queue_num,
    jsonb_build_object(
      'via', 'admin_confirm',
      'actor_id', auth.uid(),
      'prev_status', v_prev_status,
      'deadline_at', v_row.season1_invite_deadline_at
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'already', false,
    'status', 'expired',
    'owner_id', v_row.owner_id,
    'queue_num', v_row.season1_invite_queue_num,
    'owner_tag', public.owner_registry_resolve_tag(v_row.owner_id),
    'season1', public.season1_invite_row_json(v_row)
  );
END;
$fn$;

COMMENT ON FUNCTION public.admin_season1_invite_mark_expired(uuid) IS
  'Admin/mod: confirm a Season 1 invite as expired when the deadline passed with no reply.';

GRANT EXECUTE ON FUNCTION public.admin_season1_invite_mark_expired(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
