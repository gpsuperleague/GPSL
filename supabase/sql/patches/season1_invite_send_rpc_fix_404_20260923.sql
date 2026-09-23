-- =============================================================================
-- Install Season 1 invite send RPC (clears 404)
--
-- Creates BOTH:
--   public.admin_s1_invite_send(uuid)          ← preferred (new name)
--   public.admin_season1_invite_send(uuid)     ← original name the UI also tries
--
-- Run ALL of this in Supabase SQL Editor.
-- Final SELECT must show 2 rows. Then hard-refresh admin waiting list.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

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

-- Shared implementation
CREATE OR REPLACE FUNCTION public._admin_s1_invite_send_impl(p_owner_id uuid)
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
  v_deadline_label text;
  v_title text;
  v_body text;
  v_is_staff boolean := false;
  v_has_offer_count boolean;
  v_has_inbox_id boolean;
  v_resent boolean := false;
BEGIN
  BEGIN
    v_is_staff := public.is_gpsl_admin_or_mod();
  EXCEPTION WHEN undefined_function THEN
    BEGIN
      v_is_staff := public.is_gpsl_admin();
    EXCEPTION WHEN undefined_function THEN
      v_is_staff := false;
    END;
  END;
  IF NOT coalesce(v_is_staff, false) THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;

  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'owner_id required';
  END IF;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = p_owner_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No registry row for owner';
  END IF;

  IF v_row.season1_invite_queue_num IS NULL THEN
    RAISE EXCEPTION 'Assign a Season 1 queue number before inviting';
  END IF;

  IF v_row.season1_invite_response = 'accepted' THEN
    RAISE EXCEPTION 'Owner already accepted Season 1';
  END IF;

  -- Already offered is OK: re-send (fresh 48h window + inbox + Discord).
  v_resent := (
    v_row.season1_invite_status = 'offered'
    AND v_row.season1_invite_response IS NULL
  );

  SELECT u.email::text INTO v_email FROM auth.users u WHERE u.id = p_owner_id;
  IF nullif(btrim(coalesce(v_email, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Owner has no email';
  END IF;

  BEGIN
    v_tag := nullif(btrim(public.owner_registry_resolve_tag(p_owner_id)), '');
  EXCEPTION WHEN undefined_function THEN
    v_tag := NULL;
  END;
  v_tag := coalesce(v_tag, nullif(btrim(v_row.owner_tag), ''), 'owner');

  v_deadline := now() + interval '48 hours';
  v_token := encode(gen_random_bytes(24), 'hex');
  v_deadline_label :=
    to_char(v_deadline AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' UK';

  v_title := 'You''re invited to GPSL Season 1';
  v_body :=
    'Congratulations ' || v_tag
    || ' — you have been invited to join GPSL Season 1.'
    || E'\n\nYou have 48 hours to accept or decline.'
    || E'\nDeadline: ' || v_deadline_label || '.'
    || E'\nQueue: #' || v_row.season1_invite_queue_num::text || '.'
    || E'\n\nRespond in Inbox or on the Waiting list page.';

  -- Inbox best-effort
  BEGIN
    BEGIN
      v_inbox_id := public.owner_inbox_send(
        'season1_invite', v_title, v_body, NULL, p_owner_id,
        NULL, NULL, NULL, NULL,
        'waiting_list.html#season1',
        'season1_invite:' || p_owner_id::text || ':' || v_token,
        NULL, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.competition_inbox (
        recipient_club_short_name, owner_id, message_type,
        title, body, action_href, dedupe_key
      ) VALUES (
        NULL, p_owner_id, 'season1_invite',
        v_title, v_body, 'waiting_list.html#season1',
        'season1_invite:' || p_owner_id::text || ':' || v_token
      )
      RETURNING id INTO v_inbox_id;
    END;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'inbox skipped: %', SQLERRM;
    v_inbox_id := NULL;
  END;

  UPDATE public.gpsl_owner_registry
  SET season1_invite_status = 'offered',
      season1_invite_offered_at = now(),
      season1_invite_deadline_at = v_deadline,
      season1_invite_token = v_token,
      season1_invite_responded_at = NULL,
      season1_invite_response = CASE
        WHEN season1_invite_response = 'declined' THEN NULL
        ELSE season1_invite_response
      END
  WHERE owner_id = p_owner_id;

  -- Optional columns (tolerate either naming from earlier patches)
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'gpsl_owner_registry'
      AND column_name = 'season1_invite_inbox_id'
  ) INTO v_has_inbox_id;
  IF v_has_inbox_id AND v_inbox_id IS NOT NULL THEN
    UPDATE public.gpsl_owner_registry
    SET season1_invite_inbox_id = v_inbox_id
    WHERE owner_id = p_owner_id;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'gpsl_owner_registry'
      AND column_name = 'season1_invite_offer_count'
  ) INTO v_has_offer_count;
  IF v_has_offer_count THEN
    UPDATE public.gpsl_owner_registry
    SET season1_invite_offer_count = coalesce(season1_invite_offer_count, 0) + 1
    WHERE owner_id = p_owner_id;
  END IF;

  SELECT * INTO v_row FROM public.gpsl_owner_registry WHERE owner_id = p_owner_id;

  -- Discord best-effort
  BEGIN
    IF to_regprocedure(
      'public.gpsl_discord_feed_enqueue(text,text,text,integer,text,jsonb)'
    ) IS NOT NULL THEN
      PERFORM public.gpsl_discord_feed_enqueue(
        'news',
        'Season 1 invite — @' || ltrim(v_tag, '@'),
        '@' || ltrim(v_tag, '@') || ' has been invited to GPSL Season 1.'
          || E'\nDeadline: ' || v_deadline_label
          || E'\nQueue: #' || v_row.season1_invite_queue_num::text,
        16750848,
        'season1_invite:' || p_owner_id::text || ':' || v_token,
        jsonb_build_object(
          'channel', 'news',
          'kind', 'season1_invite',
          'ping', true,
          'owner_tag', v_tag,
          'owner_tags', jsonb_build_array(v_tag),
          'deadline_label', v_deadline_label,
          'queue_num', v_row.season1_invite_queue_num
        )
      );
    ELSIF to_regclass('public.gpsl_discord_feed_queue') IS NOT NULL THEN
      INSERT INTO public.gpsl_discord_feed_queue (
        event_type, headline, body, color, dedupe_key, metadata, status
      ) VALUES (
        'news',
        left('Season 1 invite — @' || ltrim(v_tag, '@'), 250),
        '@' || ltrim(v_tag, '@') || ' invited to Season 1. Deadline: ' || v_deadline_label,
        16750848,
        'season1_invite:' || p_owner_id::text || ':' || v_token,
        jsonb_build_object(
          'channel', 'news', 'kind', 'season1_invite', 'ping', true,
          'owner_tag', v_tag, 'owner_tags', jsonb_build_array(v_tag)
        ),
        'pending'
      )
      ON CONFLICT DO NOTHING;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'discord skipped: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'resent', v_resent,
    'owner_id', p_owner_id,
    'email', v_email,
    'owner_tag', v_tag,
    'queue_num', v_row.season1_invite_queue_num,
    'deadline_at', v_deadline,
    'deadline_label', v_deadline_label,
    'inbox_id', v_inbox_id,
    'email_outbox_id', NULL
  );
END;
$fn$;

-- Preferred new name
CREATE OR REPLACE FUNCTION public.admin_s1_invite_send(p_owner_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public._admin_s1_invite_send_impl(p_owner_id);
$$;

-- Original name (restore / keep in sync)
CREATE OR REPLACE FUNCTION public.admin_season1_invite_send(p_owner_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public._admin_s1_invite_send_impl(p_owner_id);
$$;

GRANT EXECUTE ON FUNCTION public._admin_s1_invite_send_impl(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_s1_invite_send(uuid) TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION public.admin_season1_invite_send(uuid) TO authenticated, service_role, anon;

NOTIFY pgrst, 'reload schema';
SELECT pg_notify('pgrst', 'reload schema');

-- Must return 2 rows
SELECT p.proname AS name,
       pg_get_function_identity_arguments(p.oid) AS args,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS ok_auth
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('admin_s1_invite_send', 'admin_season1_invite_send')
ORDER BY 1;
