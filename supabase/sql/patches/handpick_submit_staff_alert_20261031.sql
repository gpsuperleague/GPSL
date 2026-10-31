-- Staff alert when an owner submits a mid-season handpick wishlist (squad + optional manager).
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.handpick_submit_wishlist(
  p_club_short_name text,
  p_player_ids text[],
  p_manager_id bigint DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_ids text[] := coalesce(p_player_ids, ARRAY[]::text[]);
  v_owner uuid;
  v_handpick boolean;
  v_id bigint;
  v_clean text[] := ARRAY[]::text[];
  v_pid text;
  v_club_name text;
  v_owner_tag text;
  v_mgr_name text;
  v_player_n int := 0;
  v_body text;
  v_alert_id bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RAISE EXCEPTION 'Not allowed for this club';
  END IF;

  SELECT c.owner_id, coalesce(c.handpick_intake, false), c."Club"
  INTO v_owner, v_handpick, v_club_name
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  IF NOT v_handpick THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_in_handpick');
  END IF;

  IF coalesce(array_length(v_ids, 1), 0) = 0 AND p_manager_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'empty_wishlist');
  END IF;

  FOREACH v_pid IN ARRAY v_ids
  LOOP
    v_pid := btrim(coalesce(v_pid, ''));
    IF v_pid = '' THEN CONTINUE; END IF;
    IF NOT (v_pid = ANY (v_clean)) THEN
      v_clean := array_append(v_clean, v_pid);
    END IF;
  END LOOP;

  IF p_manager_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public."Managers" m
    WHERE m.id = p_manager_id
      AND nullif(btrim(coalesce(m.contracted_club, '')), '') IS NULL
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'manager_not_fa');
  END IF;

  UPDATE public.club_handpick_submissions
  SET status = 'withdrawn',
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = 'Replaced by newer wishlist'
  WHERE club_short_name = v_club
    AND status = 'pending';

  INSERT INTO public.club_handpick_submissions (
    club_short_name, owner_id, player_ids, manager_id, note, status
  ) VALUES (
    v_club,
    coalesce(v_owner, auth.uid()),
    v_clean,
    p_manager_id,
    nullif(btrim(p_note), ''),
    'pending'
  )
  RETURNING id INTO v_id;

  v_player_n := coalesce(array_length(v_clean, 1), 0);

  IF p_manager_id IS NOT NULL THEN
    SELECT m.name INTO v_mgr_name
    FROM public."Managers" m
    WHERE m.id = p_manager_id;
  END IF;

  BEGIN
    SELECT nullif(btrim(o.owner_tag), '') INTO v_owner_tag
    FROM public."Owners" o
    WHERE o.id = coalesce(v_owner, auth.uid());
  EXCEPTION WHEN OTHERS THEN
    v_owner_tag := NULL;
  END;

  -- Notify admins / mods on Staff alerts
  IF to_regprocedure('public.gpsl_staff_alert_create(text,text,text,text,jsonb,text)') IS NOT NULL THEN
    BEGIN
      v_body := format(
        E'%s (%s) submitted a mid-season handpick wishlist.\nPlayers: %s\nManager: %s\nOwner: %s\n\nReview and approve on Handpick Squad (or Season owner board).',
        coalesce(nullif(btrim(v_club_name), ''), v_club),
        v_club,
        v_player_n::text,
        coalesce(nullif(btrim(v_mgr_name), ''), CASE WHEN p_manager_id IS NULL THEN '— none —' ELSE ('#' || p_manager_id::text) END),
        coalesce(v_owner_tag, '—')
      );
      IF nullif(btrim(p_note), '') IS NOT NULL THEN
        v_body := v_body || E'\n\nOwner note: ' || btrim(p_note);
      END IF;

      v_alert_id := public.gpsl_staff_alert_create(
        'handpick_wishlist',
        format('Handpick wishlist: %s', v_club),
        v_body,
        format('handpick_squad.html?club=%s', v_club),
        jsonb_build_object(
          'club_short_name', v_club,
          'submission_id', v_id,
          'player_count', v_player_n,
          'manager_id', p_manager_id,
          'owner_id', coalesce(v_owner, auth.uid())
        ),
        format('handpick_wishlist:%s', v_id)
      );
    EXCEPTION WHEN OTHERS THEN
      v_alert_id := NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'submission_id', v_id,
    'club', v_club,
    'player_count', v_player_n,
    'manager_id', p_manager_id,
    'staff_alert_id', v_alert_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_submit_wishlist(text, text[], bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_submit_wishlist(text, text[], bigint, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
