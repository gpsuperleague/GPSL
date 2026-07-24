-- =============================================================================
-- Dashboard matchday synopsis + check-in-open inbox for both owners.
-- Panel window: kick-off −30m → kick-off +30m (play block).
-- Check-in itself still opens at kick-off for 10 minutes (unchanged).
-- Inbox match_checkin_open fires once per fixture when check-in opens.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_dashboard_preview_minutes()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 30; $$;

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

  v_title := 'Check-in open — match ready';
  v_body := format(
    E'Check-in is open for %s vs %s.\n\nKick-off: %s\nYou have %s minutes to check in on Schedule / Dashboard.\nBoth clubs must check in before Match Day unlocks.',
    coalesce(v_home_name, v_fixture.home_club_short_name),
    coalesce(v_away_name, v_fixture.away_club_short_name),
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
    v_fixture.season_id,
    NULL
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
    v_fixture.season_id,
    NULL
  );
  IF v_id IS NOT NULL THEN v_sent := v_sent + 1; END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'sent', v_sent
  );
END;
$function$;

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
      AND NOT EXISTS (
        SELECT 1
        FROM public.competition_inbox i
        WHERE i.dedupe_key = 'match_checkin_open:' || f.id::text || ':home'
           OR i.dedupe_key = 'match_checkin_open:' || f.id::text || ':away'
      )
  LOOP
    v_res := public.match_schedule_notify_checkin_open(v_row.fixture_id);
    IF coalesce((v_res->>'sent')::int, 0) > 0 THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'fixtures_notified', v_n);
END;
$function$;

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
  v_block int := public.match_schedule_block_minutes();
  v_items jsonb := '[]'::jsonb;
  v_row record;
  v_home_in boolean;
  v_away_in boolean;
  v_my_in boolean;
  v_kickoff timestamptz;
  v_opens timestamptz;
  v_closes timestamptz;
  v_checkin_end timestamptz;
  v_can_check_in boolean;
  v_can_play boolean;
  v_opponent text;
  v_home_name text;
  v_away_name text;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN jsonb_build_object('ok', true, 'club', NULL, 'fixtures', '[]'::jsonb);
  END IF;

  -- Best-effort: send any due check-in inbox notices while owners are online
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

    v_can_check_in := (
      v_row.status = 'scheduled'
      AND now() >= v_kickoff
      AND now() < v_checkin_end
      AND NOT v_my_in
      AND public.club_has_signed_manager(v_club)
    );
    v_can_play := (
      v_row.status = 'scheduled'
      AND v_home_in AND v_away_in
      AND now() >= v_kickoff
      AND now() < v_closes
      AND public.club_has_signed_manager(v_row.home_club_short_name)
      AND public.club_has_signed_manager(v_row.away_club_short_name)
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
        'checkin_opens_at', v_kickoff,
        'checkin_closes_at', v_checkin_end,
        'home_checked_in', v_home_in,
        'away_checked_in', v_away_in,
        'my_checked_in', v_my_in,
        'can_check_in', v_can_check_in,
        'can_enter_result', v_can_play,
        'before_kickoff', now() < v_kickoff
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'server_now', now(),
    'preview_minutes', v_preview,
    'checkin_minutes', v_checkin,
    'block_minutes', v_block,
    'fixtures', v_items
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_dashboard_preview_minutes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_notify_checkin_open(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_process_due_checkin_notices() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.dashboard_my_matchday_synopsis() TO authenticated;

NOTIFY pgrst, 'reload schema';
