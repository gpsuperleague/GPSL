-- Fix: manager_assign_to_club overload mismatch / "function is not unique".
-- Prefer manager_assign_to_club_dedupe.sql (drops all overloads + recreates canonical).

CREATE OR REPLACE FUNCTION public.admin_testing_assign_manager(
  p_manager_id bigint,
  p_club_short text,
  p_seasons smallint DEFAULT 2,
  p_release_club_manager boolean DEFAULT true,
  p_release_manager_contract boolean DEFAULT false,
  p_waive_fee boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := trim(p_club_short);
  v_mgr public."Managers"%rowtype;
  v_club_mgr_id bigint;
  v_result jsonb;
  v_seasons smallint := greatest(coalesce(p_seasons, 2), 1::smallint);
  v_fee numeric;
  v_buyer_pays boolean := NOT coalesce(p_waive_fee, true);
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club) THEN
    RAISE EXCEPTION 'Club not found: %', v_club;
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  IF v_mgr.contracted_club = v_club THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_assigned', true,
      'manager_id', p_manager_id,
      'manager_name', v_mgr.name,
      'club', v_club
    );
  END IF;

  SELECT m.id INTO v_club_mgr_id
  FROM public."Managers" m
  WHERE m.contracted_club = v_club
  LIMIT 1;

  IF v_club_mgr_id IS NOT NULL AND v_club_mgr_id <> p_manager_id THEN
    IF NOT coalesce(p_release_club_manager, false) THEN
      RAISE EXCEPTION 'Club % already has manager % — enable release current club manager', v_club, v_club_mgr_id;
    END IF;
    PERFORM public.manager_release_from_club(v_club_mgr_id, NULL, 0, 'admin_testing');
  END IF;

  IF v_mgr.contracted_club IS NOT NULL
     AND btrim(v_mgr.contracted_club) <> ''
     AND v_mgr.contracted_club <> v_club THEN
    IF NOT coalesce(p_release_manager_contract, false) THEN
      RAISE EXCEPTION 'Manager is contracted to % — enable release from current club', v_mgr.contracted_club;
    END IF;
    PERFORM public.manager_release_from_club(p_manager_id, NULL, 0, 'admin_testing');
  END IF;

  IF coalesce(p_waive_fee, true) THEN
    v_fee := 0;
  ELSE
    v_fee := NULL;
  END IF;

  v_result := public.manager_assign_to_club(
    p_manager_id,
    v_club,
    v_seasons,
    v_fee,
    v_buyer_pays
  );

  RETURN v_result || jsonb_build_object(
    'manager_name', v_mgr.name,
    'club', v_club
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_testing_assign_manager(
  bigint, text, smallint, boolean, boolean, boolean
) TO authenticated;

NOTIFY pgrst, 'reload schema';
