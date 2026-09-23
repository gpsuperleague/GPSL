-- =============================================================================
-- MINIMAL: create admin_season1_invite_send (fixes 404 on Invite to Season 1)
--
-- Run this alone in Supabase SQL Editor if you get:
--   POST .../rpc/admin_season1_invite_send 404
--
-- Safe re-run. Ends with schema reload for PostgREST.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Admin gate (prefer existing helpers)
CREATE OR REPLACE FUNCTION public.season1_invite_require_staff()
RETURNS void
LANGUAGE plpgsql
STABLE
AS $fn$
BEGIN
  IF to_regprocedure('public.is_gpsl_admin_or_mod()') IS NOT NULL THEN
    IF NOT public.is_gpsl_admin_or_mod() THEN
      RAISE EXCEPTION 'Admin or mod only';
    END IF;
    RETURN;
  END IF;
  IF to_regprocedure('public.is_gpsl_admin()') IS NOT NULL THEN
    IF NOT public.is_gpsl_admin() THEN
      RAISE EXCEPTION 'Admin only';
    END IF;
    RETURN;
  END IF;
  RAISE EXCEPTION 'No admin check function installed';
END;
$fn$;

-- Tag resolver
CREATE OR REPLACE FUNCTION public.season1_invite_owner_tag(p_owner_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_tag text;
BEGIN
  IF to_regprocedure('public.owner_registry_resolve_tag(uuid)') IS NOT NULL THEN
    v_tag := public.owner_registry_resolve_tag(p_owner_id);
  END IF;
  IF nullif(btrim(coalesce(v_tag, '')), '') IS NULL THEN
    SELECT nullif(btrim(r.owner_tag), '') INTO v_tag
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = p_owner_id;
  END IF;
  RETURN coalesce(nullif(btrim(v_tag), ''), 'owner');
END;
$fn$;

-- Deadline label
CREATE OR REPLACE FUNCTION public.season1_invite_format_deadline_uk(p_at timestamptz)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT to_char(coalesce(p_at, now()) AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI')
    || ' UK';
$$;

-- Ensure required columns exist
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

-- Inbox helper
CREATE OR REPLACE FUNCTION public.season1_invite_send_inbox(
  p_owner_id uuid,
  p_title text,
  p_body text,
  p_action_href text,
  p_dedupe_key text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_id bigint;
BEGIN
  IF p_owner_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_dedupe_key IS NOT NULL THEN
    SELECT i.id INTO v_id
    FROM public.competition_inbox i
    WHERE i.dedupe_key = p_dedupe_key
    LIMIT 1;
    IF v_id IS NOT NULL THEN
      RETURN v_id;
    END IF;
  END IF;

  BEGIN
    v_id := public.owner_inbox_send(
      'season1_invite', p_title, p_body, NULL, p_owner_id,
      NULL, NULL, NULL, NULL,
      p_action_href, p_dedupe_key, NULL, NULL
    );
    IF v_id IS NOT NULL THEN
      RETURN v_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'owner_inbox_send fallback: %', SQLERRM;
  END;

  INSERT INTO public.competition_inbox (
    recipient_club_short_name, owner_id, message_type,
    title, body, action_href, dedupe_key
  ) VALUES (
    NULL, p_owner_id, 'season1_invite',
    p_title, p_body, p_action_href, p_dedupe_key
  )
  RETURNING id INTO v_id;

  RETURN v_id;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'season1_invite_send_inbox failed: %', SQLERRM;
  RETURN NULL;
END;
$fn$;

-- Discord helper (best-effort)
CREATE OR REPLACE FUNCTION public.season1_invite_enqueue_discord_news(
  p_owner_id uuid,
  p_owner_tag text,
  p_deadline timestamptz,
  p_deadline_label text,
  p_queue_num integer,
  p_token text,
  p_discord_user_id text DEFAULT NULL
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
  v_deadline_label text := coalesce(nullif(btrim(p_deadline_label), ''), '48 hours');
  v_headline text := 'Season 1 invite — ' || v_mention;
  v_body text;
  v_dedupe text :=
    'season1_invite:' || coalesce(p_owner_id::text, 'na') || ':'
    || coalesce(nullif(btrim(p_token), ''), 'na');
BEGIN
  v_body :=
    v_mention || ' has been invited to GPSL Season 1.'
    || E'\nDeadline: ' || v_deadline_label
    || CASE WHEN p_queue_num IS NOT NULL THEN E'\nQueue: #' || p_queue_num::text ELSE '' END;

  IF to_regprocedure(
    'public.gpsl_discord_feed_enqueue(text,text,text,integer,text,jsonb)'
  ) IS NOT NULL THEN
    BEGIN
      v_id := public.gpsl_discord_feed_enqueue(
        'news', v_headline, v_body, 16750848, v_dedupe,
        jsonb_build_object(
          'channel', 'news',
          'kind', 'season1_invite',
          'ping', true,
          'owner_tag', v_tag,
          'owner_tags', jsonb_build_array(v_tag),
          'discord_user_id', nullif(btrim(coalesce(p_discord_user_id, '')), ''),
          'deadline_at', p_deadline,
          'deadline_label', v_deadline_label,
          'queue_num', p_queue_num
        )
      );
    EXCEPTION WHEN OTHERS THEN
      v_id := NULL;
    END;
  END IF;

  IF v_id IS NULL AND to_regclass('public.gpsl_discord_feed_queue') IS NOT NULL THEN
    BEGIN
      INSERT INTO public.gpsl_discord_feed_queue (
        event_type, headline, body, color, dedupe_key, metadata, status
      ) VALUES (
        'news', left(v_headline, 250), v_body, 16750848, v_dedupe,
        jsonb_build_object(
          'channel', 'news', 'kind', 'season1_invite', 'ping', true,
          'owner_tag', v_tag, 'owner_tags', jsonb_build_array(v_tag)
        ),
        'pending'
      )
      ON CONFLICT DO NOTHING
      RETURNING id INTO v_id;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN v_id;
END;
$fn$;

-- Optional event log (no-op if events table missing)
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
  IF to_regclass('public.gpsl_season1_invite_events') IS NULL THEN
    RETURN;
  END IF;
  INSERT INTO public.gpsl_season1_invite_events (
    owner_id, event_type, queue_num, actor_id, details
  ) VALUES (
    p_owner_id, p_event_type, p_queue_num, auth.uid(), coalesce(p_details, '{}'::jsonb)
  );
EXCEPTION WHEN OTHERS THEN
  NULL;
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

-- Widen inbox types (best effort)
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
    UNION SELECT 'season1_invite'
  ) s;

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IS NULL OR message_type IN (%s)) NOT VALID',
    v_list
  );
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'inbox type widen skipped: %', SQLERRM;
END;
$inbox$;

-- ===== THE RPC the UI calls =====
DROP FUNCTION IF EXISTS public.admin_season1_invite_send(uuid);

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
  v_discord_qid bigint;
  v_deadline_label text;
  v_title text;
  v_body text;
  v_site text := 'https://gpsuperleague.github.io/GPSL';
  v_discord_user text;
BEGIN
  PERFORM public.season1_invite_require_staff();

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = p_owner_id
  FOR UPDATE;

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

  v_tag := public.season1_invite_owner_tag(p_owner_id);
  v_discord_user := nullif(btrim(coalesce(v_row.discord_user_id, '')), '');

  v_deadline := now() + interval '48 hours';
  v_token := encode(gen_random_bytes(24), 'hex');
  v_deadline_label := public.season1_invite_format_deadline_uk(v_deadline);

  v_title := 'You''re invited to GPSL Season 1';
  v_body :=
    'Congratulations ' || v_tag
    || ' — you have been invited to join GPSL Season 1 (club auction).'
    || E'\n\nYou have 48 hours to accept or decline.'
    || E'\nDeadline: ' || v_deadline_label || '.'
    || E'\nQueue position: #' || v_row.season1_invite_queue_num::text || '.'
    || E'\n\nRespond from Inbox, Waiting list, or your email links.';

  v_inbox_id := public.season1_invite_send_inbox(
    p_owner_id,
    v_title,
    v_body,
    'waiting_list.html#season1',
    'season1_invite:' || p_owner_id::text || ':' || v_token
  );

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

  v_discord_qid := public.season1_invite_enqueue_discord_news(
    p_owner_id,
    v_tag,
    v_deadline,
    v_deadline_label,
    v_row.season1_invite_queue_num,
    v_token,
    v_discord_user
  );

  PERFORM public.season1_invite_log_event(
    p_owner_id,
    'invite_sent',
    v_row.season1_invite_queue_num,
    jsonb_build_object(
      'deadline_at', v_deadline,
      'inbox_id', v_inbox_id,
      'discord_queue_id', v_discord_qid
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
    'discord_queue_id', v_discord_qid,
    'email_outbox_id', NULL,
    'season1', public.season1_invite_row_json(v_row)
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_season1_invite_send(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_season1_invite_send(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.season1_invite_send_inbox(uuid, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.season1_invite_enqueue_discord_news(uuid, text, timestamptz, text, integer, text, text) TO authenticated;

-- Force PostgREST to see the new RPC (404 goes away after this)
NOTIFY pgrst, 'reload schema';

SELECT
  'admin_season1_invite_send ready' AS status,
  to_regprocedure('public.admin_season1_invite_send(uuid)') AS proc;
