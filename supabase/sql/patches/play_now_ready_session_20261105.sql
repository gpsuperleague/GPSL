-- =============================================================================
-- Play Now ready-session (20 min) + rename old flow to "Bring KO forward"
-- (2026-11-05)
--
-- New Play Now:
--   • First press starts shared 20-min window + countdown
--   • Each owner checks in only after THEY pressed, while window open
--   • After BOTH pressed → suspend original KO check-in/forfeit until
--     result confirmed, Play Now reset, or admin clear
--   • One press only → expire, no fine, KO unchanged, clear session check-ins
--   • Both ready + window end incomplete → fine ladder + dual enter/reset
--
-- Old mutual-override kind 'play_now' stays (Bring KO forward in UI).
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.competition_fixture_play_now_session (
  fixture_id bigint PRIMARY KEY
    REFERENCES public.competition_fixtures (id) ON DELETE CASCADE,
  window_started_at timestamptz NOT NULL,
  window_ends_at timestamptz NOT NULL,
  home_pressed_at timestamptz,
  away_pressed_at timestamptz,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN (
      'open', 'both_ready', 'miss_open', 'expired',
      'resolved_reset', 'resolved_played', 'admin_cleared'
    )),
  ko_forfeit_suspended boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS competition_fixture_play_now_session_status_idx
  ON public.competition_fixture_play_now_session (status);

COMMENT ON TABLE public.competition_fixture_play_now_session IS
  'Bilateral Play Now ready session: 20-min check-in window from first press; suspends agreed-KO forfeit after both ready.';

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_play_now_window_minutes()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 20 $$;

CREATE OR REPLACE FUNCTION public.match_schedule_play_now_session_active(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_fixture_play_now_session s
    WHERE s.fixture_id = p_fixture_id
      AND s.status IN ('open', 'both_ready', 'miss_open')
  );
$$;

CREATE OR REPLACE FUNCTION public.match_schedule_play_now_ko_suspended(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_fixture_play_now_session s
    WHERE s.fixture_id = p_fixture_id
      AND s.ko_forfeit_suspended
      AND s.status IN ('open', 'both_ready', 'miss_open')
  );
$$;

