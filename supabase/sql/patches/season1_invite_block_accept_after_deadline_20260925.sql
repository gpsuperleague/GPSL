-- =============================================================================
-- Season 1 invites: owners cannot accept after the deadline
-- =============================================================================
-- owner_season1_invite_respond already rejects late replies (sets status=expired
-- and raises). This patch updates get_mine so waiting-list / inbox stop showing
-- Accept/Decline once the deadline has passed.
--
-- Admins can still record DM replies via admin_season1_invite_respond_on_behalf.
-- Run in Supabase SQL Editor, then hard-refresh waiting list / inbox.
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

CREATE OR REPLACE FUNCTION public.owner_season1_invite_get_mine()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_expired boolean := false;
  v_pending boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('authenticated', false);
  END IF;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = auth.uid();

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'authenticated', true,
      'has_invite', false,
      'expired', false
    );
  END IF;

  v_expired :=
    coalesce(v_row.season1_invite_status, '') = 'expired'
    OR (
      coalesce(v_row.season1_invite_status, '') = 'offered'
      AND v_row.season1_invite_response IS NULL
      AND v_row.season1_invite_deadline_at IS NOT NULL
      AND v_row.season1_invite_deadline_at < now()
    );

  v_pending :=
    coalesce(v_row.season1_invite_status, '') = 'offered'
    AND v_row.season1_invite_response IS NULL
    AND NOT v_expired;

  RETURN jsonb_build_object(
    'authenticated', true,
    'has_invite', v_pending,
    'expired', v_expired,
    'season1', public.season1_invite_row_json(v_row)
  );
END;
$fn$;

COMMENT ON FUNCTION public.owner_season1_invite_get_mine() IS
  'Current owner Season 1 invite; has_invite is false after the deadline.';

GRANT EXECUTE ON FUNCTION public.owner_season1_invite_get_mine() TO authenticated;

NOTIFY pgrst, 'reload schema';
