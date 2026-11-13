-- Admin read-only preview of another club's owner screens.
-- Sets the existing transaction guard so my_club_shortname() returns that club
-- for the reads inside this call, then clears it. Writes stay on the signed-in club.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.admin_owner_screen_preview(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_out jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_club IS NULL OR NOT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club
  ) THEN
    RAISE EXCEPTION 'Club % not found', coalesce(v_club, '');
  END IF;

  PERFORM public.gpsl_sim_set_acting_club(v_club);
  BEGIN
    v_out := jsonb_build_object(
      'club', v_club,
      'checklist', public.dashboard_matchday_checklist(),
      'arrangements', public.owner_upcoming_arrangements(),
      'strikes', public.my_club_strike_board(),
      'ready', public.owner_season_ready_checklist(),
      'matchday', public.dashboard_my_matchday_synopsis()
    );
    PERFORM public.gpsl_sim_set_acting_club(NULL);
    RETURN v_out;
  EXCEPTION WHEN OTHERS THEN
    PERFORM public.gpsl_sim_set_acting_club(NULL);
    RAISE;
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_owner_screen_preview(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_owner_screen_preview(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_schedule_preview(p_fixture_id bigint, p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_out jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_club IS NULL OR NOT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club
  ) THEN
    RAISE EXCEPTION 'Club % not found', coalesce(v_club, '');
  END IF;

  PERFORM public.gpsl_sim_set_acting_club(v_club);
  BEGIN
    v_out := public.match_schedule_fixture_context(p_fixture_id);
    PERFORM public.gpsl_sim_set_acting_club(NULL);
    RETURN v_out;
  EXCEPTION WHEN OTHERS THEN
    PERFORM public.gpsl_sim_set_acting_club(NULL);
    RAISE;
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_schedule_preview(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_schedule_preview(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
