-- =============================================================================
-- Discord: #gpsl-notifications channel
--
-- Ops announcements: auctions, transfer window, month tick, season start,
-- challenges, nation pick turns (@owner), match reminders, OOC batch, vacants.
--
-- Setup:
-- 1) Discord → create #gpsl-notifications → Webhooks → copy URL
-- 2) Supabase → Edge Functions → Secrets:
--      DISCORD_NOTIFICATIONS_WEBHOOK_URL = that webhook
-- 3) Run this SQL
-- 4) Redeploy: supabase functions deploy discord-sky-feed
-- 5) Optional cron (every 30–60 min):
--      SELECT cron.schedule(
--        'gpsl-discord-notifications-tick',
--        '*/30 * * * *',
--        $$SELECT public.gpsl_discord_notifications_tick();$$
--      );
--
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_discord_notifications_state (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  last_gpsl_month text,
  last_challenge_start_key text,
  last_challenge_close_key text,
  last_intl_week_key text,
  last_match_reminder_key text,
  last_ooc_key text,
  last_vacant_key text,
  last_draft_open_key text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.gpsl_discord_notifications_state (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_enqueue_notification(
  p_event_type text,
  p_headline text,
  p_body text DEFAULT NULL,
  p_color integer DEFAULT 5793266, -- 0x5865f2
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

-- ---------------------------------------------------------------------------
-- Club / owner helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_notifications_owner_tag(p_club_short_name text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tag text;
BEGIN
  SELECT coalesce(
           nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), ''),
           nullif(btrim(c.owner), '')
         )
  INTO v_tag
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name
  LIMIT 1;

  RETURN nullif(btrim(coalesce(v_tag, '')), '');
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Special auctions → notifications (was news)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_special_auction_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_title text;
  v_detail text;
  v_type_label text;
  v_status_label text;
BEGIN
  IF NEW.status NOT IN ('scheduled', 'active') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status IN ('scheduled', 'active')
     AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  v_title := coalesce(nullif(btrim(NEW.title), ''), 'Special auction');
  v_type_label := CASE NEW.auction_type
    WHEN 'lowest_unique' THEN 'Lowest unique bid'
    WHEN 'snap' THEN 'Snap auction'
    WHEN 'blind_gauntlet' THEN 'Blind Gauntlet'
    ELSE 'Special auction'
  END;
  v_status_label := CASE NEW.status
    WHEN 'scheduled' THEN 'Upcoming'
    WHEN 'active' THEN 'Live now'
    ELSE initcap(NEW.status)
  END;

  v_detail := concat_ws(
    E'\n',
    v_status_label || ' · ' || v_type_label,
    'Starts: ' || to_char(NEW.start_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' (UK)',
    CASE
      WHEN NEW.auction_type = 'snap' THEN NULL
      WHEN NEW.end_time IS NOT NULL THEN
        'Ends: ' || to_char(NEW.end_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' (UK)'
      ELSE NULL
    END
  );

  PERFORM public.gpsl_discord_feed_enqueue_notification(
    'auction',
    format('🔨 SPECIAL AUCTION — %s', v_title),
    v_detail,
    22456,
    'special_auction:' || NEW.id::text || ':' || NEW.status,
    jsonb_build_object('auction_id', NEW.id, 'auction_type', NEW.auction_type)
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- global_settings: transfer window, draft/manager/club auctions
-- ---------------------------------------------------------------------------

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
  -- Club auction open
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
  END IF;

  -- Transfer window: see gpsl_discord_transfer_window_notify_fix.sql
  -- (dedicated trigger — do not handle here; old WHEN OTHERS swallowed failures)

  -- Player / manager draft auctions scheduled or enabled
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

DO $$
BEGIN
  IF to_regclass('public.global_settings') IS NULL THEN
    RETURN;
  END IF;
  DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_club_auction ON public.global_settings;
  CREATE TRIGGER trg_gpsl_discord_feed_club_auction
    AFTER UPDATE ON public.global_settings
    FOR EACH ROW
    EXECUTE FUNCTION public.gpsl_discord_feed_on_club_auction_settings();
END $$;

-- NOTE: also run gpsl_discord_transfer_window_notify_fix.sql for transfer window Discord posts.

-- ---------------------------------------------------------------------------
-- Season start
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_season_activated()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_label text := 'Season ' || NEW.id::text;
BEGIN
  BEGIN
    v_label := coalesce(
      nullif(btrim(to_jsonb(NEW)->>'label'), ''),
      nullif(btrim(to_jsonb(NEW)->>'name'), ''),
      nullif(btrim(to_jsonb(NEW)->>'season_label'), ''),
      'Season ' || NEW.id::text
    );
  EXCEPTION WHEN OTHERS THEN
    v_label := 'Season ' || NEW.id::text;
  END;

  IF TG_OP = 'UPDATE'
     AND NEW.is_current IS TRUE
     AND coalesce(OLD.is_current, false) IS FALSE THEN
    PERFORM public.gpsl_discord_feed_enqueue_notification(
      'notification',
      '🏁 SEASON START',
      format('%s is now live. Good luck everyone.', v_label),
      15844367,
      'season_start:' || NEW.id::text,
      jsonb_build_object('season_id', NEW.id, 'kind', 'season_start')
    );
  ELSIF TG_OP = 'UPDATE'
     AND lower(coalesce(NEW.status, '')) = 'active'
     AND lower(coalesce(OLD.status, '')) IS DISTINCT FROM 'active' THEN
    PERFORM public.gpsl_discord_feed_enqueue_notification(
      'notification',
      '🏁 SEASON START',
      format('%s is now active.', v_label),
      15844367,
      'season_active:' || NEW.id::text,
      jsonb_build_object('season_id', NEW.id, 'kind', 'season_start')
    );
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$function$;

DO $$
BEGIN
  IF to_regclass('public.competition_seasons') IS NULL THEN
    RETURN;
  END IF;
  DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_season_activated ON public.competition_seasons;
  CREATE TRIGGER trg_gpsl_discord_feed_season_activated
    AFTER UPDATE ON public.competition_seasons
    FOR EACH ROW
    EXECUTE FUNCTION public.gpsl_discord_feed_on_season_activated();
END $$;

-- ---------------------------------------------------------------------------
-- Nation selection: open + pick turn with @owner_tag
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_nation_pick_turn(p_pick_rank smallint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_tag text;
  v_mention text;
  v_club_name text;
  v_total int;
BEGIN
  SELECT count(*)::int INTO v_total
  FROM public.international_owner_draft_order();

  FOR v_club IN
    SELECT d.club_short_name, d.pick_order
    FROM public.international_owner_draft_order() d
    WHERE d.pick_order = p_pick_rank
  LOOP
    PERFORM public.owner_inbox_send(
      'nation_pick_turn',
      'Your turn — pick a nation',
      format(
        E'Nation selection: you are pick #%s of %s.\nChoose your national team on the Nation selection page.',
        p_pick_rank,
        v_total
      ),
      v_club.club_short_name,
      NULL,
      NULL, NULL, NULL, NULL,
      'nation_select.html',
      'nation_pick:' || p_pick_rank::text || ':' || v_club.club_short_name,
      NULL, NULL
    );

    v_tag := public.gpsl_discord_notifications_owner_tag(v_club.club_short_name);
    v_mention := CASE WHEN v_tag IS NOT NULL THEN '@' || ltrim(v_tag, '@') ELSE NULL END;
    SELECT coalesce(c."Club", v_club.club_short_name) INTO v_club_name
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club.club_short_name;

    PERFORM public.gpsl_discord_feed_enqueue_notification(
      'notification',
      format('🌍 NATION SELECTION — pick #%s', p_pick_rank),
      concat_ws(
        E'\n',
        format('%s is on the clock.', coalesce(v_club_name, v_club.club_short_name)),
        CASE WHEN v_mention IS NOT NULL THEN format('Your turn %s — choose a nation.', v_mention) END,
        format('Pick %s of %s.', p_pick_rank, coalesce(v_total, 0))
      ),
      5793266,
      'nation_pick_turn:' || p_pick_rank::text || ':' || v_club.club_short_name,
      jsonb_build_object(
        'kind', 'nation_pick_turn',
        'club_short_name', v_club.club_short_name,
        'pick_rank', p_pick_rank,
        'owner_tag', v_tag,
        'mention', v_mention,
        'ping', true
      )
    );
  END LOOP;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_nation_pick_turn(smallint) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Tick digests: month, challenges, intl week, match reminders, OOC, vacants, draft open
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_notifications_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_state public.gpsl_discord_notifications_state%rowtype;
  v_month text;
  v_prev_month text;
  v_month_label text;
  v_season_id bigint;
  v_key text;
  v_count int;
  v_cup int;
  v_names text;
  v_done text[] := ARRAY[]::text[];
  v_gs public.global_settings%rowtype;
  r record;
BEGIN
  SELECT * INTO v_state FROM public.gpsl_discord_notifications_state WHERE id = 1;
  IF NOT FOUND THEN
    INSERT INTO public.gpsl_discord_notifications_state (id) VALUES (1);
    SELECT * INTO v_state FROM public.gpsl_discord_notifications_state WHERE id = 1;
  END IF;

  v_prev_month := v_state.last_gpsl_month;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  -- Current GPSL month
  BEGIN
    IF to_regprocedure('public.competition_active_gpsl_month()') IS NOT NULL THEN
      v_month := public.competition_active_gpsl_month();
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_month := NULL;
  END;

  -- Challenge close when month ticks past gpsl_month_to (use previous month before updating state)
  IF v_season_id IS NOT NULL
     AND v_month IS NOT NULL
     AND v_prev_month IS NOT NULL
     AND lower(v_month) IS DISTINCT FROM lower(v_prev_month)
     AND to_regclass('public.competition_challenge_config') IS NOT NULL THEN
    FOR r IN
      SELECT c.id, c.title, c.window_phase, c.gpsl_month_to
      FROM public.competition_challenge_config c
      WHERE c.season_id = v_season_id
        AND lower(c.gpsl_month_to) = lower(v_prev_month)
    LOOP
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'notification',
        format('🎯 CHALLENGES CLOSING — %s', initcap(coalesce(r.window_phase, 'window'))),
        format('%s has closed with the end of %s.', coalesce(r.title, 'Season challenges'), initcap(r.gpsl_month_to)),
        10038562,
        'chal_close:' || r.id::text || ':' || r.gpsl_month_to,
        jsonb_build_object('kind', 'challenge_close', 'challenge_id', r.id)
      );
      v_done := v_done || ARRAY['challenge_close'];
    END LOOP;
  END IF;

  IF v_month IS NOT NULL AND v_month IS DISTINCT FROM v_prev_month THEN
    BEGIN
      v_month_label := public.competition_gpsl_month_label(v_month);
    EXCEPTION WHEN OTHERS THEN
      v_month_label := initcap(v_month);
    END;

    PERFORM public.gpsl_discord_feed_enqueue_notification(
      'notification',
      format('📅 GPSL MONTH — %s', v_month_label),
      format('We are now in %s. Fixtures, challenges, and calendars have moved on.', v_month_label),
      5793266,
      'gpsl_month:' || coalesce(v_season_id::text, 'x') || ':' || v_month,
      jsonb_build_object('kind', 'gpsl_month', 'gpsl_month', v_month)
    );
    UPDATE public.gpsl_discord_notifications_state
    SET last_gpsl_month = v_month, updated_at = now()
    WHERE id = 1;
    v_done := v_done || ARRAY['gpsl_month'];
  END IF;

  -- Draft auction "open now" (time-based)
  SELECT * INTO v_gs FROM public.global_settings LIMIT 1;
  IF FOUND
     AND v_gs.draft_auction_start_time IS NOT NULL
     AND now() >= v_gs.draft_auction_start_time
     AND (
       coalesce(v_gs.draft_auction_enabled, false)
       OR coalesce(v_gs.manager_draft_auction_enabled, false)
     ) THEN
    v_key := 'draft_open:' || to_char(v_gs.draft_auction_start_time AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI');
    IF v_state.last_draft_open_key IS DISTINCT FROM v_key THEN
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'draft',
        '🧾 DRAFT AUCTION LIVE',
        concat_ws(
          E'\n',
          CASE WHEN coalesce(v_gs.draft_auction_enabled, false) THEN 'Player draft bidding is open.' END,
          CASE WHEN coalesce(v_gs.manager_draft_auction_enabled, false) THEN 'Manager draft bidding is open.' END
        ),
        8070335,
        v_key,
        jsonb_build_object('kind', 'draft_open')
      );
      UPDATE public.gpsl_discord_notifications_state
      SET last_draft_open_key = v_key, updated_at = now()
      WHERE id = 1;
      v_done := v_done || ARRAY['draft_open'];
    END IF;
  END IF;

  -- Challenges starting (dedupe_key prevents repeats)
  IF v_season_id IS NOT NULL AND v_month IS NOT NULL
     AND to_regclass('public.competition_challenge_config') IS NOT NULL THEN
    FOR r IN
      SELECT c.id, c.title, c.window_phase, c.gpsl_month_from
      FROM public.competition_challenge_config c
      WHERE c.season_id = v_season_id
        AND lower(c.gpsl_month_from) = lower(v_month)
    LOOP
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'notification',
        format('🎯 CHALLENGES STARTING — %s', initcap(coalesce(r.window_phase, 'window'))),
        format('%s is now open for %s.', coalesce(r.title, 'Season challenges'), initcap(v_month)),
        15844367,
        'chal_start:' || r.id::text || ':' || v_month,
        jsonb_build_object('kind', 'challenge_start', 'challenge_id', r.id)
      );
      v_done := v_done || ARRAY['challenge_start'];
    END LOOP;
  END IF;

  -- International match week (fixtures exist for current month)
  IF v_season_id IS NOT NULL AND v_month IS NOT NULL
     AND to_regclass('public.international_fixtures') IS NOT NULL THEN
    BEGIN
      SELECT count(*)::int INTO v_count
      FROM public.international_fixtures f
      WHERE lower(f.gpsl_month) = lower(v_month);
    EXCEPTION WHEN OTHERS THEN
      v_count := 0;
    END;

    IF coalesce(v_count, 0) > 0 THEN
      v_key := 'intl:' || v_season_id::text || ':' || v_month;
      IF v_state.last_intl_week_key IS DISTINCT FROM v_key THEN
        PERFORM public.gpsl_discord_feed_enqueue_notification(
          'notification',
          format('🌐 INTERNATIONAL MATCH WEEK — %s', initcap(v_month)),
          format('%s international fixture(s) are scheduled this GPSL month. Check International Matchday.', v_count),
          5793266,
          v_key,
          jsonb_build_object('kind', 'international_week', 'count', v_count)
        );
        UPDATE public.gpsl_discord_notifications_state
        SET last_intl_week_key = v_key, updated_at = now()
        WHERE id = 1;
        v_done := v_done || ARRAY['international_week'];
      END IF;
    END IF;
  END IF;

  -- Match reminders: scheduled league + cup fixtures still outstanding this month
  IF v_season_id IS NOT NULL AND v_month IS NOT NULL THEN
    v_key := 'matches:' || v_season_id::text || ':' || v_month || ':' ||
             to_char(now() AT TIME ZONE 'Europe/London', 'IYYY-IW');

    IF v_state.last_match_reminder_key IS DISTINCT FROM v_key THEN
      SELECT count(*)::int INTO v_count
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND lower(f.gpsl_month) = lower(v_month)
        AND f.status = 'scheduled'
        AND f.competition_type = 'league';

      SELECT count(*)::int INTO v_cup
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND lower(f.gpsl_month) = lower(v_month)
        AND f.status = 'scheduled'
        AND f.competition_type = 'cup';

      IF coalesce(v_count, 0) > 0 OR coalesce(v_cup, 0) > 0 THEN
        PERFORM public.gpsl_discord_feed_enqueue_notification(
          'notification',
          format('⚽ MATCHES DUE — %s', initcap(v_month)),
          format(
            E'Weekly reminder for outstanding fixtures this GPSL month:\nLeague: %s scheduled\nCup: %s scheduled\nPlease arrange kick-offs and submit results.',
            coalesce(v_count, 0),
            coalesce(v_cup, 0)
          ),
          15158332,
          v_key,
          jsonb_build_object(
            'kind', 'match_reminder',
            'league_scheduled', coalesce(v_count, 0),
            'cup_scheduled', coalesce(v_cup, 0)
          )
        );
        UPDATE public.gpsl_discord_notifications_state
        SET last_match_reminder_key = v_key, updated_at = now()
        WHERE id = 1;
        v_done := v_done || ARRAY['match_reminder'];
      END IF;
    END IF;
  END IF;

  -- Vacant clubs (daily digest while any remain)
  v_key := 'vacant:' || to_char(now() AT TIME ZONE 'Europe/London', 'YYYY-MM-DD');
  IF v_state.last_vacant_key IS DISTINCT FROM v_key THEN
    SELECT count(*)::int,
           string_agg(c."Club", ', ' ORDER BY c."Club")
    INTO v_count, v_names
    FROM public."Clubs" c
    WHERE c.owner_id IS NULL;

    IF coalesce(v_count, 0) > 0 THEN
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'notification',
        format('🏚️ VACANT CLUBS — %s', v_count),
        left(coalesce(v_names, 'Vacant clubs listed in club auction.'), 900),
        10038562,
        v_key,
        jsonb_build_object('kind', 'vacant_clubs', 'count', v_count)
      );
      UPDATE public.gpsl_discord_notifications_state
      SET last_vacant_key = v_key, updated_at = now()
      WHERE id = 1;
      v_done := v_done || ARRAY['vacant_clubs'];
    END IF;
  END IF;

  -- Out of contract — single batch message (defensive column probing)
  v_key := 'ooc:' || coalesce(v_season_id::text, 'x') || ':' || coalesce(v_month, 'x');
  IF v_state.last_ooc_key IS DISTINCT FROM v_key THEN
    v_count := NULL;
    BEGIN
      SELECT count(*)::int INTO v_count
      FROM public."Players" p
      WHERE p.contract_seasons_remaining = 0
        AND nullif(btrim(p."Club"::text), '') IS NOT NULL
        AND p."Club"::text IS DISTINCT FROM 'FOREIGN';
    EXCEPTION WHEN undefined_column THEN
      BEGIN
        SELECT count(*)::int INTO v_count
        FROM public."Players" p
        WHERE nullif(btrim(p."Contract"::text), '') IN ('0', '0.0')
          AND nullif(btrim(p."Club"::text), '') IS NOT NULL;
      EXCEPTION WHEN OTHERS THEN
        v_count := NULL;
      END;
    WHEN OTHERS THEN
      v_count := NULL;
    END;

    IF coalesce(v_count, 0) > 0 THEN
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'notification',
        format('📋 OUT OF CONTRACT — %s players', v_count),
        format(
          '%s player(s) are out of contract (batch notice). Check contracts / free agents — not listed individually here.',
          v_count
        ),
        12370112,
        v_key,
        jsonb_build_object('kind', 'out_of_contract_batch', 'count', v_count)
      );
      UPDATE public.gpsl_discord_notifications_state
      SET last_ooc_key = v_key, updated_at = now()
      WHERE id = 1;
      v_done := v_done || ARRAY['out_of_contract'];
    END IF;
  END IF;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'announced', to_jsonb(v_done),
    'gpsl_month', v_month,
    'season_id', v_season_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_notifications_tick() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_discord_notifications_tick_now()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.gpsl_discord_notifications_tick();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_notifications_tick_now() TO authenticated;

-- Optional pg_cron (ignore if extension missing)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid)
    FROM cron.job
    WHERE jobname = 'gpsl-discord-notifications-tick';

    PERFORM cron.schedule(
      'gpsl-discord-notifications-tick',
      '15,45 * * * *',
      $$SELECT public.gpsl_discord_notifications_tick();$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron schedule skipped: %', SQLERRM;
END $$;

NOTIFY pgrst, 'reload schema';
