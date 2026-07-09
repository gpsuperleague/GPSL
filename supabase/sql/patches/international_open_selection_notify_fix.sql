-- =============================================================================
-- Fix: international_admin_open_selection fails with
--   function public.owner_inbox_notify_nation_pick_turn(integer) does not exist
--
-- Cause: literal `1` is integer; notify function is smallint-only.
-- Also: if every club already has a nation (admin override), opening a draft
-- window should not require a pick-turn notify.
--
-- Run once in Supabase SQL Editor, then retry Open selection.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_nation_pick_turn(p_pick_rank smallint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_total integer;
BEGIN
  IF p_pick_rank IS NULL OR p_pick_rank < 1 THEN
    RETURN;
  END IF;

  SELECT count(*)::integer INTO v_total
  FROM public.international_owner_draft_order();

  FOR v_club IN
    SELECT d.club_short_name, d.pick_order
    FROM public.international_owner_draft_order() d
    WHERE d.pick_order = p_pick_rank
      AND d.nation_code IS NULL
  LOOP
    PERFORM public.owner_inbox_send(
      'nation_pick_turn',
      'Your turn — pick a nation',
      format(
        E'Nation selection: you are pick #%s of %s.\nChoose your national team on the Nation selection page.',
        p_pick_rank,
        v_total
      ),
      v_club.club_short_name,
      NULL,
      NULL, NULL, NULL, NULL,
      'nation_select.html',
      'nation_pick:' || p_pick_rank::text || ':' || v_club.club_short_name,
      NULL, NULL
    );
  END LOOP;
END;
$function$;

-- Integer overload so callers passing bare integers (1, v_int) still work
CREATE OR REPLACE FUNCTION public.owner_inbox_notify_nation_pick_turn(p_pick_rank integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.owner_inbox_notify_nation_pick_turn(p_pick_rank::smallint);
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_admin_open_selection(p_phase text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_phase text := coalesce(nullif(btrim(p_phase), ''), 'initial');
  v_club record;
  v_first_pick smallint;
  v_waiting integer := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_phase NOT IN ('initial', 'post_world_cup') THEN
    RAISE EXCEPTION 'Invalid phase';
  END IF;

  UPDATE public.international_selection_windows
  SET is_open = false, closes_at = coalesce(closes_at, now())
  WHERE is_open = true;

  -- First club in draft order that still needs a nation (admin may have
  -- pre-assigned everyone — then there is no one on the clock).
  SELECT coalesce(min(d.pick_order), 1)::smallint INTO v_first_pick
  FROM public.international_owner_draft_order() d
  WHERE d.nation_code IS NULL;

  SELECT count(*)::integer INTO v_waiting
  FROM public.international_owner_draft_order() d
  WHERE d.nation_code IS NULL;

  INSERT INTO public.international_selection_windows (phase, is_open, opens_at, current_pick_rank)
  VALUES (v_phase, true, now(), v_first_pick)
  RETURNING id INTO v_id;

  -- Broadcast "selection open" only if someone still needs to pick
  IF v_waiting > 0
     AND to_regprocedure('public.owner_inbox_send(text,text,text,text,uuid,text,text,text,text,text,text,text,text)') IS NOT NULL THEN
    FOR v_club IN
      SELECT c."ShortName" AS short_name
      FROM public."Clubs" c
      WHERE c.owner_id IS NOT NULL
    LOOP
      BEGIN
        PERFORM public.owner_inbox_send(
          'nation_selection_open',
          'Nation selection is open',
          E'The international nation draft has started. Owners will pick in ranking order — you will receive a message when it is your turn.',
          v_club.short_name,
          NULL,
          NULL, NULL, NULL, NULL,
          'nation_select.html',
          'nation_open:' || v_id::text || ':' || v_club.short_name,
          NULL, NULL
        );
      EXCEPTION
        WHEN OTHERS THEN
          NULL; -- don't block opening selection on inbox failures
      END;
    END LOOP;
  END IF;

  IF v_waiting > 0 THEN
    BEGIN
      PERFORM public.owner_inbox_notify_nation_pick_turn(v_first_pick);
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
  ELSE
    -- Everyone already has a nation (e.g. full admin override) — close immediately
    UPDATE public.international_selection_windows
    SET is_open = false, closes_at = now()
    WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_nation_pick_turn(smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_nation_pick_turn(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_open_selection(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
