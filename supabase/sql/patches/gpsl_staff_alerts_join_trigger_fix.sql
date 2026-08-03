-- =============================================================================
-- Fix: staff alerts on new GPSL joins (missed notifications)
--
-- Cause: alerts were only called from discord-join-complete edge code. If that
-- function was not redeployed after gpsl_staff_alerts.sql, joins succeed with
-- no in-app alert and no Discord #gpsl-notifications ping.
--
-- Fix:
--   • DB trigger on gpsl_owner_registry (source of truth for new members)
--   • Discord enqueue uses event_type = notification
--   • Backfill alerts for recent joins that never got one
--
-- Safe re-run. Still redeploy discord-join-complete (belt + suspenders).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_staff_alert_notify_member_joined(
  p_owner_id uuid,
  p_email text DEFAULT NULL,
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
  v_email text := coalesce(nullif(btrim(p_email), ''), '—');
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

  -- Resolve email from auth if missing
  IF v_email = '—' THEN
    BEGIN
      SELECT coalesce(nullif(btrim(u.email), ''), '—')
      INTO v_email
      FROM auth.users u
      WHERE u.id = p_owner_id;
    EXCEPTION WHEN OTHERS THEN
      v_email := '—';
    END;
  END IF;

  v_joined := CASE
    WHEN p_discord_joined_at IS NOT NULL THEN
      to_char(p_discord_joined_at AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI')
    ELSE 'unknown'
  END;

  v_headline := format('New GPSL member: %s', v_tag);
  v_body := format(
    E'Owner tag: %s\nEmail: %s\nDiscord: %s\nDiscord server joined: %s (UK)\n\nThey are on the waiting list.',
    v_tag,
    v_email,
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
      'email', nullif(v_email, '—'),
      'owner_tag', p_owner_tag,
      'discord_user_id', p_discord_user_id,
      'discord_username', p_discord_username,
      'discord_joined_at', p_discord_joined_at
    ),
    'member_joined:' || p_owner_id::text
  );

  -- Discord #gpsl-notifications (best-effort)
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

-- Fire on registry insert / first join completion (does not rely on edge deploy)
CREATE OR REPLACE FUNCTION public.trg_gpsl_owner_registry_staff_alert_joined()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fire boolean := false;
  v_email text;
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
    -- Join form completion: fairplay accepted for the first time while on waiting list
    v_fire := NEW.waiting_list_tier IS NOT NULL
      AND NEW.fairplay_accepted_at IS NOT NULL
      AND OLD.fairplay_accepted_at IS NULL;
  END IF;

  IF NOT v_fire THEN
    RETURN NEW;
  END IF;

  BEGIN
    SELECT u.email INTO v_email FROM auth.users u WHERE u.id = NEW.owner_id;
  EXCEPTION WHEN OTHERS THEN
    v_email := NULL;
  END;

  BEGIN
    PERFORM public.gpsl_staff_alert_notify_member_joined(
      NEW.owner_id,
      v_email,
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

DROP TRIGGER IF EXISTS gpsl_owner_registry_staff_alert_joined ON public.gpsl_owner_registry;
CREATE TRIGGER gpsl_owner_registry_staff_alert_joined
  AFTER INSERT OR UPDATE OF fairplay_accepted_at, waiting_list_tier, status, discord_user_id
  ON public.gpsl_owner_registry
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_gpsl_owner_registry_staff_alert_joined();

-- Backfill: anyone on waiting list (last 14 days) without a member_joined alert
CREATE OR REPLACE FUNCTION public.admin_staff_alerts_backfill_recent_joins(
  p_days int DEFAULT 14
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_days int := greatest(1, least(coalesce(p_days, 14), 90));
  v_r record;
  v_email text;
  v_id bigint;
  v_n int := 0;
  v_details jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_r IN
    SELECT r.*
    FROM public.gpsl_owner_registry r
    WHERE r.waiting_list_tier IS NOT NULL
      AND coalesce(r.fairplay_accepted_at, r.status_changed_at, r.discord_joined_at) >=
          (now() - make_interval(days => v_days))
      AND NOT EXISTS (
        SELECT 1
        FROM public.gpsl_staff_alerts a
        WHERE a.alert_type = 'member_joined'
          AND a.metadata ->> 'dedupe_key' = 'member_joined:' || r.owner_id::text
      )
    ORDER BY coalesce(r.fairplay_accepted_at, r.status_changed_at) DESC NULLS LAST
  LOOP
    v_email := NULL;
    BEGIN
      SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_r.owner_id;
    EXCEPTION WHEN OTHERS THEN
      v_email := NULL;
    END;

    v_id := public.gpsl_staff_alert_notify_member_joined(
      v_r.owner_id,
      v_email,
      v_r.owner_tag,
      v_r.discord_user_id,
      NULL,
      v_r.discord_joined_at
    );

    IF v_id IS NOT NULL THEN
      v_n := v_n + 1;
      v_details := v_details || jsonb_build_array(
        jsonb_build_object(
          'owner_id', v_r.owner_id,
          'owner_tag', v_r.owner_tag,
          'alert_id', v_id
        )
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'days', v_days,
    'alerts_created', v_n,
    'details', v_details
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_staff_alert_notify_member_joined(uuid, text, text, text, text, timestamptz)
  TO service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_staff_alerts_backfill_recent_joins(int) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Create missing alerts for recent joins now:
SELECT public.admin_staff_alerts_backfill_recent_joins(14);
