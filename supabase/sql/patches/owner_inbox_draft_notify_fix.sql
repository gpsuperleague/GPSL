-- Draft inbox: notify on manager/player draft re-enable (not only start_time change).
-- Also clears manager draft flag on schedule reset. Safe to re-run.

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_draft_schedule_from_settings(
  p_old public.global_settings,
  p_new public.global_settings
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_start text;
  v_start_changed boolean;
  v_player_on boolean;
  v_manager_on boolean;
  v_player_notify boolean;
  v_manager_notify boolean;
  v_dedupe_ts text;
BEGIN
  IF p_new.draft_auction_start_time IS NULL THEN
    RETURN;
  END IF;

  v_start_changed := p_new.draft_auction_start_time IS DISTINCT FROM p_old.draft_auction_start_time;
  v_player_on := coalesce(p_new.draft_auction_enabled, false);
  v_manager_on := coalesce(p_new.manager_draft_auction_enabled, false);

  v_player_notify := v_player_on
    AND (
      v_start_changed
      OR (v_player_on AND NOT coalesce(p_old.draft_auction_enabled, false))
    );

  v_manager_notify := v_manager_on
    AND (
      v_start_changed
      OR (v_manager_on AND NOT coalesce(p_old.manager_draft_auction_enabled, false))
    );

  IF NOT v_player_notify AND NOT v_manager_notify THEN
    RETURN;
  END IF;

  v_start := to_char(p_new.draft_auction_start_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI');
  v_dedupe_ts := floor(extract(epoch FROM coalesce(p_new.updated_at, now())))::text;

  IF v_player_notify THEN
    PERFORM public.owner_inbox_notify_all_clubs(
      'draft_scheduled',
      'Player draft auction scheduled',
      format(
        E'Player draft auction opens %s (UK).\nBidding closes at a secret random time — the countdown on the draft auction page never shows the exact moment in advance.\nCheck GPDB and Draft Auction.',
        v_start
      ),
      'draftauction.html',
      'draft_scheduled:player:' || p_new.draft_auction_start_time::text || ':' || v_dedupe_ts,
      NULL
    );
  END IF;

  IF v_manager_notify THEN
    PERFORM public.owner_inbox_notify_all_clubs(
      'draft_scheduled',
      'Manager draft auction scheduled',
      format(
        E'Manager draft auction opens %s (UK).\nBidding closes at a secret random time — the countdown on MGDB never shows the exact moment in advance.\nCheck MGDB and Manager Draft Auction.',
        v_start
      ),
      'manager_draftauction.html',
      'draft_scheduled:manager:' || p_new.draft_auction_start_time::text || ':' || v_dedupe_ts,
      NULL
    );
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_global_settings_inbox_notify()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.owner_inbox_notify_draft_schedule_from_settings(OLD, NEW);

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

GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_draft_schedule_from_settings(public.global_settings, public.global_settings) TO authenticated;

-- Reset schedule should disable manager draft too (was left on after reset).
CREATE OR REPLACE FUNCTION public.admin_reset_draft_auction()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not authorized to reset draft auction';
  END IF;

  UPDATE public.global_settings
  SET draft_auction_enabled = false,
      manager_draft_auction_enabled = false,
      draft_random_finish_time = null,
      draft_auction_start_time = null,
      updated_at = now()
  WHERE id = 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_purge_draft_auction_data()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  DELETE FROM public."Player_Transfer_Bids"
  WHERE listing_id IN (
    SELECT id FROM public."Player_Transfer_Listings" WHERE listing_type = 'draft'
  );

  DELETE FROM public."Player_Transfer_Bids"
  WHERE is_first_draft_bid = true OR is_draft_join = true;

  DELETE FROM public."Transfer_History"
  WHERE listing_id IN (
    SELECT id FROM public."Player_Transfer_Listings" WHERE listing_type = 'draft'
  );

  DELETE FROM public."Player_Transfer_Listings"
  WHERE listing_type = 'draft';

  UPDATE public.global_settings
  SET draft_auction_enabled = false,
      manager_draft_auction_enabled = false,
      draft_random_finish_time = null,
      draft_auction_start_time = null,
      updated_at = now()
  WHERE id = 1;
END;
$function$;
