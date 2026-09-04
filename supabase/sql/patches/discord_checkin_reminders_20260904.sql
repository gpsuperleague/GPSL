-- =============================================================================
-- Discord: check-in open reminders → #gpsl-scheduled (with @owner tags)
--
-- Arranged kick-offs already post immediately via discord_scheduled_matches_*.
-- This adds a second post when check-in opens (at kick-off):
--   • Same #gpsl-scheduled channel
--   • Pings both club owners (@tag) via edge bot resolve
--   • Optional best-effort DM when discord_user_id is known (edge)
--
-- Also cron the check-in notice processor every minute (was only on dashboard load).
--
-- Setup: run SQL; redeploy discord-sky-feed (multi-ping + optional DM).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_notify_checkin_open(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_fmt text;
  v_home_name text;
  v_away_name text;
  v_title text;
  v_body text;
  v_href text;
  v_sent int := 0;
  v_id bigint;
  v_home_tag text;
  v_away_tag text;
  v_home_discord text;
  v_away_discord text;
  v_discord_body text;
  v_qid bigint;
  v_comp text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_scheduled');
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_kickoff');
  END IF;

  -- Only once check-in has opened (at kick-off), and still within check-in window+grace
  IF now() < v_kickoff THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_early');
  END IF;

  IF now() >= v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval
                + interval '15 minutes' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_late');
  END IF;

  BEGIN
    v_fmt := public.match_schedule_format_kickoff_uk(v_kickoff);
  EXCEPTION WHEN OTHERS THEN
    v_fmt := to_char(v_kickoff AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') || ' UK';
  END;

  SELECT c."Club" INTO v_home_name
  FROM public."Clubs" c WHERE c."ShortName" = v_fixture.home_club_short_name;
  SELECT c."Club" INTO v_away_name
  FROM public."Clubs" c WHERE c."ShortName" = v_fixture.away_club_short_name;

  v_home_name := coalesce(nullif(btrim(v_home_name), ''), v_fixture.home_club_short_name, 'Home');
  v_away_name := coalesce(nullif(btrim(v_away_name), ''), v_fixture.away_club_short_name, 'Away');

  v_title := 'Check-in open — match ready';
  v_body := format(
    E'Check-in is open for %s vs %s.\n\nKick-off: %s\nYou have %s minutes to check in on Schedule / Dashboard.\nBoth clubs must check in before Match Day unlocks.',
    v_home_name,
    v_away_name,
    v_fmt,
    public.match_schedule_checkin_minutes()::text
  );
  v_href := 'fixture_schedule.html?fixture=' || p_fixture_id::text;

  v_id := public.owner_inbox_send(
    'match_checkin_open',
    v_title,
    v_body,
    v_fixture.home_club_short_name,
    NULL,
    p_fixture_id,
    NULL, NULL, NULL,
    v_href,
    'match_checkin_open:' || p_fixture_id::text || ':home',
    v_fixture.gpsl_month,
    v_fixture.season_id
  );
  IF v_id IS NOT NULL THEN v_sent := v_sent + 1; END IF;

  v_id := public.owner_inbox_send(
    'match_checkin_open',
    v_title,
    v_body,
    v_fixture.away_club_short_name,
    NULL,
    p_fixture_id,
    NULL, NULL, NULL,
    v_href,
    'match_checkin_open:' || p_fixture_id::text || ':away',
    v_fixture.gpsl_month,
    v_fixture.season_id
  );
  IF v_id IS NOT NULL THEN v_sent := v_sent + 1; END IF;

  -- Discord #gpsl-scheduled with owner tags (best-effort)
  BEGIN
    IF to_regprocedure(
      'public.gpsl_discord_feed_enqueue_scheduled(text,text,text,integer,text,jsonb)'
    ) IS NOT NULL THEN
      BEGIN
        v_home_tag := public.gpsl_discord_notifications_owner_tag(v_fixture.home_club_short_name);
      EXCEPTION WHEN OTHERS THEN
        v_home_tag := NULL;
      END;
      BEGIN
        v_away_tag := public.gpsl_discord_notifications_owner_tag(v_fixture.away_club_short_name);
      EXCEPTION WHEN OTHERS THEN
        v_away_tag := NULL;
      END;

      SELECT nullif(btrim(r.discord_user_id), '') INTO v_home_discord
      FROM public."Clubs" c
      JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
      WHERE c."ShortName" = v_fixture.home_club_short_name
      LIMIT 1;

      SELECT nullif(btrim(r.discord_user_id), '') INTO v_away_discord
      FROM public."Clubs" c
      JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
      WHERE c."ShortName" = v_fixture.away_club_short_name
      LIMIT 1;

      IF v_fixture.competition_type = 'cup'
         OR nullif(btrim(coalesce(v_fixture.cup_code, '')), '') IS NOT NULL THEN
        v_comp := 'CUP';
      ELSE
        v_comp := 'LEAGUE';
      END IF;

      v_discord_body := format(
        E'%s vs %s\nKick-off: %s\nCheck-in is open — you have %s minutes.\nBoth clubs must check in before Match Day unlocks.',
        v_home_name,
        v_away_name,
        v_fmt,
        public.match_schedule_checkin_minutes()::text
      );

      v_qid := public.gpsl_discord_feed_enqueue_scheduled(
        'scheduled',
        format('⏰ CHECK-IN OPEN · %s — %s vs %s', v_comp, v_home_name, v_away_name),
        v_discord_body,
        15105570, -- amber
        'scheduled:checkin:' || p_fixture_id::text,
        jsonb_build_object(
          'kind', 'checkin_open',
          'ping', true,
          'fixture_id', p_fixture_id,
          'kickoff_at', v_kickoff,
          'owner_tags', coalesce((
            SELECT jsonb_agg(to_jsonb(t) ORDER BY ord)
            FROM (
              SELECT 1 AS ord, nullif(btrim(v_home_tag), '') AS t
              UNION ALL
              SELECT 2, nullif(btrim(v_away_tag), '')
            ) x
            WHERE t IS NOT NULL
          ), '[]'::jsonb),
          'discord_user_ids', coalesce((
            SELECT jsonb_agg(to_jsonb(t) ORDER BY ord)
            FROM (
              SELECT 1 AS ord, nullif(btrim(v_home_discord), '') AS t
              UNION ALL
              SELECT 2, nullif(btrim(v_away_discord), '')
            ) x
            WHERE t IS NOT NULL
          ), '[]'::jsonb),
          'try_dm', true
        )
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Discord check-in enqueue failed for fixture %: %', p_fixture_id, SQLERRM;
    v_qid := NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'sent', v_sent,
    'discord_queue_id', v_qid
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_notify_checkin_open(bigint)
  TO authenticated, service_role;

-- Keep process function; ensure it marks Discord dedupe independently of inbox
-- (inbox may already exist from earlier dashboard load — still allow Discord once)
CREATE OR REPLACE FUNCTION public.match_schedule_process_due_checkin_notices()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_n int := 0;
  v_res jsonb;
BEGIN
  FOR v_row IN
    SELECT f.id AS fixture_id
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule sch
      ON sch.fixture_id = f.id
     AND sch.status = 'agreed'
     AND sch.agreed_kickoff_at IS NOT NULL
    WHERE f.status = 'scheduled'
      AND sch.agreed_kickoff_at <= now()
      AND sch.agreed_kickoff_at > now()
        - (public.match_schedule_checkin_minutes() || ' minutes')::interval
        - interval '15 minutes'
      AND (
        NOT EXISTS (
          SELECT 1
          FROM public.competition_inbox i
          WHERE i.dedupe_key = 'match_checkin_open:' || f.id::text || ':home'
             OR i.dedupe_key = 'match_checkin_open:' || f.id::text || ':away'
        )
        OR (
          to_regclass('public.gpsl_discord_feed_queue') IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
            FROM public.gpsl_discord_feed_queue q
            WHERE q.dedupe_key = 'scheduled:checkin:' || f.id::text
          )
        )
      )
  LOOP
    v_res := public.match_schedule_notify_checkin_open(v_row.fixture_id);
    IF coalesce((v_res->>'sent')::int, 0) > 0
       OR v_res->>'discord_queue_id' IS NOT NULL THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'fixtures_notified', v_n);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_process_due_checkin_notices()
  TO authenticated, service_role;

-- Cron: every minute during match windows
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-match-checkin-notices');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-match-checkin-notices',
      '* * * * *',
      $$SELECT public.match_schedule_process_due_checkin_notices();$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron check-in notices schedule skipped: %', SQLERRM;
END;
$cron$;

NOTIFY pgrst, 'reload schema';
