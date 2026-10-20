-- =============================================================================
-- Club Wire: upcoming fine / forfeit cutoffs for the signed-in owner's club
--
-- Surfaces propose / late-fee / reply / month-lock / check-in / play-window
-- deadlines beside outbid alerts on the dashboard Club Wire card.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_wire_cutoffs()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_season bigint;
  v_out jsonb := '[]'::jsonb;
  v_lock_at timestamptz;
  v_lock_month text;
  r record;
  v_side text;
  v_home_proposed boolean;
  v_opp text;
  v_state text;
  v_title text;
  v_detail text;
  v_sev text;
  v_at timestamptz;
  v_kind text;
  v_href text;
  v_before int := 10;
  v_after int := 10;
  v_opens timestamptz;
  v_closes timestamptz;
  v_grace int;
  v_final_lock timestamptz;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club', 'cutoffs', '[]'::jsonb);
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'club_short_name', v_club, 'cutoffs', '[]'::jsonb);
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

  -- Next GPSL month lock (fines / unfinished checks)
  SELECT c.lock_at, c.gpsl_month
  INTO v_lock_at, v_lock_month
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season
    AND c.lock_at > now() - interval '1 hour'
  ORDER BY c.lock_at
  LIMIT 1;

  IF v_lock_at IS NOT NULL AND v_lock_at <= now() + interval '21 days' THEN
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', 'month_lock:' || coalesce(v_lock_month, ''),
      'kind', 'month_lock',
      'at', v_lock_at,
      'title', 'GPSL month lock',
      'detail', format(
        'Thu lock — unproposed homes (₿2.5m), late proposals (₿1m), overdue replies, unfinished no-shows (3–0 + ₿2.5m). Closing %s.',
        public.competition_gpsl_month_label(v_lock_month)
      ),
      'severity', CASE
        WHEN v_lock_at <= now() + interval '48 hours' THEN 'urgent'
        WHEN v_lock_at <= now() + interval '5 days' THEN 'warn'
        ELSE 'info'
      END,
      'href', 'fixtures.html',
      'fixture_id', NULL
    ));
  END IF;

  -- Upcoming arrange / reply cutoffs (same window as owner_upcoming_arrangements)
  FOR r IN
    SELECT
      f.id,
      f.gpsl_month,
      f.matchday,
      f.competition_type,
      f.cup_code,
      f.cup_round,
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
      AND cal.unlock_at <= now() + interval '21 days'
      AND coalesce(s.status, 'unscheduled') <> 'agreed'
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(f.id)
      )
    ORDER BY cal.unlock_at, f.id
  LOOP
    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    v_opp := CASE WHEN v_side = 'home'
      THEN upper(btrim(r.away_club_short_name))
      ELSE upper(btrim(r.home_club_short_name)) END;
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
        'detail', CASE
          WHEN r.response_due_at < now() THEN 'Overdue — first month lock warns; later locks while still overdue = ₿2.5m'
          ELSE 'Reply before this deadline (often 24h turns)'
        END,
        'severity', CASE
          WHEN r.response_due_at < now() THEN 'urgent'
          WHEN r.response_due_at <= now() + interval '6 hours' THEN 'warn'
          ELSE 'info'
        END,
        'href', v_href,
        'fixture_id', r.id
      ));
    ELSIF v_state = 'propose' THEN
      -- Late-fee window opens 48h before play-month unlock (public copy)
      IF r.unlock_at - interval '48 hours' > now() THEN
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'id', 'late_fee:' || r.id::text,
          'kind', 'late_fee',
          'at', r.unlock_at - interval '48 hours',
          'title', format('Propose vs %s (avoid late fee)', v_opp),
          'detail', format(
            'Propose by %s UK to avoid the ₿1m late fee. No proposal by month unlock → ₿2.5m (repeats each lock).',
            to_char((r.unlock_at - interval '48 hours') AT TIME ZONE 'Europe/London', 'Dy HH24:MI')
          ),
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
        'detail', CASE
          WHEN now() >= r.unlock_at - interval '48 hours' THEN
            'Late-fee window open (₿1m). No proposal by this unlock → ₿2.5m Match Management fine.'
          ELSE
            'Home must propose a kick-off before this GPSL month opens.'
        END,
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

  -- Agreed kick-offs: check-in window (no-show → forfeit risk at later lock)
  FOR r IN
    SELECT
      f.id,
      f.home_club_short_name,
      f.away_club_short_name,
      s.agreed_kickoff_at
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id AND s.status = 'agreed'
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND s.agreed_kickoff_at IS NOT NULL
      AND s.agreed_kickoff_at > now() - interval '2 hours'
      AND s.agreed_kickoff_at <= now() + interval '3 days'
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_fixture_checkin c
        WHERE c.fixture_id = f.id AND upper(btrim(c.club_short_name)) = v_club
      )
    ORDER BY s.agreed_kickoff_at
    LIMIT 6
  LOOP
    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    v_opp := CASE WHEN v_side = 'home'
      THEN upper(btrim(r.away_club_short_name))
      ELSE upper(btrim(r.home_club_short_name)) END;
    v_opens := r.agreed_kickoff_at - make_interval(mins => v_before);
    v_closes := r.agreed_kickoff_at + make_interval(mins => v_after);
    v_href := 'fixture_schedule.html?fixture=' || r.id::text;

    IF now() < v_opens THEN
      v_kind := 'checkin';
      v_at := v_opens;
      v_title := format('Check-in opens vs %s', v_opp);
      v_detail := format('Window %s–%s UK. Miss alone → no-show risk (3–0 + ₿2.5m at later lock if unfinished).',
        to_char(v_opens AT TIME ZONE 'Europe/London', 'Dy HH24:MI'),
        to_char(v_closes AT TIME ZONE 'Europe/London', 'HH24:MI'));
      v_sev := CASE WHEN v_opens <= now() + interval '6 hours' THEN 'warn' ELSE 'info' END;
    ELSIF now() <= v_closes THEN
      v_kind := 'checkin';
      v_at := v_closes;
      v_title := format('Check in now vs %s', v_opp);
      v_detail := 'Check-in window open — miss alone and the match stays unfinished → forfeit risk at month lock.';
      v_sev := 'urgent';
    ELSE
      v_kind := 'noshow';
      v_at := coalesce(v_lock_at, v_closes);
      v_title := format('Check-in missed vs %s', v_opp);
      v_detail := 'Reschedule on the schedule page, or face 3–0 + ₿2.5m at month lock if still unfinished.';
      v_sev := 'urgent';
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

  -- Play-window / final lock for unfinished fixtures whose play month has opened
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
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(f.id)
      )
    ORDER BY f.id
    LIMIT 12
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

    IF v_final_lock IS NULL OR v_final_lock <= now() OR v_final_lock > now() + interval '14 days' THEN
      CONTINUE;
    END IF;

    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    v_opp := CASE WHEN v_side = 'home'
      THEN upper(btrim(r.away_club_short_name))
      ELSE upper(btrim(r.home_club_short_name)) END;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', 'play_window:' || r.id::text,
      'kind', 'play_window',
      'at', v_final_lock,
      'title', format('Last play chance vs %s', v_opp),
      'detail', 'Still unplayed after this lock → awarded by scheduling activity (true tie 0–0).',
      'severity', CASE WHEN v_final_lock <= now() + interval '3 days' THEN 'warn' ELSE 'info' END,
      'href', 'fixture_schedule.html?fixture=' || r.id::text,
      'fixture_id', r.id
    ));
  END LOOP;

  -- Sort by at, keep first 10
  SELECT coalesce(jsonb_agg(x.elem ORDER BY (x.elem->>'at')::timestamptz, x.elem->>'id'), '[]'::jsonb)
  INTO v_out
  FROM (
    SELECT elem
    FROM jsonb_array_elements(v_out) AS elem
    ORDER BY (elem->>'at')::timestamptz NULLS LAST, elem->>'id'
    LIMIT 10
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'next_month_lock_at', v_lock_at,
    'next_month_lock_month', v_lock_month,
    'cutoffs', coalesce(v_out, '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_wire_cutoffs() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_wire_cutoffs() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_wire_cutoffs() TO service_role;
