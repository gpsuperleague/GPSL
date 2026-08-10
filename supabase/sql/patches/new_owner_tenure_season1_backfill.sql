-- =============================================================================
-- New Owner first-season slots — Season 1 tenure backfill
-- =============================================================================
-- Symptom: Squad action menu has no "New Owner release / transfer list" options.
-- Cause: Clubs.owner_assigned_season_id is NULL for owners assigned before the
-- tenure trigger / mark ran, so club_is_new_owner_release_eligible() is false
-- and the UI hides the actions entirely.
--
-- Also: window is only open in preseason / GPSL June–July / January+TW.
-- If status=active, no live month, and transfer_window_open=false, options stay
-- greyed even when tenure is correct — open the transfer window for testing.
-- =============================================================================

-- Ensure trigger still marks tenure on future owner_id changes
CREATE OR REPLACE FUNCTION public.trg_clubs_owner_change_new_owner_tenure()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
BEGIN
  IF NEW.owner_id IS NULL AND OLD.owner_id IS NOT NULL THEN
    NEW.owner_assigned_season_id := NULL;
    NEW.new_owner_releases_remaining := 0;
    RETURN NEW;
  END IF;

  IF NEW.owner_id IS NOT NULL
    AND NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;

    NEW.owner_assigned_season_id := v_season_id;
    NEW.new_owner_releases_remaining := 3;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS clubs_owner_change_new_owner_tenure ON public."Clubs";
CREATE TRIGGER clubs_owner_change_new_owner_tenure
  BEFORE UPDATE OF owner_id ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_clubs_owner_change_new_owner_tenure();

-- Season 1: every currently owned club is in its first GPSL season with this owner
UPDATE public."Clubs" c
SET owner_assigned_season_id = s.id,
    new_owner_releases_remaining = greatest(coalesce(c.new_owner_releases_remaining, 0), 3)
FROM (
  SELECT id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
) s
WHERE c.owner_id IS NOT NULL
  AND c."ShortName" <> 'FOREIGN'
  AND (
    c.owner_assigned_season_id IS NULL
    OR c.owner_assigned_season_id = s.id
  );

-- Harden admin assign to always mark tenure (finances path may skip re-charge)
CREATE OR REPLACE FUNCTION public.admin_assign_club_owner(
  p_owner_email text,
  p_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(trim(p_owner_email));
  v_short text := upper(trim(p_club_short_name));
  v_user_id uuid;
  v_club_name text;
  v_replaced_previous boolean := false;
  v_registry_status text;
  v_displaced uuid;
  v_old_club text;
  v_tag text;
  v_display_owner text;
  v_pending numeric;
  v_starting numeric;
  v_fin jsonb;
  v_needs_finance boolean := false;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'Owner email is required';
  END IF;

  IF v_short IS NULL OR v_short = '' THEN
    RAISE EXCEPTION 'Club ShortName is required';
  END IF;

  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %', p_owner_email;
  END IF;

  SELECT r.status, r.pending_starting_balance
  INTO v_registry_status, v_pending
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  IF v_registry_status = 'archived' THEN
    RAISE EXCEPTION 'Owner is archived — unarchive before linking to a club';
  END IF;

  SELECT c."Club" INTO v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short;

  IF v_club_name IS NULL THEN
    RAISE EXCEPTION 'Club ShortName % not found', v_short;
  END IF;

  SELECT c.owner_id INTO v_displaced
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short
    AND c.owner_id IS NOT NULL
    AND c.owner_id <> v_user_id
  LIMIT 1;

  IF v_displaced IS NOT NULL THEN
    v_replaced_previous := true;
    PERFORM public.admin_owner_detach_core(v_displaced, 'on_break', 'Displaced by admin club link');
  END IF;

  SELECT c."ShortName"
  INTO v_old_club
  FROM public."Clubs" c
  WHERE c.owner_id = v_user_id
    AND c."ShortName" <> v_short
  LIMIT 1;

  IF v_old_club IS NOT NULL THEN
    PERFORM public.admin_club_vacate(v_old_club);
  END IF;

  SELECT nullif(btrim(r.owner_tag), '')
  INTO v_tag
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  v_display_owner := coalesce(v_tag, split_part(v_email, '@', 1));

  UPDATE public."Clubs"
  SET owner_id = v_user_id,
      owner = v_display_owner
  WHERE "ShortName" = v_short;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Failed to update club %', v_short;
  END IF;

  -- Always (re)mark first-season New Owner slots for this assign
  PERFORM public.club_mark_new_owner_tenure(v_short);

  v_needs_finance :=
    NOT public.club_had_prior_finance_season(
      v_short,
      public.competition_finances_current_season_id()
    )
    AND NOT public.club_has_assignment_infra_purchase(v_short, v_user_id);

  IF v_needs_finance THEN
    v_starting := greatest(
      coalesce(nullif(v_pending, 0), public.club_auction_default_starting_balance()),
      0
    );

    v_fin := public.owner_apply_club_assignment_finances(
      v_short,
      v_user_id,
      v_starting,
      NULL,
      'admin_assign',
      jsonb_build_object(
        'assignment_key', v_user_id::text || ':' || v_short,
        'dup_key', v_user_id::text || ':' || v_short
      ),
      format('Club assigned — %s (%s)', v_club_name, v_short)
    );
  END IF;

  INSERT INTO public.gpsl_owner_registry (owner_id, status, owner_tag, last_club_short_name, status_changed_at)
  VALUES (v_user_id, 'active', v_tag, v_short, now())
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'active',
      owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
      last_club_short_name = v_short,
      pending_starting_balance = CASE
        WHEN v_needs_finance THEN 0
        ELSE gpsl_owner_registry.pending_starting_balance
      END,
      status_note = NULL,
      status_changed_at = now();

  IF to_regprocedure('public.owner_inbox_send_welcome(uuid, text)') IS NOT NULL THEN
    PERFORM public.owner_inbox_send_welcome(v_user_id, v_short);
  END IF;

  RETURN jsonb_build_object(
    'user_id', v_user_id,
    'email', p_owner_email,
    'club_short_name', v_short,
    'club_name', v_club_name,
    'replaced_previous_owner', v_replaced_previous,
    'from_club_short_name', v_old_club,
    'finances_applied', v_needs_finance,
    'finances', v_fin,
    'new_owner_releases_remaining', 3
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_assign_club_owner(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'backfilled', (
    SELECT count(*)::int
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND c."ShortName" <> 'FOREIGN'
      AND c.owner_assigned_season_id = (
        SELECT id FROM public.competition_seasons WHERE is_current = true LIMIT 1
      )
      AND coalesce(c.new_owner_releases_remaining, 0) > 0
  ),
  'window_open', public.club_new_owner_release_window_open(),
  'transfer_window_open', (SELECT transfer_window_open FROM public.global_settings WHERE id = 1)
) AS status;
