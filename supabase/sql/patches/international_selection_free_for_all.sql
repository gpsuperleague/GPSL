-- =============================================================================
-- Nation selection: free-for-all mode (anyone still without a nation can pick)
--
-- Admin: Open free-for-all on admin_international.html
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.international_selection_windows
  ADD COLUMN IF NOT EXISTS pick_mode text NOT NULL DEFAULT 'ordered';

DO $$
BEGIN
  ALTER TABLE public.international_selection_windows
    DROP CONSTRAINT IF EXISTS international_selection_windows_pick_mode_check;
  ALTER TABLE public.international_selection_windows
    ADD CONSTRAINT international_selection_windows_pick_mode_check
    CHECK (pick_mode IN ('ordered', 'free_for_all'));
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

COMMENT ON COLUMN public.international_selection_windows.pick_mode IS
  'ordered = draft pick order; free_for_all = any club without a nation may claim.';

-- Drop 1-arg overload if present so (text, text DEFAULT) is clean
DROP FUNCTION IF EXISTS public.international_admin_open_selection(text);

CREATE OR REPLACE FUNCTION public.international_admin_open_selection(
  p_phase text DEFAULT 'initial',
  p_pick_mode text DEFAULT 'ordered'
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_phase text := coalesce(nullif(btrim(p_phase), ''), 'initial');
  v_mode text := lower(coalesce(nullif(btrim(p_pick_mode), ''), 'ordered'));
  v_club record;
  v_first_pick smallint;
  v_waiting integer := 0;
  v_title text;
  v_body text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_phase NOT IN ('initial', 'post_world_cup') THEN
    RAISE EXCEPTION 'Invalid phase';
  END IF;

  IF v_mode NOT IN ('ordered', 'free_for_all') THEN
    RAISE EXCEPTION 'Invalid pick_mode (ordered | free_for_all)';
  END IF;

  UPDATE public.international_selection_windows
  SET is_open = false, closes_at = coalesce(closes_at, now())
  WHERE is_open = true;

  SELECT coalesce(min(d.pick_order), 1)::smallint INTO v_first_pick
  FROM public.international_owner_draft_order() d
  WHERE d.nation_code IS NULL;

  SELECT count(*)::integer INTO v_waiting
  FROM public.international_owner_draft_order() d
  WHERE d.nation_code IS NULL;

  INSERT INTO public.international_selection_windows (
    phase, is_open, opens_at, current_pick_rank, pick_mode
  )
  VALUES (v_phase, true, now(), v_first_pick, v_mode)
  RETURNING id INTO v_id;

  IF v_mode = 'free_for_all' THEN
    v_title := 'Nation selection is open (free for all)';
    v_body := E'Nation selection is open as a free-for-all.\n\n'
      || E'Any owner who still does not have a national team can claim an available nation now on Nation selection — no waiting for pick order.';
  ELSE
    v_title := 'Nation selection is open';
    v_body := E'The international nation draft has started. Owners will pick in ranking order — you will receive a message when it is your turn.';
  END IF;

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
          v_title,
          v_body,
          v_club.short_name,
          NULL,
          NULL, NULL, NULL, NULL,
          'nation_select.html',
          'nation_open:' || v_id::text || ':' || v_mode || ':' || v_club.short_name,
          NULL, NULL
        );
      EXCEPTION
        WHEN OTHERS THEN
          NULL;
      END;
    END LOOP;
  END IF;

  IF v_waiting > 0 AND v_mode = 'ordered' THEN
    BEGIN
      PERFORM public.owner_inbox_notify_nation_pick_turn(v_first_pick);
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
  ELSIF v_waiting = 0 THEN
    UPDATE public.international_selection_windows
    SET is_open = false, closes_at = now()
    WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_admin_open_selection(text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.international_claim_nation(p_nation_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_window record;
  v_my_pick smallint;
  v_current_pick smallint;
  v_nation text := btrim(upper(p_nation_code));
  v_cycle_id bigint;
  v_next_pick smallint;
  v_nation_name text;
  v_mode text;
  v_has_nation boolean;
  v_waiting integer;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_window
  FROM public.international_selection_windows
  WHERE is_open = true
  ORDER BY id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nation selection is not open';
  END IF;

  v_mode := coalesce(v_window.pick_mode, 'ordered');

  SELECT pick_order INTO v_my_pick
  FROM public.international_owner_draft_order()
  WHERE club_short_name = v_club;

  IF v_my_pick IS NULL THEN
    RAISE EXCEPTION 'Your club is not in the owner draft order';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.international_owner_nations ion
    WHERE ion.club_short_name = v_club AND ion.is_active = true
  ) INTO v_has_nation;

  IF v_mode = 'free_for_all' THEN
    IF v_has_nation THEN
      RAISE EXCEPTION 'You already have a national team — free-for-all is only for clubs still without a nation';
    END IF;
  ELSE
    v_current_pick := v_window.current_pick_rank;
    IF v_my_pick <> v_current_pick THEN
      RAISE EXCEPTION 'Not your pick yet (currently pick #% — you are #%).', v_current_pick, v_my_pick;
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.international_nations n
    WHERE n.code = v_nation AND n.active = true
  ) THEN
    RAISE EXCEPTION 'Nation not found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.international_owner_nations ion
    WHERE ion.nation_code = v_nation AND ion.is_active = true
  ) THEN
    RAISE EXCEPTION 'Nation already taken';
  END IF;

  IF to_regprocedure('public.international_nation_pool_is_selectable(text)') IS NOT NULL
     AND NOT public.international_nation_pool_is_selectable(v_nation) THEN
    RAISE EXCEPTION 'This nation cannot be selected — GPDB pool too small for a squad or GPSL club';
  END IF;

  SELECT n.name INTO v_nation_name FROM public.international_nations n WHERE n.code = v_nation;

  SELECT id INTO v_cycle_id FROM public.international_wc_cycles ORDER BY cycle_no DESC LIMIT 1;

  UPDATE public.international_owner_nations
  SET is_active = false, released_at = now()
  WHERE club_short_name = v_club AND is_active = true;

  INSERT INTO public.international_owner_nations (
    club_short_name, nation_code, cycle_id, selection_phase, is_active, locked_until_cycle_id
  )
  VALUES (v_club, v_nation, v_cycle_id, v_window.phase, true, v_cycle_id);

  SELECT count(*)::integer INTO v_waiting
  FROM public.international_owner_draft_order() d
  WHERE NOT EXISTS (
    SELECT 1 FROM public.international_owner_nations ion
    WHERE ion.club_short_name = d.club_short_name AND ion.is_active = true
  );

  SELECT coalesce(min(pick_order), 61)::smallint INTO v_next_pick
  FROM public.international_owner_draft_order() d
  WHERE NOT EXISTS (
    SELECT 1 FROM public.international_owner_nations ion
    WHERE ion.club_short_name = d.club_short_name AND ion.is_active = true
  );

  IF v_waiting = 0 OR v_next_pick >= 61 THEN
    UPDATE public.international_selection_windows
    SET is_open = false, closes_at = now()
    WHERE id = v_window.id;
  ELSIF v_mode = 'ordered' THEN
    UPDATE public.international_selection_windows
    SET current_pick_rank = v_next_pick
    WHERE id = v_window.id;
    IF to_regprocedure('public.owner_inbox_notify_nation_pick_turn(smallint)') IS NOT NULL THEN
      PERFORM public.owner_inbox_notify_nation_pick_turn(v_next_pick);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'club', v_club,
    'nation', v_nation,
    'nation_name', v_nation_name,
    'pick', v_my_pick,
    'next_pick', v_next_pick,
    'pick_mode', v_mode,
    'waiting', v_waiting
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_claim_nation(text) TO authenticated;

