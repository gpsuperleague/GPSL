-- =============================================================================
-- Discord: new member joins → #gpsl-news (not notifications / calendar)
--
-- Owner appointment already posts to News. Website join / waiting-list signup
-- was going via gpsl_discord_feed_enqueue_notification → notifications webhook
-- (often attached to a calendar-style channel). Route joins to News instead.
--
-- Safe re-run. No edge redeploy required (routing uses existing news webhook).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_staff_alert_notify_member_joined(
  p_owner_id uuid,
  p_email text DEFAULT NULL, -- ignored (compat); never stored or published
  p_owner_tag text DEFAULT NULL,
  p_discord_user_id text DEFAULT NULL,
  p_discord_username text DEFAULT NULL,
  p_discord_joined_at timestamptz DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_tag text := coalesce(nullif(btrim(p_owner_tag), ''), '—');
  v_mention text;
  v_discord text := coalesce(
    nullif(btrim(p_discord_username), ''),
    nullif(btrim(p_discord_user_id), ''),
    '—'
  );
  v_joined text;
  v_body text;
  v_headline text;
BEGIN
  IF p_owner_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Intentionally unused: private email must not be copied into shared alerts.
  PERFORM p_email;

  v_mention := '@' || ltrim(v_tag, '@');

  v_joined := CASE
    WHEN p_discord_joined_at IS NOT NULL THEN
      to_char(p_discord_joined_at AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI')
    ELSE 'unknown'
  END;

  v_headline := format('🆕 NEW MEMBER — %s', v_mention);
  v_body := format(
    E'%s has joined GPSL and is on the waiting list.\nDiscord: %s\nServer joined: %s (UK)',
    v_mention,
    v_discord,
    v_joined
  );

  v_id := public.gpsl_staff_alert_create(
    'member_joined',
    format('New GPSL member: %s', v_tag),
    format(
      E'Owner tag: %s\nDiscord: %s\nDiscord server joined: %s (UK)\n\nThey are on the waiting list.',
      v_tag,
      v_discord,
      v_joined
    ),
    'admin_owners_waiting_list.html',
    jsonb_build_object(
      'owner_id', p_owner_id,
      'owner_tag', p_owner_tag,
      'discord_user_id', p_discord_user_id,
      'discord_username', p_discord_username,
      'discord_joined_at', p_discord_joined_at
    ),
    'member_joined:' || p_owner_id::text
  );

  -- Discord #gpsl-news (same feed as new owner appointments)
  BEGIN
    IF to_regprocedure(
      'public.gpsl_discord_feed_enqueue(text,text,text,integer,text,jsonb)'
    ) IS NOT NULL THEN
      PERFORM public.gpsl_discord_feed_enqueue(
        'member',
        v_headline,
        v_body,
        5763719, -- green-ish
        'member_joined:' || p_owner_id::text,
        jsonb_build_object(
          'owner_id', p_owner_id,
          'owner_tag', nullif(btrim(p_owner_tag), ''),
          'mention', v_mention,
          'kind', 'member_joined',
          'channel', 'news'
        )
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'member_joined Discord enqueue failed: %', SQLERRM;
  END;

  RETURN v_id;
END;
$function$;

COMMENT ON FUNCTION public.gpsl_staff_alert_notify_member_joined(uuid, text, text, text, text, timestamptz) IS
  'Staff alert + Discord #gpsl-news post when a new member joins (waiting list). Email never published.';

GRANT EXECUTE ON FUNCTION public.gpsl_staff_alert_notify_member_joined(uuid, text, text, text, text, timestamptz)
  TO authenticated, service_role;

-- Re-route any still-pending notification-channel join posts to News
UPDATE public.gpsl_discord_feed_queue q
SET
  event_type = 'member',
  metadata = coalesce(q.metadata, '{}'::jsonb)
    || jsonb_build_object('channel', 'news', 'kind', 'member_joined'),
  last_error = NULL,
  status = CASE WHEN q.status = 'error' THEN 'pending' ELSE q.status END
WHERE q.status IN ('pending', 'error', 'posting')
  AND (
    q.dedupe_key LIKE 'member_joined:%'
    OR coalesce(q.metadata->>'kind', '') = 'member_joined'
    OR q.headline ILIKE '%New GPSL member%'
    OR q.headline ILIKE '%NEW MEMBER%'
  )
  AND coalesce(q.metadata->>'channel', '') IN ('notifications', 'notification', '');

NOTIFY pgrst, 'reload schema';
