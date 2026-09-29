-- =============================================================================
-- Matchday checklist (per owner, per fixture)
--
-- Steps per fixture:
--   schedule  → kick-off agreed (home proposes first; reply owed + deadline)
--   squad     → saved matchday 23 valid (dashboard only; uses auth club)
--   checkin   → checked in (window: 10 min before KO → 10 min after)
--   result    → result submitted / confirmed by you
--   stats     → your player stats entered
--   confirm   → opponent confirmed
--   video     → match video uploaded (+₿200k); 72h after month lock, then
--               24h suspended point
--
-- Fixtures in scope (current season, league + cup):
--   · active GPSL month
--   · any fixture with a pending result submission
--   · last month's played fixtures still inside the video window
--   · any fixture with a suspended video point
--
-- RPCs:
--   dashboard_matchday_checklist()  → full checklist for my club (dashboard)
--   matchday_checklist_count()      → "your move" count (nav badge)
--   matchday_checklist_lock_nudges() → one inbox nudge per club ≤24h before
--                                      month lock, only if items are open
--
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Inbox message type: matchday_checklist (keeps every existing type)
-- ---------------------------------------------------------------------------
DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION
    SELECT 'matchday_checklist'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END;
$inbox_types$;

-- ---------------------------------------------------------------------------
-- Expected match video filename for a fixture
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.matchday_checklist_video_filename(p_fixture_id bigint)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT format(
    '%s %s-%s %s [%s-%s].mp4',
    upper(btrim(f.home_club_short_name)),
    coalesce(f.home_goals::text, 'H'),
    coalesce(f.away_goals::text, 'A'),
    upper(btrim(f.away_club_short_name)),
    CASE
      WHEN coalesce(f.competition_type, 'league') = 'cup' THEN
        CASE lower(coalesce(f.cup_code, ''))
          WHEN 'super8' THEN 'S8'
          WHEN 'plate' THEN 'PL'
          WHEN 'shield' THEN 'SH'
          WHEN 'bowl' THEN 'BO'
          WHEN 'league_cup' THEN 'LC'
          ELSE upper(coalesce(f.cup_code, 'CUP'))
        END
      ELSE
        CASE f.division
          WHEN 'superleague' THEN 'SL'
          WHEN 'championship_a' THEN 'CA'
          WHEN 'championship_b' THEN 'CB'
          ELSE 'SL'
        END
    END,
    CASE
      WHEN coalesce(f.competition_type, 'league') = 'cup'
        THEN 'R' || coalesce(f.cup_round::text, '?')
      ELSE 'MD' || coalesce(f.matchday::text, '?')
    END
  )
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;
$$;

