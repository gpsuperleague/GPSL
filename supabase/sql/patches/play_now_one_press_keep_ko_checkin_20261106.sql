-- =============================================================================
-- Play Now one-press expire: keep overlapping KO check-ins (2026-11-06)
--
-- Bug: fixture_try_checkin_forfeit calls play_now_session_tick first. One-press
-- expiry deleted ALL check-ins, then KO forfeit saw both missing → both_miss
-- even when a club had checked in for the agreed KO (BES 9426 @ 19:20).
--
-- Fix: on one-press expire, only wipe check-ins when the Play Now window did
-- not overlap the agreed-KO check-in window.
-- Also corrects fixture 9426: reverse BES both_miss strike; FLA stays no-show.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_play_now_session_tick(p_fixture_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
  v_agreed_ko timestamptz;
  v_ko_open timestamptz;
  v_ko_close timestamptz;
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

  -- Only one side pressed → expire quietly (no Play Now fine).
  -- If the session overlapped the agreed-KO check-in window, keep check-in
  -- rows so fixture_try_checkin_forfeit can see who showed for KO. Wiping
  -- them first caused both_miss after a valid KO check-in (9426 BES/FLA).
  IF v_sess.home_pressed_at IS NULL OR v_sess.away_pressed_at IS NULL THEN
    v_agreed_ko := public.match_schedule_agreed_kickoff(p_fixture_id);
    IF v_agreed_ko IS NOT NULL THEN
      v_ko_open := public.match_schedule_checkin_opens_at(v_agreed_ko);
      v_ko_close := v_agreed_ko
        + (public.match_schedule_checkin_minutes() || ' minutes')::interval;
    END IF;

    IF v_agreed_ko IS NULL
       OR v_ko_open IS NULL
       OR NOT (
         v_sess.window_started_at < v_ko_close
         AND v_sess.window_ends_at > v_ko_open
       )
    THEN
      DELETE FROM public.competition_fixture_checkin WHERE fixture_id = p_fixture_id;
    END IF;

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
$function$



-- ---------------------------------------------------------------------------
-- Correct BES vs FLA fixture 9426 (2026-11-05 19:30 UK)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bes_owner uuid;
  v_season bigint;
BEGIN
  SELECT owner_id INTO v_bes_owner FROM public."Clubs" WHERE "ShortName" = 'BES';
  SELECT season_id INTO v_season FROM public.competition_fixtures WHERE id = 9426;

  -- Drop erroneous BES both_miss event (BES Discord check-in 19:20:48)
  DELETE FROM public.competition_fixture_no_show_events
  WHERE fixture_id = 9426
    AND club_short_name = 'BES'
    AND both_miss = true
    AND kickoff_at = '2026-11-05 19:30:00+00'::timestamptz;

  -- FLA really missed; keep event but clear both_miss flag
  UPDATE public.competition_fixture_no_show_events
  SET both_miss = false
  WHERE fixture_id = 9426
    AND club_short_name = 'FLA'
    AND kickoff_at = '2026-11-05 19:30:00+00'::timestamptz
    AND both_miss = true;

  IF v_bes_owner IS NOT NULL AND v_season IS NOT NULL THEN
    UPDATE public.competition_owner_season_strikes
    SET strike_count = greatest(strike_count - 1, 0),
        updated_at = now()
    WHERE season_id = v_season
      AND owner_id = v_bes_owner
      AND strike_count > 0;
  END IF;

  UPDATE public.competition_fixture_schedule
  SET admin_result_unlock_note = 'onesided_checkin_auto: BES may submit or either may reschedule; FLA missed check-in (corrected 2026-11-06: Play Now one-press expire had wiped BES KO check-in before both_miss)',
      updated_at = now()
  WHERE fixture_id = 9426
    AND coalesce(admin_result_unlock_note, '') ILIKE '%both_miss%';
END $$;
