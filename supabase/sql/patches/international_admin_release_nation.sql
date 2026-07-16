-- Admin: release one club from its national team (does not close selection)
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.international_admin_release_nation(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(coalesce(p_club, ''));
  v_nation text;
  v_nation_name text;
  v_count integer := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club = '' THEN
    RAISE EXCEPTION 'Club is required';
  END IF;

  SELECT ion.nation_code INTO v_nation
  FROM public.international_owner_nations ion
  WHERE ion.club_short_name = v_club
    AND ion.is_active = true
  ORDER BY ion.id DESC
  LIMIT 1;

  IF v_nation IS NULL THEN
    RAISE EXCEPTION '% has no active national team', v_club;
  END IF;

  SELECT n.name INTO v_nation_name
  FROM public.international_nations n
  WHERE n.code = v_nation;

  UPDATE public.international_owner_nations
  SET is_active = false,
      released_at = now()
  WHERE club_short_name = v_club
    AND is_active = true;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'nation_code', v_nation,
    'nation_name', coalesce(v_nation_name, v_nation),
    'released', v_count
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_admin_release_nation(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
