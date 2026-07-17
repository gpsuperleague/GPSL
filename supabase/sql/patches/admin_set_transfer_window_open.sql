-- =============================================================================
-- Admin RPC: set transfer window open/closed
-- Discord: ONE notification via AFTER UPDATE trigger only (not also from RPC).
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
  -- Stable per transition direction + minute is enough; avoid double from ms jitter
  v_ts text := to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI');
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

  -- Do NOT call request_flush here — queue AFTER INSERT already flushes.
  -- A second flush races the first and posts the same row twice to Discord.

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_notify_transfer_window(boolean)
  TO authenticated, service_role;

-- Sole Discord path for transfer window flips
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_transfer_window()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.transfer_window_open IS DISTINCT FROM OLD.transfer_window_open THEN
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

-- RPC: update only — Discord comes from the trigger above (exactly once)
CREATE OR REPLACE FUNCTION public.admin_set_transfer_window_open(p_open boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_before boolean;
  v_after boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

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

  RETURN jsonb_build_object(
    'ok', true,
    'transfer_window_open', v_after,
    'changed', v_after IS DISTINCT FROM v_before,
    'hint', CASE
      WHEN v_after IS NOT DISTINCT FROM v_before THEN
        'Window already in that state — flip the other way for a Discord post.'
      ELSE
        'Updated. One Discord notification is queued via trigger.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_set_transfer_window_open(boolean) TO authenticated;

-- Remove transfer-window Discord from the club-auction settings trigger if still present
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

  -- transfer window: ONLY trg_gpsl_discord_feed_transfer_window

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

NOTIFY pgrst, 'reload schema';