-- Tick: expire one-press sessions; open miss path when both ready & window ended
CREATE OR REPLACE FUNCTION public.match_schedule_play_now_session_tick(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_sess public.competition_fixture_play_now_session;
  v_home_in boolean;
  v_away_in boolean;
  v_attempt integer := 1;
  v_home_res jsonb;
  v_away_res jsonb;
  v_one_res jsonb;
  v_loser text;
  v_winner text;
  v_new_event boolean := false;
  v_event_ko timestamptz;
BEGIN
  SELECT * INTO v_sess
  FROM public.competition_fixture_play_now_session
  WHERE fixture_id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_sess.status NOT IN ('open', 'both_ready') THEN
    RETURN;
  END IF;

  IF now() < v_sess.window_ends_at THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RETURN;
  END IF;

  -- Only one side pressed → expire quietly
  IF v_sess.home_pressed_at IS NULL OR v_sess.away_pressed_at IS NULL THEN
    DELETE FROM public.competition_fixture_checkin WHERE fixture_id = p_fixture_id;
    UPDATE public.competition_fixture_play_now_session
    SET status = 'expired',
        ko_forfeit_suspended = false,
        updated_at = now()
    WHERE fixture_id = p_fixture_id;
    RETURN;
  END IF;

  -- Both pressed; window ended
  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;
  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in THEN
    -- Both checked in — leave both_ready; submit uses normal both-in path
    UPDATE public.competition_fixture_play_now_session
    SET updated_at = now()
    WHERE fixture_id = p_fixture_id;
    RETURN;
  END IF;

  SELECT coalesce(s.play_attempt_count, 1) INTO v_attempt
  FROM public.competition_fixture_schedule s WHERE s.fixture_id = p_fixture_id;
  IF v_attempt < 1 THEN v_attempt := 1; END IF;

  -- Distinct event key from agreed KO so Play Now miss doesn't collide
  v_event_ko := v_sess.window_started_at;

  IF NOT v_home_in AND NOT v_away_in THEN
    v_home_res := public.match_schedule_apply_club_noshow(
      p_fixture_id, v_fixture.home_club_short_name, v_event_ko, v_attempt, true
    );
    v_away_res := public.match_schedule_apply_club_noshow(
      p_fixture_id, v_fixture.away_club_short_name, v_event_ko, v_attempt, true
    );
    v_new_event := NOT (
      coalesce((v_home_res->>'deduped')::boolean, false)
      AND coalesce((v_away_res->>'deduped')::boolean, false)
    );
  ELSIF v_home_in AND NOT v_away_in THEN
    v_loser := v_fixture.away_club_short_name;
    v_winner := v_fixture.home_club_short_name;
    v_one_res := public.match_schedule_apply_club_noshow(
      p_fixture_id, v_loser, v_event_ko, v_attempt, false
    );
    v_new_event := coalesce((v_one_res->>'ok')::boolean, false)
      AND NOT coalesce((v_one_res->>'deduped')::boolean, false)
      AND NOT coalesce((v_one_res->>'skipped')::boolean, false);
  ELSE
    v_loser := v_fixture.home_club_short_name;
    v_winner := v_fixture.away_club_short_name;
    v_one_res := public.match_schedule_apply_club_noshow(
      p_fixture_id, v_loser, v_event_ko, v_attempt, false
    );
    v_new_event := coalesce((v_one_res->>'ok')::boolean, false)
      AND NOT coalesce((v_one_res->>'deduped')::boolean, false)
      AND NOT coalesce((v_one_res->>'skipped')::boolean, false);
  END IF;

  IF v_new_event
     AND EXISTS (
       SELECT 1 FROM public.competition_fixtures f
       WHERE f.id = p_fixture_id AND f.status = 'scheduled'
     )
  THEN
    PERFORM public.match_schedule_bump_attempt_on_noshow(p_fixture_id);
  END IF;

  UPDATE public.competition_fixture_play_now_session
  SET status = 'miss_open',
      ko_forfeit_suspended = true,
      updated_at = now()
  WHERE fixture_id = p_fixture_id;

  UPDATE public.competition_fixture_schedule s
  SET admin_result_unlock_at = coalesce(s.admin_result_unlock_at, now()),
      admin_result_unlock_note = coalesce(
        s.admin_result_unlock_note,
        'play_now_miss: enter result or reset; fines/strikes kept; agreed KO suspended'
      ),
      updated_at = now()
  WHERE s.fixture_id = p_fixture_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Press Play Now
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fixture_play_now_press(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '30s'
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_sess public.competition_fixture_play_now_session;
  v_is_home boolean;
  v_mins integer := public.match_schedule_play_now_window_minutes();
  v_both boolean := false;
  v_opp text;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF to_regprocedure('public.club_assert_has_manager_for_matches(text)') IS NOT NULL THEN
    PERFORM public.club_assert_has_manager_for_matches(v_club);
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for Play now';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RAISE EXCEPTION 'Manual arrange fixture — Play now is not used';
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'Agree a kick-off before using Play now';
  END IF;

  IF v_kickoff <= now() THEN
    RAISE EXCEPTION 'Play now is only available before the agreed kick-off';
  END IF;

  -- Pending mutual "Bring KO forward" / new-time blocks a parallel session
  IF EXISTS (
    SELECT 1 FROM public.competition_fixture_mutual_override o
    WHERE o.fixture_id = p_fixture_id AND o.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'Resolve the pending kick-off change request first';
  END IF;

  PERFORM public.match_schedule_play_now_session_tick(p_fixture_id);

  SELECT * INTO v_sess
  FROM public.competition_fixture_play_now_session
  WHERE fixture_id = p_fixture_id
  FOR UPDATE;

  IF FOUND AND v_sess.status IN ('miss_open') THEN
    RAISE EXCEPTION 'Play now window already closed — enter a result or reset the session';
  END IF;

  IF FOUND AND v_sess.status IN ('expired', 'resolved_reset', 'resolved_played', 'admin_cleared') THEN
    DELETE FROM public.competition_fixture_play_now_session WHERE fixture_id = p_fixture_id;
  END IF;

  v_is_home := (v_club = v_fixture.home_club_short_name);

  IF NOT EXISTS (
       SELECT 1 FROM public.competition_fixture_play_now_session s
       WHERE s.fixture_id = p_fixture_id
         AND s.status IN ('open', 'both_ready')
     ) THEN
    INSERT INTO public.competition_fixture_play_now_session (
      fixture_id, window_started_at, window_ends_at,
      home_pressed_at, away_pressed_at, status, ko_forfeit_suspended
    ) VALUES (
      p_fixture_id, now(), now() + (v_mins || ' minutes')::interval,
      CASE WHEN v_is_home THEN now() ELSE NULL END,
      CASE WHEN NOT v_is_home THEN now() ELSE NULL END,
      'open', false
    )
    RETURNING * INTO v_sess;
  ELSE
    IF now() >= v_sess.window_ends_at THEN
      PERFORM public.match_schedule_play_now_session_tick(p_fixture_id);
      RAISE EXCEPTION 'Play now window has closed';
    END IF;

    IF v_is_home AND v_sess.home_pressed_at IS NOT NULL THEN
      RETURN jsonb_build_object('ok', true, 'already_pressed', true, 'session', row_to_json(v_sess));
    END IF;
    IF NOT v_is_home AND v_sess.away_pressed_at IS NOT NULL THEN
      RETURN jsonb_build_object('ok', true, 'already_pressed', true, 'session', row_to_json(v_sess));
    END IF;

    UPDATE public.competition_fixture_play_now_session
    SET home_pressed_at = CASE WHEN v_is_home THEN coalesce(home_pressed_at, now()) ELSE home_pressed_at END,
        away_pressed_at = CASE WHEN NOT v_is_home THEN coalesce(away_pressed_at, now()) ELSE away_pressed_at END,
        updated_at = now()
    WHERE fixture_id = p_fixture_id
    RETURNING * INTO v_sess;
  END IF;

  v_both := v_sess.home_pressed_at IS NOT NULL AND v_sess.away_pressed_at IS NOT NULL;
  IF v_both THEN
    UPDATE public.competition_fixture_play_now_session
    SET status = 'both_ready',
        ko_forfeit_suspended = true,
        updated_at = now()
    WHERE fixture_id = p_fixture_id
    RETURNING * INTO v_sess;
  END IF;

  v_opp := CASE WHEN v_is_home THEN v_fixture.away_club_short_name ELSE v_fixture.home_club_short_name END;

  BEGIN
    PERFORM public.match_schedule_notify_opponent(
      v_fixture,
      'match_play_now_pressed',
      CASE WHEN v_both THEN 'Play now — both ready' ELSE 'Play now — opponent ready' END,
      public.club_display_name(v_club)
        || CASE
          WHEN v_both THEN
            ' also pressed Play now. Check in before '
            || to_char(v_sess.window_ends_at AT TIME ZONE 'Europe/London', 'HH24:MI')
            || ' UK.'
          ELSE
            ' pressed Play now. Press Play now and check in before '
            || to_char(v_sess.window_ends_at AT TIME ZONE 'Europe/London', 'HH24:MI')
            || ' UK (20 min from first press).'
        END,
      v_opp,
      'playnow:' || p_fixture_id::text || ':' || v_club
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'both_ready', v_both,
    'window_ends_at', v_sess.window_ends_at,
    'ko_forfeit_suspended', v_sess.ko_forfeit_suspended,
    'status', v_sess.status
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fixture_play_now_press(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fixture_play_now_press(bigint) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Reset Play Now (as if never pressed) — fines already applied stay
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fixture_play_now_reset(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_sess public.competition_fixture_play_now_session;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture not open';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_result_submissions rs
    WHERE rs.fixture_id = p_fixture_id AND rs.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A result is pending confirmation — confirm or reject it before resetting Play now';
  END IF;

  SELECT * INTO v_sess
  FROM public.competition_fixture_play_now_session
  WHERE fixture_id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND OR v_sess.status NOT IN ('open', 'both_ready', 'miss_open') THEN
    RAISE EXCEPTION 'No active Play now session to reset';
  END IF;

  DELETE FROM public.competition_fixture_checkin WHERE fixture_id = p_fixture_id;

  UPDATE public.competition_fixture_play_now_session
  SET status = 'resolved_reset',
      ko_forfeit_suspended = false,
      updated_at = now()
  WHERE fixture_id = p_fixture_id;

  RETURN jsonb_build_object(
    'ok', true,
    'message', 'Play now cleared — original agreed kick-off still stands'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fixture_play_now_reset(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fixture_play_now_reset(bigint) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_fixture_play_now_clear(
  p_fixture_id bigint,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  DELETE FROM public.competition_fixture_checkin WHERE fixture_id = p_fixture_id;

  INSERT INTO public.competition_fixture_play_now_session AS s (
    fixture_id, window_started_at, window_ends_at, status, ko_forfeit_suspended
  ) VALUES (
    p_fixture_id, now(), now(), 'admin_cleared', false
  )
  ON CONFLICT (fixture_id) DO UPDATE
  SET status = 'admin_cleared',
      ko_forfeit_suspended = false,
      updated_at = now();

  UPDATE public.competition_fixture_schedule
  SET admin_result_unlock_note = coalesce(
        nullif(btrim(p_note), ''),
        'admin cleared Play now session'
      ),
      updated_at = now()
  WHERE fixture_id = p_fixture_id;

  RETURN jsonb_build_object('ok', true, 'fixture_id', p_fixture_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_fixture_play_now_clear(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_fixture_play_now_clear(bigint, text) TO authenticated, service_role;

-- Mark session played when fixture becomes played (soft — also via confirm path)
CREATE OR REPLACE FUNCTION public.match_schedule_play_now_mark_played(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public.competition_fixture_play_now_session
  SET status = 'resolved_played',
      ko_forfeit_suspended = false,
      updated_at = now()
  WHERE fixture_id = p_fixture_id
    AND status IN ('open', 'both_ready', 'miss_open');
END;
$function$;

-- ---------------------------------------------------------------------------
-- Session JSON for UI (+ tick)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_play_now_session_json(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_sess public.competition_fixture_play_now_session;
  v_kickoff timestamptz;
  v_home_in boolean := false;
  v_away_in boolean := false;
  v_my_pressed boolean := false;
  v_can_press boolean := false;
  v_can_check_in boolean := false;
  v_can_reset boolean := false;
  v_can_enter boolean := false;
  v_miss_mode text := NULL;
  v_has_mgr boolean := true;
  v_pending_result boolean := false;
  v_secs integer := 0;
BEGIN
  PERFORM public.match_schedule_play_now_session_tick(p_fixture_id);

  BEGIN
    v_club := public.my_club_shortname();
  EXCEPTION WHEN OTHERS THEN
    v_club := NULL;
  END;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);

  SELECT * INTO v_sess
  FROM public.competition_fixture_play_now_session
  WHERE fixture_id = p_fixture_id;

  IF NOT FOUND OR v_sess.status IN ('expired', 'resolved_reset', 'resolved_played', 'admin_cleared') THEN
    v_can_press :=
      v_fixture.status = 'scheduled'
      AND v_kickoff IS NOT NULL
      AND v_kickoff > now()
      AND v_club IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name)
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_fixture_mutual_override o
        WHERE o.fixture_id = p_fixture_id AND o.status = 'pending'
      );
    RETURN jsonb_build_object(
      'active', false,
      'can_press', v_can_press,
      'window_minutes', public.match_schedule_play_now_window_minutes()
    );
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;
  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  v_pending_result := EXISTS (
    SELECT 1 FROM public.competition_result_submissions rs
    WHERE rs.fixture_id = p_fixture_id AND rs.status = 'pending'
  );

  IF to_regprocedure('public.club_has_signed_manager(text)') IS NOT NULL AND v_club IS NOT NULL THEN
    v_has_mgr := coalesce(public.club_has_signed_manager(v_club), false);
  END IF;

  IF v_club = v_fixture.home_club_short_name THEN
    v_my_pressed := v_sess.home_pressed_at IS NOT NULL;
  ELSIF v_club = v_fixture.away_club_short_name THEN
    v_my_pressed := v_sess.away_pressed_at IS NOT NULL;
  END IF;

  v_secs := greatest(0, floor(extract(epoch FROM (v_sess.window_ends_at - now())))::int);

  v_can_press :=
    v_sess.status IN ('open', 'both_ready')
    AND now() < v_sess.window_ends_at
    AND NOT v_my_pressed
    AND v_club IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name);

  v_can_check_in :=
    v_sess.status IN ('open', 'both_ready')
    AND now() < v_sess.window_ends_at
    AND v_my_pressed
    AND v_has_mgr
    AND NOT (
      (v_club = v_fixture.home_club_short_name AND v_home_in)
      OR (v_club = v_fixture.away_club_short_name AND v_away_in)
    );

  v_can_reset :=
    v_sess.status IN ('open', 'both_ready', 'miss_open')
    AND NOT v_pending_result
    AND v_club IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name);

  IF v_sess.status = 'miss_open' AND NOT v_pending_result THEN
    IF v_home_in AND NOT v_away_in THEN
      IF v_club = v_fixture.home_club_short_name THEN v_miss_mode := 'onesided_checked';
      ELSIF v_club = v_fixture.away_club_short_name THEN v_miss_mode := 'onesided_missed'; END IF;
    ELSIF v_away_in AND NOT v_home_in THEN
      IF v_club = v_fixture.away_club_short_name THEN v_miss_mode := 'onesided_checked';
      ELSIF v_club = v_fixture.home_club_short_name THEN v_miss_mode := 'onesided_missed'; END IF;
    ELSIF NOT v_home_in AND NOT v_away_in THEN
      v_miss_mode := 'both_miss';
    END IF;
  END IF;

  v_can_enter :=
    NOT v_pending_result
    AND v_has_mgr
    AND (
      (v_home_in AND v_away_in AND v_sess.status IN ('both_ready', 'miss_open'))
      OR v_miss_mode IN ('onesided_checked', 'both_miss')
    );

  RETURN jsonb_build_object(
    'active', true,
    'status', v_sess.status,
    'window_started_at', v_sess.window_started_at,
    'window_ends_at', v_sess.window_ends_at,
    'seconds_remaining', v_secs,
    'home_pressed', v_sess.home_pressed_at IS NOT NULL,
    'away_pressed', v_sess.away_pressed_at IS NOT NULL,
    'my_pressed', v_my_pressed,
    'ko_forfeit_suspended', v_sess.ko_forfeit_suspended,
    'can_press', v_can_press,
    'can_check_in', v_can_check_in,
    'can_reset', v_can_reset,
    'can_enter_result', v_can_enter,
    'miss_choice_mode', v_miss_mode,
    'result_pending', v_pending_result,
    'window_minutes', public.match_schedule_play_now_window_minutes(),
    'home_checked_in', v_home_in,
    'away_checked_in', v_away_in
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_play_now_session_json(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_play_now_session_json(bigint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- fixture_check_in: allow Play Now window
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
  v_ready jsonb;
  v_issue text;
  v_pn jsonb;
  v_play_now_ok boolean := false;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF to_regprocedure('public.gpsl_owner_ready_lock_reason(text)') IS NOT NULL THEN
    v_issue := public.gpsl_owner_ready_lock_reason(v_club);
    IF v_issue IS NOT NULL AND btrim(v_issue) <> '' THEN
      RAISE EXCEPTION '%', v_issue;
    END IF;
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

  IF to_regprocedure('public.club_matchday_checkin_ready(bigint)') IS NOT NULL THEN
    v_ready := public.club_matchday_checkin_ready(p_fixture_id);
    IF coalesce((v_ready->>'ok')::boolean, false) = false THEN
      SELECT value::text
      INTO v_issue
      FROM jsonb_array_elements_text(coalesce(v_ready->'issues', '[]'::jsonb))
      LIMIT 1;
      RAISE EXCEPTION '%', coalesce(v_issue, 'Saved matchday squad is not ready for this fixture.');
    END IF;
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'Kick-off time is not agreed yet';
  END IF;

  -- Play Now ready-session check-in
  IF to_regprocedure('public.match_schedule_play_now_session_json(bigint)') IS NOT NULL THEN
    v_pn := public.match_schedule_play_now_session_json(p_fixture_id);
    IF coalesce((v_pn->>'active')::boolean, false)
       AND coalesce((v_pn->>'can_check_in')::boolean, false) THEN
      v_play_now_ok := true;
    ELSIF coalesce((v_pn->>'active')::boolean, false)
          AND coalesce((v_pn->>'my_pressed')::boolean, false) = false
          AND coalesce(v_pn->>'status', '') IN ('open', 'both_ready')
          AND now() < (v_pn->>'window_ends_at')::timestamptz THEN
      RAISE EXCEPTION 'Press Play now before you can check in during this session';
    ELSIF coalesce((v_pn->>'active')::boolean, false)
          AND coalesce(v_pn->>'status', '') IN ('open', 'both_ready')
          AND now() >= (v_pn->>'window_ends_at')::timestamptz THEN
      RAISE EXCEPTION 'Play now check-in window has closed';
    END IF;
  END IF;

  IF NOT v_play_now_ok THEN
    v_window_open := public.match_schedule_checkin_opens_at(v_kickoff);
    v_window_end := v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;

    IF now() < v_window_open THEN
      IF to_regprocedure('public.match_schedule_format_kickoff_uk(timestamptz)') IS NOT NULL THEN
        RAISE EXCEPTION 'Check-in opens at %', public.match_schedule_format_kickoff_uk(v_window_open);
      END IF;
      RAISE EXCEPTION 'Check-in is not open yet';
    END IF;

    IF now() >= v_window_end THEN
      IF to_regprocedure('public.fixture_try_checkin_forfeit(bigint)') IS NOT NULL THEN
        PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
      END IF;
      RAISE EXCEPTION 'Check-in window has closed';
    END IF;
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

  RETURN jsonb_build_object(
    'ok', true,
    'checked_in_at', now(),
    'play_now', v_play_now_ok
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_check_in(bigint) TO authenticated, service_role;
