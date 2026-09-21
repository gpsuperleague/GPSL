-- Require primary interest + backup club for auction onboarding readiness.
-- Waiting-list owners are prompted in UI; invited owners cannot enter/bid until both marks exist.
--
-- Apply after:
--   club_auction_interest_backup_20260921.sql
--   owner_preclub_tag_preserve_waiting_list.sql
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.owner_onboarding_has_club_interest_marks(p_owner_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    EXISTS (
      SELECT 1
      FROM public.club_auction_interests i
      WHERE i.owner_id = p_owner_id
        AND i.mark_kind = 'interest'
    )
    AND EXISTS (
      SELECT 1
      FROM public.club_auction_interests i
      WHERE i.owner_id = p_owner_id
        AND i.mark_kind = 'backup'
    );
$$;

COMMENT ON FUNCTION public.owner_onboarding_has_club_interest_marks(uuid) IS
  'True when the owner has both a primary interest and a backup club marked.';

CREATE OR REPLACE FUNCTION public.owner_onboarding_auction_ready(p_owner_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    nullif(btrim(coalesce(r.owner_tag, '')), '') IS NOT NULL
    AND nullif(btrim(coalesce(r.owner_timezone, '')), '') IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.gpsl_owner_registry_availability_slot s
      WHERE s.owner_id = p_owner_id
    )
    AND public.owner_onboarding_has_club_interest_marks(p_owner_id)
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = p_owner_id
    AND r.status = 'awaiting_club_auction';
$$;

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
  v_has_interest boolean;
  v_has_backup boolean;
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

  SELECT EXISTS (
    SELECT 1 FROM public.club_auction_interests i
    WHERE i.owner_id = auth.uid() AND i.mark_kind = 'interest'
  ) INTO v_has_interest;

  SELECT EXISTS (
    SELECT 1 FROM public.club_auction_interests i
    WHERE i.owner_id = auth.uid() AND i.mark_kind = 'backup'
  ) INTO v_has_backup;

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
    'has_club_interest', v_has_interest,
    'has_club_backup', v_has_backup,
    'needs_club_interest', v_preclub AND NOT v_has_interest,
    'needs_club_backup', v_preclub AND NOT v_has_backup,
    'auction_onboarding_ready',
      v_awaiting
      AND v_tag IS NOT NULL
      AND v_tz IS NOT NULL
      AND coalesce(v_slot_count, 0) > 0
      AND v_has_interest
      AND v_has_backup,
    'is_member', v_member,
    'is_archived', coalesce(v_row.status, '') = 'archived',
    'is_caretaker', v_caretaker,
    'waiting_list_position', v_pos,
    'waiting_list_total', coalesce(v_total, 0)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_onboarding_has_club_interest_marks(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_onboarding_auction_ready(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_registry_get_self() TO authenticated;

-- Hard-stop on public place_bid wrapper (max-bid auto still goes via place_bid_internal;
-- UI auction_onboarding_ready already blocks the room until marks exist).
CREATE OR REPLACE FUNCTION public.club_auction_assert_interest_marks(p_owner_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.club_auction_interests i
    WHERE i.owner_id = p_owner_id AND i.mark_kind = 'interest'
  ) THEN
    RAISE EXCEPTION 'Mark your primary club interest on club_database.html before bidding';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.club_auction_interests i
    WHERE i.owner_id = p_owner_id AND i.mark_kind = 'backup'
  ) THEN
    RAISE EXCEPTION 'Mark your backup club on club_database.html before bidding';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_auction_place_bid(
  p_club_short_name text,
  p_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  PERFORM public.club_auction_assert_interest_marks(v_owner);
  v_result := public.club_auction_place_bid_internal(
    v_owner, p_club_short_name, p_amount, false
  );
  PERFORM public.club_auction_resolve_max_bids(upper(trim(p_club_short_name)));
  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_auction_assert_interest_marks(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_place_bid(text, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
