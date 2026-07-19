-- =============================================================================
-- Fix stadium_expansion_create_quote
--
-- Bug: stadium_attendance_v2.sql rewrote the RPC to call
-- competition_current_club_short_name() which does not exist.
-- Correct helper is my_club_shortname().
--
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS stadium_new_build_max_capacity integer NOT NULL DEFAULT 55000;

CREATE OR REPLACE FUNCTION public.stadium_expansion_create_quote(p_seats integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_current int;
  v_base int;
  v_max int;
  v_headroom int;
  v_cps numeric;
  v_total numeric;
  v_quote_id bigint;
  v_max_build int;
BEGIN
  v_club := public.my_club_shortname();

  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF coalesce(p_seats, 0) <= 0 THEN
    RAISE EXCEPTION 'Seats must be positive';
  END IF;

  IF to_regprocedure('public.stadium_expansion_sync_progress(text)') IS NOT NULL THEN
    PERFORM public.stadium_expansion_sync_progress(v_club);
  END IF;

  SELECT coalesce(c."Capacity", 0)::int, coalesce(c.base_capacity, c."Capacity", 0)::int
  INTO v_current, v_base
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club not found';
  END IF;

  SELECT coalesce(gs.stadium_new_build_max_capacity, 55000)
  INTO v_max_build
  FROM public.global_settings gs
  WHERE gs.id = 1;

  v_max_build := coalesce(v_max_build, 55000);

  IF v_current > v_max_build THEN
    RAISE EXCEPTION
      'Stadium expansion is only available for clubs with capacity at or below % seats',
      v_max_build;
  END IF;

  v_max := public.stadium_max_capacity(v_base);
  v_headroom := public.stadium_expansion_headroom(v_club);

  IF v_headroom <= 0 THEN
    RAISE EXCEPTION 'Stadium is at maximum capacity — expansion not available';
  END IF;

  IF p_seats > v_headroom THEN
    RAISE EXCEPTION 'Cannot add % seats — only % headroom remaining', p_seats, v_headroom;
  END IF;

  v_cps := public.stadium_expansion_cost_per_seat(v_current);
  v_total := round(p_seats * v_cps, 2);

  INSERT INTO public.stadium_expansion_quotes (
    club_short_name, seats, capacity_at_quote, cost_per_seat, total_cost
  )
  VALUES (v_club, p_seats, v_current, v_cps, v_total)
  RETURNING id INTO v_quote_id;

  RETURN jsonb_build_object(
    'quote_id', v_quote_id,
    'seats', p_seats,
    'cost_per_seat', v_cps,
    'total_cost', v_total,
    'capacity_at_quote', v_current,
    'max_capacity', v_max,
    'headroom', v_headroom,
    'new_build_max_capacity', v_max_build
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.stadium_expansion_create_quote(integer) TO authenticated;

-- Tiny helper so stadium.html can read the build cap without needing the
-- full global_settings_public column (often stripped by later view recreates).
CREATE OR REPLACE FUNCTION public.stadium_expansion_new_build_max()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT gs.stadium_new_build_max_capacity FROM public.global_settings gs WHERE gs.id = 1),
    55000
  )::integer;
$$;

GRANT EXECUTE ON FUNCTION public.stadium_expansion_new_build_max() TO authenticated;
GRANT EXECUTE ON FUNCTION public.stadium_expansion_new_build_max() TO anon;

NOTIFY pgrst, 'reload schema';
