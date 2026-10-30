-- =============================================================================
-- Admin replay / catch-up: surface on Club Wire + Arrange now + Matchday checklist
-- (2026-10-30)
--
-- Bug: August (etc.) fixtures reset for replay stay scheduled/unscheduled, but
-- owner_upcoming_arrangements + club_wire_cutoffs only list fixtures whose
-- *play-month unlock is still in the future*. Past-month unlocks never light up,
-- so owners do not see “need to re-arrange”.
--
-- Fix: also include
--   • admin_replay_reset_at IS NOT NULL (admin wipe for replay)
--   • catch-up fixtures still not agreed
-- in Arrange now, Club Wire cutoffs, and Matchday checklist.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.owner_upcoming_arrangements()
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
  v_active text;
  v_active_lock timestamptz;
  r record;
  v_side text;
  v_state text;
  v_home_proposed boolean;
  v_is_replay boolean;
  v_is_catch_up boolean;
  v_propose_by timestamptz;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club', 'fixtures', '[]'::jsonb);
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'fixtures', '[]'::jsonb);
  END IF;

  v_active := public.competition_active_gpsl_month(v_season, now());
  SELECT c.lock_at INTO v_active_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season
    AND lower(btrim(c.gpsl_month)) = lower(btrim(coalesce(v_active, '')));

  FOR r IN
    SELECT
      f.id, f.gpsl_month, f.matchday, f.competition_type, f.cup_code, f.cup_round,
      f.home_club_short_name, f.away_club_short_name,
      f.admin_replay_reset_at,
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
      AND coalesce(s.status, 'unscheduled') <> 'agreed'
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(f.id)
      )
      AND (
        -- Normal: next month(s) still unlocking
        (cal.unlock_at > now() AND cal.unlock_at <= now() + interval '15 days')
        -- Admin wipe for replay (any past month)
        OR f.admin_replay_reset_at IS NOT NULL
        -- Catch-up still needing a kick-off
        OR (
          to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
          AND public.match_schedule_fixture_is_catch_up(f.id)
        )
      )
    ORDER BY
      CASE WHEN f.admin_replay_reset_at IS NOT NULL THEN 0 ELSE 1 END,
      cal.unlock_at,
      f.competition_type DESC,
      f.matchday,
      f.cup_round,
      f.id
  LOOP
    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    v_is_replay := r.admin_replay_reset_at IS NOT NULL;
    BEGIN
      v_is_catch_up := public.match_schedule_fixture_is_catch_up(r.id);
    EXCEPTION WHEN OTHERS THEN
      v_is_catch_up := false;
    END;

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

    -- Replay / catch-up: pressure against current month lock, not the old unlock
    v_propose_by := CASE
      WHEN v_is_replay OR v_is_catch_up THEN coalesce(v_active_lock, now() + interval '7 days')
      ELSE r.unlock_at
    END;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'fixture_id', r.id,
      'side', v_side,
      'opponent_short_name', CASE WHEN v_side = 'home'
        THEN upper(btrim(r.away_club_short_name)) ELSE upper(btrim(r.home_club_short_name)) END,
      'gpsl_month', r.gpsl_month,
      'matchday', r.matchday,
      'competition_type', r.competition_type,
      'cup_code', r.cup_code,
      'cup_round', r.cup_round,
      'propose_by', v_propose_by,
      'late_fee_from', CASE
        WHEN v_is_replay OR v_is_catch_up THEN NULL
        ELSE r.unlock_at - interval '48 hours'
      END,
      'response_due_at', r.response_due_at,
      'state', v_state,
      'is_admin_replay', v_is_replay,
      'is_catch_up', v_is_catch_up
    ));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'club_short_name', v_club, 'fixtures', v_out);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_upcoming_arrangements() TO authenticated;

COMMENT ON FUNCTION public.owner_upcoming_arrangements() IS
  'Dashboard Arrange now: upcoming unlocks + admin-replay / catch-up fixtures still needing a kick-off.';