-- ---------------------------------------------------------------------------
-- Core builder (club-scoped; no auth assumptions except optional squad check)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.matchday_checklist_for_club(
  p_club text,
  p_include_squad boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_season_id bigint;
  v_month text;
  v_lock timestamptz;
  v_grace int := 72;
  v_before int := 10;
  v_after int := 10;
  v_now timestamptz := now();
  r record;
  v_side text;
  v_opp text;
  v_steps jsonb;
  v_flags jsonb;
  v_fixtures jsonb := '[]'::jsonb;
  v_club_flags jsonb := '[]'::jsonb;
  v_sch record;
  v_sch_found boolean;
  v_sub record;
  v_sub_found boolean;
  v_rej boolean;
  v_my_in boolean;
  v_opp_in boolean;
  v_opens timestamptz;
  v_closes timestamptz;
  v_played boolean;
  v_stats_done boolean;
  v_video_deadline timestamptz;
  v_video record;
  v_fail record;
  v_fail_found boolean;
  v_ingest_bad boolean;
  v_filename text;
  v_ready jsonb;
  v_issue text;
  v_step jsonb;
  v_needs int;
  v_total_needs int := 0;
  v_next jsonb;
  v_all_done boolean;
  v_hol record;
  v_short int;
  v_min int;
  v_avail int;
  v_inc record;
  v_schedule_href text;
  v_matchday_href text;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'club_short_name', v_club, 'fixtures', '[]'::jsonb,
      'flags', '[]'::jsonb, 'needs_you', 0, 'reason', 'no_season');
  END IF;

  v_month := public.competition_active_gpsl_month(v_season_id, v_now);

  SELECT cal.lock_at INTO v_lock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_season_id
    AND lower(btrim(cal.gpsl_month)) = lower(btrim(coalesce(v_month, '')));

  BEGIN
    v_grace := coalesce(public.match_video_missing_fine_grace_hours(), 72);
  EXCEPTION WHEN OTHERS THEN
    v_grace := 72;
  END;
  BEGIN
    v_before := coalesce(public.match_schedule_checkin_open_before_minutes(), 10);
    v_after := coalesce(public.match_schedule_checkin_minutes(), 10);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  FOR r IN
    SELECT
      f.*,
      cal.lock_at AS month_lock_at
    FROM public.competition_fixtures f
    LEFT JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    WHERE f.season_id = v_season_id
      AND f.status <> 'cancelled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND (
        (v_month IS NOT NULL AND lower(btrim(f.gpsl_month)) = lower(v_month))
        OR EXISTS (
          SELECT 1 FROM public.competition_result_submissions s
          WHERE s.fixture_id = f.id AND s.status = 'pending'
        )
        OR (
          f.status = 'played'
          AND cal.lock_at IS NOT NULL
          AND cal.lock_at <= v_now
          AND v_now < cal.lock_at + make_interval(hours => v_grace + 24)
        )
        OR EXISTS (
          SELECT 1 FROM public.fixture_match_video_failures fail
          WHERE fail.fixture_id = f.id
            AND upper(btrim(fail.club_short_name)) = v_club
            AND fail.pts_status = 'suspended'
        )
      )
    ORDER BY coalesce(cal.lock_at, 'infinity'::timestamptz), f.competition_type DESC, f.matchday, f.cup_round, f.id
  LOOP
    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    v_opp := CASE WHEN v_side = 'home' THEN upper(btrim(r.away_club_short_name)) ELSE upper(btrim(r.home_club_short_name)) END;
    v_played := r.status = 'played';
    v_steps := '[]'::jsonb;
    v_flags := '[]'::jsonb;
    v_schedule_href := 'fixture_schedule.html?fixture=' || r.id;
    v_matchday_href := 'matchday.html?fixture=' || r.id;

    SELECT * INTO v_sch FROM public.competition_fixture_schedule WHERE fixture_id = r.id;
    v_sch_found := FOUND;

    SELECT * INTO v_sub
    FROM public.competition_result_submissions
    WHERE fixture_id = r.id AND status = 'pending'
    ORDER BY id DESC LIMIT 1;
    v_sub_found := FOUND;

    v_rej := NOT v_played AND NOT v_sub_found AND EXISTS (
      SELECT 1 FROM public.competition_result_submissions s
      WHERE s.fixture_id = r.id
        AND s.status = 'rejected'
        AND s.id = (SELECT max(s2.id) FROM public.competition_result_submissions s2 WHERE s2.fixture_id = r.id)
    );

    v_my_in := EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = r.id AND upper(btrim(c.club_short_name)) = v_club
    );
    v_opp_in := EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = r.id AND upper(btrim(c.club_short_name)) = v_opp
    );

    -- 1. Kick-off agreed
    IF v_played OR (v_sch_found AND v_sch.status = 'agreed') THEN
      v_step := jsonb_build_object('key', 'schedule', 'label', 'Kick-off agreed', 'state', 'done',
        'due_at', CASE WHEN v_sch_found THEN v_sch.agreed_kickoff_at END);
    ELSIF v_sch_found AND v_sch.status = 'negotiating' THEN
      IF upper(btrim(coalesce(v_sch.response_required_club_short_name, ''))) = v_club THEN
        v_step := jsonb_build_object('key', 'schedule', 'label', 'Reply to kick-off proposal',
          'state', CASE WHEN v_sch.response_due_at IS NOT NULL AND v_sch.response_due_at < v_now THEN 'overdue' ELSE 'todo' END,
          'due_at', v_sch.response_due_at, 'href', v_schedule_href, 'action', 'Reply');
      ELSE
        v_step := jsonb_build_object('key', 'schedule', 'label', 'Kick-off proposed — waiting on opponent',
          'state', 'waiting', 'due_at', v_sch.response_due_at, 'href', v_schedule_href);
      END IF;
    ELSE
      IF v_side = 'home' THEN
        v_step := jsonb_build_object('key', 'schedule', 'label', 'Propose a kick-off time',
          'state', 'todo', 'href', v_schedule_href, 'action', 'Propose');
      ELSE
        v_step := jsonb_build_object('key', 'schedule', 'label', 'Waiting for home club to propose kick-off',
          'state', 'waiting', 'href', v_schedule_href);
      END IF;
    END IF;
    v_steps := v_steps || jsonb_build_array(v_step);

    -- Check-in window
    v_opens := NULL;
    v_closes := NULL;
    IF v_sch_found AND v_sch.status = 'agreed' AND v_sch.agreed_kickoff_at IS NOT NULL THEN
      v_opens := v_sch.agreed_kickoff_at - make_interval(mins => v_before);
      v_closes := v_sch.agreed_kickoff_at + make_interval(mins => v_after);
    END IF;

    -- 2. Squad ready (dashboard only)
    IF p_include_squad THEN
      IF v_played OR v_my_in OR v_sub_found THEN
        v_step := jsonb_build_object('key', 'squad', 'label', 'Matchday squad ready', 'state', 'done');
      ELSE
        v_ready := NULL;
        BEGIN
          v_ready := public.club_matchday_checkin_ready(r.id);
        EXCEPTION WHEN OTHERS THEN
          v_ready := NULL;
        END;
        IF v_ready IS NULL THEN
          v_step := jsonb_build_object('key', 'squad', 'label', 'Matchday squad ready', 'state', 'upcoming',
            'href', v_matchday_href || '&fix_checkin_squad=1');
        ELSIF coalesce((v_ready->>'ok')::boolean, false) THEN
          v_step := jsonb_build_object('key', 'squad', 'label', 'Matchday squad ready', 'state', 'done');
        ELSE
          v_issue := v_ready->'issues'->>0;
          v_step := jsonb_build_object('key', 'squad', 'label', 'Fix matchday squad', 'state', 'todo',
            'detail', v_issue, 'href', v_matchday_href || '&fix_checkin_squad=1', 'action', 'Fix squad');
        END IF;
      END IF;
      v_steps := v_steps || jsonb_build_array(v_step);
    END IF;

    -- 3. Checked in
    IF v_played OR v_sub_found OR v_my_in THEN
      v_step := jsonb_build_object('key', 'checkin', 'label', 'Checked in', 'state', 'done',
        'detail', CASE WHEN NOT v_played AND NOT v_sub_found AND NOT v_opp_in THEN 'Waiting for opponent to check in' END);
    ELSIF v_opens IS NULL THEN
      v_step := jsonb_build_object('key', 'checkin', 'label', 'Check in', 'state', 'upcoming',
        'detail', 'Opens 10 min before an agreed kick-off');
    ELSIF v_now < v_opens THEN
      v_step := jsonb_build_object('key', 'checkin', 'label', 'Check in', 'state', 'upcoming',
        'due_at', v_opens, 'detail', 'Opens 10 min before kick-off');
    ELSIF v_now < v_closes THEN
      v_step := jsonb_build_object('key', 'checkin', 'label', 'Check in now', 'state', 'todo',
        'due_at', v_closes, 'href', v_matchday_href, 'action', 'Check in', 'checkin_fixture_id', r.id);
    ELSE
      v_step := jsonb_build_object('key', 'checkin', 'label', 'Check-in window missed', 'state', 'overdue',
        'detail', 'See the Schedule page (reschedule / no-show rules)', 'href', v_schedule_href, 'action', 'Schedule');
    END IF;
    v_steps := v_steps || jsonb_build_array(v_step);

    -- 4. Result submitted
    IF v_played THEN
      v_step := jsonb_build_object('key', 'result', 'label', 'Result submitted', 'state', 'done',
        'detail', CASE WHEN r.home_goals IS NOT NULL THEN r.home_goals || '–' || r.away_goals END);
    ELSIF v_sub_found AND upper(btrim(v_sub.submitted_by_club)) = v_club THEN
      v_step := jsonb_build_object('key', 'result', 'label', 'Result submitted', 'state', 'done',
        'detail', v_sub.home_goals || '–' || v_sub.away_goals);
    ELSIF v_sub_found THEN
      v_step := jsonb_build_object('key', 'result', 'label', 'Confirm result (' || v_sub.home_goals || '–' || v_sub.away_goals || ')',
        'state', 'todo', 'href', 'matchday.html?fixture=' || r.id || '&confirm=' || v_sub.id, 'action', 'Confirm');
    ELSIF v_rej THEN
      v_step := jsonb_build_object('key', 'result', 'label', 'Result rejected — re-submit', 'state', 'todo',
        'href', v_matchday_href, 'action', 'Re-submit');
      v_flags := v_flags || jsonb_build_array(jsonb_build_object('key', 'dispute', 'level', 'warn',
        'text', 'Result was rejected — agree the score or raise it with admins'));
    ELSIF v_my_in AND v_opp_in THEN
      v_step := jsonb_build_object('key', 'result', 'label', 'Enter the result', 'state', 'todo',
        'href', v_matchday_href, 'action', 'Enter result');
    ELSE
      v_step := jsonb_build_object('key', 'result', 'label', 'Submit result', 'state', 'upcoming');
    END IF;
    v_steps := v_steps || jsonb_build_array(v_step);

    -- 5. Your stats
    v_stats_done := false;
    IF v_played THEN
      v_stats_done := EXISTS (
        SELECT 1 FROM public.competition_match_player_stats ps
        WHERE ps.fixture_id = r.id AND upper(btrim(ps.club_short_name)) = v_club
      );
      v_step := jsonb_build_object('key', 'stats', 'label', 'Your player stats',
        'state', CASE WHEN v_stats_done THEN 'done' ELSE 'na' END,
        'detail', CASE WHEN NOT v_stats_done THEN 'No stats recorded' END);
    ELSIF v_sub_found AND upper(btrim(v_sub.submitted_by_club)) = v_club THEN
      v_stats_done := jsonb_array_length(coalesce(v_sub.player_stats, '[]'::jsonb)) > 0;
      v_step := jsonb_build_object('key', 'stats', 'label', 'Your player stats',
        'state', CASE WHEN v_stats_done THEN 'done' ELSE 'na' END);
    ELSIF v_sub_found THEN
      v_step := jsonb_build_object('key', 'stats', 'label', 'Enter your stats when confirming', 'state', 'todo',
        'href', 'matchday.html?fixture=' || r.id || '&confirm=' || v_sub.id, 'action', 'Confirm', 'counted', false);
    ELSE
      v_step := jsonb_build_object('key', 'stats', 'label', 'Your player stats', 'state', 'upcoming');
    END IF;
    v_steps := v_steps || jsonb_build_array(v_step);

    -- 6. Opponent confirmed
    IF v_played THEN
      v_step := jsonb_build_object('key', 'confirm', 'label', 'Result confirmed', 'state', 'done');
    ELSIF v_sub_found AND upper(btrim(v_sub.submitted_by_club)) = v_club THEN
      v_step := jsonb_build_object('key', 'confirm', 'label', 'Waiting on opponent to confirm', 'state', 'waiting');
    ELSE
      v_step := jsonb_build_object('key', 'confirm', 'label', 'Opponent confirms', 'state', 'upcoming');
    END IF;
    v_steps := v_steps || jsonb_build_array(v_step);

    -- 7. Match video
    v_filename := public.matchday_checklist_video_filename(r.id);
    SELECT * INTO v_video FROM public.fixture_match_videos WHERE fixture_id = r.id AND side = v_side;
    IF FOUND THEN
      v_step := jsonb_build_object('key', 'video', 'label', 'Match video uploaded', 'state', 'done',
        'detail', CASE WHEN coalesce(v_video.credited_amount, 0) > 0 THEN '+₿' || to_char(v_video.credited_amount, 'FM999,999,999') || ' credited' END);
    ELSE
      SELECT * INTO v_fail FROM public.fixture_match_video_failures
      WHERE fixture_id = r.id AND side = v_side;
      v_fail_found := FOUND;
      v_video_deadline := CASE WHEN r.month_lock_at IS NOT NULL THEN r.month_lock_at + make_interval(hours => v_grace) END;

      IF v_fail_found AND v_fail.pts_status = 'suspended' THEN
        v_step := jsonb_build_object('key', 'video', 'label', 'Upload video — 1 point suspended', 'state', 'overdue',
          'due_at', v_fail.pts_suspend_until, 'filename', v_filename, 'href', 'discord', 'action', 'Upload',
          'detail', 'Upload before the deadline to avoid the point deduction');
      ELSIF v_fail_found AND v_fail.pts_status = 'cleared' AND coalesce(v_fail.fine_amount, 0) = 0 THEN
        v_step := jsonb_build_object('key', 'video', 'label', 'Match video missed (waived — ease-in)', 'state', 'na');
      ELSIF v_fail_found THEN
        v_step := jsonb_build_object('key', 'video', 'label', 'Match video missed', 'state', 'missed',
          'detail', 'Fine' || CASE WHEN v_fail.pts_status = 'full' THEN ' and point deduction applied' ELSE ' applied' END);
      ELSIF NOT v_played THEN
        v_step := jsonb_build_object('key', 'video', 'label', 'Upload match video (+₿200k)', 'state', 'upcoming',
          'filename', v_filename, 'detail', 'After the match — within 72h of month lock');
      ELSE
        v_ingest_bad := EXISTS (
          SELECT 1 FROM public.fixture_match_video_ingest_log l
          WHERE l.fixture_id = r.id AND l.side = v_side AND NOT l.ok
        );
        v_step := jsonb_build_object('key', 'video', 'label', 'Upload match video (+₿200k)',
          'state', CASE
            WHEN v_ingest_bad THEN 'warn'
            WHEN v_video_deadline IS NOT NULL AND v_video_deadline < v_now THEN 'overdue'
            ELSE 'todo' END,
          'due_at', v_video_deadline, 'filename', v_filename, 'href', 'discord', 'action', 'Upload',
          'detail', CASE WHEN v_ingest_bad THEN 'Last upload did not match this fixture — check the filename' END);
      END IF;
    END IF;
    v_steps := v_steps || jsonb_build_array(v_step);

    -- Fixture flags
    FOR v_inc IN
      SELECT i.status
      FROM public.competition_fixture_network_incidents i
      WHERE i.fixture_id = r.id AND i.status <> 'resolved'
      ORDER BY i.id DESC
      LIMIT 1
    LOOP
      v_flags := v_flags || jsonb_build_array(jsonb_build_object('key', 'network', 'level', 'warn',
        'text', 'Network incident open (' || replace(v_inc.status, '_', ' ') || ')', 'href', v_matchday_href));
    END LOOP;

    SELECT h.ends_at INTO v_hol
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_season_id
      AND upper(btrim(h.club_short_name)) = v_opp
      AND h.ends_at > v_now
      AND h.starts_at < coalesce(r.month_lock_at, v_now + interval '14 days')
    ORDER BY h.starts_at
    LIMIT 1;
    IF FOUND THEN
      v_flags := v_flags || jsonb_build_array(jsonb_build_object('key', 'opp_holiday', 'level', 'info',
        'text', 'Opponent on holiday until ' || to_char(v_hol.ends_at AT TIME ZONE 'Europe/London', 'Dy DD Mon')));
    END IF;

    -- Summarise
    SELECT count(*)::int INTO v_needs
    FROM jsonb_array_elements(v_steps) s
    WHERE s->>'state' IN ('todo', 'overdue', 'warn')
      AND s ? 'href'
      AND coalesce((s->>'counted')::boolean, true);

    SELECT s INTO v_next
    FROM jsonb_array_elements(v_steps) WITH ORDINALITY AS t(s, n)
    WHERE s->>'state' IN ('overdue', 'todo', 'warn') AND s ? 'href'
    ORDER BY CASE s->>'state' WHEN 'overdue' THEN 0 WHEN 'todo' THEN 1 ELSE 2 END, n
    LIMIT 1;

    SELECT bool_and(s->>'state' IN ('done', 'na')) INTO v_all_done
    FROM jsonb_array_elements(v_steps) s;

    v_total_needs := v_total_needs + v_needs;

    v_fixtures := v_fixtures || jsonb_build_array(jsonb_build_object(
      'fixture_id', r.id,
      'competition_type', r.competition_type,
      'division', r.division,
      'cup_code', r.cup_code,
      'cup_round', r.cup_round,
      'matchday', r.matchday,
      'gpsl_month', r.gpsl_month,
      'month_lock_at', r.month_lock_at,
      'status', r.status,
      'side', v_side,
      'home_club_short_name', r.home_club_short_name,
      'away_club_short_name', r.away_club_short_name,
      'opponent_short_name', v_opp,
      'agreed_kickoff_at', CASE WHEN v_sch_found THEN v_sch.agreed_kickoff_at END,
      'steps', v_steps,
      'flags', v_flags,
      'needs_you', v_needs,
      'all_done', coalesce(v_all_done, false),
      'next_action', v_next
    ));
  END LOOP;

  -- Club flags
  SELECT h.starts_at, h.ends_at INTO v_hol
  FROM public.club_owner_holidays h
  WHERE h.season_id = v_season_id
    AND upper(btrim(h.club_short_name)) = v_club
    AND h.ends_at > v_now
    AND h.starts_at < v_now + interval '7 days'
  ORDER BY h.starts_at
  LIMIT 1;
  IF FOUND THEN
    v_club_flags := v_club_flags || jsonb_build_array(jsonb_build_object('key', 'holiday', 'level', 'info',
      'text', CASE WHEN v_hol.starts_at <= v_now THEN 'You are on holiday until ' ELSE 'Holiday booked until ' END
        || to_char(v_hol.ends_at AT TIME ZONE 'Europe/London', 'Dy DD Mon'),
      'href', 'owner_details.html'));
  END IF;

  BEGIN
    v_min := public.squad_minimum_size();
    v_avail := public.club_available_player_count(v_club);
    v_short := greatest(v_min - v_avail, 0);
    IF v_short > 0 THEN
      v_club_flags := v_club_flags || jsonb_build_array(jsonb_build_object('key', 'squad_min', 'level', 'warn',
        'text', format('Only %s fit players (min %s)', v_avail, v_min)
          || CASE WHEN public.emergency_loan_window_open(v_month) THEN ' — emergency loan available' ELSE '' END,
        'href', 'squad.html'));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'month_lock_at', v_lock,
    'fixtures', v_fixtures,
    'flags', v_club_flags,
    'needs_you', v_total_needs
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.matchday_checklist_for_club(text, boolean) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Dashboard RPC (my club, includes squad readiness)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dashboard_matchday_checklist()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
BEGIN
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;
  RETURN public.matchday_checklist_for_club(v_club, true);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.dashboard_matchday_checklist() TO authenticated;

