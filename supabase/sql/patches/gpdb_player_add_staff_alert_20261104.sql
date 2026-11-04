-- =============================================================================
-- Staff alert when an owner requests a GPDB player add or legacy unlock
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpdb_player_add_submit(
  p_konami_id text,
  p_preview jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_kid text := public.gpdb_player_add_normalize_kid(p_konami_id);
  v_uid uuid := auth.uid();
  v_name text;
  v_id bigint;
  v_preview jsonb := coalesce(p_preview, '{}'::jsonb);
  v_open int;
  v_legacy boolean := false;
  v_club text;
  v_club_name text;
  v_owner_tag text;
  v_alert_id bigint;
  v_alert_type text;
  v_title text;
  v_body text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required';
  END IF;
  IF v_kid IS NULL OR v_kid !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'Enter a numeric Konami ID';
  END IF;

  SELECT coalesce(p.pesdb_unavailable, false) INTO v_legacy
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_kid;

  IF FOUND AND NOT v_legacy THEN
    RAISE EXCEPTION 'Player % is already in GPDB', v_kid;
  END IF;

  v_name := nullif(btrim(coalesce(
    v_preview->>'player_name',
    v_preview->>'name',
    ''
  )), '');
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Confirm a PESDB player first (missing name)';
  END IF;

  -- Cap open pending requests per member
  SELECT count(*)::int INTO v_open
  FROM public.gpdb_player_add_requests r
  WHERE r.requested_by = v_uid
    AND r.status = 'pending';
  IF coalesce(v_open, 0) >= 5 THEN
    RAISE EXCEPTION 'You already have % pending add requests — wait for admin review', v_open;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpdb_player_add_requests r
    WHERE r.konami_id = v_kid AND r.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A pending request already exists for Konami ID %', v_kid;
  END IF;

  v_preview := v_preview || jsonb_build_object(
    'konami_id', v_kid,
    'player_name', v_name,
    'legacy_restore', coalesce(v_legacy, false)
  );

  INSERT INTO public.gpdb_player_add_requests (
    konami_id, requested_by, status, preview, player_name
  ) VALUES (
    v_kid, v_uid, 'pending', v_preview, v_name
  )
  RETURNING id INTO v_id;

  -- Context for staff alert
  SELECT c."ShortName", c."Club", nullif(btrim(c.owner), '')
  INTO v_club, v_club_name, v_owner_tag
  FROM public."Clubs" c
  WHERE c.owner_id = v_uid
  LIMIT 1;

  IF v_owner_tag IS NULL THEN
    SELECT nullif(btrim(r.owner_tag), '') INTO v_owner_tag
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = v_uid
    LIMIT 1;
  END IF;

  IF to_regprocedure('public.gpsl_staff_alert_create(text,text,text,text,jsonb,text)') IS NOT NULL THEN
    BEGIN
      IF coalesce(v_legacy, false) THEN
        v_alert_type := 'gpdb_legacy_unlock_request';
        v_title := format('Legacy unlock requested: %s', v_name);
        v_body := format(
          E'%s requested unlocking legacy card %s (Konami %s).\nReview on Admin → GPDB sync → Add player requests.',
          coalesce(v_owner_tag, 'An owner'),
          v_name,
          v_kid
        );
      ELSE
        v_alert_type := 'gpdb_player_add_request';
        v_title := format('GPDB add requested: %s', v_name);
        v_body := format(
          E'%s requested adding %s (Konami %s) to GPDB.\nReview on Admin → GPDB sync → Add player requests.',
          coalesce(v_owner_tag, 'An owner'),
          v_name,
          v_kid
        );
      END IF;

      IF v_club IS NOT NULL THEN
        v_body := v_body || format(
          E'\nClub: %s (%s)',
          coalesce(nullif(btrim(v_club_name), ''), v_club),
          v_club
        );
      END IF;

      v_alert_id := public.gpsl_staff_alert_create(
        v_alert_type,
        v_title,
        v_body,
        'admin_gpdb_sync.html#player-add-requests',
        jsonb_build_object(
          'request_id', v_id,
          'konami_id', v_kid,
          'player_name', v_name,
          'legacy_restore', coalesce(v_legacy, false),
          'owner_id', v_uid,
          'club_short_name', v_club
        ),
        format('gpdb_player_add_request:%s', v_kid)
      );
    EXCEPTION WHEN OTHERS THEN
      v_alert_id := NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_id,
    'konami_id', v_kid,
    'player_name', v_name,
    'legacy_restore', coalesce(v_legacy, false),
    'status', 'pending',
    'staff_alert_id', v_alert_id
  );
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'A pending request already exists for Konami ID %', v_kid;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.gpdb_player_add_submit(text, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
