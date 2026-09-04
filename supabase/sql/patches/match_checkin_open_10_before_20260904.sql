-- =============================================================================
-- Check-in opens 10 minutes before kick-off
--
-- Was: open at kick-off → close at kick-off + checkin_minutes (10).
-- Now: open at kick-off − 10 → close at kick-off + checkin_minutes (still 10 after).
--
-- Updates: helpers, fixture_check_in, fixture context (live def rewrite),
-- dashboard synopsis, inbox/Discord check-in notices.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_checkin_open_before_minutes()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 10; $$;

COMMENT ON FUNCTION public.match_schedule_checkin_open_before_minutes() IS
  'Minutes before agreed kick-off when check-in becomes available.';

CREATE OR REPLACE FUNCTION public.match_schedule_checkin_opens_at(p_kickoff timestamptz)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_kickoff IS NULL THEN NULL
    ELSE p_kickoff
      - (public.match_schedule_checkin_open_before_minutes() || ' minutes')::interval
  END;
$$;

GRANT EXECUTE ON FUNCTION public.match_schedule_checkin_open_before_minutes()
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.match_schedule_checkin_opens_at(timestamptz)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Check-in RPC (manager gate preserved)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fixture_check_in(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_window_open timestamptz;
  v_window_end timestamptz;
  v_home_in boolean;
  v_away_in boolean;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF to_regprocedure('public.club_assert_has_manager_for_matches(text)') IS NOT NULL THEN
    PERFORM public.club_assert_has_manager_for_matches(v_club);
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for check-in';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'Kick-off time is not agreed yet';
  END IF;

  v_window_open := public.match_schedule_checkin_opens_at(v_kickoff);
  v_window_end := v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;

  IF now() < v_window_open THEN
    RAISE EXCEPTION 'Check-in opens at %', public.match_schedule_format_kickoff_uk(v_window_open);
  END IF;

  IF now() >= v_window_end THEN
    IF to_regprocedure('public.fixture_try_checkin_forfeit(bigint)') IS NOT NULL THEN
      PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
    END IF;
    RAISE EXCEPTION 'Check-in window has closed';
  END IF;

  INSERT INTO public.competition_fixture_checkin (fixture_id, club_short_name)
  VALUES (p_fixture_id, v_club)
  ON CONFLICT (fixture_id, club_short_name) DO NOTHING;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in
     AND to_regprocedure('public.match_schedule_clear_no_show(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
  END IF;

  RETURN jsonb_build_object('ok', true, 'checked_in_at', now());
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_check_in(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Rewrite live match_schedule_fixture_context check-in open expressions
-- ---------------------------------------------------------------------------
DO $ctx$
DECLARE
  v_def text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef('public.match_schedule_fixture_context(bigint)'::regprocedure)
  INTO v_def;

  IF v_def IS NULL THEN
    RAISE NOTICE 'match_schedule_fixture_context missing — skip context rewrite';
    RETURN;
  END IF;

  v_new := v_def;

  -- window_opens_at: kickoff → opens_at helper
  v_new := replace(
    v_new,
    '''window_opens_at'', v_kickoff',
    '''window_opens_at'', public.match_schedule_checkin_opens_at(v_kickoff)'
  );

  -- can_check_in / similar: now() >= v_kickoff → opens_at
  v_new := replace(
    v_new,
    'now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_checkin_minutes()',
    'now() >= public.match_schedule_checkin_opens_at(v_kickoff) AND now() < v_kickoff + (public.match_schedule_checkin_minutes()'
  );

  IF v_new = v_def THEN
    RAISE NOTICE 'match_schedule_fixture_context: no check-in open patterns found (already patched?)';
  ELSE
    EXECUTE v_new;
  END IF;
END;
$ctx$;

-- ---------------------------------------------------------------------------
-- Inbox + Discord: fire from 10 minutes before kick-off
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_notify_checkin_open(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_opens timestamptz;
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
  v_before int := public.match_schedule_checkin_open_before_minutes();
  v_after int := public.match_schedule_checkin_minutes();
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

  v_opens := public.match_schedule_checkin_opens_at(v_kickoff);

  IF now() < v_opens THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_early');
  END IF;

  IF now() >= v_kickoff + (v_after || ' minutes')::interval + interval '15 minutes' THEN
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
    E'Check-in is open for %s vs %s.\n\nKick-off: %s\nOpens %s minutes before kick-off and stays open until %s minutes after.\nBoth clubs must check in before Match Day unlocks.',
    v_home_name,
    v_away_name,
    v_fmt,
    v_before::text,
    v_after::text
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
        E'%s vs %s\nKick-off: %s\nCheck-in is open — from %s min before KO until %s min after.\nBoth clubs must check in before Match Day unlocks.',
        v_home_name,
        v_away_name,
        v_fmt,
        v_before::text,
        v_after::text
      );

      v_qid := public.gpsl_discord_feed_enqueue_scheduled(
        'scheduled',
        format('⏰ CHECK-IN OPEN · %s — %s vs %s', v_comp, v_home_name, v_away_name),
        v_discord_body,
        15105570,
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
    'discord_queue_id', v_qid,
    'opens_at', v_opens
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_notify_checkin_open(bigint)
  TO authenticated, service_role;

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
      AND public.match_schedule_checkin_opens_at(sch.agreed_kickoff_at) <= now()
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

-- ---------------------------------------------------------------------------
-- Dashboard synopsis
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dashboard_my_matchday_synopsis()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_preview int := public.match_schedule_dashboard_preview_minutes();
  v_checkin int := public.match_schedule_checkin_minutes();
  v_before int := public.match_schedule_checkin_open_before_minutes();
  v_block int := public.match_schedule_block_minutes();
  v_items jsonb := '[]'::jsonb;
  v_row record;
  v_home_in boolean;
  v_away_in boolean;
  v_my_in boolean;
  v_kickoff timestamptz;
  v_checkin_open timestamptz;
  v_opens timestamptz;
  v_closes timestamptz;
  v_checkin_end timestamptz;
  v_can_check_in boolean;
  v_can_play boolean;
  v_opponent text;
  v_home_name text;
  v_away_name text;
  v_has_mgr boolean := true;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN jsonb_build_object('ok', true, 'club', NULL, 'fixtures', '[]'::jsonb);
  END IF;

  BEGIN
    PERFORM public.match_schedule_process_due_checkin_notices();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  FOR v_row IN
    SELECT
      f.id,
      f.season_id,
      f.competition_type,
      f.cup_code,
      f.matchday,
      f.gpsl_month,
      f.home_club_short_name,
      f.away_club_short_name,
      f.status,
      sch.agreed_kickoff_at
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule sch
      ON sch.fixture_id = f.id
     AND sch.status = 'agreed'
     AND sch.agreed_kickoff_at IS NOT NULL
    WHERE f.status = 'scheduled'
      AND (f.home_club_short_name = v_club OR f.away_club_short_name = v_club)
      AND now() >= sch.agreed_kickoff_at - (v_preview || ' minutes')::interval
      AND now() < sch.agreed_kickoff_at + (v_block || ' minutes')::interval
    ORDER BY sch.agreed_kickoff_at ASC, f.id ASC
    LIMIT 5
  LOOP
    v_kickoff := v_row.agreed_kickoff_at;
    v_checkin_open := public.match_schedule_checkin_opens_at(v_kickoff);
    v_opens := v_kickoff - (v_preview || ' minutes')::interval;
    v_closes := v_kickoff + (v_block || ' minutes')::interval;
    v_checkin_end := v_kickoff + (v_checkin || ' minutes')::interval;

    SELECT EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = v_row.id AND c.club_short_name = v_row.home_club_short_name
    ) INTO v_home_in;
    SELECT EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = v_row.id AND c.club_short_name = v_row.away_club_short_name
    ) INTO v_away_in;
    v_my_in := CASE
      WHEN v_club = v_row.home_club_short_name THEN v_home_in
      ELSE v_away_in
    END;

    IF to_regprocedure('public.club_has_signed_manager(text)') IS NOT NULL THEN
      v_has_mgr := public.club_has_signed_manager(v_club);
    ELSE
      v_has_mgr := true;
    END IF;

    v_can_check_in := (
      v_row.status = 'scheduled'
      AND now() >= v_checkin_open
      AND now() < v_checkin_end
      AND NOT v_my_in
      AND v_has_mgr
    );
    v_can_play := (
      v_row.status = 'scheduled'
      AND v_home_in AND v_away_in
      AND now() >= v_kickoff
      AND now() < v_closes
      AND (
        to_regprocedure('public.club_has_signed_manager(text)') IS NULL
        OR (
          public.club_has_signed_manager(v_row.home_club_short_name)
          AND public.club_has_signed_manager(v_row.away_club_short_name)
        )
      )
    );

    v_opponent := CASE
      WHEN v_club = v_row.home_club_short_name THEN v_row.away_club_short_name
      ELSE v_row.home_club_short_name
    END;

    SELECT c."Club" INTO v_home_name
    FROM public."Clubs" c WHERE c."ShortName" = v_row.home_club_short_name;
    SELECT c."Club" INTO v_away_name
    FROM public."Clubs" c WHERE c."ShortName" = v_row.away_club_short_name;

    v_items := v_items || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_row.id,
        'season_id', v_row.season_id,
        'competition_type', v_row.competition_type,
        'cup_code', v_row.cup_code,
        'matchday', v_row.matchday,
        'gpsl_month', v_row.gpsl_month,
        'home_club_short_name', v_row.home_club_short_name,
        'away_club_short_name', v_row.away_club_short_name,
        'home_club_name', coalesce(v_home_name, v_row.home_club_short_name),
        'away_club_name', coalesce(v_away_name, v_row.away_club_short_name),
        'opponent_short_name', v_opponent,
        'agreed_kickoff_at', v_kickoff,
        'panel_opens_at', v_opens,
        'panel_closes_at', v_closes,
        'checkin_opens_at', v_checkin_open,
        'checkin_closes_at', v_checkin_end,
        'home_checked_in', v_home_in,
        'away_checked_in', v_away_in,
        'my_checked_in', v_my_in,
        'can_check_in', v_can_check_in,
        'can_enter_result', v_can_play,
        'before_kickoff', now() < v_kickoff,
        'before_checkin', now() < v_checkin_open
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'server_now', now(),
    'preview_minutes', v_preview,
    'checkin_open_before_minutes', v_before,
    'checkin_minutes', v_checkin,
    'block_minutes', v_block,
    'fixtures', v_items
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.dashboard_my_matchday_synopsis() TO authenticated;

NOTIFY pgrst, 'reload schema';
