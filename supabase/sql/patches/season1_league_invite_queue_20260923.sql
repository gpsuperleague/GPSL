-- =============================================================================
-- Season 1 league invite queue
--
-- Admin waiting-list board:
--   • Click S1# cell → assign next dense number (global 1..N)
--   • Click again (confirm) → clear number; everyone below bumps up
--   • Action "Invite to season 1" → 48h offer (inbox + Discord news + email)
--   • Accept/decline via inbox, waiting-list room, or email token link
--   • Permanent accepted/declined audit (registry + events table)
--
-- Run in Supabase SQL Editor. Safe re-run.
-- Then deploy edge function: season1-invite-mail (optional RESEND_API_KEY).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Registry columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS season1_invite_queue_num integer,
  ADD COLUMN IF NOT EXISTS season1_invite_status text,
  ADD COLUMN IF NOT EXISTS season1_invite_offered_at timestamptz,
  ADD COLUMN IF NOT EXISTS season1_invite_deadline_at timestamptz,
  ADD COLUMN IF NOT EXISTS season1_invite_responded_at timestamptz,
  ADD COLUMN IF NOT EXISTS season1_invite_response text,
  ADD COLUMN IF NOT EXISTS season1_invite_token text,
  ADD COLUMN IF NOT EXISTS season1_invite_inbox_id bigint,
  ADD COLUMN IF NOT EXISTS season1_invite_offer_count integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.gpsl_owner_registry.season1_invite_queue_num IS
  'Dense Season 1 invite order (1..N). Cleared when slot freed; lower numbers bump up.';
COMMENT ON COLUMN public.gpsl_owner_registry.season1_invite_status IS
  'queued | offered | accepted | declined | expired';
