-- =============================================================================
-- Allow admin_owner_archive when the owner has no club
--
-- Symptom:
--   ❌ Owner is not linked to any club
--   (waiting-list / on_break / orphan registry rows cannot be archived)
--
-- Fix:
--   admin_owner_detach_core still requires a club for status=member (remove → WL),
--   but status=archived works without a club: mark registry archived, leave WL,
--   keep last_club / tag / nation from registry when present.
--
-- Safe re-run. Apply in Supabase SQL Editor.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_owner_detach_core(
  p_owner_id uuid,
  p_status text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_club_name text;
  v_tag text;
  v_nation text;
  v_email text;
  v_final_status text;
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_auth_exists boolean := false;
  v_reg public.gpsl_owner_registry%rowtype;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Legacy alias from pre-waiting-list lifecycle
  IF v_status = 'on_break' THEN
    v_status := 'member';
  END IF;

  IF v_status NOT IN ('archived', 'member') THEN
    RAISE EXCEPTION 'Invalid detach status % (use archived or member)', p_status;
  END IF;

  SELECT c."ShortName", c."Club", nullif(btrim(c.owner), '')
  INTO v_club, v_club_name, v_tag
  FROM public."Clubs" c
  WHERE c.owner_id = p_owner_id
  LIMIT 1;

  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = p_owner_id;
  v_auth_exists := FOUND;

  -- No club linked ----------------------------------------------------------
  IF v_club IS NULL THEN
    -- Detach-to-waiting-list still needs a club to vacate
    IF v_status <> 'archived' THEN
      RAISE EXCEPTION 'Owner is not linked to any club';
    END IF;

    IF NOT v_auth_exists THEN
      DELETE FROM public.gpsl_owner_registry WHERE owner_id = p_owner_id;
      RETURN jsonb_build_object(
        'owner_id', p_owner_id,
        'email', NULL,
        'status', 'orphan_cleared',
        'club_short_name', NULL,
        'club_name', NULL,
        'owner_tag', NULL,
        'nation_code', NULL,
        'orphan_auth_user', true,
        'had_club', false
      );
    END IF;

    SELECT * INTO v_reg
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = p_owner_id;

    IF FOUND THEN
      v_tag := coalesce(v_tag, nullif(btrim(v_reg.owner_tag), ''));
      v_club := v_reg.last_club_short_name;
      v_nation := v_reg.last_nation_code;
    END IF;

    IF v_tag IS NULL THEN
      SELECT nullif(btrim(r.owner_tag), '')
      INTO v_tag
      FROM public.competition_owner_season_ranking r
      WHERE r.owner_id = p_owner_id
      ORDER BY r.season_id DESC
      LIMIT 1;
    END IF;

    IF v_club IS NOT NULL THEN
      SELECT c."Club" INTO v_club_name
      FROM public."Clubs" c
      WHERE c."ShortName" = v_club
      LIMIT 1;
    END IF;

    INSERT INTO public.gpsl_owner_registry (
      owner_id, status, owner_tag, last_club_short_name, last_nation_code,
      status_note, status_changed_at
    )
    VALUES (
      p_owner_id, 'archived', v_tag, v_club, v_nation,
      nullif(btrim(p_note), ''), now()
    )
    ON CONFLICT (owner_id) DO UPDATE
    SET status = 'archived',
        owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
        last_club_short_name = coalesce(
          excluded.last_club_short_name,
          gpsl_owner_registry.last_club_short_name
        ),
        last_nation_code = coalesce(
          excluded.last_nation_code,
          gpsl_owner_registry.last_nation_code
        ),
        status_note = coalesce(excluded.status_note, gpsl_owner_registry.status_note),
        waiting_list_tier = NULL,
        waiting_list_admin_sort = NULL,
        waiting_list_use_admin_sort = false,
        returned_to_list_at = NULL,
        absence_note = NULL,
        status_changed_at = now();

    BEGIN
      PERFORM public.waiting_list_leave_list(p_owner_id);
    EXCEPTION WHEN undefined_function THEN
      NULL;
    END;

    RETURN jsonb_build_object(
      'owner_id', p_owner_id,
      'email', v_email,
      'status', 'archived',
      'club_short_name', v_club,
      'club_name', v_club_name,
      'owner_tag', v_tag,
      'nation_code', v_nation,
      'orphan_auth_user', false,
      'had_club', false
    );
  END IF;

  -- Has club — existing detach path ----------------------------------------
  SELECT ion.nation_code INTO v_nation
  FROM public.international_owner_nations ion
  WHERE ion.club_short_name = v_club AND ion.is_active = true
  LIMIT 1;

  IF v_tag IS NULL THEN
    SELECT coalesce(nullif(btrim(r.owner_tag), ''), v_club)
    INTO v_tag
    FROM public.competition_owner_season_ranking r
    WHERE r.owner_id = p_owner_id
    ORDER BY r.season_id DESC
    LIMIT 1;
  END IF;

  IF v_tag IS NOT NULL AND upper(btrim(v_tag)) = upper(btrim(v_club)) THEN
    v_tag := NULL;
  END IF;

  UPDATE public."Clubs"
  SET owner_id = NULL, owner = NULL
  WHERE owner_id = p_owner_id;

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

  IF NOT v_auth_exists THEN
    DELETE FROM public.gpsl_owner_registry WHERE owner_id = p_owner_id;

    RETURN jsonb_build_object(
      'owner_id', p_owner_id,
      'email', NULL,
      'status', 'orphan_cleared',
      'club_short_name', v_club,
      'club_name', v_club_name,
      'owner_tag', v_tag,
      'nation_code', v_nation,
      'orphan_auth_user', true,
      'had_club', true
    );
  END IF;

  v_final_status := v_status;

  IF v_status = 'archived' THEN
    INSERT INTO public.gpsl_owner_registry (
      owner_id, status, owner_tag, last_club_short_name, last_nation_code,
      status_note, status_changed_at
    )
    VALUES (
      p_owner_id, 'archived', v_tag, v_club, v_nation,
      nullif(btrim(p_note), ''), now()
    )
    ON CONFLICT (owner_id) DO UPDATE
    SET status = 'archived',
        owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
        last_club_short_name = excluded.last_club_short_name,
        last_nation_code = excluded.last_nation_code,
        status_note = coalesce(excluded.status_note, gpsl_owner_registry.status_note),
        waiting_list_tier = NULL,
        waiting_list_admin_sort = NULL,
        waiting_list_use_admin_sort = false,
        returned_to_list_at = NULL,
        absence_note = NULL,
        status_changed_at = now();

    BEGIN
      PERFORM public.waiting_list_leave_list(p_owner_id);
    EXCEPTION WHEN undefined_function THEN
      NULL;
    END;
  ELSE
    INSERT INTO public.gpsl_owner_registry (
      owner_id, status, owner_tag, last_club_short_name, last_nation_code,
      status_note, status_changed_at
    )
    VALUES (
      p_owner_id, 'member', v_tag, v_club, v_nation,
      nullif(btrim(p_note), ''), now()
    )
    ON CONFLICT (owner_id) DO UPDATE
    SET owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
        last_club_short_name = excluded.last_club_short_name,
        last_nation_code = excluded.last_nation_code,
        status_note = coalesce(excluded.status_note, gpsl_owner_registry.status_note);

    BEGIN
      PERFORM public.waiting_list_enqueue_returning(p_owner_id);
    EXCEPTION WHEN undefined_function THEN
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'owner_id', p_owner_id,
    'email', v_email,
    'status', v_final_status,
    'club_short_name', v_club,
    'club_name', v_club_name,
    'owner_tag', v_tag,
    'nation_code', v_nation,
    'orphan_auth_user', false,
    'had_club', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_owner_detach_core(uuid, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
