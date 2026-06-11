-- Fix draft schedule inbox: separate player vs manager wording; never reveal random finish time.
-- Run after owner_inbox_notifications.sql. Safe to re-run.

CREATE OR REPLACE FUNCTION public.trg_global_settings_inbox_notify()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_start text;
  v_player_on boolean;
  v_manager_on boolean;
BEGIN
  IF NEW.draft_auction_start_time IS DISTINCT FROM OLD.draft_auction_start_time
     AND NEW.draft_auction_start_time IS NOT NULL THEN
    v_start := to_char(NEW.draft_auction_start_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI');
    v_player_on := coalesce(NEW.draft_auction_enabled, false);
    v_manager_on := coalesce(NEW.manager_draft_auction_enabled, false);

    IF v_player_on THEN
      PERFORM public.owner_inbox_notify_all_clubs(
        'draft_scheduled',
        'Player draft auction scheduled',
        format(
          E'Player draft auction opens %s (UK).\nBidding closes at a secret random time — the countdown on the draft auction page never shows the exact moment in advance.\nCheck GPDB and Draft Auction.',
          v_start
        ),
        'draftauction.html',
        'draft_scheduled:player:' || NEW.draft_auction_start_time::text,
        NULL
      );
    END IF;

    IF v_manager_on THEN
      PERFORM public.owner_inbox_notify_all_clubs(
        'draft_scheduled',
        'Manager draft auction scheduled',
        format(
          E'Manager draft auction opens %s (UK).\nBidding closes at a secret random time — the countdown on MGDB never shows the exact moment in advance.\nCheck MGDB and Manager Draft Auction.',
          v_start
        ),
        'manager_draftauction.html',
        'draft_scheduled:manager:' || NEW.draft_auction_start_time::text,
        NULL
      );
    END IF;
  END IF;

  IF NEW.transfer_window_open IS TRUE AND coalesce(OLD.transfer_window_open, false) IS FALSE THEN
    PERFORM public.owner_inbox_notify_all_clubs(
      'transfer_upcoming',
      'Transfer window is open',
      E'The transfer window is now open. List players, make offers, and watch the transfer market.',
      'transfer_center.html',
      'transfer_window_open:' || to_char(now(), 'YYYYMMDD'),
      NULL
    );
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS global_settings_inbox_notify ON public.global_settings;
CREATE TRIGGER global_settings_inbox_notify
  AFTER UPDATE ON public.global_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_global_settings_inbox_notify();
