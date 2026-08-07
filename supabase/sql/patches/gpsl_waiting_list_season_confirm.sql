-- =============================================================================
-- Waiting list: persistent "confirmed test / live season" ticks
--
-- Two booleans on gpsl_owner_registry (survive leave/rejoin/archive).
-- Admin waiting list UI toggles via admin_waiting_list_set_season_confirmed.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS confirmed_test_season boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS confirmed_live_season boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.gpsl_owner_registry.confirmed_test_season IS
  'Admin tick: owner confirmed for the test season (waiting list).';
COMMENT ON COLUMN public.gpsl_owner_registry.confirmed_live_season IS
  'Admin tick: owner confirmed for the live season (waiting list).';

CREATE OR REPLACE FUNCTION public.waiting_list_admin()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_waiting jsonb;
  v_other jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'position', w.list_position,
      'owner_id', w.owner_id,
      'email', w.email,
      'owner_tag', w.owner_tag,
      'status', w.registry_status,
      'tier', w.waiting_list_tier,
      'account_created_at', w.account_created_at,
      'last_club_short_name', w.last_club_short_name,
      'absence_note', w.absence_note,
      'returned_to_list_at', w.returned_to_list_at,
      'pending_starting_balance', w.pending_starting_balance,
      'use_admin_sort', (
        SELECT r.waiting_list_use_admin_sort
        FROM public.gpsl_owner_registry r
        WHERE r.owner_id = w.owner_id
      ),
      'confirmed_test_season', (
        SELECT coalesce(r.confirmed_test_season, false)
        FROM public.gpsl_owner_registry r
        WHERE r.owner_id = w.owner_id
      ),
      'confirmed_live_season', (
        SELECT coalesce(r.confirmed_live_season, false)
        FROM public.gpsl_owner_registry r
        WHERE r.owner_id = w.owner_id
      )
    )
    ORDER BY w.list_position
  ), '[]'::jsonb)
  INTO v_waiting
  FROM public.waiting_list_ordered_rows(true) w;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'owner_id', r.owner_id,
      'email', u.email,
      'owner_tag', public.owner_registry_resolve_tag(r.owner_id),
      'status', r.status,
      'last_club_short_name', r.last_club_short_name,
      'confirmed_test_season', coalesce(r.confirmed_test_season, false),
      'confirmed_live_season', coalesce(r.confirmed_live_season, false)
    )
    ORDER BY u.email
  ), '[]'::jsonb)
  INTO v_other
  FROM public.gpsl_owner_registry r
  JOIN auth.users u ON u.id = r.owner_id
  WHERE r.status = 'awaiting_club_auction'
    AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id);

  RETURN jsonb_build_object(
    'waiting', v_waiting,
    'invited_to_auction', v_other
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_waiting_list_set_season_confirmed(
  p_owner_id uuid,
  p_which text,
  p_confirmed boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_which text := lower(btrim(coalesce(p_which, '')));
  v_confirmed boolean := coalesce(p_confirmed, false);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'owner_id required';
  END IF;

  IF v_which NOT IN ('test', 'live') THEN
    RAISE EXCEPTION 'p_which must be test or live';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.gpsl_owner_registry r WHERE r.owner_id = p_owner_id
  ) THEN
    RAISE EXCEPTION 'Owner not found in registry';
  END IF;

  IF v_which = 'test' THEN
    UPDATE public.gpsl_owner_registry
    SET confirmed_test_season = v_confirmed
    WHERE owner_id = p_owner_id;
  ELSE
    UPDATE public.gpsl_owner_registry
    SET confirmed_live_season = v_confirmed
    WHERE owner_id = p_owner_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'which', v_which,
    'confirmed', v_confirmed
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.waiting_list_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_waiting_list_set_season_confirmed(uuid, text, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
