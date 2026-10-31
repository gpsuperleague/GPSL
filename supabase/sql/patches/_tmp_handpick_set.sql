CREATE OR REPLACE FUNCTION public.handpick_basket_set(
  p_player_id text,
  p_tagged boolean,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_exists boolean := false;
  v_res jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;
  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;
  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.club_handpick_basket b
    WHERE b.club_short_name = v_club AND b.player_id = v_pid
  ) INTO v_exists;

  IF coalesce(p_tagged, false) THEN
    IF v_exists THEN
      RETURN jsonb_build_object('ok', true, 'tagged', true, 'club', v_club, 'player_id', v_pid);
    END IF;
    v_res := public.handpick_basket_toggle(v_pid, v_club);
    RETURN v_res;
  END IF;

  IF v_exists THEN
    DELETE FROM public.club_handpick_basket
    WHERE club_short_name = v_club AND player_id = v_pid;
  END IF;
  RETURN jsonb_build_object('ok', true, 'tagged', false, 'club', v_club, 'player_id', v_pid);
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_basket_set(text, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_basket_set(text, boolean, text) TO authenticated;
NOTIFY pgrst, 'reload schema';
