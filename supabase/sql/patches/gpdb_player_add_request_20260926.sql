-- =============================================================================
-- Member request: add missing player to GPDB by Konami ID
--
-- Flow:
--   1) Member looks up Konami ID (GPDB check via RPC; PESDB via scrape preview)
--   2) If already in GPDB → return card links (no request)
--   3) If on PESDB → member confirms → pending row for admin
--   4) Admin approve → insert free agent; reject → note
--
-- Run in Supabase SQL Editor. Safe re-run.
-- Redeploy edge: gpdb-pesdb-scrape (preview_one_player for members).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpdb_player_add_requests (
  id bigserial PRIMARY KEY,
  konami_id text NOT NULL,
  requested_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
  preview jsonb NOT NULL DEFAULT '{}'::jsonb,
  player_name text,
  admin_note text,
  reviewed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS gpdb_player_add_requests_status_idx
  ON public.gpdb_player_add_requests (status, created_at DESC);

CREATE INDEX IF NOT EXISTS gpdb_player_add_requests_kid_idx
  ON public.gpdb_player_add_requests (konami_id, status);

CREATE UNIQUE INDEX IF NOT EXISTS gpdb_player_add_requests_pending_kid_uidx
  ON public.gpdb_player_add_requests (konami_id)
  WHERE status = 'pending';

ALTER TABLE public.gpdb_player_add_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpdb_player_add_requests_select_own ON public.gpdb_player_add_requests;
CREATE POLICY gpdb_player_add_requests_select_own
  ON public.gpdb_player_add_requests FOR SELECT TO authenticated
  USING (
    requested_by = auth.uid()
    OR public.is_gpsl_admin()
  );

COMMENT ON TABLE public.gpdb_player_add_requests IS
  'Member requests to add a PESDB player missing from GPDB; admin approve inserts free agent.';

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpdb_player_add_normalize_kid(p_kid text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT nullif(btrim(coalesce(p_kid, '')), '');
$$;

CREATE OR REPLACE FUNCTION public.gpdb_player_add_staff_ok()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF public.is_gpsl_admin() THEN
    RETURN true;
  END IF;
  IF to_regprocedure('public.is_gpsl_admin_or_mod()') IS NOT NULL
     AND public.is_gpsl_admin_or_mod() THEN
    RETURN true;
  END IF;
  RETURN false;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Member: lookup in GPDB (and pending queue)
-- ---------------------------------------------------------------------------
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
    p."Contracted_Team" AS contracted_team
  INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_kid
  LIMIT 1;

  IF FOUND THEN
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
    'konami_id', v_kid,
    'needs_pesdb', true,
    'pesdb_url', 'https://pesdb.net/efootball/?id=' || v_kid
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.gpdb_player_add_lookup(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Member: confirm preview → pending request
-- ---------------------------------------------------------------------------
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
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required';
  END IF;
  IF v_kid IS NULL OR v_kid !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'Enter a numeric Konami ID';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Players" p WHERE p."Konami_ID"::text = v_kid
  ) THEN
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

  -- Ensure konami_id on snapshot
  v_preview := v_preview || jsonb_build_object('konami_id', v_kid, 'player_name', v_name);

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
    'status', 'pending'
  );
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'A pending request already exists for Konami ID %', v_kid;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.gpdb_player_add_submit(text, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- Member: my recent requests
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpdb_player_add_my_requests()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'authenticated', false, 'rows', '[]'::jsonb);
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'id', r.id,
      'konami_id', r.konami_id,
      'player_name', r.player_name,
      'status', r.status,
      'admin_note', r.admin_note,
      'created_at', r.created_at,
      'reviewed_at', r.reviewed_at,
      'gpdb_url', 'GPDB.html?player=' || r.konami_id,
      'career_url', 'player_career.html?id=' || r.konami_id
    )
    ORDER BY r.created_at DESC
  ), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT *
    FROM public.gpdb_player_add_requests
    WHERE requested_by = v_uid
    ORDER BY created_at DESC
    LIMIT 20
  ) r;

  RETURN jsonb_build_object('ok', true, 'authenticated', true, 'rows', v_rows);
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.gpdb_player_add_my_requests() TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin: list
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_gpdb_player_add_list(
  p_status text DEFAULT 'pending'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_status text := lower(nullif(btrim(coalesce(p_status, 'pending')), ''));
  v_rows jsonb;
BEGIN
  IF NOT public.gpdb_player_add_staff_ok() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;

  IF v_status IS NULL OR v_status NOT IN ('pending', 'approved', 'rejected', 'cancelled', 'all') THEN
    v_status := 'pending';
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'id', x.id,
      'konami_id', x.konami_id,
      'player_name', x.player_name,
      'status', x.status,
      'preview', x.preview,
      'admin_note', x.admin_note,
      'created_at', x.created_at,
      'reviewed_at', x.reviewed_at,
      'reviewed_by', x.reviewed_by,
      'requester_id', x.requested_by,
      'requester_tag', x.requester_tag,
      'requester_email', x.requester_email,
      'pesdb_url', 'https://pesdb.net/efootball/?id=' || x.konami_id
    )
    ORDER BY x.created_at DESC
  ), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      r.*,
      coalesce(
        nullif(btrim(public.owner_registry_resolve_tag(r.requested_by)), ''),
        '—'
      ) AS requester_tag,
      u.email::text AS requester_email
    FROM public.gpdb_player_add_requests r
    LEFT JOIN auth.users u ON u.id = r.requested_by
    WHERE v_status = 'all' OR r.status = v_status
    ORDER BY r.created_at DESC
    LIMIT 200
  ) x;

  RETURN jsonb_build_object('ok', true, 'status', v_status, 'rows', v_rows);
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_gpdb_player_add_list(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin: reject
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_gpdb_player_add_reject(
  p_id bigint,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row public.gpdb_player_add_requests%ROWTYPE;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
BEGIN
  IF NOT public.gpdb_player_add_staff_ok() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'request id required';
  END IF;

  SELECT * INTO v_row
  FROM public.gpdb_player_add_requests
  WHERE id = p_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;

  IF v_row.status IS DISTINCT FROM 'pending' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already', true,
      'status', v_row.status,
      'id', v_row.id
    );
  END IF;

  UPDATE public.gpdb_player_add_requests
  SET status = 'rejected',
      admin_note = v_note,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'ok', true,
    'id', v_row.id,
    'status', 'rejected',
    'konami_id', v_row.konami_id,
    'player_name', v_row.player_name
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_gpdb_player_add_reject(bigint, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin: approve (marks approved after insert done client-side, or inserts here)
-- Prefer: pass p_row (enriched) → insert free agent + mark approved in one txn
-- ---------------------------------------------------------------------------
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

  IF EXISTS (
    SELECT 1 FROM public."Players" p WHERE p."Konami_ID"::text = v_req.konami_id
  ) THEN
    UPDATE public.gpdb_player_add_requests
    SET status = 'approved',
        admin_note = coalesce(v_note, 'Already in GPDB at approve time'),
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
      'konami_id', v_req.konami_id,
      'gpdb_url', 'GPDB.html?player=' || v_req.konami_id,
      'career_url', 'player_career.html?id=' || v_req.konami_id
    );
  END IF;

  v_payload := coalesce(p_row, v_req.preview, '{}'::jsonb);
  v_payload := v_payload || jsonb_build_object(
    'konami_id', v_req.konami_id,
    'player_name', coalesce(
      nullif(btrim(v_payload->>'player_name'), ''),
      v_req.player_name
    )
  );

  -- Temporarily allow insert via existing admin-only RPC (caller is admin)
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

-- Smoke:
-- SELECT public.gpdb_player_add_lookup('123456');
-- SELECT public.admin_gpdb_player_add_list('pending');
