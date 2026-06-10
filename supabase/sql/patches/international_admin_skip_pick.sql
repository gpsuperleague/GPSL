-- =============================================================================
-- Admin: skip / nudge current nation-selection picker to the next owner
-- Run after competition_international.sql (safe re-run)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.international_admin_skip_current_pick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_window record;
  v_current smallint;
  v_skipped_club text;
  v_skipped_name text;
  v_next_pick smallint;
  v_remaining integer;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_window
  FROM public.international_selection_windows
  WHERE is_open = true
  ORDER BY id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nation selection is not open';
  END IF;

  v_current := v_window.current_pick_rank;

  SELECT d.club_short_name, d.club_name
  INTO v_skipped_club, v_skipped_name
  FROM public.international_owner_draft_order() d
  WHERE d.pick_order = v_current
  LIMIT 1;

  SELECT min(d.pick_order)::smallint INTO v_next_pick
  FROM public.international_owner_draft_order() d
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.international_owner_nations ion
    WHERE ion.club_short_name = d.club_short_name
      AND ion.is_active = true
  )
  AND d.pick_order > v_current;

  IF v_next_pick IS NULL THEN
    SELECT min(d.pick_order)::smallint INTO v_next_pick
    FROM public.international_owner_draft_order() d
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.international_owner_nations ion
      WHERE ion.club_short_name = d.club_short_name
        AND ion.is_active = true
    );
  END IF;

  SELECT count(*)::integer INTO v_remaining
  FROM public.international_owner_draft_order() d
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.international_owner_nations ion
    WHERE ion.club_short_name = d.club_short_name
      AND ion.is_active = true
  );

  IF v_remaining <= 1 THEN
    RAISE EXCEPTION
      'Only one owner is still waiting for a nation — use Assign nation or close selection';
  END IF;

  IF v_next_pick IS NULL OR v_next_pick = v_current THEN
    RAISE EXCEPTION 'No next picker available to skip to';
  END IF;

  IF v_next_pick >= 61 THEN
    UPDATE public.international_selection_windows
    SET is_open = false,
        closes_at = now()
    WHERE id = v_window.id;
  ELSE
    UPDATE public.international_selection_windows
    SET current_pick_rank = v_next_pick
    WHERE id = v_window.id;
  END IF;

  RETURN jsonb_build_object(
    'skipped_pick', v_current,
    'skipped_club', v_skipped_club,
    'skipped_club_name', v_skipped_name,
    'next_pick', v_next_pick,
    'remaining_without_nation', v_remaining
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_admin_skip_current_pick() TO authenticated;

NOTIFY pgrst, 'reload schema';
