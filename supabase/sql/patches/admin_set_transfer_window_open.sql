-- =============================================================================
-- Admin RPC: set transfer window + always enqueue #gpsl-notifications
--
-- Self-contained: includes notify helper (previous trigger no-op'd if missing).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_enqueue_notification(
  p_event_type text,
  p_headline text,
  p_body text DEFAULT NULL,
  p_color integer DEFAULT 5793266,
  p_dedupe_key text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN public.gpsl_discord_feed_enqueue(
    coalesce(nullif(btrim(p_event_type), ''), 'notification'),
    p_headline,
    p_body,
    p_color,
    p_dedupe_key,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('channel', 'notifications')
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_enqueue_notification(text, text, text, integer, text, jsonb)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_discord_notify_transfer_window(p_open boolean)
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

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_transfer_window()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  -- Skip when admin RPC already enqueues (session flag)
  IF TG_OP = 'UPDATE'
     AND NEW.transfer_window_open IS DISTINCT FROM OLD.transfer_window_open
     AND coalesce(current_setting('gpsl.skip_transfer_window_discord', true), '') <> '1' THEN
    BEGIN
      PERFORM public.gpsl_discord_notify_transfer_window(
        NEW.transfer_window_open IS TRUE
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'trg transfer window Discord notify failed: %', SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_transfer_window ON public.global_settings;
CREATE TRIGGER trg_gpsl_discord_feed_transfer_window
  AFTER UPDATE OF transfer_window_open ON public.global_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_transfer_window();

CREATE OR REPLACE FUNCTION public.admin_set_transfer_window_open(p_open boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_before boolean;
  v_after boolean;
  v_queue_id bigint;
  v_discord_err text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Prevent trigger double-post; RPC enqueues explicitly
  PERFORM set_config('gpsl.skip_transfer_window_discord', '1', true);

  SELECT transfer_window_open INTO v_before
  FROM public.global_settings
  WHERE id = 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_global_settings');
  END IF;

  UPDATE public.global_settings
  SET transfer_window_open = coalesce(p_open, false),
      updated_at = now()
  WHERE id = 1
  RETURNING transfer_window_open INTO v_after;

  IF v_after IS DISTINCT FROM v_before THEN
    BEGIN
      v_queue_id := public.gpsl_discord_notify_transfer_window(v_after IS TRUE);
    EXCEPTION WHEN OTHERS THEN
      v_discord_err := SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'transfer_window_open', v_after,
    'changed', v_after IS DISTINCT FROM v_before,
    'discord_queue_id', v_queue_id,
    'discord_error', v_discord_err,
    'hint', CASE
      WHEN v_after IS NOT DISTINCT FROM v_before THEN
        'Window already in that state — flip the other way to enqueue Discord.'
      WHEN v_queue_id IS NOT NULL THEN
        'Queued for #gpsl-notifications — Push queue if auto-flush is off.'
      WHEN v_discord_err IS NOT NULL THEN
        'Window updated but Discord enqueue failed: ' || v_discord_err
      ELSE
        'Window updated but no queue id — check gpsl_discord_feed_enqueue exists.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_set_transfer_window_open(boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
