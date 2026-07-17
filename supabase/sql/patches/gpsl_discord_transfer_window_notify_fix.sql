-- =============================================================================
-- Fix: transfer window open/close → #gpsl-notifications
--
-- Why it failed: Discord notify lived inside a broad global_settings trigger
-- that swallowed ALL errors (WHEN OTHERS), so enqueue failures were silent.
-- Also inbox only notified on open, never close.
--
-- Run this after gpsl_discord_notifications_channel.sql (needs enqueue helper).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_notify_transfer_window(
  p_open boolean
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_ts text := to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISSMS');
BEGIN
  IF p_open THEN
    v_id := public.gpsl_discord_feed_enqueue_notification(
      'notification',
      '🪟 TRANSFER WINDOW OPEN',
      'The transfer window is now open. List players, make offers, and watch the market.',
      5793266,
      'transfer_window_open:' || v_ts,
      jsonb_build_object('kind', 'transfer_window', 'open', true)
    );
  ELSE
    v_id := public.gpsl_discord_feed_enqueue_notification(
      'notification',
      '🪟 TRANSFER WINDOW CLOSED',
      'The transfer window is now shut. Direct market deals are paused until it reopens.',
      10038562,
      'transfer_window_closed:' || v_ts,
      jsonb_build_object('kind', 'transfer_window', 'open', false)
    );
  END IF;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_notify_transfer_window(boolean)
  TO authenticated, service_role;

-- Dedicated trigger — does not share exception handling with club-auction logic
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_transfer_window()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.transfer_window_open IS DISTINCT FROM OLD.transfer_window_open THEN
    PERFORM public.gpsl_discord_notify_transfer_window(
      NEW.transfer_window_open IS TRUE
    );
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_transfer_window ON public.global_settings;
CREATE TRIGGER trg_gpsl_discord_feed_transfer_window
  AFTER UPDATE OF transfer_window_open ON public.global_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_transfer_window();

-- Inbox path: open + close, and also Discord (belt-and-suspenders)
CREATE OR REPLACE FUNCTION public.trg_global_settings_inbox_notify()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.owner_inbox_notify_draft_schedule_from_settings(OLD, NEW);

  IF NEW.transfer_window_open IS DISTINCT FROM OLD.transfer_window_open THEN
    IF NEW.transfer_window_open IS TRUE THEN
      PERFORM public.owner_inbox_notify_all_clubs(
        'transfer_upcoming',
        'Transfer window is open',
        E'The transfer window is now open. List players, make offers, and watch the transfer market.',
        'transfer_center.html',
        'transfer_window_open:' || to_char(now(), 'YYYYMMDDHH24MI'),
        NULL
      );
    ELSE
      PERFORM public.owner_inbox_notify_all_clubs(
        'transfer_upcoming',
        'Transfer window is closed',
        E'The transfer window is now shut. Transfer market actions are paused until it reopens.',
        'transfer_center.html',
        'transfer_window_closed:' || to_char(now(), 'YYYYMMDDHH24MI'),
        NULL
      );
    END IF;

    -- Discord is handled by trg_gpsl_discord_feed_transfer_window; no duplicate here.
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS global_settings_inbox_notify ON public.global_settings;
CREATE TRIGGER global_settings_inbox_notify
  AFTER UPDATE ON public.global_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_global_settings_inbox_notify();

-- Stop swallowing errors in the broader settings Discord trigger
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_club_auction_settings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_start text;
  v_vacant int;
  v_names text;
BEGIN
  IF TG_OP = 'UPDATE'
     AND coalesce(NEW.club_auction_enabled, false) = true
     AND coalesce(OLD.club_auction_enabled, false) = false THEN
    BEGIN
      SELECT count(*)::int,
             string_agg(c."Club", ', ' ORDER BY c."Club")
      INTO v_vacant, v_names
      FROM public."Clubs" c
      WHERE c.owner_id IS NULL;
    EXCEPTION WHEN OTHERS THEN
      v_vacant := NULL;
      v_names := NULL;
    END;

    BEGIN
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'auction',
        '🔨 CLUB AUCTION OPEN',
        concat_ws(
          E'\n',
          'The club auction is now open.',
          CASE WHEN v_vacant IS NOT NULL THEN format('Vacant clubs: %s', v_vacant) END,
          nullif(left(coalesce(v_names, ''), 900), '')
        ),
        22456,
        'club_auction_open:' || to_char(now() AT TIME ZONE 'Europe/London', 'YYYY-MM-DD-HH24'),
        jsonb_build_object('kind', 'club_auction')
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'gpsl discord club auction notify failed: %', SQLERRM;
    END;
  END IF;

  -- Transfer window moved to trg_gpsl_discord_feed_transfer_window

  IF TG_OP = 'UPDATE' AND NEW.draft_auction_start_time IS NOT NULL THEN
    v_start := to_char(
      NEW.draft_auction_start_time AT TIME ZONE 'Europe/London',
      'Dy DD Mon YYYY HH24:MI'
    ) || ' (UK)';

    IF coalesce(NEW.draft_auction_enabled, false)
       AND (
         NEW.draft_auction_start_time IS DISTINCT FROM OLD.draft_auction_start_time
         OR NOT coalesce(OLD.draft_auction_enabled, false)
       ) THEN
      BEGIN
        PERFORM public.gpsl_discord_feed_enqueue_notification(
          'draft',
          '🧾 PLAYER DRAFT AUCTION',
          format('Player draft auction is scheduled.%sStarts: %s', E'\n', v_start),
          8070335,
          'player_draft_sched:' || to_char(NEW.draft_auction_start_time AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI'),
          jsonb_build_object('kind', 'player_draft')
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'gpsl discord player draft notify failed: %', SQLERRM;
      END;
    END IF;

    IF coalesce(NEW.manager_draft_auction_enabled, false)
       AND (
         NEW.draft_auction_start_time IS DISTINCT FROM OLD.draft_auction_start_time
         OR NOT coalesce(OLD.manager_draft_auction_enabled, false)
       ) THEN
      BEGIN
        PERFORM public.gpsl_discord_feed_enqueue_notification(
          'draft',
          '👔 MANAGER DRAFT AUCTION',
          format('Manager draft auction is scheduled.%sStarts: %s', E'\n', v_start),
          8070335,
          'manager_draft_sched:' || to_char(NEW.draft_auction_start_time AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI'),
          jsonb_build_object('kind', 'manager_draft')
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'gpsl discord manager draft notify failed: %', SQLERRM;
      END;
    END IF;
  END IF;

  RETURN NEW;
EXCEPTION WHEN undefined_column THEN
  RETURN NEW;
END;
$function$;

-- Admin: force a transfer-window Discord post (for testing without flipping twice)
CREATE OR REPLACE FUNCTION public.admin_discord_test_transfer_window_notify(
  p_open boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_id := public.gpsl_discord_notify_transfer_window(coalesce(p_open, true));

  RETURN jsonb_build_object(
    'ok', true,
    'queue_id', v_id,
    'hint', CASE
      WHEN v_id IS NULL THEN 'Enqueue returned null — check gpsl_discord_feed_enqueue_notification exists'
      ELSE 'Queued. Push Discord queue if auto-flush is off.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_test_transfer_window_notify(boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
