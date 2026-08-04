-- =============================================================================
-- admin_owner_remove_from_club: optional waiting-list enqueue
--
-- p_add_to_waiting_list = true  (default) → member + returning waiting list
-- p_add_to_waiting_list = false → vacate club/nation only; not on waiting list
--   (registry status on_break; history kept; can Link club later)
--
-- Also accepts owner_id for the admin remove list UI.
-- Safe re-run.
-- =============================================================================

DROP FUNCTION IF EXISTS public.admin_owner_remove_from_club(text);
DROP FUNCTION IF EXISTS public.admin_owner_remove_from_club(text, boolean);
DROP FUNCTION IF EXISTS public.admin_owner_remove_from_club(text, boolean, uuid);

CREATE OR REPLACE FUNCTION public.admin_owner_remove_from_club(
  p_owner_email text DEFAULT NULL,
  p_add_to_waiting_list boolean DEFAULT true,
  p_owner_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id uuid;
  v_res jsonb;
  v_club text;
  v_club_name text;
  v_tag text;
  v_nation text;
  v_email text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_user_id := p_owner_id;
  IF v_user_id IS NULL AND nullif(btrim(coalesce(p_owner_email, '')), '') IS NOT NULL THEN
    SELECT u.id INTO v_user_id
    FROM auth.users u
    WHERE lower(u.email) = lower(btrim(p_owner_email))
    LIMIT 1;
  END IF;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Owner email or owner_id required';
  END IF;

  IF coalesce(p_add_to_waiting_list, true) THEN
    v_res := public.admin_owner_detach_core(v_user_id, 'member', NULL);
    RETURN v_res || jsonb_build_object('added_to_waiting_list', true);
  END IF;

  -- Vacate only — do not enqueue waiting list
  SELECT c."ShortName", c."Club", nullif(btrim(c.owner), '')
  INTO v_club, v_club_name, v_tag
  FROM public."Clubs" c
  WHERE c.owner_id = v_user_id
  LIMIT 1;

  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Owner is not linked to any club';
  END IF;

  SELECT ion.nation_code INTO v_nation
  FROM public.international_owner_nations ion
  WHERE ion.club_short_name = v_club AND ion.is_active = true
  LIMIT 1;

  IF v_tag IS NULL THEN
    SELECT coalesce(nullif(btrim(r.owner_tag), ''), v_club)
    INTO v_tag
    FROM public.competition_owner_season_ranking r
    WHERE r.owner_id = v_user_id
    ORDER BY r.season_id DESC
    LIMIT 1;
  END IF;

  IF v_tag IS NOT NULL AND upper(btrim(v_tag)) = upper(btrim(v_club)) THEN
    v_tag := NULL;
  END IF;

  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_user_id;

  UPDATE public."Clubs"
  SET owner_id = NULL, owner = NULL
  WHERE owner_id = v_user_id;

  UPDATE public.international_owner_nations
  SET is_active = false, released_at = now()
  WHERE club_short_name = v_club AND is_active = true;

  BEGIN
    UPDATE public.gpsl_club_caretaker
    SET ended_at = now(), ended_by = 'OWNER_DETACHED'
    WHERE club_short_name = v_club AND ended_at IS NULL;
  EXCEPTION WHEN undefined_table THEN
    NULL;
  END;

  INSERT INTO public.gpsl_owner_registry (
    owner_id, status, owner_tag, last_club_short_name, last_nation_code,
    status_note, status_changed_at,
    waiting_list_tier, waiting_list_admin_sort, waiting_list_use_admin_sort,
    returned_to_list_at, absence_note
  )
  VALUES (
    v_user_id, 'on_break', v_tag, v_club, v_nation,
    'Removed from club (not on waiting list)', now(),
    NULL, NULL, false, NULL, NULL
  )
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'on_break',
      owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
      last_club_short_name = excluded.last_club_short_name,
      last_nation_code = excluded.last_nation_code,
      status_note = excluded.status_note,
      waiting_list_tier = NULL,
      waiting_list_admin_sort = NULL,
      waiting_list_use_admin_sort = false,
      returned_to_list_at = NULL,
      absence_note = NULL,
      status_changed_at = now();

  BEGIN
    PERFORM public.waiting_list_leave_list(v_user_id);
  EXCEPTION WHEN undefined_function THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'owner_id', v_user_id,
    'email', v_email,
    'status', 'on_break',
    'club_short_name', v_club,
    'club_name', v_club_name,
    'owner_tag', v_tag,
    'nation_code', v_nation,
    'added_to_waiting_list', false
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_owner_remove_from_club(text, boolean, uuid)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
