-- Qualifying path for new accounts.
-- Accounts created before required_from keep the old waiting-list route.
-- A new account sets a tag and availability, logs five practice friendlies,
-- and has one video approved before they join the waiting list.
-- A club is still an admin decision: auction invite, or one named handpick club for 7 days.

CREATE TABLE IF NOT EXISTS public.gpsl_qualifying_settings (
  id int PRIMARY KEY CHECK (id = 1),
  required_from timestamptz NOT NULL
);

INSERT INTO public.gpsl_qualifying_settings (id, required_from)
VALUES (1, now())
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.gpsl_qualifying_friendly (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  played_on date NOT NULL,
  opponent text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gpsl_qualifying_friendly_opponent_len CHECK (char_length(opponent) BETWEEN 2 AND 80)
);

CREATE INDEX IF NOT EXISTS gpsl_qualifying_friendly_owner_idx
  ON public.gpsl_qualifying_friendly (owner_id, played_on);

CREATE TABLE IF NOT EXISTS public.gpsl_qualifying_video (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  upload_code text NOT NULL,
  status text NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted', 'approved', 'rejected')),
  checklist jsonb,
  review_note text,
  reviewed_at timestamptz,
  reviewed_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS gpsl_qualifying_video_owner_idx
  ON public.gpsl_qualifying_video (owner_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS gpsl_qualifying_video_one_open_idx
  ON public.gpsl_qualifying_video (owner_id)
  WHERE status = 'submitted';

CREATE TABLE IF NOT EXISTS public.gpsl_qualifying_grant (
  owner_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  handpick_club text,
  handpick_due_at timestamptz,
  granted_by uuid,
  granted_at timestamptz
);

ALTER TABLE public.gpsl_qualifying_friendly ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpsl_qualifying_video ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpsl_qualifying_grant ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpsl_qualifying_settings ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.qualifying_checklist_labels()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'pa3', 'PA3 or PA4',
    'advanced', 'Advanced skill only',
    'matchroom', 'Match-room settings shown',
    'manager', 'Manager shown',
    'subtactic', 'Subtactic shown',
    'squad', 'Squad shown',
    'no_individual', 'No individual player instructions',
    'no_drag', 'No dragging players on the formation',
    'recording', 'Recording runs from the settings through to the ratings'
  );
$$;

CREATE OR REPLACE FUNCTION public.owner_qualifying_is_subject(p_owner_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM auth.users u
    JOIN public.gpsl_qualifying_settings s ON s.id = 1
    WHERE u.id = p_owner_id
      AND u.created_at >= s.required_from
  );
$$;

CREATE OR REPLACE FUNCTION public.owner_qualifying_upload_code(p_owner_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT 'QUAL-' || upper(substr(replace(p_owner_id::text, '-', ''), 1, 8))
    || '-' || (
      1 + (
        SELECT count(*)::int
        FROM public.gpsl_qualifying_video v
        WHERE v.owner_id = p_owner_id
          AND v.status = 'rejected'
      )
    )::text;
$$;

CREATE OR REPLACE FUNCTION public.owner_qualifying_claim_block(
  p_owner_id uuid,
  p_club text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_club text;
  v_due timestamptz;
BEGIN
  IF NOT public.owner_qualifying_is_subject(p_owner_id) THEN
    RETURN NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.gpsl_qualifying_video v
    WHERE v.owner_id = p_owner_id
      AND v.status = 'approved'
  ) THEN
    RETURN 'Finish the qualifying steps and have the video approved before taking a club.';
  END IF;

  UPDATE public.gpsl_qualifying_grant g
  SET handpick_club = NULL,
      handpick_due_at = NULL
  WHERE g.owner_id = p_owner_id
    AND g.handpick_due_at IS NOT NULL
    AND g.handpick_due_at < now();

  SELECT upper(btrim(g.handpick_club)), g.handpick_due_at
  INTO v_club, v_due
  FROM public.gpsl_qualifying_grant g
  WHERE g.owner_id = p_owner_id;

  IF v_club IS NULL OR v_club = '' THEN
    RETURN 'An admin names the one club you can handpick. Until then you stay on the waiting list.';
  END IF;

  IF upper(btrim(coalesce(p_club, ''))) IS DISTINCT FROM v_club THEN
    RETURN format('You can handpick %s only.', v_club);
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_qualifying_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_subject boolean;
  v_tag text;
  v_slots int;
  v_friendlies jsonb;
  v_friendly_count int;
  v_video jsonb;
  v_approved boolean;
  v_grant_club text;
  v_grant_due timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('authenticated', false);
  END IF;

  v_subject := public.owner_qualifying_is_subject(v_uid);
  v_tag := nullif(btrim(coalesce(public.owner_registry_resolve_tag(v_uid), '')), '');

  SELECT count(*)::int INTO v_slots
  FROM public.gpsl_owner_registry_availability_slot s
  WHERE s.owner_id = v_uid;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'id', f.id,
      'played_on', f.played_on,
      'opponent', f.opponent
    )
    ORDER BY f.played_on, f.id
  ), '[]'::jsonb), count(*)::int
  INTO v_friendlies, v_friendly_count
  FROM public.gpsl_qualifying_friendly f
  WHERE f.owner_id = v_uid;

  SELECT jsonb_build_object(
    'id', v.id,
    'status', v.status,
    'upload_code', v.upload_code,
    'review_note', v.review_note,
    'checklist', v.checklist,
    'created_at', v.created_at
  )
  INTO v_video
  FROM public.gpsl_qualifying_video v
  WHERE v.owner_id = v_uid
  ORDER BY v.created_at DESC
  LIMIT 1;

  v_approved := coalesce(v_video->>'status', '') = 'approved';

  SELECT upper(btrim(g.handpick_club)), g.handpick_due_at
  INTO v_grant_club, v_grant_due
  FROM public.gpsl_qualifying_grant g
  WHERE g.owner_id = v_uid
    AND (g.handpick_due_at IS NULL OR g.handpick_due_at >= now());

  RETURN jsonb_build_object(
    'authenticated', true,
    'subject', v_subject,
    'tag_done', v_tag IS NOT NULL,
    'owner_tag', v_tag,
    'availability_done', coalesce(v_slots, 0) > 0,
    'availability_slots', coalesce(v_slots, 0),
    'step1_done', v_tag IS NOT NULL AND coalesce(v_slots, 0) > 0,
    'friendlies', v_friendlies,
    'friendly_count', coalesce(v_friendly_count, 0),
    'friendlies_done', coalesce(v_friendly_count, 0) >= 5,
    'upload_code', public.owner_qualifying_upload_code(v_uid),
    'video', v_video,
    'video_open', coalesce(v_video->>'status', '') = 'submitted',
    'video_approved', v_approved,
    'handpick_club', NULLIF(v_grant_club, ''),
    'handpick_due_at', v_grant_due,
    'friendly_channel', '［𝐆𝐏𝐒𝐋］𝐐𝐮𝐚𝐥𝐢𝐟𝐲𝐢𝐧𝐠-𝐅𝐫𝐢𝐞𝐧𝐝𝐥𝐢𝐞𝐬',
    'video_channel', '𝐐𝐮𝐚𝐥𝐢𝐟𝐲𝐢𝐧𝐠-𝐕𝐢𝐝𝐞𝐨𝐬'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_qualifying_log_friendly(
  p_played_on date,
  p_opponent text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_opp text := btrim(coalesce(p_opponent, ''));
  v_created date;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF NOT public.owner_qualifying_is_subject(v_uid) THEN
    RAISE EXCEPTION 'Qualifying does not apply to this account';
  END IF;
  IF NOT coalesce((public.owner_qualifying_state()->>'step1_done')::boolean, false) THEN
    RAISE EXCEPTION 'Set your owner tag and match availability first';
  END IF;
  IF p_played_on IS NULL OR p_played_on > CURRENT_DATE THEN
    RAISE EXCEPTION 'Use the day you played';
  END IF;
  SELECT u.created_at::date INTO v_created FROM auth.users u WHERE u.id = v_uid;
  IF p_played_on < v_created THEN
    RAISE EXCEPTION 'That day is before this account existed';
  END IF;
  IF char_length(v_opp) < 2 OR char_length(v_opp) > 80 THEN
    RAISE EXCEPTION 'Name who you played, in a few words';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.gpsl_qualifying_video v
    WHERE v.owner_id = v_uid AND v.status = 'approved'
  ) THEN
    RAISE EXCEPTION 'Your video is already approved';
  END IF;

  INSERT INTO public.gpsl_qualifying_friendly (owner_id, played_on, opponent)
  VALUES (v_uid, p_played_on, v_opp);

  RETURN public.owner_qualifying_state();
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_qualifying_submit_video()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_state jsonb;
  v_code text;
  v_id bigint;
  v_tag text;
  v_body text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  v_state := public.owner_qualifying_state();
  IF NOT coalesce((v_state->>'subject')::boolean, false) THEN
    RAISE EXCEPTION 'Qualifying does not apply to this account';
  END IF;
  IF NOT coalesce((v_state->>'friendlies_done')::boolean, false) THEN
    RAISE EXCEPTION 'Log five friendlies first';
  END IF;
  IF coalesce((v_state->>'video_approved')::boolean, false) THEN
    RAISE EXCEPTION 'Your video is already approved';
  END IF;
  IF coalesce((v_state->>'video_open')::boolean, false) THEN
    RAISE EXCEPTION 'A video is already waiting for review';
  END IF;

  v_code := v_state->>'upload_code';
  v_tag := coalesce(v_state->>'owner_tag', 'New member');

  INSERT INTO public.gpsl_qualifying_video (owner_id, upload_code, status)
  VALUES (v_uid, v_code, 'submitted')
  RETURNING id INTO v_id;

  v_body := format(
    E'%s submitted a qualifying video.\nCode: %s\nChannel: %s\nFriendlies logged: %s\n\nTick the matchday card on Qualifying videos.',
    v_tag,
    v_code,
    v_state->>'video_channel',
    v_state->>'friendly_count'
  );

  IF to_regprocedure('public.gpsl_staff_alert_create(text,text,text,text,jsonb,text)') IS NOT NULL THEN
    PERFORM public.gpsl_staff_alert_create(
      'qualifying_video',
      format('Qualifying video: %s', v_tag),
      v_body,
      'admin_qualifying.html',
      jsonb_build_object('video_id', v_id, 'owner_id', v_uid, 'upload_code', v_code),
      format('qualifying_video:%s', v_id)
    );
  END IF;

  RETURN public.owner_qualifying_state();
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_qualifying_queue()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Staff only';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at)
    FROM (
      SELECT
        v.id,
        v.owner_id,
        v.upload_code,
        v.status,
        v.created_at,
        v.review_note,
        v.checklist,
        public.owner_registry_resolve_tag(v.owner_id) AS owner_tag,
        (
          SELECT count(*)::int
          FROM public.gpsl_qualifying_friendly f
          WHERE f.owner_id = v.owner_id
        ) AS friendly_count,
        g.handpick_club,
        g.handpick_due_at
      FROM public.gpsl_qualifying_video v
      LEFT JOIN public.gpsl_qualifying_grant g ON g.owner_id = v.owner_id
      WHERE v.status = 'submitted'
         OR (
           v.status = 'approved'
           AND v.created_at = (
             SELECT max(v2.created_at)
             FROM public.gpsl_qualifying_video v2
             WHERE v2.owner_id = v.owner_id
           )
           AND NOT EXISTS (
             SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v.owner_id
           )
         )
    ) x
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_qualifying_review(
  p_video_id bigint,
  p_action text,
  p_checklist jsonb,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action text := lower(btrim(coalesce(p_action, '')));
  v_owner uuid;
  v_labels jsonb := public.qualifying_checklist_labels();
  v_key text;
  v_failed text := '';
  v_all boolean := true;
  v_note text;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Staff only';
  END IF;
  IF v_action NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'action must be approve or reject';
  END IF;

  SELECT v.owner_id INTO v_owner
  FROM public.gpsl_qualifying_video v
  WHERE v.id = p_video_id
    AND v.status = 'submitted'
  FOR UPDATE;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'That video is not waiting for review';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(v_labels)
  LOOP
    IF coalesce((p_checklist->>v_key)::boolean, false) IS NOT TRUE THEN
      v_all := false;
      v_failed := concat_ws(', ', nullif(v_failed, ''), v_labels->>v_key);
    END IF;
  END LOOP;

  IF v_action = 'approve' AND NOT v_all THEN
    RAISE EXCEPTION 'Approve only when every matchday tick is on';
  END IF;
  IF v_action = 'reject' AND v_all THEN
    RAISE EXCEPTION 'Reject by leaving the failed ticks unticked';
  END IF;

  v_note := nullif(btrim(coalesce(p_note, '')), '');
  IF v_action = 'reject' THEN
    v_note := concat_ws(E'\n', 'Failed: ' || v_failed, v_note);
  END IF;

  UPDATE public.gpsl_qualifying_video
  SET status = CASE WHEN v_action = 'approve' THEN 'approved' ELSE 'rejected' END,
      checklist = p_checklist,
      review_note = v_note,
      reviewed_at = now(),
      reviewed_by = auth.uid()
  WHERE id = p_video_id;

  IF v_action = 'approve'
     AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_owner) THEN
    INSERT INTO public.gpsl_owner_registry (
      owner_id, status, waiting_list_tier, status_changed_at
    )
    VALUES (v_owner, 'member', 'new', now())
    ON CONFLICT (owner_id) DO UPDATE
    SET status = CASE
          WHEN gpsl_owner_registry.status IN ('active', 'awaiting_club_auction', 'on_absence')
            THEN gpsl_owner_registry.status
          ELSE 'member'
        END,
        waiting_list_tier = coalesce(gpsl_owner_registry.waiting_list_tier, 'new'),
        status_changed_at = now();
  END IF;

  RETURN jsonb_build_object('ok', true, 'status', v_action, 'video_id', p_video_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_qualifying_grant_handpick(
  p_owner_id uuid,
  p_club text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_name text;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Staff only';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.gpsl_qualifying_video v
    WHERE v.owner_id = p_owner_id AND v.status = 'approved'
  ) THEN
    RAISE EXCEPTION 'Approve the video first';
  END IF;

  SELECT c."Club" INTO v_name
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Club % not found', v_club;
  END IF;

  INSERT INTO public.gpsl_qualifying_grant (
    owner_id, handpick_club, handpick_due_at, granted_by, granted_at
  )
  VALUES (p_owner_id, v_club, now() + interval '7 days', auth.uid(), now())
  ON CONFLICT (owner_id) DO UPDATE
  SET handpick_club = excluded.handpick_club,
      handpick_due_at = excluded.handpick_due_at,
      granted_by = excluded.granted_by,
      granted_at = excluded.granted_at;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'club_name', v_name,
    'due_at', now() + interval '7 days'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.owner_qualifying_state() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.owner_qualifying_log_friendly(date, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.owner_qualifying_submit_video() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.owner_qualifying_claim_block(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_qualifying_queue() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_qualifying_review(bigint, text, jsonb, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_qualifying_grant_handpick(uuid, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.owner_qualifying_state() TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_qualifying_log_friendly(date, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_qualifying_submit_video() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_qualifying_queue() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_qualifying_review(bigint, text, jsonb, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_qualifying_grant_handpick(uuid, text) TO authenticated;

DO $claim_guard$
DECLARE
  v_def text;
  v_old text := $old$  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;$old$;
  v_new text := $new$  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF public.owner_qualifying_claim_block(v_uid, v_short) IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'qualifying',
      'detail', public.owner_qualifying_claim_block(v_uid, v_short)
    );
  END IF;$new$;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.waiting_list_claim_vacant_club(text)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');
  IF position('owner_qualifying_claim_block' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'claim auth check not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$claim_guard$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'required_from', (SELECT required_from FROM public.gpsl_qualifying_settings WHERE id = 1),
  'claim_guard', position(
    'owner_qualifying_claim_block' IN pg_get_functiondef('public.waiting_list_claim_vacant_club(text)'::regprocedure)
  ) > 0,
  'state', to_regprocedure('public.owner_qualifying_state()') IS NOT NULL
) AS info;
