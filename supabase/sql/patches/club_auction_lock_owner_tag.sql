-- =============================================================================
-- Lock owner tag once set during club auction (awaiting_club_auction, no club)
-- Prevents mid-auction renames confusing the Leader column / settlement.
-- Run after owner_onboarding_club_auction.sql
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

  IF v_existing_tag IS NOT NULL
     AND v_existing_tag IS DISTINCT FROM v_tag
     AND coalesce(v_status, 'awaiting_club_auction') = 'awaiting_club_auction' THEN
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
      status = CASE
        WHEN gpsl_owner_registry.status = 'archived' THEN gpsl_owner_registry.status
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
    'locked', true,
    'pending_starting_balance', coalesce(
      (SELECT r.pending_starting_balance FROM public.gpsl_owner_registry r WHERE r.owner_id = auth.uid()),
      v_starting
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_registry_set_tag(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
