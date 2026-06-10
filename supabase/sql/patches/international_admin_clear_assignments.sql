-- Admin: clear all nation assignments (reset) without opening selection
-- Run after competition_international.sql (safe re-run)

CREATE OR REPLACE FUNCTION public.international_admin_clear_nation_assignments()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count integer := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.international_selection_windows
  SET is_open = false,
      closes_at = coalesce(closes_at, now())
  WHERE is_open = true;

  UPDATE public.international_owner_nations
  SET is_active = false,
      released_at = now()
  WHERE is_active = true;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

-- Opening selection no longer clears nations (use clear_assignments first)
CREATE OR REPLACE FUNCTION public.international_admin_open_selection(p_phase text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_phase text := coalesce(nullif(btrim(p_phase), ''), 'initial');
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_phase NOT IN ('initial', 'post_world_cup') THEN
    RAISE EXCEPTION 'Invalid phase';
  END IF;

  UPDATE public.international_selection_windows
  SET is_open = false,
      closes_at = coalesce(closes_at, now())
  WHERE is_open = true;

  INSERT INTO public.international_selection_windows (phase, is_open, opens_at, current_pick_rank)
  VALUES (v_phase, true, now(), 1)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_admin_clear_nation_assignments() TO authenticated;

NOTIFY pgrst, 'reload schema';
