-- =============================================================================
-- owner_registry_get_self: expose season board ticks for owner landing pages
--
-- Matches admin Season owner board checkboxes:
--   confirmed_test_season, confirmed_live_season, needs_club_auction
--
-- Run after owner_preclub_tag_preserve_waiting_list.sql /
-- gpsl_waiting_list_season_confirm.sql. Safe re-run.
-- =============================================================================

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
    'waiting_list_total', coalesce(v_total, 0),
    'confirmed_test_season', coalesce(v_row.confirmed_test_season, false),
    'confirmed_live_season', coalesce(v_row.confirmed_live_season, false)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_registry_get_self() TO authenticated;

NOTIFY pgrst, 'reload schema';
