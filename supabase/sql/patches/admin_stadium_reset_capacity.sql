-- =============================================================================
-- Admin testing: reset a club stadium to original (base) capacity
--
-- - Sets Clubs."Capacity" = coalesce(base_capacity, Capacity)
-- - Cancels in-progress expansion orders (no auto-refund — testing tool)
-- - Leaves completed order history rows in place
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_stadium_reset_to_base_capacity(
  p_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_base int;
  v_before int;
  v_after int;
  v_cancelled int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club IS NULL OR v_club = '' OR v_club = 'FOREIGN' THEN
    RAISE EXCEPTION 'Club short name required';
  END IF;

  SELECT
    coalesce(c."Capacity", 0)::int,
    coalesce(c.base_capacity, c."Capacity", 0)::int
  INTO v_before, v_base
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club not found: %', v_club;
  END IF;

  -- Ensure base_capacity is populated for future expansions
  UPDATE public."Clubs" c
  SET base_capacity = v_base
  WHERE c."ShortName" = v_club
    AND c.base_capacity IS NULL;

  IF to_regclass('public.stadium_expansion_orders') IS NOT NULL THEN
    UPDATE public.stadium_expansion_orders o
    SET
      status = 'cancelled',
      cancelled_at = coalesce(o.cancelled_at, now()),
      goahead_decision = coalesce(o.goahead_decision, 'cancel')
    WHERE o.club_short_name = v_club
      AND o.status IN ('pre_build', 'awaiting_goahead', 'building');

    GET DIAGNOSTICS v_cancelled = ROW_COUNT;
  END IF;

  UPDATE public."Clubs" c
  SET "Capacity" = v_base
  WHERE c."ShortName" = v_club;

  SELECT coalesce(c."Capacity", 0)::int
  INTO v_after
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF to_regprocedure('public.competition_stadium_sync_fill_state(text, bigint)') IS NOT NULL THEN
    BEGIN
      PERFORM public.competition_stadium_sync_fill_state(v_club, NULL);
    EXCEPTION
      WHEN OTHERS THEN
        NULL; -- fill sync is best-effort for testing
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'capacity_before', v_before,
    'base_capacity', v_base,
    'capacity_after', v_after,
    'orders_cancelled', v_cancelled
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_stadium_reset_to_base_capacity(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
