-- =============================================================================
-- Season 1 Invite Mass lane
--
-- • Existing "Invite to season 1" = priority lane (S1# order, unchanged)
-- • New "Invite Mass" = mass lane: no S1# until accept; joins Confirmed behind
--   all priority members; among mass, order = first to accept (responded_at)
--
-- Run in Supabase SQL Editor. Safe re-run.
-- Then hard-refresh admin waiting list + waiting_list.html.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Column + backfill
-- ---------------------------------------------------------------------------
ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS season1_invite_lane text;

COMMENT ON COLUMN public.gpsl_owner_registry.season1_invite_lane IS
  'priority = reserved S1# invite; mass = accept-order behind priority.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'gpsl_owner_registry_s1_lane_chk'
  ) THEN
    ALTER TABLE public.gpsl_owner_registry
      ADD CONSTRAINT gpsl_owner_registry_s1_lane_chk
      CHECK (
        season1_invite_lane IS NULL
        OR season1_invite_lane IN ('priority', 'mass')
      );
  END IF;
END $$;

-- Existing invite activity → priority (preserves current queue behaviour)
UPDATE public.gpsl_owner_registry
SET season1_invite_lane = 'priority'
WHERE season1_invite_lane IS NULL
  AND (
    season1_invite_queue_num IS NOT NULL
    OR season1_invite_status IS NOT NULL
    OR season1_invite_response IS NOT NULL
  );

-- ---------------------------------------------------------------------------
-- Row JSON (keep deadline_passed; add lane)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.season1_invite_row_json(r public.gpsl_owner_registry)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'queue_num', r.season1_invite_queue_num,
    'lane', coalesce(nullif(btrim(r.season1_invite_lane), ''), 'priority'),
    'status', r.season1_invite_status,
    'response', r.season1_invite_response,
    'offered_at', r.season1_invite_offered_at,
    'deadline_at', r.season1_invite_deadline_at,
    'deadline_label', CASE
      WHEN r.season1_invite_deadline_at IS NULL THEN NULL
      ELSE public.season1_invite_format_deadline_uk(r.season1_invite_deadline_at)
    END,
    'deadline_passed',
      r.season1_invite_deadline_at IS NOT NULL
      AND r.season1_invite_deadline_at < now(),
    'responded_at', r.season1_invite_responded_at,
    'offer_count', coalesce(r.season1_invite_offer_count, 0)
  );
$$;

