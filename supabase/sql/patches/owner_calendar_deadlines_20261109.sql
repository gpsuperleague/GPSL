-- =============================================================================
-- My Calendar deadlines for the owner they belong to, plus an inbox warning
-- in the 24 hours before each one.
--
-- Calendar: owner_calendar_deadlines() for the signed-in club.
--   Propose / reply / check-in / last play chance / video / result.
--   A result deadline is only listed for a club that has not entered its side.
-- Inbox: owner_deadline_warning_tick() once per deadline, 24h before it.
--   Propose and reply already have their own warnings, so those are not sent again.
--
-- Safe re-run. The last statement sends any warning that is already due.
-- =============================================================================

DO $inbox$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NULL OR position('''owner_deadline_warning''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t) INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION SELECT 'owner_deadline_warning'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;
  EXECUTE format(
    'ALTER TABLE public.competition_inbox ADD CONSTRAINT competition_inbox_message_type_check CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );
  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END
$inbox$;

CREATE OR REPLACE FUNCTION public.owner_personal_deadlines(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(p_club), ''));
  v_season bigint;
  v_out jsonb := '[]'::jsonb;
  v_me text;
  v_admin boolean := false;
  r record;
  v_cal record;
  v_side text;
  v_opp text;
  v_href text;
  v_state text;
  v_home_proposed boolean;
  v_before int := 10;
  v_after int := 10;
  v_opens timestamptz;
  v_closes timestamptz;
  v_grace int;
  v_video_grace int := 72;
  v_recover int := 24;
  v_final_lock timestamptz;
  v_play timestamptz;
  v_lock timestamptz;
  v_due_month text;
  v_due_sort smallint;
  v_entered text;
  v_remind_at timestamptz;
  v_close_at timestamptz;
  v_arranged boolean;
  v_title text;
  v_detail text;
  v_sev text;
  v_kind text;
  v_at timestamptz;
BEGIN
  IF v_club IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  BEGIN
    v_admin := coalesce(public.is_gpsl_admin(), false);
  EXCEPTION WHEN OTHERS THEN
    v_admin := false;
  END;

  v_me := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  IF v_me IS DISTINCT FROM v_club
     AND coalesce(auth.role(), '') IS DISTINCT FROM 'service_role'
     AND NOT v_admin
     AND session_user NOT IN ('postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  BEGIN
    v_before := coalesce(public.match_schedule_checkin_open_before_minutes(), 10);
  EXCEPTION WHEN OTHERS THEN
    v_before := 10;
  END;
  BEGIN
    v_after := coalesce(public.match_schedule_checkin_minutes(), 10);
  EXCEPTION WHEN OTHERS THEN
    v_after := 10;
  END;
  BEGIN
    v_video_grace := coalesce(public.match_video_missing_fine_grace_hours(), 72);
  EXCEPTION WHEN OTHERS THEN
    v_video_grace := 72;
  END;
  BEGIN
    SELECT coalesce(s.missing_pts_suspend_hours, 24)
    INTO v_recover
    FROM public.gpsl_discord_match_videos_settings s
    WHERE s.id = 1;
  EXCEPTION WHEN OTHERS THEN
    v_recover := 24;
  END;
  IF v_recover IS NULL OR v_recover < 1 THEN
    v_recover := 24;
  END IF;

  -- Home propose / reply. The club that has to act is the only one listed.
  FOR r IN
    SELECT
      f.id,
      f.gpsl_month,
      f.matchday,
      f.home_club_short_name,
      f.away_club_short_name,
      cal.unlock_at,
      s.status AS sched_status,
      s.response_required_club_short_name AS reply_club,
      s.response_due_at
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND cal.unlock_at > now()
      AND cal.unlock_at <= now() + interval '150 days'
      AND coalesce(s.status, 'unscheduled') <> 'agreed'
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
      AND NOT public.match_schedule_fixture_deadlines_suppressed_for_club(f.id, v_club)
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(f.id)
      )
    ORDER BY cal.unlock_at, f.id
  LOOP
    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    v_opp := CASE WHEN v_side = 'home'
      THEN coalesce(public.club_display_name(r.away_club_short_name), r.away_club_short_name)
      ELSE coalesce(public.club_display_name(r.home_club_short_name), r.home_club_short_name) END;
    v_href := 'fixture_schedule.html?fixture=' || r.id::text;

    BEGIN
      v_home_proposed := public.match_schedule_home_has_proposed(r.id, now());
    EXCEPTION WHEN OTHERS THEN
      v_home_proposed := coalesce(r.sched_status, 'unscheduled') <> 'unscheduled';
    END;

    v_state := CASE
      WHEN coalesce(r.sched_status, 'unscheduled') = 'negotiating'
           AND upper(btrim(coalesce(r.reply_club, ''))) = v_club THEN 'reply'
      WHEN coalesce(r.sched_status, 'unscheduled') = 'negotiating' THEN 'waiting'
      WHEN v_side = 'home' AND NOT v_home_proposed THEN 'propose'
      ELSE 'waiting_home'
    END;

    IF v_state = 'reply' AND r.response_due_at IS NOT NULL THEN
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', 'reply:' || r.id::text,
        'kind', 'reply',
        'at', r.response_due_at,
        'title', format('Reply vs %s', v_opp),
        'detail', 'Reply before this deadline. First overdue month lock warns; later locks while still overdue are ₿2,500,000.',
        'severity', CASE
          WHEN r.response_due_at <= now() + interval '12 hours' THEN 'urgent'
          WHEN r.response_due_at <= now() + interval '2 days' THEN 'warn'
          ELSE 'info'
        END,
        'href', v_href,
        'fixture_id', r.id
      ));
    ELSIF v_state = 'propose' THEN
      IF r.unlock_at - interval '48 hours' > now() THEN
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'id', 'late_fee:' || r.id::text,
          'kind', 'late_fee',
          'at', r.unlock_at - interval '48 hours',
          'title', format('Propose vs %s (avoid late fee)', v_opp),
          'detail', 'Propose before this time to avoid the ₿1,000,000 late fee. No proposal by month unlock is ₿2,500,000.',
          'severity', CASE
            WHEN r.unlock_at - interval '48 hours' <= now() + interval '36 hours' THEN 'warn'
            ELSE 'info'
          END,
          'href', v_href,
          'fixture_id', r.id
        ));
      END IF;

      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', 'propose:' || r.id::text,
        'kind', 'propose',
        'at', r.unlock_at,
        'title', format('Propose vs %s (avoid ₿2.5m)', v_opp),
        'detail', 'Home must propose a kick-off before this GPSL month opens.',
        'severity', CASE
          WHEN now() >= r.unlock_at - interval '48 hours' THEN 'urgent'
          WHEN r.unlock_at <= now() + interval '5 days' THEN 'warn'
          ELSE 'info'
        END,
        'href', v_href,
        'fixture_id', r.id
      ));
    END IF;
  END LOOP;

  -- Check-in for this club only, once a kick-off is agreed.
  FOR r IN
    SELECT f.id, f.home_club_short_name, f.away_club_short_name, s.agreed_kickoff_at
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule s
      ON s.fixture_id = f.id AND s.status = 'agreed'
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND s.agreed_kickoff_at IS NOT NULL
      AND s.agreed_kickoff_at > now() - interval '2 hours'
      AND s.agreed_kickoff_at <= now() + interval '21 days'
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
      AND NOT public.match_schedule_fixture_deadlines_suppressed_for_club(f.id, v_club)
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_fixture_checkin c
        WHERE c.fixture_id = f.id AND upper(btrim(c.club_short_name)) = v_club
      )
    ORDER BY s.agreed_kickoff_at
  LOOP
    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    v_opp := CASE WHEN v_side = 'home'
      THEN coalesce(public.club_display_name(r.away_club_short_name), r.away_club_short_name)
      ELSE coalesce(public.club_display_name(r.home_club_short_name), r.home_club_short_name) END;
    v_opens := r.agreed_kickoff_at - make_interval(mins => v_before);
    v_closes := r.agreed_kickoff_at + make_interval(mins => v_after);
    v_href := 'matchday.html?fixture=' || r.id::text;

    IF now() < v_opens THEN
      v_kind := 'checkin';
      v_at := v_opens;
      v_title := format('Check-in opens vs %s', v_opp);
      v_detail := format(
        'Your check-in opens %s minutes before kick-off and closes %s minutes after.',
        v_before, v_after
      );
      v_sev := CASE WHEN v_opens <= now() + interval '12 hours' THEN 'warn' ELSE 'info' END;
    ELSIF now() <= v_closes THEN
      v_kind := 'checkin';
      v_at := v_closes;
      v_title := format('Check in now vs %s', v_opp);
      v_detail := 'Your check-in window is open.';
      v_sev := 'urgent';
    ELSE
      CONTINUE;
    END IF;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', v_kind || ':' || r.id::text,
      'kind', v_kind,
      'at', v_at,
      'title', v_title,
      'detail', v_detail,
      'severity', v_sev,
      'href', v_href,
      'fixture_id', r.id
    ));
  END LOOP;

  -- Last chance to play, for this club, while the fixture is still unplayed.
  FOR r IN
    SELECT
      f.id,
      f.gpsl_month,
      f.competition_type,
      f.home_club_short_name,
      f.away_club_short_name,
      public.competition_gpsl_month_sort(f.gpsl_month) AS play_sort
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal_play
      ON cal_play.season_id = f.season_id
     AND lower(btrim(cal_play.gpsl_month)) = lower(btrim(f.gpsl_month))
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND cal_play.unlock_at <= now()
      AND public.competition_gpsl_month_sort(f.gpsl_month) IS NOT NULL
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
      AND NOT public.match_schedule_fixture_deadlines_suppressed_for_club(f.id, v_club)
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(f.id)
      )
    ORDER BY f.id
  LOOP
    BEGIN
      v_grace := public.match_schedule_play_grace_months(r.competition_type, r.gpsl_month);
    EXCEPTION WHEN OTHERS THEN
      v_grace := CASE WHEN lower(coalesce(r.competition_type, 'league')) = 'cup' THEN 1 ELSE 2 END;
    END;

    SELECT cal.lock_at INTO v_final_lock
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_season
      AND public.competition_gpsl_month_sort(cal.gpsl_month) <= r.play_sort + v_grace
    ORDER BY public.competition_gpsl_month_sort(cal.gpsl_month) DESC
    LIMIT 1;

    IF v_final_lock IS NULL
       OR v_final_lock <= now()
       OR v_final_lock > now() + interval '90 days' THEN
      CONTINUE;
    END IF;

    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    v_opp := CASE WHEN v_side = 'home'
      THEN coalesce(public.club_display_name(r.away_club_short_name), r.away_club_short_name)
      ELSE coalesce(public.club_display_name(r.home_club_short_name), r.home_club_short_name) END;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', 'play_window:' || r.id::text,
      'kind', 'play_window',
      'at', v_final_lock,
      'title', format('Last play chance vs %s', v_opp),
      'detail', 'Still unplayed after this lock and the match is awarded from scheduling activity.',
      'severity', CASE WHEN v_final_lock <= now() + interval '3 days' THEN 'warn' ELSE 'info' END,
      'href', 'fixture_schedule.html?fixture=' || r.id::text,
      'fixture_id', r.id
    ));
  END LOOP;

  -- Video upload: only the side that has not uploaded.
  IF to_regprocedure('public.match_video_due_gpsl_month(bigint)') IS NOT NULL THEN
    FOR r IN
      SELECT
        f.id,
        CASE
          WHEN upper(btrim(f.home_club_short_name)) = v_club
            THEN coalesce(public.club_display_name(f.away_club_short_name), f.away_club_short_name)
          ELSE coalesce(public.club_display_name(f.home_club_short_name), f.home_club_short_name)
        END AS opp,
        cal.lock_at + make_interval(hours => v_video_grace) AS video_due_at,
        fail.pts_status,
        fail.pts_suspend_until
      FROM public.competition_fixtures f
      JOIN public.competition_season_calendar cal
        ON cal.season_id = f.season_id
       AND lower(btrim(cal.gpsl_month)) = lower(btrim(public.match_video_due_gpsl_month(f.id)))
      LEFT JOIN public.fixture_match_video_failures fail
        ON fail.fixture_id = f.id
       AND fail.side = CASE
         WHEN upper(btrim(f.home_club_short_name)) = v_club THEN 'home'
         ELSE 'away'
       END
      WHERE f.season_id = v_season
        AND f.status = 'played'
        AND coalesce(f.is_void, false) = false
        AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
        AND cal.lock_at IS NOT NULL
        AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
        AND NOT EXISTS (
          SELECT 1
          FROM public.fixture_match_videos v
          WHERE v.fixture_id = f.id
            AND v.side = CASE
              WHEN upper(btrim(f.home_club_short_name)) = v_club THEN 'home'
              ELSE 'away'
            END
        )
        AND (
          (
            fail.id IS NULL
            AND cal.lock_at + make_interval(hours => v_video_grace) > now() - interval '14 days'
            AND cal.lock_at + make_interval(hours => v_video_grace) <= now() + interval '150 days'
          )
          OR (
            fail.pts_status = 'suspended'
            AND fail.pts_suspend_until IS NOT NULL
            AND fail.pts_suspend_until > now() - interval '12 hours'
          )
        )
      ORDER BY coalesce(fail.pts_suspend_until, cal.lock_at + make_interval(hours => v_video_grace)), f.id
    LOOP
      v_href := 'matchday.html?fixture=' || r.id::text;
      IF r.pts_status = 'suspended' THEN
        v_kind := 'video_suspend';
        v_at := r.pts_suspend_until;
        v_title := format('Upload video vs %s (clear suspended point)', r.opp);
        v_detail := '1 point is suspended. Upload before this time to keep it.';
        v_sev := 'urgent';
      ELSE
        v_kind := 'video';
        v_at := r.video_due_at;
        v_title := format('Upload match video vs %s', r.opp);
        v_detail := format(
          'Your video is due %s hours after the month this match was played in locked.',
          v_video_grace
        );
        v_sev := CASE
          WHEN r.video_due_at <= now() + interval '48 hours' THEN 'warn'
          ELSE 'info'
        END;
      END IF;

      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', v_kind || ':' || r.id::text,
        'kind', v_kind,
        'at', v_at,
        'title', v_title,
        'detail', v_detail,
        'severity', v_sev,
        'href', v_href,
        'fixture_id', r.id
      ));
    END LOOP;
  END IF;

  -- Result deadline. Only the club that has not entered its side.
  IF to_regprocedure('public.match_video_play_at(bigint)') IS NOT NULL
     AND to_regprocedure('public.match_video_due_lock_at(bigint)') IS NOT NULL
     AND to_regprocedure('public.match_video_due_gpsl_month(bigint)') IS NOT NULL THEN
    FOR r IN
      SELECT f.id, f.gpsl_month, f.home_club_short_name, f.away_club_short_name
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season
        AND f.status IN ('scheduled', 'played')
        AND coalesce(f.is_forfeit, false) = false
        AND coalesce(f.is_void, false) = false
        AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
        AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      ORDER BY f.id
    LOOP
      v_play := public.match_video_play_at(r.id);
      v_lock := public.match_video_due_lock_at(r.id);
      v_due_month := public.match_video_due_gpsl_month(r.id);
      IF v_play IS NULL OR v_lock IS NULL OR v_play > now() THEN
        CONTINUE;
      END IF;

      IF EXISTS (
        SELECT 1 FROM public.competition_result_submissions s
        WHERE s.fixture_id = r.id AND s.status = 'confirmed'
      ) OR (
        EXISTS (
          SELECT 1 FROM public.competition_fixtures f
          WHERE f.id = r.id
            AND f.status = 'played'
            AND f.home_goals IS NOT NULL
            AND f.away_goals IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM public.competition_result_submissions s
              WHERE s.fixture_id = f.id AND s.status = 'pending'
            )
        )
      ) THEN
        CONTINUE;
      END IF;

      v_entered := NULL;
      SELECT s.submitted_by_club INTO v_entered
      FROM public.competition_result_submissions s
      WHERE s.fixture_id = r.id AND s.status = 'pending'
      ORDER BY s.id DESC
      LIMIT 1;

      IF v_entered IS NOT NULL AND upper(btrim(v_entered)) = v_club THEN
        CONTINUE;
      END IF;

      v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
      v_opp := CASE WHEN v_side = 'home'
        THEN coalesce(public.club_display_name(r.away_club_short_name), r.away_club_short_name)
        ELSE coalesce(public.club_display_name(r.home_club_short_name), r.home_club_short_name)
      END;
      v_href := 'matchday.html?fixture=' || r.id::text;
      v_remind_at := v_lock + make_interval(hours => v_video_grace);
      v_close_at := v_remind_at + make_interval(hours => v_recover);
      v_arranged := EXISTS (
        SELECT 1
        FROM public.competition_fixture_schedule sch
        WHERE sch.fixture_id = r.id
          AND sch.status = 'agreed'
          AND sch.agreed_kickoff_at IS NOT NULL
          AND sch.agreed_kickoff_at <= now()
      );
      v_due_sort := public.competition_gpsl_month_sort(v_due_month);

      IF v_remind_at > now() - interval '21 days'
         AND v_remind_at <= now() + interval '150 days'
         AND v_close_at > now() - interval '1 hour' THEN
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'id', 'result_enter:' || r.id::text,
          'kind', 'result_enter',
          'at', v_remind_at,
          'title', CASE
            WHEN v_entered IS NOT NULL THEN format('Confirm result vs %s', v_opp)
            ELSE format('Enter result vs %s', v_opp)
          END,
          'detail', CASE
            WHEN v_entered IS NOT NULL THEN
              'Your opponent has entered a score. ₿500,000 if you have not confirmed by this time.'
            ELSE
              format(
                '₿500,000 if your result is still not in. You then have %s hours to finish it.',
                v_recover
              )
          END,
          'severity', CASE
            WHEN v_remind_at <= now() + interval '24 hours' THEN 'urgent'
            WHEN v_remind_at <= now() + interval '5 days' THEN 'warn'
            ELSE 'info'
          END,
          'href', v_href,
          'fixture_id', r.id
        ));
      END IF;

      IF v_close_at > now() - interval '21 days'
         AND v_close_at <= now() + interval '150 days'
         AND (v_entered IS NOT NULL OR v_arranged) THEN
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'id', 'result_close:' || r.id::text,
          'kind', 'result_close',
          'at', v_close_at,
          'title', CASE
            WHEN v_entered IS NOT NULL THEN format('Score confirmed vs %s', v_opp)
            ELSE format('Result extension vs %s', v_opp)
          END,
          'detail', CASE
            WHEN v_entered IS NOT NULL THEN
              'If you still have not confirmed, another ₿500,000 and their score is confirmed. Starters are rated 3. It cannot be edited.'
            ELSE
              'No score in. Another ₿500,000 to each club. The result stays open.'
          END,
          'severity', CASE
            WHEN v_close_at <= now() + interval '24 hours' THEN 'urgent'
            ELSE 'warn'
          END,
          'href', v_href,
          'fixture_id', r.id
        ));
      END IF;

      IF v_entered IS NULL AND v_due_sort IS NOT NULL THEN
        FOR v_cal IN
          SELECT
            lower(btrim(c.gpsl_month)) AS gpsl_month,
            c.lock_at,
            public.competition_gpsl_month_sort(c.gpsl_month) AS sort
          FROM public.competition_season_calendar c
          WHERE c.season_id = v_season
            AND c.lock_at IS NOT NULL
            AND c.lock_at > now() - interval '21 days'
            AND c.lock_at <= now() + interval '180 days'
            AND public.competition_gpsl_month_sort(c.gpsl_month) > v_due_sort
          ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
        LOOP
          IF v_cal.sort >= v_due_sort + 2 THEN
            v_out := v_out || jsonb_build_array(jsonb_build_object(
              'id', 'result_void:' || r.id::text,
              'kind', 'result_void',
              'at', v_cal.lock_at,
              'title', format('Result void vs %s', v_opp),
              'detail', 'Two months after the played month. If there is still no score, the match is void. Neither club gets the result. It counts as played.',
              'severity', CASE
                WHEN v_cal.lock_at <= now() + interval '7 days' THEN 'urgent'
                ELSE 'warn'
              END,
              'href', v_href,
              'fixture_id', r.id
            ));
            EXIT;
          ELSIF v_arranged THEN
            v_out := v_out || jsonb_build_array(jsonb_build_object(
              'id', 'result_month:' || r.id::text || ':' || v_cal.gpsl_month,
              'kind', 'result_month',
              'at', v_cal.lock_at,
              'title', format('Result still open vs %s', v_opp),
              'detail', format(
                'Another ₿500,000 at the %s lock while the match is still arranged and no score is in.',
                coalesce(public.competition_gpsl_month_label(v_cal.gpsl_month), v_cal.gpsl_month)
              ),
              'severity', CASE
                WHEN v_cal.lock_at <= now() + interval '7 days' THEN 'warn'
                ELSE 'info'
              END,
              'href', v_href,
              'fixture_id', r.id
            ));
          END IF;
        END LOOP;
      END IF;
    END LOOP;
  END IF;

  SELECT coalesce(jsonb_agg(x.elem ORDER BY (x.elem->>'at')::timestamptz, x.elem->>'id'), '[]'::jsonb)
  INTO v_out
  FROM jsonb_array_elements(v_out) AS x(elem);

  RETURN coalesce(v_out, '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_personal_deadlines(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_personal_deadlines(text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.owner_calendar_deadlines()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(coalesce(public.my_club_shortname(), '')), '');
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club', 'deadlines', '[]'::jsonb);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'deadlines', public.owner_personal_deadlines(v_club)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_calendar_deadlines() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_calendar_deadlines() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.owner_deadline_warning_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_item jsonb;
  v_at timestamptz;
  v_kind text;
  v_tz text;
  v_when text;
  v_sent int := 0;
  v_season bigint;
BEGIN
  IF NOT (
    coalesce(auth.role(), '') = 'service_role'
    OR coalesce(public.is_gpsl_admin(), false)
    OR session_user IN ('postgres', 'supabase_admin')
  ) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  FOR v_club IN
    SELECT c."ShortName"
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND nullif(btrim(c."ShortName"), '') IS NOT NULL
  LOOP
    FOR v_item IN
      SELECT elem
      FROM jsonb_array_elements(public.owner_personal_deadlines(v_club)) AS elem
    LOOP
      v_kind := v_item->>'kind';
      IF v_kind IN ('propose', 'late_fee', 'reply', 'video_suspend') THEN
        CONTINUE;
      END IF;

      BEGIN
        v_at := (v_item->>'at')::timestamptz;
      EXCEPTION WHEN OTHERS THEN
        CONTINUE;
      END;

      IF v_at IS NULL OR v_at <= now() OR v_at > now() + interval '24 hours' THEN
        CONTINUE;
      END IF;

      v_tz := 'Europe/London';
      BEGIN
        v_tz := coalesce(public.match_schedule_club_timezone(v_club), 'Europe/London');
      EXCEPTION WHEN OTHERS THEN
        v_tz := 'Europe/London';
      END;
      v_when := to_char(v_at AT TIME ZONE v_tz, 'Dy DD Mon HH24:MI')
        || ' ' || replace(v_tz, '_', ' ');

      BEGIN
        IF public.owner_inbox_send(
          'owner_deadline_warning',
          coalesce(v_item->>'title', 'Deadline soon'),
          format(
            E'%s\nDue %s.\n%s',
            coalesce(v_item->>'detail', 'This deadline is on your calendar.'),
            v_when,
            'Open My Calendar for the full list.'
          ),
          v_club,
          NULL,
          nullif(v_item->>'fixture_id', '')::bigint,
          NULL, NULL, NULL,
          coalesce(v_item->>'href', 'owner_calendar.html'),
          'owner_deadline_warn:' || coalesce(v_item->>'id', v_kind) || ':' || v_club,
          NULL,
          v_season,
          NULL
        ) IS NOT NULL THEN
          v_sent := v_sent + 1;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'deadline warning % %: %', v_club, v_item->>'id', SQLERRM;
      END;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'warned', v_sent);
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_deadline_warning_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.owner_deadline_warning_tick() TO service_role;

COMMENT ON FUNCTION public.owner_personal_deadlines(text) IS
  'Deadlines that belong to one club: propose, reply, check-in, last play, video, and result. Result rows are only for a club that has not entered its side.';

COMMENT ON FUNCTION public.owner_deadline_warning_tick() IS
  'Inbox warning in the 24 hours before each personal deadline. Propose and reply keep their existing warnings.';

DO $cron$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE WARNING 'pg_cron not enabled — deadline warnings will not run on their own';
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-deadline-warnings') THEN
    PERFORM cron.unschedule('gpsl-deadline-warnings');
  END IF;

  PERFORM cron.schedule(
    'gpsl-deadline-warnings',
    '*/15 * * * *',
    $q$SELECT public.owner_deadline_warning_tick();$q$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule deadline warnings: %', SQLERRM;
END
$cron$;

NOTIFY pgrst, 'reload schema';

SELECT public.owner_deadline_warning_tick();
