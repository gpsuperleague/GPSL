-- =============================================================================
-- Pre-club owner setup: set owner tag without kicking waiting-list members
-- off the list (status must stay member / on_absence).
-- Also expose prep flags on owner_registry_get_self for waiting-list members.
-- Run after owner_onboarding_availability.sql / club_auction_lock_owner_tag.sql
-- =============================================================================

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
  v_existing_tag text;
  v_status text;
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

  SELECT nullif(btrim(r.owner_tag), ''), r.status
  INTO v_existing_tag, v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = auth.uid();

  -- Lock tag once set for club auction invitees (not waiting-list members).
  IF v_existing_tag IS NOT NULL
     AND v_existing_tag IS DISTINCT FROM v_tag
     AND coalesce(v_status, '') = 'awaiting_club_auction' THEN
    RAISE EXCEPTION
      'Your owner tag is locked for the club auction (%). Contact an admin if it must be changed.',
      v_existing_tag;
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
      -- Preserve waiting-list / break / archived; only nudge unknown → auction.
      status = CASE
        WHEN gpsl_owner_registry.status = 'archived' THEN gpsl_owner_registry.status
        WHEN public.waiting_list_on_list_status(coalesce(gpsl_owner_registry.status, ''))
          THEN gpsl_owner_registry.status
        WHEN gpsl_owner_registry.status IN ('on_break', 'active', 'awaiting_club_auction')
          THEN gpsl_owner_registry.status
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
    'locked', coalesce(v_status, '') = 'awaiting_club_auction'
      OR (
        SELECT coalesce(r.status, '') = 'awaiting_club_auction'
        FROM public.gpsl_owner_registry r
        WHERE r.owner_id = auth.uid()
      ),
    'pending_starting_balance', coalesce(
      (SELECT r.pending_starting_balance FROM public.gpsl_owner_registry r WHERE r.owner_id = auth.uid()),
      v_starting
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_registry_set_tag(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.owner_registry_get_self()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_has_club boolean;
  v_caretaker boolean;
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_tag text;
  v_tz text;
  v_slot_count int;
  v_pos int;
  v_total int;
  v_awaiting boolean;
  v_member boolean;
  v_preclub boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('authenticated', false);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c.owner_id = auth.uid()
  ) INTO v_has_club;

  SELECT EXISTS (
    SELECT 1 FROM public.gpsl_club_caretaker ct
    WHERE ct.caretaker_owner_id = auth.uid() AND ct.ended_at IS NULL
  ) INTO v_caretaker;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = auth.uid();

  v_tag := public.owner_registry_resolve_tag(auth.uid());
  v_tz := nullif(btrim(coalesce(v_row.owner_timezone, '')), '');

  SELECT count(*)::int INTO v_slot_count
  FROM public.gpsl_owner_registry_availability_slot s
  WHERE s.owner_id = auth.uid();

  SELECT w.list_position INTO v_pos
  FROM public.waiting_list_ordered_rows(false) w
  WHERE w.owner_id = auth.uid();

  SELECT count(*)::int INTO v_total
  FROM public.waiting_list_ordered_rows(false);

  v_awaiting := NOT v_has_club
    AND coalesce(v_row.status, '') = 'awaiting_club_auction';

  v_member := NOT v_has_club
    AND public.waiting_list_on_list_status(coalesce(v_row.status, ''));

  v_preclub := v_awaiting OR v_member;

  RETURN jsonb_build_object(
    'authenticated', true,
    'has_club', v_has_club,
    'status', v_row.status,
    'owner_tag', v_tag,
    'owner_timezone', v_tz,
    'availability_slot_count', coalesce(v_slot_count, 0),
    'pending_starting_balance', coalesce(v_row.pending_starting_balance, 0),
    'needs_club_auction', v_awaiting,
    'needs_owner_tag', v_preclub AND v_tag IS NULL,
    'needs_onboarding_timezone', v_preclub AND v_tz IS NULL,
    'needs_onboarding_availability', v_preclub AND coalesce(v_slot_count, 0) < 1,
    'auction_onboarding_ready',
      v_awaiting
      AND v_tag IS NOT NULL
      AND v_tz IS NOT NULL
      AND coalesce(v_slot_count, 0) > 0,
    'is_member', v_member,
    'is_archived', coalesce(v_row.status, '') = 'archived',
    'is_caretaker', v_caretaker,
    'waiting_list_position', v_pos,
    'waiting_list_total', coalesce(v_total, 0)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_registry_get_self() TO authenticated;

NOTIFY pgrst, 'reload schema';