-- ---------------------------------------------------------------------------
-- Assign S1# → mark priority lane
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_season1_invite_assign_next(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_next integer;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;
  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'owner_id required';
  END IF;

  SELECT * INTO v_row FROM public.gpsl_owner_registry WHERE owner_id = p_owner_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No registry row';
  END IF;

  IF v_row.season1_invite_queue_num IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true, 'already', true, 'owner_id', p_owner_id,
      'queue_num', v_row.season1_invite_queue_num,
      'season1', public.season1_invite_row_json(v_row)
    );
  END IF;

  SELECT coalesce(max(season1_invite_queue_num), 0) + 1 INTO v_next
  FROM public.gpsl_owner_registry;

  UPDATE public.gpsl_owner_registry
  SET season1_invite_queue_num = v_next,
      season1_invite_lane = 'priority',
      season1_invite_status = coalesce(nullif(btrim(season1_invite_status), ''), 'queued')
  WHERE owner_id = p_owner_id
  RETURNING * INTO v_row;

  PERFORM public.season1_invite_log_event(
    p_owner_id, 'queue_assigned', v_next,
    jsonb_build_object('source', 'admin_click', 'lane', 'priority')
  );

  RETURN jsonb_build_object(
    'ok', true, 'already', false, 'owner_id', p_owner_id,
    'queue_num', v_next,
    'season1', public.season1_invite_row_json(v_row)
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- On mass accept: assign trailing display # (optional label; sort uses lane)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.season1_invite_assign_mass_queue_on_accept(p_owner_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_next integer;
BEGIN
  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = p_owner_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF coalesce(v_row.season1_invite_lane, 'priority') IS DISTINCT FROM 'mass' THEN
    RETURN v_row.season1_invite_queue_num;
  END IF;

  IF v_row.season1_invite_queue_num IS NOT NULL THEN
    RETURN v_row.season1_invite_queue_num;
  END IF;

  IF coalesce(v_row.season1_invite_response, '') IS DISTINCT FROM 'accepted' THEN
    RETURN NULL;
  END IF;

  SELECT coalesce(max(season1_invite_queue_num), 0) + 1 INTO v_next
  FROM public.gpsl_owner_registry;

  UPDATE public.gpsl_owner_registry
  SET season1_invite_queue_num = v_next
  WHERE owner_id = p_owner_id;

  PERFORM public.season1_invite_log_event(
    p_owner_id, 'mass_queue_assigned', v_next,
    jsonb_build_object('lane', 'mass', 'via', 'accept')
  );

  RETURN v_next;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.season1_invite_assign_mass_queue_on_accept(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Discord enqueue: mass line when no queue #
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.season1_invite_enqueue_discord_news(
  p_owner_id uuid,
  p_owner_tag text,
  p_deadline timestamptz,
  p_deadline_label text,
  p_queue_num integer,
  p_token text,
  p_discord_user_id text DEFAULT NULL,
  p_lane text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_id bigint;
  v_tag text := coalesce(nullif(btrim(p_owner_tag), ''), 'owner');
  v_mention text := '@' || ltrim(v_tag, '@');
  v_offered_label text;
  v_deadline_label text := coalesce(nullif(btrim(p_deadline_label), ''), '48 hours');
  v_lane text := lower(nullif(btrim(coalesce(p_lane, '')), ''));
  v_headline text;
  v_body text;
BEGIN
  IF to_regprocedure(
    'public.gpsl_discord_feed_enqueue(text,text,text,integer,text,jsonb)'
  ) IS NULL THEN
    RETURN NULL;
  END IF;

  v_offered_label := to_char(
    timezone('Europe/London', coalesce(
      (SELECT season1_invite_offered_at FROM public.gpsl_owner_registry WHERE owner_id = p_owner_id),
      now()
    )),
    'Dy DD Mon YYYY HH24:MI'
  ) || ' UK';

  v_headline := CASE
    WHEN v_lane = 'mass' THEN 'Season 1 mass invite — ' || v_mention
    ELSE 'Season 1 invite — ' || v_mention
  END;

  v_body :=
    v_mention || CASE
      WHEN v_lane = 'mass' THEN ' has been mass-invited to GPSL Season 1.'
      ELSE ' has been invited to GPSL Season 1.'
    END
    || E'\nInvited: ' || v_offered_label
    || E'\nDeadline: ' || v_deadline_label
    || CASE
         WHEN p_queue_num IS NOT NULL THEN E'\nQueue: #' || p_queue_num::text
         WHEN v_lane = 'mass' THEN
           E'\nLane: Mass (joins behind reserved places by accept order)'
         ELSE ''
       END;

  BEGIN
    v_id := public.gpsl_discord_feed_enqueue(
      'news',
      v_headline,
      v_body,
      16750848,
      'season1_invite:' || p_owner_id::text || ':' || coalesce(nullif(btrim(p_token), ''), 'na'),
      jsonb_build_object(
        'channel', 'news',
        'kind', 'season1_invite',
        'ping', true,
        'owner_tag', v_tag,
        'owner_tags', jsonb_build_array(v_tag),
        'discord_user_id', nullif(btrim(coalesce(p_discord_user_id, '')), ''),
        'deadline_at', p_deadline,
        'deadline_label', v_deadline_label,
        'queue_num', p_queue_num,
        'lane', coalesce(v_lane, 'priority'),
        'offered_label_uk', v_offered_label
      )
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'season1 Discord enqueue failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.season1_invite_enqueue_discord_news(
  uuid, text, timestamptz, text, integer, text, text, text
) TO authenticated;

-- Keep 7-arg overload callable (Postgres creates new signature; grant old if present)
DO $g$
BEGIN
  IF to_regprocedure(
    'public.season1_invite_enqueue_discord_news(uuid,text,timestamptz,text,integer,text,text)'
  ) IS NOT NULL THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.season1_invite_enqueue_discord_news(uuid, text, timestamptz, text, integer, text, text) TO authenticated';
  END IF;
END;
$g$;

-- ---------------------------------------------------------------------------
-- Shared offer writer (priority or mass)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_season1_invite_send_lane(
  p_owner_id uuid,
  p_lane text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_lane text := lower(nullif(btrim(coalesce(p_lane, '')), ''));
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_email text;
  v_tag text;
  v_deadline timestamptz;
  v_token text;
  v_inbox_id bigint;
  v_email_id bigint;
  v_discord_qid bigint;
  v_deadline_label text;
  v_title text;
  v_body text;
  v_site text := 'https://gpsuperleague.github.io/GPSL';
  v_accept_url text;
  v_decline_url text;
  v_discord_user text;
  v_is_mass boolean;
  v_queue_line text;
  v_lane_line text;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;

  IF v_lane IS NULL OR v_lane NOT IN ('priority', 'mass') THEN
    RAISE EXCEPTION 'lane must be priority or mass';
  END IF;
  v_is_mass := (v_lane = 'mass');

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = p_owner_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No registry row';
  END IF;

  IF NOT v_is_mass AND v_row.season1_invite_queue_num IS NULL THEN
    RAISE EXCEPTION 'Assign a Season 1 queue number before inviting';
  END IF;

  IF v_is_mass AND v_row.season1_invite_queue_num IS NOT NULL
     AND coalesce(v_row.season1_invite_lane, 'priority') = 'priority' THEN
    RAISE EXCEPTION
      'Owner has S1#% — clear the number first, or use Invite to season 1',
      v_row.season1_invite_queue_num;
  END IF;

  IF v_row.season1_invite_response = 'accepted' THEN
    RAISE EXCEPTION 'Owner already accepted Season 1';
  END IF;

  IF v_row.season1_invite_status = 'offered'
     AND v_row.season1_invite_deadline_at IS NOT NULL
     AND v_row.season1_invite_deadline_at > now()
     AND v_row.season1_invite_response IS NULL THEN
    RAISE EXCEPTION 'Invite already pending until %',
      public.season1_invite_format_deadline_uk(v_row.season1_invite_deadline_at);
  END IF;

  SELECT u.email::text INTO v_email FROM auth.users u WHERE u.id = p_owner_id;
  IF nullif(btrim(coalesce(v_email, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Owner has no email';
  END IF;

  v_tag := coalesce(
    nullif(btrim(public.owner_registry_resolve_tag(p_owner_id)), ''),
    nullif(btrim(v_row.owner_tag), ''),
    'owner'
  );
  v_discord_user := nullif(btrim(coalesce(v_row.discord_user_id, '')), '');

  v_deadline := now() + interval '48 hours';
  v_token := coalesce(
    (
      SELECT encode(extensions.gen_random_bytes(24), 'hex')
      WHERE to_regprocedure('extensions.gen_random_bytes(integer)') IS NOT NULL
    ),
    replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
  );
  v_deadline_label := public.season1_invite_format_deadline_uk(v_deadline);
  v_accept_url := v_site || '/season1_invite.html?token=' || v_token || '&decision=accept';
  v_decline_url := v_site || '/season1_invite.html?token=' || v_token || '&decision=decline';

  IF v_is_mass THEN
    v_queue_line := '';
    v_lane_line :=
      E'\nThis is a mass invite: you join behind owners with reserved Season 1 places, '
      || 'in the order invites are accepted.';
    v_title := 'You''re invited to GPSL Season 1 (mass invite)';
    v_body :=
      'Congratulations ' || v_tag
      || ' — you have been invited to join GPSL Season 1 (club auction).'
      || v_lane_line
      || E'\n\nYou have 48 hours to accept or decline.'
      || E'\nDeadline: ' || v_deadline_label || '.'
      || E'\n\nRespond from Inbox, Waiting list, or your email links.';
  ELSE
    v_queue_line := E'\nQueue position: #' || v_row.season1_invite_queue_num::text || '.';
    v_lane_line := '';
    v_title := 'You''re invited to GPSL Season 1';
    v_body :=
      'Congratulations ' || v_tag
      || ' — you have been invited to join GPSL Season 1 (club auction).'
      || E'\n\nYou have 48 hours to accept or decline.'
      || E'\nDeadline: ' || v_deadline_label || '.'
      || v_queue_line
      || E'\n\nRespond from Inbox, Waiting list, or your email links.';
  END IF;

  IF to_regprocedure(
    'public.season1_invite_send_inbox(uuid,text,text,text,text)'
  ) IS NOT NULL THEN
    v_inbox_id := public.season1_invite_send_inbox(
      p_owner_id,
      v_title,
      v_body,
      'waiting_list.html#season1',
      'season1_invite:' || p_owner_id::text || ':' || v_token
    );
  ELSIF to_regprocedure(
    'public.owner_inbox_send(text,text,text,text,uuid,bigint,bigint,bigint,bigint,text,text,text,bigint,bigint)'
  ) IS NOT NULL THEN
    v_inbox_id := public.owner_inbox_send(
      'season1_invite',
      v_title,
      v_body,
      NULL,
      p_owner_id,
      NULL, NULL, NULL, NULL,
      'waiting_list.html#season1',
      'season1_invite:' || p_owner_id::text || ':' || v_token,
      NULL, NULL, NULL
    );
  END IF;

  UPDATE public.gpsl_owner_registry
  SET season1_invite_status = 'offered',
      season1_invite_lane = v_lane,
      season1_invite_offered_at = now(),
      season1_invite_deadline_at = v_deadline,
      season1_invite_token = v_token,
      season1_invite_inbox_id = v_inbox_id,
      season1_invite_offer_count = coalesce(season1_invite_offer_count, 0) + 1,
      season1_invite_responded_at = NULL,
      season1_invite_response = CASE
        WHEN season1_invite_response = 'declined' THEN NULL
        ELSE season1_invite_response
      END,
      -- Mass invites must not keep a stale priority number
      season1_invite_queue_num = CASE
        WHEN v_is_mass THEN NULL
        ELSE season1_invite_queue_num
      END
  WHERE owner_id = p_owner_id
  RETURNING * INTO v_row;

  v_discord_qid := public.season1_invite_enqueue_discord_news(
    p_owner_id,
    v_tag,
    v_deadline,
    v_deadline_label,
    v_row.season1_invite_queue_num,
    v_token,
    v_discord_user,
    v_lane
  );

  INSERT INTO public.gpsl_email_outbox (
    kind, to_email, to_owner_id, subject, html_body, text_body, metadata
  ) VALUES (
    'season1_invite',
    v_email,
    p_owner_id,
    v_title,
    '<div style="font-family:Arial,Helvetica,sans-serif;line-height:1.5;color:#222">'
      || '<h2 style="color:#cc7a00;margin:0 0 12px">'
      || CASE WHEN v_is_mass
           THEN 'You''re invited to GPSL Season 1 (mass invite)'
           ELSE 'You''re invited to GPSL Season 1'
         END
      || '</h2>'
      || '<p>Hi <strong>' || replace(replace(v_tag, '&', '&amp;'), '<', '&lt;') || '</strong>,</p>'
      || '<p>You have been invited to join <strong>GPSL Season 1</strong> and the club auction.</p>'
      || CASE WHEN v_is_mass THEN
           '<p>This is a <strong>mass invite</strong>: you join behind owners with reserved Season 1 places, '
           || 'in the order invites are accepted.</p>'
         ELSE ''
         END
      || '<p>You have <strong>48 hours</strong> to accept or decline.<br>'
      || 'Deadline: <strong>' || v_deadline_label || '</strong>.</p>'
      || CASE WHEN NOT v_is_mass THEN
           '<p>Queue position: <strong>#' || v_row.season1_invite_queue_num::text || '</strong></p>'
         ELSE ''
         END
      || '<p style="margin:22px 0">'
      || '<a href="' || v_accept_url || '" style="background:#2a7;color:#fff;padding:10px 16px;border-radius:4px;text-decoration:none;margin-right:10px">Accept</a>'
      || '<a href="' || v_decline_url || '" style="background:#844;color:#fff;padding:10px 16px;border-radius:4px;text-decoration:none">Decline</a>'
      || '</p>'
      || '<p style="color:#666;font-size:13px">You can also respond in GPSL Inbox or on the Waiting list page.</p>'
      || '</div>',
    v_body || E'\n\nAccept: ' || v_accept_url || E'\nDecline: ' || v_decline_url,
    jsonb_build_object(
      'token', v_token,
      'deadline_at', v_deadline,
      'queue_num', v_row.season1_invite_queue_num,
      'lane', v_lane,
      'accept_url', v_accept_url,
      'decline_url', v_decline_url
    )
  )
  RETURNING id INTO v_email_id;

  PERFORM public.season1_invite_log_event(
    p_owner_id, 'invite_sent', v_row.season1_invite_queue_num,
    jsonb_build_object(
      'deadline_at', v_deadline,
      'inbox_id', v_inbox_id,
      'email_outbox_id', v_email_id,
      'discord_queue_id', v_discord_qid,
      'lane', v_lane
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'email', v_email,
    'owner_tag', v_tag,
    'queue_num', v_row.season1_invite_queue_num,
    'lane', v_lane,
    'deadline_at', v_deadline,
    'deadline_label', v_deadline_label,
    'inbox_id', v_inbox_id,
    'email_outbox_id', v_email_id,
    'discord_queue_id', v_discord_qid,
    'season1', public.season1_invite_row_json(v_row)
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_season1_invite_send_lane(uuid, text)
  TO authenticated, service_role;

-- Priority wrappers (existing names)
CREATE OR REPLACE FUNCTION public.admin_season1_invite_send(p_owner_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.admin_season1_invite_send_lane(p_owner_id, 'priority');
$$;

CREATE OR REPLACE FUNCTION public.admin_s1_invite_send(p_owner_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.admin_season1_invite_send_lane(p_owner_id, 'priority');
$$;

-- Mass wrappers
CREATE OR REPLACE FUNCTION public.admin_season1_invite_send_mass(p_owner_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.admin_season1_invite_send_lane(p_owner_id, 'mass');
$$;

CREATE OR REPLACE FUNCTION public.admin_s1_invite_send_mass(p_owner_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.admin_season1_invite_send_lane(p_owner_id, 'mass');
$$;

GRANT EXECUTE ON FUNCTION public.admin_season1_invite_send(uuid)
  TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION public.admin_s1_invite_send(uuid)
  TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION public.admin_season1_invite_send_mass(uuid)
  TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION public.admin_s1_invite_send_mass(uuid)
  TO authenticated, service_role, anon;

-- ---------------------------------------------------------------------------
-- Member respond: assign mass # on accept
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_season1_invite_respond(
  p_decision text,
  p_token text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_decision text := lower(nullif(btrim(coalesce(p_decision, '')), ''));
  v_token text := nullif(btrim(coalesce(p_token, '')), '');
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_uid uuid := auth.uid();
  v_mass_num integer;
BEGIN
  IF v_decision IS NULL OR v_decision NOT IN ('accept','accepted','decline','declined') THEN
    RAISE EXCEPTION 'decision must be accept or decline';
  END IF;
  v_decision := CASE WHEN v_decision IN ('accept','accepted') THEN 'accepted' ELSE 'declined' END;

  IF v_token IS NOT NULL THEN
    SELECT * INTO v_row FROM public.gpsl_owner_registry
    WHERE season1_invite_token = v_token FOR UPDATE;
  ELSIF v_uid IS NOT NULL THEN
    SELECT * INTO v_row FROM public.gpsl_owner_registry
    WHERE owner_id = v_uid FOR UPDATE;
  ELSE
    RAISE EXCEPTION 'Sign in or provide invite token';
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invite not found';
  END IF;

  IF v_row.season1_invite_response IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true, 'already', true,
      'response', v_row.season1_invite_response,
      'owner_id', v_row.owner_id,
      'queue_num', v_row.season1_invite_queue_num,
      'lane', coalesce(v_row.season1_invite_lane, 'priority'),
      'season1', public.season1_invite_row_json(v_row)
    );
  END IF;

  IF coalesce(v_row.season1_invite_status, '') <> 'offered' THEN
    RAISE EXCEPTION 'No pending Season 1 invite';
  END IF;

  IF v_row.season1_invite_deadline_at IS NOT NULL
     AND v_row.season1_invite_deadline_at < now() THEN
    UPDATE public.gpsl_owner_registry
    SET season1_invite_status = 'expired'
    WHERE owner_id = v_row.owner_id;
    PERFORM public.season1_invite_log_event(
      v_row.owner_id, 'invite_expired', v_row.season1_invite_queue_num, '{}'::jsonb
    );
    RAISE EXCEPTION 'Invite deadline has passed (%)',
      public.season1_invite_format_deadline_uk(v_row.season1_invite_deadline_at);
  END IF;

  UPDATE public.gpsl_owner_registry
  SET season1_invite_status = v_decision,
      season1_invite_response = v_decision,
      season1_invite_responded_at = now()
  WHERE owner_id = v_row.owner_id
  RETURNING * INTO v_row;

  IF v_decision = 'accepted' THEN
    v_mass_num := public.season1_invite_assign_mass_queue_on_accept(v_row.owner_id);
    IF v_mass_num IS NOT NULL THEN
      SELECT * INTO v_row FROM public.gpsl_owner_registry WHERE owner_id = v_row.owner_id;
    END IF;
  END IF;

  IF v_row.season1_invite_inbox_id IS NOT NULL THEN
    UPDATE public.competition_inbox
    SET read_at = coalesce(read_at, now())
    WHERE id = v_row.season1_invite_inbox_id;
  END IF;

  PERFORM public.season1_invite_log_event(
    v_row.owner_id,
    CASE WHEN v_decision = 'accepted' THEN 'invite_accepted' ELSE 'invite_declined' END,
    v_row.season1_invite_queue_num,
    jsonb_build_object(
      'via_token', v_token IS NOT NULL,
      'lane', coalesce(v_row.season1_invite_lane, 'priority')
    )
  );

  RETURN jsonb_build_object(
    'ok', true, 'already', false,
    'response', v_decision,
    'owner_id', v_row.owner_id,
    'queue_num', v_row.season1_invite_queue_num,
    'lane', coalesce(v_row.season1_invite_lane, 'priority'),
    'owner_tag', public.owner_registry_resolve_tag(v_row.owner_id),
    'season1', public.season1_invite_row_json(v_row)
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.owner_season1_invite_respond(text, text)
  TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- Admin on-behalf: same mass # assignment
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_season1_invite_respond_on_behalf(
  p_owner_id uuid,
  p_decision text,
  p_force boolean DEFAULT false,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_decision text := lower(nullif(btrim(coalesce(p_decision, '')), ''));
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_prev_response text;
  v_prev_status text;
  v_mass_num integer;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;
  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'owner_id required';
  END IF;

  IF v_decision IS NULL OR v_decision NOT IN ('accept', 'accepted', 'decline', 'declined') THEN
    RAISE EXCEPTION 'decision must be accept or decline';
  END IF;
  v_decision := CASE
    WHEN v_decision IN ('accept', 'accepted') THEN 'accepted'
    ELSE 'declined'
  END;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = p_owner_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No registry row for owner %', p_owner_id;
  END IF;

  v_prev_response := v_row.season1_invite_response;
  v_prev_status := v_row.season1_invite_status;

  IF v_prev_response IS NOT NULL
     AND v_prev_response = v_decision
     AND NOT coalesce(p_force, false) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already', true,
      'response', v_prev_response,
      'owner_id', v_row.owner_id,
      'queue_num', v_row.season1_invite_queue_num,
      'lane', coalesce(v_row.season1_invite_lane, 'priority'),
      'season1', public.season1_invite_row_json(v_row)
    );
  END IF;

  IF v_prev_response IS NOT NULL
     AND v_prev_response IS DISTINCT FROM v_decision
     AND NOT coalesce(p_force, false) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already', true,
      'response', v_prev_response,
      'owner_id', v_row.owner_id,
      'queue_num', v_row.season1_invite_queue_num,
      'lane', coalesce(v_row.season1_invite_lane, 'priority'),
      'season1', public.season1_invite_row_json(v_row),
      'hint', format('Already %s — confirm overwrite to set %s', v_prev_response, v_decision)
    );
  END IF;

  -- Legacy DM with no lane → priority (does not jump into mass accept-order)
  UPDATE public.gpsl_owner_registry
  SET season1_invite_status = v_decision,
      season1_invite_response = v_decision,
      season1_invite_responded_at = now(),
      season1_invite_lane = coalesce(nullif(btrim(season1_invite_lane), ''), 'priority')
  WHERE owner_id = p_owner_id
  RETURNING * INTO v_row;

  IF v_decision = 'accepted' THEN
    v_mass_num := public.season1_invite_assign_mass_queue_on_accept(v_row.owner_id);
    IF v_mass_num IS NOT NULL THEN
      SELECT * INTO v_row FROM public.gpsl_owner_registry WHERE owner_id = v_row.owner_id;
    END IF;
  END IF;

  IF v_row.season1_invite_inbox_id IS NOT NULL THEN
    BEGIN
      UPDATE public.competition_inbox
      SET read_at = coalesce(read_at, now())
      WHERE id = v_row.season1_invite_inbox_id;
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
  END IF;

  PERFORM public.season1_invite_log_event(
    v_row.owner_id,
    CASE
      WHEN v_decision = 'accepted' THEN 'invite_accepted_on_behalf'
      ELSE 'invite_declined_on_behalf'
    END,
    v_row.season1_invite_queue_num,
    jsonb_build_object(
      'via', 'admin_dm',
      'actor_id', auth.uid(),
      'force', coalesce(p_force, false),
      'prev_status', v_prev_status,
      'prev_response', v_prev_response,
      'note', v_note,
      'lane', coalesce(v_row.season1_invite_lane, 'priority')
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'already', false,
    'response', v_decision,
    'owner_id', v_row.owner_id,
    'queue_num', v_row.season1_invite_queue_num,
    'lane', coalesce(v_row.season1_invite_lane, 'priority'),
    'owner_tag', public.owner_registry_resolve_tag(v_row.owner_id),
    'season1', public.season1_invite_row_json(v_row),
    'on_behalf', true
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_season1_invite_respond_on_behalf(uuid, text, boolean, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Public board: priority first, then mass (accept / offer time)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.waiting_list_public()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rows jsonb;
  v_total int;
  v_self_pos int;
  v_on_board_mode text := 'invited';
  v_on_board jsonb;
  v_on_board_total int;
  v_self_on_board_pos int;
  v_s1_confirmed jsonb;
  v_s1_confirmed_total int;
  v_self_s1_confirmed_pos int;
  v_use_admin boolean;
BEGIN
  SELECT coalesce(bool_and(
    r.waiting_list_use_admin_sort AND r.waiting_list_admin_sort IS NOT NULL
  ), false)
  INTO v_use_admin
  FROM public.gpsl_owner_registry r
  WHERE (
      public.waiting_list_on_list_status(r.status)
      AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
    )
    OR EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id);

  -- Middle: Invited (priority by S1#, then mass by offered_at)
  WITH latest_country AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      upper(nullif(btrim(coalesce(e.country_code, '')), '')) AS country_code
    FROM public.owner_login_origin_events e
    WHERE nullif(btrim(coalesce(e.country_code, '')), '') IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  latest_timezone AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      nullif(btrim(coalesce(e.timezone_name, '')), '') AS timezone_name
    FROM public.owner_login_origin_events e
    WHERE nullif(btrim(coalesce(e.timezone_name, '')), '') IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  invited AS (
    SELECT
      r.owner_id,
      public.owner_registry_resolve_tag(r.owner_id) AS owner_tag,
      r.season1_invite_queue_num AS queue_num,
      coalesce(nullif(btrim(r.season1_invite_lane), ''), 'priority') AS lane,
      r.season1_invite_offered_at AS invited_at,
      r.season1_invite_deadline_at AS deadline_at,
      lc.country_code,
      coalesce(
        nullif(btrim(coalesce(r.owner_timezone, '')), ''),
        (
          SELECT nullif(btrim(coalesce(c.owner_timezone, '')), '')
          FROM public."Clubs" c
          WHERE c.owner_id = r.owner_id
          ORDER BY c."ShortName"
          LIMIT 1
        ),
        lt.timezone_name
      ) AS origin_timezone
    FROM public.gpsl_owner_registry r
    LEFT JOIN latest_country lc ON lc.owner_id = r.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = r.owner_id
    WHERE r.season1_invite_status = 'offered'
      AND r.season1_invite_response IS NULL
  ),
  invited_ranked AS (
    SELECT
      i.*,
      row_number() OVER (
        ORDER BY
          CASE WHEN i.lane = 'mass' THEN 1 ELSE 0 END,
          i.queue_num NULLS LAST,
          i.invited_at NULLS LAST,
          i.owner_tag,
          i.owner_id
      )::int AS position
    FROM invited i
  )
  SELECT
    coalesce(jsonb_agg(
      jsonb_build_object(
        'position', invited_ranked.position,
        'owner_id', invited_ranked.owner_id,
        'owner_tag', invited_ranked.owner_tag,
        'queue_num', invited_ranked.queue_num,
        'lane', invited_ranked.lane,
        'country_code', invited_ranked.country_code,
        'origin_timezone', invited_ranked.origin_timezone,
        'deadline_at', invited_ranked.deadline_at
      )
      ORDER BY invited_ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN invited_ranked.owner_id = auth.uid() THEN invited_ranked.position END)
  INTO v_on_board, v_on_board_total, v_self_on_board_pos
  FROM invited_ranked;

  -- Left: Confirmed (priority by S1#, then mass by first accept)
  WITH latest_country AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      upper(nullif(btrim(coalesce(e.country_code, '')), '')) AS country_code
    FROM public.owner_login_origin_events e
    WHERE nullif(btrim(coalesce(e.country_code, '')), '') IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  latest_timezone AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      nullif(btrim(coalesce(e.timezone_name, '')), '') AS timezone_name
    FROM public.owner_login_origin_events e
    WHERE nullif(btrim(coalesce(e.timezone_name, '')), '') IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  confirmed AS (
    SELECT
      r.owner_id,
      public.owner_registry_resolve_tag(r.owner_id) AS owner_tag,
      r.season1_invite_queue_num AS queue_num,
      coalesce(nullif(btrim(r.season1_invite_lane), ''), 'priority') AS lane,
      r.season1_invite_responded_at AS responded_at,
      lc.country_code,
      coalesce(
        nullif(btrim(coalesce(r.owner_timezone, '')), ''),
        (
          SELECT nullif(btrim(coalesce(c.owner_timezone, '')), '')
          FROM public."Clubs" c
          WHERE c.owner_id = r.owner_id
          ORDER BY c."ShortName"
          LIMIT 1
        ),
        lt.timezone_name
      ) AS origin_timezone
    FROM public.gpsl_owner_registry r
    LEFT JOIN latest_country lc ON lc.owner_id = r.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = r.owner_id
    WHERE r.season1_invite_response = 'accepted'
  ),
  confirmed_ranked AS (
    SELECT
      c.*,
      row_number() OVER (
        ORDER BY
          CASE WHEN c.lane = 'mass' THEN 1 ELSE 0 END,
          CASE WHEN c.lane = 'mass' THEN c.responded_at END NULLS LAST,
          c.queue_num NULLS LAST,
          c.responded_at NULLS LAST,
          c.owner_tag,
          c.owner_id
      )::int AS position
    FROM confirmed c
  )
  SELECT
    coalesce(jsonb_agg(
      jsonb_build_object(
        'position', confirmed_ranked.position,
        'owner_id', confirmed_ranked.owner_id,
        'owner_tag', confirmed_ranked.owner_tag,
        'queue_num', confirmed_ranked.queue_num,
        'lane', confirmed_ranked.lane,
        'country_code', confirmed_ranked.country_code,
        'origin_timezone', confirmed_ranked.origin_timezone
      )
      ORDER BY confirmed_ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN confirmed_ranked.owner_id = auth.uid() THEN confirmed_ranked.position END)
  INTO v_s1_confirmed, v_s1_confirmed_total, v_self_s1_confirmed_pos
  FROM confirmed_ranked;

  -- Right: waiting board
  WITH latest_country AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      upper(nullif(btrim(coalesce(e.country_code, '')), '')) AS country_code
    FROM public.owner_login_origin_events e
    WHERE nullif(btrim(coalesce(e.country_code, '')), '') IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  latest_timezone AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      nullif(btrim(coalesce(e.timezone_name, '')), '') AS timezone_name
    FROM public.owner_login_origin_events e
    WHERE nullif(btrim(coalesce(e.timezone_name, '')), '') IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  board AS (
    SELECT
      r.owner_id,
      coalesce(nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''), '—') AS owner_tag,
      r.status AS registry_status,
      u.created_at AS account_created_at,
      r.waiting_list_admin_sort AS admin_sort,
      coalesce(r.confirmed_test_season, false) AS confirmed_test_season,
      true AS has_club,
      'club_owner'::text AS list_kind,
      lc.country_code,
      coalesce(
        nullif(btrim(coalesce(r.owner_timezone, '')), ''),
        (
          SELECT nullif(btrim(coalesce(c.owner_timezone, '')), '')
          FROM public."Clubs" c
          WHERE c.owner_id = r.owner_id
          ORDER BY c."ShortName"
          LIMIT 1
        ),
        lt.timezone_name
      ) AS origin_timezone,
      (r.season1_invite_response = 'declined') AS season1_rejected
    FROM public.gpsl_owner_registry r
    JOIN auth.users u ON u.id = r.owner_id
    LEFT JOIN latest_country lc ON lc.owner_id = r.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = r.owner_id
    WHERE EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)

    UNION ALL

    SELECT
      r.owner_id,
      coalesce(nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''), '—') AS owner_tag,
      r.status AS registry_status,
      u.created_at AS account_created_at,
      r.waiting_list_admin_sort AS admin_sort,
      coalesce(r.confirmed_test_season, false) AS confirmed_test_season,
      false AS has_club,
      'waiting'::text AS list_kind,
      lc.country_code,
      coalesce(
        nullif(btrim(coalesce(r.owner_timezone, '')), ''),
        (
          SELECT nullif(btrim(coalesce(c.owner_timezone, '')), '')
          FROM public."Clubs" c
          WHERE c.owner_id = r.owner_id
          ORDER BY c."ShortName"
          LIMIT 1
        ),
        lt.timezone_name
      ) AS origin_timezone,
      (r.season1_invite_response = 'declined') AS season1_rejected
    FROM public.gpsl_owner_registry r
    JOIN auth.users u ON u.id = r.owner_id
    LEFT JOIN latest_country lc ON lc.owner_id = r.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = r.owner_id
    WHERE public.waiting_list_on_list_status(r.status)
      AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
      AND coalesce(r.season1_invite_response, '') IS DISTINCT FROM 'accepted'
      AND NOT (
        r.season1_invite_status = 'offered'
        AND r.season1_invite_response IS NULL
      )
  ),
  ranked AS (
    SELECT
      b.*,
      row_number() OVER (
        ORDER BY
          CASE WHEN b.has_club THEN 0 ELSE 1 END,
          CASE WHEN b.season1_rejected THEN 1 ELSE 0 END,
          CASE WHEN v_use_admin THEN b.admin_sort END NULLS LAST,
          b.account_created_at,
          b.owner_id
      )::int AS position
    FROM board b
  )
  SELECT
    coalesce(jsonb_agg(
      jsonb_build_object(
        'position', ranked.position,
        'owner_id', ranked.owner_id,
        'owner_tag', ranked.owner_tag,
        'status', ranked.registry_status,
        'list_kind', ranked.list_kind,
        'has_club', ranked.has_club,
        'confirmed_test_season', ranked.confirmed_test_season,
        'country_code', ranked.country_code,
        'origin_timezone', ranked.origin_timezone,
        'season1_rejected', ranked.season1_rejected
      )
      ORDER BY ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN ranked.owner_id = auth.uid() THEN ranked.position END)
  INTO v_rows, v_total, v_self_pos
  FROM ranked;

  RETURN jsonb_build_object(
    'total', coalesce(v_total, 0),
    'rows', coalesce(v_rows, '[]'::jsonb),
    'my_position', v_self_pos,
    'on_board_mode', v_on_board_mode,
    'on_board', coalesce(v_on_board, '[]'::jsonb),
    'on_board_total', coalesce(v_on_board_total, 0),
    'my_on_board_position', v_self_on_board_pos,
    'season1_confirmed', coalesce(v_s1_confirmed, '[]'::jsonb),
    'season1_confirmed_total', coalesce(v_s1_confirmed_total, 0),
    'my_season1_confirmed_position', v_self_s1_confirmed_pos
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.waiting_list_public() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Smoke checks (optional):
-- SELECT season1_invite_lane, count(*) FROM gpsl_owner_registry
--  WHERE season1_invite_lane IS NOT NULL GROUP BY 1;
-- SELECT proname FROM pg_proc
--  WHERE proname IN ('admin_season1_invite_send_mass','admin_s1_invite_send_mass');
