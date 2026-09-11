-- =============================================================================
-- Match scheduling rules 2026-09-11 — PART 2 (awards, inbox, month-lock wire)
-- Run AFTER: match_scheduling_rules_20260911.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fixture_apply_score_draw_0_0(
  p_fixture_id bigint,
  p_reason text DEFAULT 'Activity tie — recorded 0–0'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND OR v_fixture.status = 'played' THEN
    RETURN;
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by window-expiry 0–0',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_fixtures
  SET
    home_goals = 0,
    away_goals = 0,
    status = 'played',
    is_forfeit = false,
    forfeit_loser_club = NULL
  WHERE id = p_fixture_id;

  BEGIN
    IF v_fixture.competition_type = 'cup' THEN
      PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
    ELSIF v_fixture.competition_type = 'league' THEN
      PERFORM public.competition_try_pay_league_division_prizes(
        v_fixture.season_id, v_fixture.division
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  PERFORM public.owner_inbox_send(
    'match_window_draw', 'Match recorded 0–0',
    coalesce(p_reason, 'Unplayed window expired — activity tied.'),
    v_fixture.home_club_short_name, NULL, p_fixture_id,
    NULL, NULL, NULL, 'fixtures.html',
    'window_draw:' || p_fixture_id::text || ':home',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
  PERFORM public.owner_inbox_send(
    'match_window_draw', 'Match recorded 0–0',
    coalesce(p_reason, 'Unplayed window expired — activity tied.'),
    v_fixture.away_club_short_name, NULL, p_fixture_id,
    NULL, NULL, NULL, 'fixtures.html',
    'window_draw:' || p_fixture_id::text || ':away',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_club_activity_tuple(
  p_season_id bigint,
  p_club_short_name text,
  p_fixture_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_closed_sort int;
  v_prev text;
  v_prev2 text;
  v_neg_proposals int := 0;
  v_logins_prev int := 0;
  v_logins_prev2 int := 0;
  v_matches_played int := 0;
  v_forfeit_losses int := 0;
  v_other_response_fines int := 0;
  v_checkins int := 0;
  v_owner uuid;
  v_prev_unlock timestamptz;
  v_prev_lock timestamptz;
  v_prev2_unlock timestamptz;
  v_prev2_lock timestamptz;
BEGIN
  v_closed_sort := public.competition_gpsl_month_sort(p_closed_gpsl_month);
  v_prev := p_closed_gpsl_month;

  SELECT c.gpsl_month INTO v_prev2
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND public.competition_gpsl_month_sort(c.gpsl_month) = v_closed_sort - 1
  LIMIT 1;

  SELECT unlock_at, lock_at INTO v_prev_unlock, v_prev_lock
  FROM public.competition_season_calendar
  WHERE season_id = p_season_id AND gpsl_month = v_prev;

  SELECT unlock_at, lock_at INTO v_prev2_unlock, v_prev2_lock
  FROM public.competition_season_calendar
  WHERE season_id = p_season_id AND gpsl_month = v_prev2;

  SELECT owner_id INTO v_owner
  FROM public."Clubs" WHERE "ShortName" = p_club_short_name;

  SELECT count(*)::int INTO v_neg_proposals
  FROM public.competition_fixture_schedule_proposal p
  WHERE p.fixture_id = p_fixture_id
    AND p.proposed_by_club_short_name = p_club_short_name
    AND p.status <> 'withdrawn';

  IF v_owner IS NOT NULL AND v_prev_unlock IS NOT NULL THEN
    SELECT count(*)::int INTO v_logins_prev
    FROM public.owner_site_login_events e
    WHERE e.owner_id = v_owner
      AND e.logged_in_at >= v_prev_unlock
      AND e.logged_in_at < coalesce(v_prev_lock, now());
  END IF;

  IF v_owner IS NOT NULL AND v_prev2_unlock IS NOT NULL THEN
    SELECT count(*)::int INTO v_logins_prev2
    FROM public.owner_site_login_events e
    WHERE e.owner_id = v_owner
      AND e.logged_in_at >= v_prev2_unlock
      AND e.logged_in_at < coalesce(v_prev2_lock, v_prev_unlock, now());
  END IF;

  SELECT count(*)::int INTO v_matches_played
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.status = 'played'
    AND (f.home_club_short_name = p_club_short_name
      OR f.away_club_short_name = p_club_short_name)
    AND coalesce(f.forfeit_loser_club, '') IS DISTINCT FROM p_club_short_name
    AND public.competition_gpsl_month_sort(f.gpsl_month) >= v_closed_sort - 1
    AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_closed_sort;

  SELECT count(*)::int INTO v_forfeit_losses
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.status = 'played'
    AND f.forfeit_loser_club = p_club_short_name
    AND public.competition_gpsl_month_sort(f.gpsl_month) >= v_closed_sort - 1
    AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_closed_sort;

  SELECT count(*)::int INTO v_other_response_fines
  FROM public.competition_fine_applied fa
  WHERE fa.season_id = p_season_id
    AND fa.club_short_name = p_club_short_name
    AND fa.tariff_code = 'match_response_deadline'
    AND fa.fixture_id IS DISTINCT FROM p_fixture_id;

  SELECT count(*)::int INTO v_checkins
  FROM public.competition_fixture_checkin c
  JOIN public.competition_fixtures f ON f.id = c.fixture_id
  WHERE f.season_id = p_season_id
    AND c.club_short_name = p_club_short_name
    AND public.competition_gpsl_month_sort(f.gpsl_month) >= v_closed_sort - 1
    AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_closed_sort;

  RETURN jsonb_build_object(
    'neg_proposals', v_neg_proposals,
    'logins_prev', v_logins_prev,
    'logins_prev2', v_logins_prev2,
    'matches_played', v_matches_played,
    'forfeit_losses', v_forfeit_losses,
    'other_response_fines', v_other_response_fines,
    'checkins', v_checkins
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_pick_window_loser(
  p_season_id bigint,
  p_fixture_id bigint,
  p_closed_gpsl_month text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_home_h boolean;
  v_away_h boolean;
  v_home jsonb;
  v_away jsonb;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_f.home_club_short_name AND c.owner_id IS NOT NULL
  ) THEN RETURN v_f.home_club_short_name; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_f.away_club_short_name AND c.owner_id IS NOT NULL
  ) THEN RETURN v_f.away_club_short_name; END IF;

  v_home_h := public.match_schedule_club_on_holiday_for_month(
    p_season_id, v_f.home_club_short_name, v_f.gpsl_month
  );
  v_away_h := public.match_schedule_club_on_holiday_for_month(
    p_season_id, v_f.away_club_short_name, v_f.gpsl_month
  );
  IF v_home_h AND v_away_h THEN RETURN NULL; END IF;
  IF v_home_h THEN RETURN v_f.home_club_short_name; END IF;
  IF v_away_h THEN RETURN v_f.away_club_short_name; END IF;

  v_home := public.match_schedule_club_activity_tuple(
    p_season_id, v_f.home_club_short_name, p_fixture_id, p_closed_gpsl_month
  );
  v_away := public.match_schedule_club_activity_tuple(
    p_season_id, v_f.away_club_short_name, p_fixture_id, p_closed_gpsl_month
  );

  IF (v_home->>'neg_proposals')::int IS DISTINCT FROM (v_away->>'neg_proposals')::int THEN
    RETURN CASE WHEN (v_home->>'neg_proposals')::int < (v_away->>'neg_proposals')::int
      THEN v_f.home_club_short_name ELSE v_f.away_club_short_name END;
  END IF;
  IF (v_home->>'logins_prev')::int IS DISTINCT FROM (v_away->>'logins_prev')::int THEN
    RETURN CASE WHEN (v_home->>'logins_prev')::int < (v_away->>'logins_prev')::int
      THEN v_f.home_club_short_name ELSE v_f.away_club_short_name END;
  END IF;
  IF (v_home->>'logins_prev2')::int IS DISTINCT FROM (v_away->>'logins_prev2')::int THEN
    RETURN CASE WHEN (v_home->>'logins_prev2')::int < (v_away->>'logins_prev2')::int
      THEN v_f.home_club_short_name ELSE v_f.away_club_short_name END;
  END IF;
  IF (v_home->>'matches_played')::int IS DISTINCT FROM (v_away->>'matches_played')::int THEN
    RETURN CASE WHEN (v_home->>'matches_played')::int < (v_away->>'matches_played')::int
      THEN v_f.home_club_short_name ELSE v_f.away_club_short_name END;
  END IF;
  IF (v_home->>'forfeit_losses')::int IS DISTINCT FROM (v_away->>'forfeit_losses')::int THEN
    RETURN CASE WHEN (v_home->>'forfeit_losses')::int > (v_away->>'forfeit_losses')::int
      THEN v_f.home_club_short_name ELSE v_f.away_club_short_name END;
  END IF;
  IF (v_home->>'other_response_fines')::int IS DISTINCT FROM (v_away->>'other_response_fines')::int THEN
    RETURN CASE WHEN (v_home->>'other_response_fines')::int > (v_away->>'other_response_fines')::int
      THEN v_f.home_club_short_name ELSE v_f.away_club_short_name END;
  END IF;
  IF (v_home->>'checkins')::int IS DISTINCT FROM (v_away->>'checkins')::int THEN
    RETURN CASE WHEN (v_home->>'checkins')::int < (v_away->>'checkins')::int
      THEN v_f.home_club_short_name ELSE v_f.away_club_short_name END;
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_enforce_scheduling_window_awards(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_lock timestamptz;
  v_f record;
  v_loser text;
  v_awarded jsonb := '[]'::jsonb;
  v_count int := 0;
BEGIN
  SELECT c.lock_at INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id AND c.gpsl_month = p_closed_gpsl_month;

  IF v_lock IS NULL OR v_lock > now() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'month_not_closed');
  END IF;

  FOR v_f IN
    SELECT f.id, f.gpsl_month, f.matchday, f.competition_type
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND public.match_schedule_fixture_play_window_expired(f.id, p_closed_gpsl_month)
  LOOP
    v_loser := public.match_schedule_pick_window_loser(
      p_season_id, v_f.id, p_closed_gpsl_month
    );

    IF v_loser IS NULL THEN
      PERFORM public.fixture_apply_score_draw_0_0(
        v_f.id,
        format(
          'Unplayed after play window · %s MD%s · activity tied → 0–0',
          public.competition_gpsl_month_label(v_f.gpsl_month),
          v_f.matchday
        )
      );
    ELSE
      PERFORM public.fixture_apply_forfeit(
        v_f.id,
        v_loser,
        'match_window_expiry',
        format(
          'Unplayed after play window · %s MD%s · awarded on activity',
          public.competition_gpsl_month_label(v_f.gpsl_month),
          v_f.matchday
        )
      );
    END IF;

    v_count := v_count + 1;
    v_awarded := v_awarded || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_f.id,
        'loser', v_loser,
        'result', CASE WHEN v_loser IS NULL THEN '0-0' ELSE '3-0 forfeit' END
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'awarded', v_count,
    'details', v_awarded
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_process_scheduling_window_awards(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cal record;
  v_job_key text;
  v_res jsonb;
  v_results jsonb := '[]'::jsonb;
BEGIN
  FOR v_cal IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'scheduling_window_awards:' || v_cal.gpsl_month;
    IF EXISTS (
      SELECT 1 FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id AND j.job_key = v_job_key
    ) THEN
      CONTINUE;
    END IF;

    v_res := public.competition_enforce_scheduling_window_awards(
      p_season_id, v_cal.gpsl_month
    );

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    ) VALUES (
      p_season_id, v_job_key, v_cal.gpsl_month, coalesce(v_res, '{}'::jsonb)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result, ran_at = now();

    v_results := v_results || jsonb_build_array(
      jsonb_build_object('gpsl_month', v_cal.gpsl_month, 'result', v_res)
    );
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'processed', v_results);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_notify_scheduling_deadline_warnings(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_sent int := 0;
  v_hours numeric;
  v_prior text;
BEGIN
  FOR v_row IN
    SELECT
      s.fixture_id,
      s.response_required_club_short_name AS club,
      s.response_due_at,
      f.gpsl_month,
      f.matchday
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = p_season_id
      AND f.status = 'scheduled'
      AND s.status = 'negotiating'
      AND s.response_due_at IS NOT NULL
      AND s.response_required_club_short_name IS NOT NULL
      AND s.response_due_at > now()
      AND s.response_due_at <= now() + interval '12 hours'
  LOOP
    v_hours := extract(epoch FROM (v_row.response_due_at - now())) / 3600.0;
    IF public.owner_inbox_send(
      'match_response_deadline_warning',
      'Reply deadline soon',
      format(
        'Reply to the pending match time for MD%s (%s) within about %s hours or face a ₿2.5m missed-response fine at month lock. Negotiation continues if you miss — fines can repeat each lock until you reply.',
        v_row.matchday,
        public.competition_gpsl_month_label(v_row.gpsl_month),
        greatest(1, ceil(v_hours))::int
      ),
      v_row.club, NULL, v_row.fixture_id,
      NULL, NULL, NULL,
      'fixture_schedule.html?fixture=' || v_row.fixture_id::text,
      'sched_due_warn:' || v_row.fixture_id::text || ':' || to_char(v_row.response_due_at, 'YYYYMMDDHH24'),
      v_row.gpsl_month, p_season_id, NULL
    ) IS NOT NULL THEN
      v_sent := v_sent + 1;
    END IF;
  END LOOP;

  FOR v_row IN
    SELECT
      f.id AS fixture_id,
      f.home_club_short_name AS club,
      f.gpsl_month,
      f.matchday,
      cal.unlock_at
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id AND cal.gpsl_month = f.gpsl_month
    WHERE f.season_id = p_season_id
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND cal.unlock_at > now()
      AND cal.unlock_at <= now() + interval '48 hours'
      AND NOT public.match_schedule_home_has_proposed(f.id, cal.unlock_at)
      AND EXISTS (
        SELECT 1 FROM public."Clubs" c
        WHERE c."ShortName" = f.home_club_short_name AND c.owner_id IS NOT NULL
      )
  LOOP
    SELECT c.gpsl_month INTO v_prior
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND public.competition_gpsl_month_sort(c.gpsl_month)
        = public.competition_gpsl_month_sort(v_row.gpsl_month) - 1
    LIMIT 1;

    IF v_prior IS NOT NULL
       AND public.match_schedule_club_on_holiday_for_month(p_season_id, v_row.club, v_prior)
    THEN
      CONTINUE;
    END IF;

    IF public.owner_inbox_send(
      'match_arrangement_deadline_warning',
      'Propose match time soon',
      format(
        'As home for MD%s (%s), propose a kick-off before the play month opens. Last 48h = ₿2.5m late fee; no proposal by lock = ₿5m (repeats each lock until you propose).',
        v_row.matchday,
        public.competition_gpsl_month_label(v_row.gpsl_month)
      ),
      v_row.club, NULL, v_row.fixture_id,
      NULL, NULL, NULL,
      'fixture_schedule.html?fixture=' || v_row.fixture_id::text,
      'sched_arr_warn:' || v_row.fixture_id::text || ':' || to_char(v_row.unlock_at, 'YYYYMMDD'),
      v_row.gpsl_month, p_season_id, NULL
    ) IS NOT NULL THEN
      v_sent := v_sent + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'sent', v_sent);
END;
$function$;

DO $wire$
DECLARE
  v_def text;
  v_marker text := 'competition_process_scheduling_window_awards';
  v_old text := E'  RETURN v_out;\nEND;';
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') IS NULL THEN
    RAISE NOTICE 'month-lock jobs missing — window awards wire skipped';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) INTO v_def;

  IF v_def IS NULL OR position(v_marker IN v_def) > 0 THEN
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'Could not locate RETURN v_out — window awards wire skipped';
    RETURN;
  END IF;

  v_new :=
    E'  BEGIN\n'
    || E'    IF to_regprocedure(''public.competition_process_scheduling_window_awards(bigint)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''scheduling_window_awards'',\n'
    || E'        public.competition_process_scheduling_window_awards(p_season_id)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION WHEN OTHERS THEN\n'
    || E'    v_out := v_out || jsonb_build_object(\n'
    || E'      ''scheduling_window_awards'', jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'    );\n'
    || E'  END;\n\n'
    || E'  BEGIN\n'
    || E'    IF to_regprocedure(''public.competition_notify_scheduling_deadline_warnings(bigint)'') IS NOT NULL THEN\n'
    || E'      PERFORM public.competition_notify_scheduling_deadline_warnings(p_season_id);\n'
    || E'    END IF;\n'
    || E'  EXCEPTION WHEN OTHERS THEN NULL;\n'
    || E'  END;\n\n'
    || E'  RETURN v_out;\nEND;';

  EXECUTE 'CREATE OR REPLACE ' || replace(v_def, v_old, v_new);
  RAISE NOTICE 'Wired window awards + deadline warnings into month-lock jobs';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Window awards wire failed: %', SQLERRM;
END;
$wire$;

DO $$
DECLARE
  v_row record;
  v_new_due timestamptz;
BEGIN
  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_due_at AS old_due,
      p.created_at AS proposed_at,
      p.proposed_by_club_short_name AS proposer
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    JOIN public.competition_fixture_schedule_proposal p ON p.id = s.pending_proposal_id
    WHERE s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND p.status = 'pending'
      AND f.status = 'scheduled'
      AND f.competition_type IN ('league', 'cup')
  LOOP
    v_new_due := public.match_schedule_compute_response_due_at(
      v_row.fixture_id, v_row.pending_proposal_id, v_row.proposed_at, v_row.proposer
    );
    IF v_new_due IS DISTINCT FROM v_row.old_due THEN
      UPDATE public.competition_fixture_schedule
      SET response_due_at = v_new_due, updated_at = now()
      WHERE fixture_id = v_row.fixture_id;
    END IF;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.competition_process_scheduling_window_awards(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_process_scheduling_window_awards(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_notify_scheduling_deadline_warnings(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_notify_scheduling_deadline_warnings(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.fixture_apply_score_draw_0_0(bigint, text) TO service_role;

NOTIFY pgrst, 'reload schema';
