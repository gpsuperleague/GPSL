-- =============================================================================
-- GPDB "request a missing player": legacy cards back on PESDB
--
-- A legacy card (Players.pesdb_unavailable = true) is no longer treated as
-- "already in GPDB". The member checks PESDB; if the card is back they can
-- request an unlock. Admin approve clears the legacy flag (same as
-- gpdb_pesdb_restore_player) and refreshes basic stats from the PESDB preview.
-- The next PESDB sync refreshes everything else (MV, reserve price, etc.).
--
-- Run after gpdb_player_add_request_20260926.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpdb_player_add_lookup(p_konami_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_kid text := public.gpdb_player_add_normalize_kid(p_konami_id);
  v_uid uuid := auth.uid();
  v_player record;
  v_pending record;
  v_legacy boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required';
  END IF;
  IF v_kid IS NULL OR v_kid !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'Enter a numeric Konami ID';
  END IF;

  SELECT
    p."Konami_ID"::text AS konami_id,
    p."Name" AS name,
    p."Position" AS position,
    p."Nation" AS nation,
    p."Age" AS age,
    p."Rating" AS rating,
    p."Contracted_Team" AS contracted_team,
    coalesce(p.pesdb_unavailable, false) AS legacy
  INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_kid
  LIMIT 1;

  IF FOUND AND NOT v_player.legacy THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_in', true,
      'konami_id', v_player.konami_id,
      'name', v_player.name,
      'position', v_player.position,
      'nation', v_player.nation,
      'age', v_player.age,
      'rating', v_player.rating,
      'contracted_team', v_player.contracted_team,
      'gpdb_url', 'GPDB.html?player=' || v_player.konami_id,
      'career_url', 'player_career.html?id=' || v_player.konami_id,
      'pesdb_url', 'https://pesdb.net/efootball/?id=' || v_player.konami_id
    );
  END IF;
  v_legacy := FOUND;

  SELECT r.id, r.status, r.player_name, r.requested_by, r.created_at
  INTO v_pending
  FROM public.gpdb_player_add_requests r
  WHERE r.konami_id = v_kid
    AND r.status = 'pending'
  ORDER BY r.id DESC
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_in', false,
      'pending', true,
      'legacy', v_legacy,
      'konami_id', v_kid,
      'request_id', v_pending.id,
      'player_name', v_pending.player_name,
      'mine', v_pending.requested_by = v_uid,
      'created_at', v_pending.created_at,
      'message', CASE
        WHEN v_pending.requested_by = v_uid THEN
          'You already have a pending request for this player — waiting on admin.'
        ELSE
          'Someone already requested this player — waiting on admin approval.'
      END
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'already_in', false,
    'pending', false,
    'legacy', v_legacy,
    'konami_id', v_kid,
    'name', CASE WHEN v_legacy THEN v_player.name END,
    'contracted_team', CASE WHEN v_legacy THEN v_player.contracted_team END,
    'needs_pesdb', true,
    'pesdb_url', 'https://pesdb.net/efootball/?id=' || v_kid
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.gpdb_player_add_lookup(text) TO authenticated;

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

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_id,
    'konami_id', v_kid,
    'player_name', v_name,
    'legacy_restore', coalesce(v_legacy, false),
    'status', 'pending'
  );
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'A pending request already exists for Konami ID %', v_kid;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.gpdb_player_add_submit(text, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_gpdb_player_add_approve(
  p_id bigint,
  p_row jsonb DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_req public.gpdb_player_add_requests%ROWTYPE;
  v_payload jsonb;
  v_insert jsonb;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_legacy boolean;
BEGIN
  IF NOT public.gpdb_player_add_staff_ok() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'request id required';
  END IF;

  SELECT * INTO v_req
  FROM public.gpdb_player_add_requests
  WHERE id = p_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;

  IF v_req.status IS DISTINCT FROM 'pending' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already', true,
      'status', v_req.status,
      'id', v_req.id
    );
  END IF;

  v_payload := coalesce(p_row, v_req.preview, '{}'::jsonb);

  SELECT coalesce(p.pesdb_unavailable, false) INTO v_legacy
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_req.konami_id;

  IF FOUND THEN
    IF v_legacy THEN
      -- Back on PESDB: unlock the legacy card and refresh basic stats
      UPDATE public."Players" p
      SET
        pesdb_unavailable = false,
        pesdb_unavailable_since = NULL,
        "Name" = coalesce(nullif(btrim(v_payload->>'player_name'), ''), p."Name"),
        "Position" = coalesce(nullif(btrim(v_payload->>'position'), ''), p."Position"),
        "Rating" = coalesce(nullif(btrim(v_payload->>'max_level_rating'), ''), nullif(btrim(v_payload->>'rating'), ''), p."Rating"::text),
        "Playstyle" = coalesce(nullif(btrim(v_payload->>'playing_style'), ''), p."Playstyle")
      WHERE p."Konami_ID"::text = v_req.konami_id;
    END IF;

    UPDATE public.gpdb_player_add_requests
    SET status = 'approved',
        admin_note = coalesce(
          v_note,
          CASE WHEN v_legacy THEN 'Legacy card restored — back on PESDB' ELSE 'Already in GPDB at approve time' END
        ),
        preview = v_payload,
        reviewed_by = auth.uid(),
        reviewed_at = now(),
        updated_at = now()
    WHERE id = p_id
    RETURNING * INTO v_req;

    RETURN jsonb_build_object(
      'ok', true,
      'id', v_req.id,
      'status', 'approved',
      'already_in_gpdb', true,
      'legacy_restored', v_legacy,
      'konami_id', v_req.konami_id,
      'gpdb_url', 'GPDB.html?player=' || v_req.konami_id,
      'career_url', 'player_career.html?id=' || v_req.konami_id
    );
  END IF;

  v_payload := v_payload || jsonb_build_object(
    'konami_id', v_req.konami_id,
    'player_name', coalesce(
      nullif(btrim(v_payload->>'player_name'), ''),
      v_req.player_name
    )
  );

  v_insert := public.gpdb_pesdb_insert_one_free_agent(v_payload);

  UPDATE public.gpdb_player_add_requests
  SET status = 'approved',
      admin_note = v_note,
      preview = v_payload,
      player_name = coalesce(v_insert->>'name', v_req.player_name),
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_req;

  RETURN jsonb_build_object(
    'ok', true,
    'id', v_req.id,
    'status', 'approved',
    'inserted', v_insert,
    'konami_id', v_req.konami_id,
    'gpdb_url', 'GPDB.html?player=' || v_req.konami_id,
    'career_url', 'player_career.html?id=' || v_req.konami_id
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_gpdb_player_add_approve(bigint, jsonb, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
