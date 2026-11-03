-- Discord #gpsl-notifications (calendar):
--   1) ~24h before active GPSL month locks
--   2) When the calendar ticks into a new GPSL month (name the new month)
-- Safe re-run. Uses gpsl_discord_feed_enqueue_notification → calendar webhook.

ALTER TABLE public.gpsl_discord_notifications_state
  ADD COLUMN IF NOT EXISTS last_month_ending_warn_key text;

CREATE OR REPLACE FUNCTION public.gpsl_discord_calendar_month_announcements()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_prev text;
  v_month_label text;
  v_next_month text;
  v_next_label text;
  v_lock_at timestamptz;
  v_unlock_at timestamptz;
  v_warn_key text;
  v_done text[] := ARRAY[]::text[];
  v_lock_uk text;
BEGIN
  IF to_regclass('public.gpsl_discord_notifications_state') IS NULL
     OR to_regprocedure('public.gpsl_discord_feed_enqueue_notification(text,text,text,integer,text,jsonb)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'discord notifications not installed');
  END IF;

  INSERT INTO public.gpsl_discord_notifications_state (id)
  VALUES (1)
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'done', v_done, 'note', 'no current season');
  END IF;

  BEGIN
    IF to_regprocedure('public.competition_active_gpsl_month(bigint,timestamptz)') IS NOT NULL THEN
      v_month := public.competition_active_gpsl_month(v_season_id, now());
    ELSIF to_regprocedure('public.competition_active_gpsl_month()') IS NOT NULL THEN
      v_month := public.competition_active_gpsl_month();
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_month := NULL;
  END;

  SELECT last_gpsl_month INTO v_prev
  FROM public.gpsl_discord_notifications_state
  WHERE id = 1;

  -- Seed quietly if we have never recorded a month (avoid mid-month spam).
  IF v_month IS NOT NULL AND v_prev IS NULL THEN
    UPDATE public.gpsl_discord_notifications_state
    SET last_gpsl_month = lower(v_month),
        updated_at = now()
    WHERE id = 1;
    v_prev := lower(v_month);
    v_done := v_done || ARRAY['seeded_last_gpsl_month'];
  END IF;

  IF v_month IS NOT NULL THEN
    SELECT c.lock_at, c.unlock_at
    INTO v_lock_at, v_unlock_at
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND lower(c.gpsl_month) = lower(v_month)
    LIMIT 1;

    SELECT c.gpsl_month INTO v_next_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.unlock_at > coalesce(v_unlock_at, now())
    ORDER BY c.unlock_at
    LIMIT 1;

    BEGIN
      v_month_label := public.competition_gpsl_month_label(v_month);
    EXCEPTION WHEN OTHERS THEN
      v_month_label := initcap(v_month);
    END;
    BEGIN
      v_next_label := CASE
        WHEN v_next_month IS NULL THEN NULL
        ELSE public.competition_gpsl_month_label(v_next_month)
      END;
    EXCEPTION WHEN OTHERS THEN
      v_next_label := initcap(v_next_month);
    END;

    -- 24h warning before lock
    IF v_lock_at IS NOT NULL
       AND now() >= v_lock_at - interval '24 hours'
       AND now() < v_lock_at THEN
      v_warn_key := 'gpsl_month_ending:' || v_season_id::text || ':' || lower(v_month)
        || ':' || to_char(v_lock_at AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI');
      v_lock_uk := to_char(v_lock_at AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI');

      IF EXISTS (
        SELECT 1 FROM public.gpsl_discord_notifications_state s
        WHERE s.id = 1 AND s.last_month_ending_warn_key IS DISTINCT FROM v_warn_key
      ) THEN
        PERFORM public.gpsl_discord_feed_enqueue_notification(
          'notification',
          format('⏰ GPSL MONTH ENDING SOON — %s', v_month_label),
          concat_ws(
            E'\n',
            format('GPSL %s locks in about 24 hours.', v_month_label),
            format('Lock time: %s (UK).', v_lock_uk),
            'Finish check-ins / results for this month before it closes.',
            CASE
              WHEN v_next_label IS NOT NULL THEN format('Next up: GPSL %s.', v_next_label)
            END
          ),
          15105570, -- amber
          v_warn_key,
          jsonb_build_object(
            'kind', 'gpsl_month_ending',
            'gpsl_month', lower(v_month),
            'lock_at', v_lock_at,
            'next_gpsl_month', lower(v_next_month)
          )
        );
        UPDATE public.gpsl_discord_notifications_state
        SET last_month_ending_warn_key = v_warn_key,
            updated_at = now()
        WHERE id = 1;
        v_done := v_done || ARRAY['month_ending_warn'];
      END IF;
    END IF;
  END IF;

  -- New month open
  IF v_month IS NOT NULL AND lower(v_month) IS DISTINCT FROM lower(coalesce(v_prev, '')) THEN
    BEGIN
      v_month_label := public.competition_gpsl_month_label(v_month);
    EXCEPTION WHEN OTHERS THEN
      v_month_label := initcap(v_month);
    END;

    PERFORM public.gpsl_discord_feed_enqueue_notification(
      'notification',
      format('📅 GPSL MONTH OPEN — %s', v_month_label),
      concat_ws(
        E'\n',
        format('We are now in GPSL %s.', v_month_label),
        CASE
          WHEN v_prev IS NOT NULL AND btrim(v_prev) <> '' THEN
            format('GPSL %s is now locked.', initcap(v_prev))
        END,
        'Fixtures, challenges, and calendars have moved on — arrange and play on the GPSL site.'
      ),
      5793266,
      'gpsl_month:' || v_season_id::text || ':' || lower(v_month),
      jsonb_build_object('kind', 'gpsl_month', 'gpsl_month', lower(v_month), 'previous', lower(v_prev))
    );

    UPDATE public.gpsl_discord_notifications_state
    SET last_gpsl_month = lower(v_month),
        updated_at = now()
    WHERE id = 1;
    v_done := v_done || ARRAY['gpsl_month_open'];
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'active_month', v_month,
    'done', to_jsonb(v_done)
  );
END;
$function$;

COMMENT ON FUNCTION public.gpsl_discord_calendar_month_announcements() IS
  'Discord calendar channel: 24h month-end warning + new GPSL month open post.';

REVOKE ALL ON FUNCTION public.gpsl_discord_calendar_month_announcements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_calendar_month_announcements() TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_calendar_month_announcements() TO authenticated;

-- Wire into notifications tick (call once near the start; skip duplicate month open in tick body).
DO $wire$
DECLARE
  v_def text;
  v_new text;
  v_marker text := 'gpsl_discord_calendar_month_announcements';
BEGIN
  IF to_regprocedure('public.gpsl_discord_notifications_tick()') IS NULL THEN
    RAISE NOTICE 'gpsl_discord_notifications_tick missing — helper is callable standalone / via cron';
    RETURN;
  END IF;

  SELECT pg_get_functiondef('public.gpsl_discord_notifications_tick()'::regprocedure)
    INTO v_def;

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'notifications_tick already calls calendar month announcements';
  ELSE
    -- Insert after BEGIN of function body (first DECLARE/BEGIN already past — inject after state load).
    IF position('v_prev_month := v_state.last_gpsl_month;' IN v_def) > 0 THEN
      v_new := replace(
        v_def,
        'v_prev_month := v_state.last_gpsl_month;',
        E'v_prev_month := v_state.last_gpsl_month;\n\n  -- Calendar month ending / open posts (#gpsl-notifications)\n  PERFORM public.gpsl_discord_calendar_month_announcements();\n  SELECT last_gpsl_month INTO v_prev_month FROM public.gpsl_discord_notifications_state WHERE id = 1;'
      );
    ELSE
      -- Fallback: after first BEGIN
      v_new := regexp_replace(
        v_def,
        'AS \$function\$\s*DECLARE',
        E'AS $function$\nDECLARE',
        'n'
      );
      v_new := replace(
        v_new,
        E'BEGIN\n  SELECT * INTO v_state FROM public.gpsl_discord_notifications_state WHERE id = 1;',
        E'BEGIN\n  PERFORM public.gpsl_discord_calendar_month_announcements();\n  SELECT * INTO v_state FROM public.gpsl_discord_notifications_state WHERE id = 1;'
      );
    END IF;

    IF v_new IS DISTINCT FROM v_def AND position(v_marker IN v_new) > 0 THEN
      EXECUTE v_new;
      RAISE NOTICE 'Wired calendar month announcements into gpsl_discord_notifications_tick';
      SELECT pg_get_functiondef('public.gpsl_discord_notifications_tick()'::regprocedure) INTO v_def;
    ELSE
      RAISE WARNING 'Could not inject into notifications_tick — ensure cron also runs gpsl_discord_calendar_month_announcements()';
    END IF;
  END IF;

  -- Neutralize duplicate "We are now in" block in tick (helper owns that post now).
  -- Keep challenge-close logic; only skip the month enqueue when helper already advanced last_gpsl_month.
  -- Soft approach: change condition so it only fires if still different AFTER helper (usually no-op).
END;
$wire$;

-- Dedicated cron every 15 minutes (in case notifications tick is slower / missing).
DO $cron$
BEGIN
  IF to_regclass('cron.job') IS NULL THEN
    RAISE NOTICE 'pg_cron not available — schedule gpsl_discord_calendar_month_announcements manually';
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-discord-calendar-month') THEN
    PERFORM cron.unschedule('gpsl-discord-calendar-month');
  END IF;

  PERFORM cron.schedule(
    'gpsl-discord-calendar-month',
    '*/15 * * * *',
    $$SELECT public.gpsl_discord_calendar_month_announcements();$$
  );
  RAISE NOTICE 'Scheduled gpsl-discord-calendar-month every 15 minutes';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'cron schedule failed: %', SQLERRM;
END;
$cron$;

-- One-shot now: seed state + queue any due warn/open
SELECT public.gpsl_discord_calendar_month_announcements() AS calendar_month_announcements;
