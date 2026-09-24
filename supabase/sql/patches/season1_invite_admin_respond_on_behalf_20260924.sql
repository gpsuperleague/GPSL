-- =============================================================================
-- Admin: mark Season 1 accept/decline on behalf (DM responses)
-- =============================================================================
-- For owners who reply by Discord DM instead of the invite link.
-- Admin-only. Allows offered or expired invites; can force-overwrite an
-- existing response if they change their mind via DM.
--
-- Run once in Supabase SQL Editor.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_season1_invite_respond_on_behalf(
  p_owner_id uuid,
  p_decision text,
  p_force boolean DEFAULT false,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_decision text := lower(nullif(btrim(coalesce(p_decision, '')), ''));
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_prev_response text;
  v_prev_status text;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;
  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'owner_id required';
  END IF;

  IF v_decision IS NULL OR v_decision NOT IN ('accept', 'accepted', 'decline', 'declined') THEN
    RAISE EXCEPTION 'decision must be accept or decline';
  END IF;
  v_decision := CASE
    WHEN v_decision IN ('accept', 'accepted') THEN 'accepted'
    ELSE 'declined'
  END;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = p_owner_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No registry row for owner';
  END IF;

  v_prev_response := v_row.season1_invite_response;
  v_prev_status := v_row.season1_invite_status;

  IF v_prev_response IS NOT NULL AND NOT coalesce(p_force, false) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already', true,
      'response', v_prev_response,
      'owner_id', v_row.owner_id,
      'queue_num', v_row.season1_invite_queue_num,
      'season1', public.season1_invite_row_json(v_row),
      'hint', 'Already recorded — pass p_force := true to overwrite'
    );
  END IF;

  IF v_prev_response IS NULL
     AND coalesce(v_prev_status, '') NOT IN ('offered', 'expired', 'queued') THEN
    RAISE EXCEPTION
      'No Season 1 invite to record (status=%). Assign S1# and send invite first.',
      coalesce(v_prev_status, 'null');
  END IF;

  UPDATE public.gpsl_owner_registry
  SET season1_invite_status = v_decision,
      season1_invite_response = v_decision,
      season1_invite_responded_at = now()
  WHERE owner_id = p_owner_id
  RETURNING * INTO v_row;

  IF v_row.season1_invite_inbox_id IS NOT NULL THEN
    UPDATE public.competition_inbox
    SET read_at = coalesce(read_at, now())
    WHERE id = v_row.season1_invite_inbox_id;
  END IF;

  PERFORM public.season1_invite_log_event(
    v_row.owner_id,
    CASE
      WHEN v_decision = 'accepted' THEN 'invite_accepted_on_behalf'
      ELSE 'invite_declined_on_behalf'
    END,
    v_row.season1_invite_queue_num,
    jsonb_build_object(
      'via', 'admin_dm',
      'actor_id', auth.uid(),
      'force', coalesce(p_force, false),
      'prev_status', v_prev_status,
      'prev_response', v_prev_response,
      'note', v_note
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'already', false,
    'response', v_decision,
    'owner_id', v_row.owner_id,
    'queue_num', v_row.season1_invite_queue_num,
    'owner_tag', public.owner_registry_resolve_tag(v_row.owner_id),
    'season1', public.season1_invite_row_json(v_row),
    'on_behalf', true
  );
END;
$fn$;

COMMENT ON FUNCTION public.admin_season1_invite_respond_on_behalf(uuid, text, boolean, text) IS
  'Admin/mod: record Season 1 accept/decline for an owner who replied by DM.';

GRANT EXECUTE ON FUNCTION public.admin_season1_invite_respond_on_behalf(uuid, text, boolean, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