-- ---------------------------------------------------------------------------
-- Club Wire cutoffs: add admin-replay / catch-up propose pressure
-- ---------------------------------------------------------------------------
DO $wire$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.club_wire_cutoffs()') IS NULL THEN
    RAISE WARNING 'club_wire_cutoffs missing';
    RETURN;
  END IF;

  SELECT replace(pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure), E'\r\n', E'\n')
    INTO v_def;

  IF position('admin_replay_reset_at IS NOT NULL' IN v_def) > 0
     AND position('Re-arrange replay' IN v_def) > 0 THEN
    RAISE NOTICE 'club_wire_cutoffs already includes admin replay';
    RETURN;
  END IF;

  -- Append a second loop before the agreed kick-off section
  v_old := E'  -- Agreed kick-offs: check-in window';
  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'club_wire agreed-kickoff needle missing — replay wire NOT injected';
    RETURN;
  END IF;

  v_new := replace($n$
  -- Admin replay / catch-up still needing a kick-off (past play-month unlock)
  FOR r IN
    SELECT
      f.id,
      f.gpsl_month,
      f.matchday,
      f.home_club_short_name,
      f.away_club_short_name,
      f.admin_replay_reset_at,
      s.status AS sched_status,
      s.response_required_club_short_name AS reply_club,
      s.response_due_at
    FROM public.competition_fixtures f
    LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND coalesce(s.status, 'unscheduled') <> 'agreed'
      AND (
        f.admin_replay_reset_at IS NOT NULL
        OR (
          to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
          AND public.match_schedule_fixture_is_catch_up(f.id)
        )
      )
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(f.id)
      )
    ORDER BY coalesce(f.admin_replay_reset_at, now()) DESC, f.id
    LIMIT 12
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

    IF v_state = 'reply' THEN
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', 'replay_reply:' || r.id::text,
        'kind', 'reply',
        'at', coalesce(r.response_due_at, now() + interval '12 hours'),
        'title', format('Reply (replay) vs %s', v_opp),
        'detail', format(
          'Admin/catch-up re-arrange — %s MD%s. Reply on the schedule page.',
          public.competition_gpsl_month_label(r.gpsl_month),
          coalesce(r.matchday::text, '?')
        ),
        'severity', 'urgent',
        'href', v_href,
        'fixture_id', r.id
      ));
    ELSIF v_state = 'propose' THEN
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', 'replay_propose:' || r.id::text,
        'kind', 'propose',
        'at', coalesce(v_lock_at, now() + interval '48 hours'),
        'title', format('Re-arrange replay vs %s', v_opp),
        'detail', format(
          'Fixture reset for replay — %s MD%s. Home must propose a new kick-off (current GPSL month window).',
          public.competition_gpsl_month_label(r.gpsl_month),
          coalesce(r.matchday::text, '?')
        ),
        'severity', 'urgent',
        'href', v_href,
        'fixture_id', r.id
      ));
    ELSIF v_state = 'waiting_home' THEN
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', 'replay_wait:' || r.id::text,
        'kind', 'propose',
        'at', coalesce(v_lock_at, now() + interval '48 hours'),
        'title', format('Replay waiting on home vs %s', v_opp),
        'detail', format(
          'Fixture reset for replay — %s MD%s. Waiting for home to propose.',
          public.competition_gpsl_month_label(r.gpsl_month),
          coalesce(r.matchday::text, '?')
        ),
        'severity', 'warn',
        'href', v_href,
        'fixture_id', r.id
      ));
    END IF;
  END LOOP;

  -- Agreed kick-offs: check-in window
$n$, E'\r\n', E'\n');

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'club_wire_cutoffs: admin replay / catch-up cutoffs injected';
END;
$wire$;

-- ---------------------------------------------------------------------------
-- Matchday checklist: include admin-replay (+ catch-up) scheduled fixtures
-- ---------------------------------------------------------------------------
DO $checklist$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.matchday_checklist_for_club(text,boolean)') IS NULL THEN
    RAISE WARNING 'matchday_checklist_for_club missing';
    RETURN;
  END IF;

  SELECT replace(
           pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure),
           E'\r\n',
           E'\n'
         )
    INTO v_def;

  IF position('admin_replay_reset_at IS NOT NULL' IN v_def) > 0 THEN
    RAISE NOTICE 'checklist already includes admin_replay_reset_at';
    RETURN;
  END IF;

  -- Prefer inserting beside holiday-early filter if present
  IF position('match_schedule_fixture_is_holiday_early(f.id)' IN v_def) > 0 THEN
    v_old := replace($n$
        OR (
          f.status = 'scheduled'
          AND to_regprocedure('public.match_schedule_fixture_is_holiday_early(bigint)') IS NOT NULL
          AND public.match_schedule_fixture_is_holiday_early(f.id)
        )
$n$, E'\r\n', E'\n');
    v_new := replace($n$
        OR (
          f.status = 'scheduled'
          AND to_regprocedure('public.match_schedule_fixture_is_holiday_early(bigint)') IS NOT NULL
          AND public.match_schedule_fixture_is_holiday_early(f.id)
        )
        OR (
          f.status = 'scheduled'
          AND f.admin_replay_reset_at IS NOT NULL
        )
        OR (
          f.status = 'scheduled'
          AND to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
          AND public.match_schedule_fixture_is_catch_up(f.id)
        )
$n$, E'\r\n', E'\n');
  ELSE
    v_old := replace($n$
      AND (
        (v_month IS NOT NULL AND lower(btrim(f.gpsl_month)) = lower(v_month))
        OR EXISTS (
          SELECT 1 FROM public.competition_result_submissions s
          WHERE s.fixture_id = f.id AND s.status = 'pending'
        )
$n$, E'\r\n', E'\n');
    v_new := replace($n$
      AND (
        (v_month IS NOT NULL AND lower(btrim(f.gpsl_month)) = lower(v_month))
        OR (
          f.status = 'scheduled'
          AND f.admin_replay_reset_at IS NOT NULL
        )
        OR (
          f.status = 'scheduled'
          AND to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
          AND public.match_schedule_fixture_is_catch_up(f.id)
        )
        OR EXISTS (
          SELECT 1 FROM public.competition_result_submissions s
          WHERE s.fixture_id = f.id AND s.status = 'pending'
        )
$n$, E'\r\n', E'\n');
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'checklist filter needle missing — admin replay NOT injected';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'matchday_checklist_for_club: admin replay / catch-up included';
END;
$checklist$;

NOTIFY pgrst, 'reload schema';

-- Smoke
SELECT
  position(
    'admin_replay_reset_at'
    IN pg_get_functiondef('public.owner_upcoming_arrangements()'::regprocedure)
  ) > 0 AS arrange_includes_replay,
  to_regprocedure('public.club_wire_cutoffs()') IS NOT NULL AS wire_fn;