COMMENT ON COLUMN public.gpsl_owner_registry.season1_invite_response IS
  'Permanent audit: accepted | declined (survives queue clear).';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'gpsl_owner_registry_s1_status_chk'
  ) THEN
    ALTER TABLE public.gpsl_owner_registry
      ADD CONSTRAINT gpsl_owner_registry_s1_status_chk
      CHECK (
        season1_invite_status IS NULL
        OR season1_invite_status IN ('queued','offered','accepted','declined','expired')
      );
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'gpsl_owner_registry_s1_response_chk'
  ) THEN
    ALTER TABLE public.gpsl_owner_registry
      ADD CONSTRAINT gpsl_owner_registry_s1_response_chk
      CHECK (
        season1_invite_response IS NULL
        OR season1_invite_response IN ('accepted','declined')
      );
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS gpsl_owner_registry_s1_queue_uidx
  ON public.gpsl_owner_registry (season1_invite_queue_num)
  WHERE season1_invite_queue_num IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS gpsl_owner_registry_s1_token_uidx
  ON public.gpsl_owner_registry (season1_invite_token)
  WHERE season1_invite_token IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Audit events
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.gpsl_season1_invite_events (
  id bigserial PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_type text NOT NULL,
  queue_num integer,
  actor_id uuid,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS gpsl_season1_invite_events_owner_idx
  ON public.gpsl_season1_invite_events (owner_id, created_at DESC);

ALTER TABLE public.gpsl_season1_invite_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_s1_events_staff_select ON public.gpsl_season1_invite_events;
CREATE POLICY gpsl_s1_events_staff_select
  ON public.gpsl_season1_invite_events FOR SELECT TO authenticated
  USING (public.is_gpsl_admin_or_mod());

-- ---------------------------------------------------------------------------
-- Email outbox
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.gpsl_email_outbox (
  id bigserial PRIMARY KEY,
  kind text NOT NULL,
  to_email text NOT NULL,
  to_owner_id uuid,
  subject text NOT NULL,
  html_body text NOT NULL,
  text_body text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','sent','failed','skipped')),
  error_text text,
  sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS gpsl_email_outbox_pending_idx
  ON public.gpsl_email_outbox (status, id)
  WHERE status = 'pending';

ALTER TABLE public.gpsl_email_outbox ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_email_outbox_staff_select ON public.gpsl_email_outbox;
CREATE POLICY gpsl_email_outbox_staff_select
  ON public.gpsl_email_outbox FOR SELECT TO authenticated
  USING (public.is_gpsl_admin_or_mod());

-- ---------------------------------------------------------------------------
-- Inbox type widen
-- ---------------------------------------------------------------------------
DO $inbox$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT 'season1_invite'
  ) s;

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  BEGIN
    ALTER TABLE public.competition_inbox
      VALIDATE CONSTRAINT competition_inbox_message_type_check;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'inbox type check left NOT VALID: %', SQLERRM;
  END;
END;
$inbox$;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.season1_invite_format_deadline_uk(p_at timestamptz)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT to_char(coalesce(p_at, now()) AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI')
    || ' UK';
$$;

CREATE OR REPLACE FUNCTION public.season1_invite_log_event(
  p_owner_id uuid,
  p_event_type text,
  p_queue_num integer DEFAULT NULL,
  p_details jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  INSERT INTO public.gpsl_season1_invite_events (owner_id, event_type, queue_num, actor_id, details)
  VALUES (
    p_owner_id,
    nullif(btrim(p_event_type), ''),
    p_queue_num,
    auth.uid(),
    coalesce(p_details, '{}'::jsonb)
  );
END;
$fn$;

CREATE OR REPLACE FUNCTION public.season1_invite_renumber_from(p_cleared_num integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_count integer := 0;
BEGIN
  IF p_cleared_num IS NULL OR p_cleared_num < 1 THEN
    RETURN 0;
  END IF;
  UPDATE public.gpsl_owner_registry r
  SET season1_invite_queue_num = r.season1_invite_queue_num - 1
  WHERE r.season1_invite_queue_num IS NOT NULL
    AND r.season1_invite_queue_num > p_cleared_num;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN coalesce(v_count, 0);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.season1_invite_row_json(r public.gpsl_owner_registry)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'queue_num', r.season1_invite_queue_num,
    'status', r.season1_invite_status,
    'response', r.season1_invite_response,
    'offered_at', r.season1_invite_offered_at,
    'deadline_at', r.season1_invite_deadline_at,
    'deadline_label', CASE
      WHEN r.season1_invite_deadline_at IS NULL THEN NULL
      ELSE public.season1_invite_format_deadline_uk(r.season1_invite_deadline_at)
    END,
    'responded_at', r.season1_invite_responded_at,
    'offer_count', coalesce(r.season1_invite_offer_count, 0)
  );
$$;

-- Map for admin board merge (avoids rewriting waiting_list_admin body)
CREATE OR REPLACE FUNCTION public.admin_season1_invite_status_map()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_map jsonb := '{}'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;

  SELECT coalesce(jsonb_object_agg(r.owner_id::text, public.season1_invite_row_json(r)), '{}'::jsonb)
  INTO v_map
  FROM public.gpsl_owner_registry r
  WHERE r.season1_invite_queue_num IS NOT NULL
     OR r.season1_invite_status IS NOT NULL
     OR r.season1_invite_response IS NOT NULL;

  RETURN v_map;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Assign next #
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
      season1_invite_status = coalesce(nullif(btrim(season1_invite_status), ''), 'queued')
  WHERE owner_id = p_owner_id
  RETURNING * INTO v_row;

  PERFORM public.season1_invite_log_event(
    p_owner_id, 'queue_assigned', v_next, jsonb_build_object('source', 'admin_click')
  );

  RETURN jsonb_build_object(
    'ok', true, 'already', false, 'owner_id', p_owner_id,
    'queue_num', v_next,
    'season1', public.season1_invite_row_json(v_row)
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Clear # + bump
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_season1_invite_clear_number(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_cleared integer;
  v_bumped integer;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;

  SELECT * INTO v_row FROM public.gpsl_owner_registry WHERE owner_id = p_owner_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No registry row';
  END IF;

  v_cleared := v_row.season1_invite_queue_num;
  IF v_cleared IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'cleared', false, 'owner_id', p_owner_id);
  END IF;

  UPDATE public.gpsl_owner_registry
  SET season1_invite_queue_num = NULL,
      season1_invite_status = CASE
        WHEN season1_invite_response IS NOT NULL THEN season1_invite_status
        WHEN season1_invite_status IN ('offered', 'queued') THEN NULL
        ELSE season1_invite_status
      END,
      season1_invite_token = CASE
        WHEN season1_invite_response IS NULL AND season1_invite_status = 'offered' THEN NULL
        ELSE season1_invite_token
      END
  WHERE owner_id = p_owner_id
  RETURNING * INTO v_row;

  v_bumped := public.season1_invite_renumber_from(v_cleared);
  PERFORM public.season1_invite_log_event(
    p_owner_id, 'queue_cleared', v_cleared, jsonb_build_object('bumped', v_bumped)
  );

  RETURN jsonb_build_object(
    'ok', true, 'cleared', true, 'owner_id', p_owner_id,
    'cleared_num', v_cleared, 'bumped', v_bumped,
    'season1', public.season1_invite_row_json(v_row)
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Send invite (48h)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_season1_invite_send(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_email text;
  v_tag text;
  v_deadline timestamptz;
  v_token text;
  v_inbox_id bigint;
  v_email_id bigint;
  v_deadline_label text;
  v_title text;
  v_body text;
  v_site text := 'https://gpsuperleague.github.io/GPSL';
  v_accept_url text;
  v_decline_url text;
  v_discord_id text;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;

  SELECT * INTO v_row FROM public.gpsl_owner_registry WHERE owner_id = p_owner_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No registry row';
  END IF;

  IF v_row.season1_invite_queue_num IS NULL THEN
    RAISE EXCEPTION 'Assign a Season 1 queue number before inviting';
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
  v_discord_id := nullif(btrim(coalesce(v_row.discord_user_id, '')), '');

  v_deadline := now() + interval '48 hours';
  v_token := encode(gen_random_bytes(24), 'hex');
  v_deadline_label := public.season1_invite_format_deadline_uk(v_deadline);
  v_accept_url := v_site || '/season1_invite.html?token=' || v_token || '&decision=accept';
  v_decline_url := v_site || '/season1_invite.html?token=' || v_token || '&decision=decline';

  v_title := 'You''re invited to GPSL Season 1';
  v_body :=
    'Congratulations ' || v_tag || ' — you have been invited to join GPSL Season 1 (club auction).'
    || E'\n\nYou have 48 hours to accept or decline.'
    || E'\nDeadline: ' || v_deadline_label || '.'
    || E'\nQueue position: #' || v_row.season1_invite_queue_num::text || '.'
    || E'\n\nRespond from Inbox, Waiting list, or your email links.';

  IF to_regprocedure(
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
      season1_invite_offered_at = now(),
      season1_invite_deadline_at = v_deadline,
      season1_invite_token = v_token,
      season1_invite_inbox_id = v_inbox_id,
      season1_invite_offer_count = coalesce(season1_invite_offer_count, 0) + 1,
      season1_invite_responded_at = NULL,
      season1_invite_response = CASE
        WHEN season1_invite_response = 'declined' THEN NULL
        ELSE season1_invite_response
      END
  WHERE owner_id = p_owner_id
  RETURNING * INTO v_row;

  IF to_regprocedure(
    'public.gpsl_discord_feed_enqueue(text,text,text,integer,text,jsonb)'
  ) IS NOT NULL THEN
    PERFORM public.gpsl_discord_feed_enqueue(
      'news',
      'Season 1 invite',
      v_tag || ' has been invited to Season 1. Deadline: ' || v_deadline_label || '.',
      16750848,
      'season1_invite:' || p_owner_id::text || ':' || v_token,
      jsonb_build_object(
        'channel', 'news',
        'ping', true,
        'owner_tag', v_tag,
        'owner_tags', jsonb_build_array(v_tag),
        'discord_user_id', v_discord_id,
        'deadline_at', v_deadline,
        'queue_num', v_row.season1_invite_queue_num
      )
    );
  END IF;

  INSERT INTO public.gpsl_email_outbox (
    kind, to_email, to_owner_id, subject, html_body, text_body, metadata
  ) VALUES (
    'season1_invite',
    v_email,
    p_owner_id,
    v_title,
    '<div style="font-family:Arial,Helvetica,sans-serif;line-height:1.5;color:#222">'
      || '<h2 style="color:#cc7a00;margin:0 0 12px">You''re invited to GPSL Season 1</h2>'
      || '<p>Hi <strong>' || replace(replace(v_tag, '&', '&amp;'), '<', '&lt;') || '</strong>,</p>'
      || '<p>You have been invited to join <strong>GPSL Season 1</strong> and the club auction.</p>'
      || '<p>You have <strong>48 hours</strong> to accept or decline.<br>'
      || 'Deadline: <strong>' || v_deadline_label || '</strong>.</p>'
      || '<p>Queue position: <strong>#' || v_row.season1_invite_queue_num::text || '</strong></p>'
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
      'email_outbox_id', v_email_id
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'email', v_email,
    'owner_tag', v_tag,
    'queue_num', v_row.season1_invite_queue_num,
    'deadline_at', v_deadline,
    'deadline_label', v_deadline_label,
    'inbox_id', v_inbox_id,
    'email_outbox_id', v_email_id,
    'season1', public.season1_invite_row_json(v_row)
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Respond
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

  IF v_row.season1_invite_inbox_id IS NOT NULL THEN
    UPDATE public.competition_inbox
    SET read_at = coalesce(read_at, now())
    WHERE id = v_row.season1_invite_inbox_id;
  END IF;

  PERFORM public.season1_invite_log_event(
    v_row.owner_id,
    CASE WHEN v_decision = 'accepted' THEN 'invite_accepted' ELSE 'invite_declined' END,
    v_row.season1_invite_queue_num,
    jsonb_build_object('via_token', v_token IS NOT NULL)
  );

  RETURN jsonb_build_object(
    'ok', true, 'already', false,
    'response', v_decision,
    'owner_id', v_row.owner_id,
    'queue_num', v_row.season1_invite_queue_num,
    'owner_tag', public.owner_registry_resolve_tag(v_row.owner_id),
    'season1', public.season1_invite_row_json(v_row)
  );
END;
$fn$;

CREATE OR REPLACE FUNCTION public.owner_season1_invite_get_mine()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row public.gpsl_owner_registry%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('authenticated', false);
  END IF;
  SELECT * INTO v_row FROM public.gpsl_owner_registry WHERE owner_id = auth.uid();
  IF NOT FOUND THEN
    RETURN jsonb_build_object('authenticated', true, 'has_invite', false);
  END IF;
  RETURN jsonb_build_object(
    'authenticated', true,
    'has_invite',
      coalesce(v_row.season1_invite_status, '') = 'offered'
      AND v_row.season1_invite_response IS NULL,
    'season1', public.season1_invite_row_json(v_row)
  );
END;
$fn$;

CREATE OR REPLACE FUNCTION public.season1_invite_peek_token(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_token text := nullif(btrim(coalesce(p_token, '')), '');
  v_row public.gpsl_owner_registry%ROWTYPE;
BEGIN
  IF v_token IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_token');
  END IF;
  SELECT * INTO v_row FROM public.gpsl_owner_registry WHERE season1_invite_token = v_token;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'owner_tag', public.owner_registry_resolve_tag(v_row.owner_id),
    'season1', public.season1_invite_row_json(v_row),
    'expired', coalesce(v_row.season1_invite_deadline_at < now(), false)
  );
END;
$fn$;

-- Edge helper: claim pending email rows
CREATE OR REPLACE FUNCTION public.admin_season1_invite_claim_email(p_outbox_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row public.gpsl_email_outbox%ROWTYPE;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;
  SELECT * INTO v_row FROM public.gpsl_email_outbox WHERE id = p_outbox_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Outbox row not found';
  END IF;
  RETURN to_jsonb(v_row);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.admin_season1_invite_mark_email(
  p_outbox_id bigint,
  p_status text,
  p_error text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;
  UPDATE public.gpsl_email_outbox
  SET status = p_status,
      error_text = nullif(btrim(coalesce(p_error, '')), ''),
      sent_at = CASE WHEN p_status = 'sent' THEN now() ELSE sent_at END
  WHERE id = p_outbox_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_season1_invite_status_map() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_season1_invite_assign_next(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_season1_invite_clear_number(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_season1_invite_send(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_season1_invite_respond(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_season1_invite_respond(text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.owner_season1_invite_get_mine() TO authenticated;
GRANT EXECUTE ON FUNCTION public.season1_invite_peek_token(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.season1_invite_peek_token(text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_season1_invite_claim_email(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_season1_invite_mark_email(bigint, text, text) TO authenticated;

-- Clear S1# when archiving via waiting-list remove (wrap existing behaviour)
CREATE OR REPLACE FUNCTION public.admin_waiting_list_remove(
  p_owner_email text DEFAULT NULL,
  p_owner_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_user_id uuid;
  v_email text;
  v_tag text;
  v_status text;
  v_cleared integer;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_owner_id IS NOT NULL THEN
    v_user_id := p_owner_id;
  ELSIF nullif(btrim(p_owner_email), '') IS NOT NULL THEN
    SELECT u.id INTO v_user_id
    FROM auth.users u
    WHERE lower(u.email) = lower(btrim(p_owner_email))
    LIMIT 1;
  ELSE
    RAISE EXCEPTION 'Provide owner email or owner id';
  END IF;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user found';
  END IF;

  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_user_id;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_user_id) THEN
    RAISE EXCEPTION 'User still has a club — remove from club first';
  END IF;

  SELECT r.status,
         coalesce(nullif(btrim(r.owner_tag), ''), nullif(btrim(v_email), '')),
         r.season1_invite_queue_num
  INTO v_status, v_tag, v_cleared
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Owner is not in the registry';
  END IF;

  IF v_status NOT IN ('member', 'on_absence', 'awaiting_club_auction', 'on_break') THEN
    RAISE EXCEPTION 'Owner is not on the waiting list / on break (status=%)', v_status;
  END IF;

  UPDATE public.gpsl_owner_registry
  SET status = 'archived',
      waiting_list_tier = NULL,
      waiting_list_admin_sort = NULL,
      waiting_list_use_admin_sort = false,
      returned_to_list_at = NULL,
      absence_note = NULL,
      pending_starting_balance = 0,
      season1_invite_queue_num = NULL,
      status_note = CASE
        WHEN v_status = 'on_break' THEN coalesce(nullif(btrim(status_note), ''), 'Archived from on break')
        ELSE coalesce(status_note, 'Removed from waiting list')
      END,
      status_changed_at = now()
  WHERE owner_id = v_user_id;

  IF v_cleared IS NOT NULL THEN
    PERFORM public.season1_invite_renumber_from(v_cleared);
    PERFORM public.season1_invite_log_event(
      v_user_id, 'queue_cleared_on_archive', v_cleared, '{}'::jsonb
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', v_user_id,
    'email', v_email,
    'owner_tag', v_tag,
    'previous_status', v_status,
    'status', 'archived',
    'cleared_s1_num', v_cleared
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_waiting_list_remove(text, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