-- ---------------------------------------------------------------------------
-- Nav badge count (no squad check — keep it light)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.matchday_checklist_count()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
BEGIN
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RETURN 0;
  END IF;
  RETURN coalesce((public.matchday_checklist_for_club(v_club, false)->>'needs_you')::int, 0);
EXCEPTION WHEN OTHERS THEN
  RETURN 0;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.matchday_checklist_count() TO authenticated;

-- ---------------------------------------------------------------------------
-- Month-lock nudge: once per club per month, ≤24h before lock, open items only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.matchday_checklist_lock_nudges()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_lock timestamptz;
  v_c record;
  v_list jsonb;
  v_needs int;
  v_lines text;
  v_sent int := 0;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role'
     AND current_user NOT IN ('postgres', 'supabase_admin')
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;
  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'sent', 0, 'reason', 'no_season');
  END IF;

  v_month := public.competition_active_gpsl_month(v_season_id, now());
  IF v_month IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'sent', 0, 'reason', 'no_active_month');
  END IF;

  SELECT lock_at INTO v_lock
  FROM public.competition_season_calendar
  WHERE season_id = v_season_id AND lower(btrim(gpsl_month)) = lower(v_month);

  IF v_lock IS NULL OR v_lock - now() > interval '24 hours' OR v_lock <= now() THEN
    RETURN jsonb_build_object('ok', true, 'sent', 0, 'reason', 'not_in_window', 'lock_at', v_lock);
  END IF;

  FOR v_c IN
    SELECT DISTINCT upper(btrim(c."ShortName")) AS short_name, c.owner_id
    FROM public."Clubs" c
    JOIN public.competition_fixtures f
      ON f.season_id = v_season_id
     AND upper(btrim(c."ShortName")) IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
    WHERE c.owner_id IS NOT NULL
  LOOP
    BEGIN
      v_list := public.matchday_checklist_for_club(v_c.short_name, false);
      v_needs := coalesce((v_list->>'needs_you')::int, 0);
      IF v_needs <= 0 THEN
        CONTINUE;
      END IF;

      SELECT string_agg(
        '• ' || upper(fx->>'home_club_short_name') || ' v ' || upper(fx->>'away_club_short_name')
          || ' — ' || (fx->'next_action'->>'label'),
        E'\n')
      INTO v_lines
      FROM jsonb_array_elements(v_list->'fixtures') fx
      WHERE coalesce((fx->>'needs_you')::int, 0) > 0;

      PERFORM public.owner_inbox_send(
        p_message_type => 'matchday_checklist',
        p_title => format('Month locks soon — %s matchday item%s open', v_needs, CASE WHEN v_needs = 1 THEN '' ELSE 's' END),
        p_body => format(
          E'The %s GPSL month locks %s (UK). Still to do:\n%s\n\nOpen your Dashboard for the full checklist.',
          initcap(v_month),
          to_char(v_lock AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI'),
          coalesce(v_lines, '')
        ),
        p_recipient_club => v_c.short_name,
        p_owner_id => v_c.owner_id,
        p_action_href => 'dashboard.html#matchdayChecklist',
        p_dedupe_key => format('mc_lock_nudge:%s:%s:%s', v_season_id, lower(v_month), v_c.short_name),
        p_gpsl_month => v_month,
        p_season_id => v_season_id
      );
      v_sent := v_sent + 1;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'sent', v_sent, 'gpsl_month', v_month, 'lock_at', v_lock);
END;
$function$;

REVOKE ALL ON FUNCTION public.matchday_checklist_lock_nudges() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.matchday_checklist_lock_nudges() TO authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-matchday-checklist-lock-nudge') THEN
      PERFORM cron.unschedule('gpsl-matchday-checklist-lock-nudge');
    END IF;
    PERFORM cron.schedule(
      'gpsl-matchday-checklist-lock-nudge',
      '17 * * * *',
      $job$SELECT public.matchday_checklist_lock_nudges();$job$
    );
  END IF;
END;
$cron$;

NOTIFY pgrst, 'reload schema';
