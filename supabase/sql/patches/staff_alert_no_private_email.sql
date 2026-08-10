-- =============================================================================
-- Privacy harden: member emails never leave the account holder
--
-- Rule: private details (email etc.) are for the logged-in user only —
-- never Discord, never staff-alert body/metadata shared across staff.
--
-- • Stop storing / resolving email in gpsl_staff_alert_notify_member_joined
-- • Scrub existing member_joined alerts (body + metadata)
-- • Scrub pending Discord feed rows that still contain an Email: line
--
-- Safe re-run. p_email kept on signature for callers; ignored.
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

  v_joined := CASE
    WHEN p_discord_joined_at IS NOT NULL THEN
      to_char(p_discord_joined_at AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI')
    ELSE 'unknown'
  END;

  v_headline := format('New GPSL member: %s', v_tag);
  v_body := format(
    E'Owner tag: %s\nDiscord: %s\nDiscord server joined: %s (UK)\n\nThey are on the waiting list.',
    v_tag,
    v_discord,
    v_joined
  );

  v_id := public.gpsl_staff_alert_create(
    'member_joined',
    v_headline,
    v_body,
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

  BEGIN
    IF to_regprocedure(
      'public.gpsl_discord_feed_enqueue_notification(text,text,text,integer,text,jsonb)'
    ) IS NOT NULL THEN
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'notification',
        '🆕 ' || v_headline,
        v_body,
        5763719,
        'member_joined:' || p_owner_id::text,
        jsonb_build_object(
          'owner_id', p_owner_id,
          'owner_tag', p_owner_tag,
          'kind', 'member_joined',
          'channel', 'notifications'
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
  'Staff + Discord alert for new waiting-list members. Never includes email or other private account details.';

GRANT EXECUTE ON FUNCTION public.gpsl_staff_alert_notify_member_joined(uuid, text, text, text, text, timestamptz)
  TO service_role;

-- Trigger: do not look up or pass email
CREATE OR REPLACE FUNCTION public.trg_gpsl_owner_registry_staff_alert_joined()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fire boolean := false;
BEGIN
  IF to_regprocedure(
       'public.gpsl_staff_alert_notify_member_joined(uuid,text,text,text,text,timestamptz)'
     ) IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_fire := NEW.waiting_list_tier IS NOT NULL
      AND NEW.status IN ('member', 'waiting', 'active');
  ELSIF TG_OP = 'UPDATE' THEN
    v_fire := NEW.waiting_list_tier IS NOT NULL
      AND NEW.fairplay_accepted_at IS NOT NULL
      AND OLD.fairplay_accepted_at IS NULL;
  END IF;

  IF NOT v_fire THEN
    RETURN NEW;
  END IF;

  BEGIN
    PERFORM public.gpsl_staff_alert_notify_member_joined(
      NEW.owner_id,
      NULL, -- never pass email into shared alerts
      NEW.owner_tag,
      NEW.discord_user_id,
      NULL,
      NEW.discord_joined_at
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'trg staff alert member_joined failed: %', SQLERRM;
  END;

  RETURN NEW;
END;
$function$;

-- Scrub historical staff alerts that already stored email
UPDATE public.gpsl_staff_alerts a
SET
  body = regexp_replace(a.body, E'(?m)^Email:.*\\n?', '', 'g'),
  metadata = coalesce(a.metadata, '{}'::jsonb) - 'email'
WHERE a.alert_type = 'member_joined'
  AND (
    a.body ~* E'(?m)^Email:'
    OR (a.metadata ? 'email')
  );

-- Scrub pending Discord queue rows (if table exists) that still have Email in body
DO $scrub$
BEGIN
  IF to_regclass('public.gpsl_discord_feed_queue') IS NOT NULL THEN
    EXECUTE $q$
      UPDATE public.gpsl_discord_feed_queue q
      SET body = regexp_replace(q.body, E'(?m)^Email:.*\\n?', '', 'g'),
          metadata = coalesce(q.metadata, '{}'::jsonb) - 'email'
      WHERE q.body ~* E'(?m)^Email:'
         OR (q.metadata ? 'email')
    $q$;
  END IF;
END;
$scrub$;