-- Skip only makes sense in ordered draft mode
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

  IF coalesce(v_window.pick_mode, 'ordered') = 'free_for_all' THEN
    RAISE EXCEPTION 'Skip pick is not used in free-for-all mode — owners without a nation can claim anytime';
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

DROP VIEW IF EXISTS public.international_selection_public;
CREATE VIEW public.international_selection_public
WITH (security_invoker = false)
AS
SELECT
  w.id,
  w.phase,
  w.is_open,
  w.opens_at,
  w.closes_at,
  w.current_pick_rank,
  coalesce(w.pick_mode, 'ordered') AS pick_mode,
  (
    SELECT d.club_short_name
    FROM public.international_owner_draft_order() d
    WHERE d.pick_order = w.current_pick_rank
    LIMIT 1
  ) AS current_pick_club,
  (
    SELECT count(*)::integer
    FROM public.international_owner_nations ion
    WHERE ion.is_active = true
  ) AS nations_assigned,
  (
    SELECT count(*)::integer
    FROM public.international_owner_draft_order() d
    WHERE d.nation_code IS NULL
  ) AS waiting_count
FROM public.international_selection_windows w
WHERE w.is_open = true
ORDER BY w.id DESC
LIMIT 1;

GRANT SELECT ON public.international_selection_public TO authenticated;

NOTIFY pgrst, 'reload schema';
