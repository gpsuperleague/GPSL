-- Part 2: forfeit suspend, assert_ready, context inject, played trigger
-- Apply after play_now_ready_session_20261105.sql

CREATE OR REPLACE FUNCTION public.fixture_try_checkin_forfeit(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_window_end timestamptz;
  v_home_in boolean;
  v_away_in boolean;
  v_loser text;
  v_winner text;
  v_attempt integer := 1;
  v_manual boolean := false;
  v_home_res jsonb;
  v_away_res jsonb;
  v_one_res jsonb;
  v_new_event boolean := false;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RETURN false;
  END IF;

  PERFORM public.match_schedule_clear_no_show_if_played(p_fixture_id);

  IF to_regprocedure('public.match_schedule_play_now_session_tick(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_play_now_session_tick(p_fixture_id);
  END IF;

  IF to_regprocedure('public.match_schedule_play_now_ko_suspended(bigint)') IS NOT NULL
     AND public.match_schedule_play_now_ko_suspended(p_fixture_id) THEN
    RETURN false;
  END IF;

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL THEN
    v_manual := public.fixture_is_manual_black_box(p_fixture_id);
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  v_window_end := v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;
  IF now() < v_window_end THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;
  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  IF v_manual THEN
    RETURN false;
  END IF;

  SELECT coalesce(s.play_attempt_count, 1) INTO v_attempt
  FROM public.competition_fixture_schedule s WHERE s.fixture_id = p_fixture_id;
  IF v_attempt < 1 THEN v_attempt := 1; END IF;

  IF NOT v_home_in AND NOT v_away_in THEN
    v_home_res := public.match_schedule_apply_club_noshow(
      p_fixture_id, v_fixture.home_club_short_name, v_kickoff, v_attempt, true
    );
    v_away_res := public.match_schedule_apply_club_noshow(
      p_fixture_id, v_fixture.away_club_short_name, v_kickoff, v_attempt, true
    );
    v_new_event := NOT (
      coalesce((v_home_res->>'deduped')::boolean, false)
      AND coalesce((v_away_res->>'deduped')::boolean, false)
    );
    IF v_new_event THEN
      PERFORM public.match_schedule_bump_attempt_on_noshow(p_fixture_id);
    END IF;

    PERFORM public.match_schedule_clear_no_show(p_fixture_id);

    UPDATE public.competition_fixture_schedule s
    SET admin_result_unlock_at = coalesce(s.admin_result_unlock_at, now()),
        admin_result_unlock_note = coalesce(
          s.admin_result_unlock_note,
          'both_miss_auto: either club may submit or reschedule; fines/strikes kept'
        ),
        updated_at = now()
    WHERE s.fixture_id = p_fixture_id;

    RETURN true;
  END IF;

  IF v_home_in AND NOT v_away_in THEN
    v_loser := v_fixture.away_club_short_name;
    v_winner := v_fixture.home_club_short_name;
  ELSE
    v_loser := v_fixture.home_club_short_name;
    v_winner := v_fixture.away_club_short_name;
  END IF;

  UPDATE public.competition_fixture_schedule
  SET no_show_club_short_name = v_loser,
      no_show_kickoff_at = v_kickoff,
      updated_at = now()
  WHERE fixture_id = p_fixture_id;

  v_one_res := public.match_schedule_apply_club_noshow(
    p_fixture_id, v_loser, v_kickoff, v_attempt, false
  );

  IF coalesce((v_one_res->>'ok')::boolean, false)
     AND NOT coalesce((v_one_res->>'deduped')::boolean, false)
     AND NOT coalesce((v_one_res->>'skipped')::boolean, false)
     AND EXISTS (
       SELECT 1 FROM public.competition_fixtures f
       WHERE f.id = p_fixture_id AND f.status = 'scheduled'
     )
  THEN
    PERFORM public.match_schedule_bump_attempt_on_noshow(p_fixture_id);
  END IF;

  UPDATE public.competition_fixture_schedule s
  SET admin_result_unlock_at = coalesce(s.admin_result_unlock_at, now()),
      admin_result_unlock_note = coalesce(
        s.admin_result_unlock_note,
        format(
          'onesided_checkin_auto: %s may submit or either may reschedule; %s missed check-in',
          upper(v_winner),
          upper(v_loser)
        )
      ),
      updated_at = now()
  WHERE s.fixture_id = p_fixture_id;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_assert_ready_to_play(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_window_end timestamptz;
  v_home_in boolean;
  v_away_in boolean;
  v_club text;
  v_checked text;
  v_missed text;
  v_pn jsonb;
  v_pn_status text;
BEGIN
  IF public.is_gpsl_admin() THEN
    RETURN;
  END IF;

  IF to_regprocedure('public.match_schedule_play_now_session_tick(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_play_now_session_tick(p_fixture_id);
  END IF;

  IF to_regprocedure('public.fixture_try_checkin_forfeit(bigint)') IS NOT NULL THEN
    PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status = 'played' THEN
    RAISE EXCEPTION 'This fixture has already been played';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for result entry';
  END IF;

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RETURN;
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'Kick-off time must be agreed before entering a result';
  END IF;

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

  IF to_regprocedure('public.match_schedule_play_now_session_json(bigint)') IS NOT NULL THEN
    v_pn := public.match_schedule_play_now_session_json(p_fixture_id);
    IF coalesce((v_pn->>'active')::boolean, false) THEN
      v_pn_status := coalesce(v_pn->>'status', '');

      BEGIN
        v_club := upper(nullif(btrim(public.my_club_shortname()), ''));
      EXCEPTION WHEN OTHERS THEN
        v_club := NULL;
      END;
      IF v_club IS NULL THEN
        RAISE EXCEPTION 'No club linked to this account';
      END IF;

      IF v_home_in AND v_away_in THEN
        NULL;
      ELSIF v_pn_status = 'miss_open' THEN
        IF (v_home_in AND NOT v_away_in) OR (v_away_in AND NOT v_home_in) THEN
          v_checked := upper(CASE WHEN v_home_in THEN v_fixture.home_club_short_name ELSE v_fixture.away_club_short_name END);
          IF v_club <> v_checked THEN
            RAISE EXCEPTION
              'You missed Play now check-in — only % can submit the result (your no-show penalty still applies)',
              v_checked;
          END IF;
        ELSIF NOT v_home_in AND NOT v_away_in THEN
          NULL;
        ELSE
          RAISE EXCEPTION 'Both clubs must check in before entering a result';
        END IF;
      ELSIF v_pn_status IN ('open', 'both_ready') THEN
        RAISE EXCEPTION 'Both clubs must check in during the Play now window before entering a result';
      ELSE
        RAISE EXCEPTION 'Both clubs must check in before entering a result';
      END IF;

      IF NOT public.match_schedule_result_month_allows_submit(p_fixture_id) THEN
        RAISE EXCEPTION
          'Result entry is closed for this fixture until its GPSL month (or a later month) is open';
      END IF;
      RETURN;
    END IF;
  END IF;

  IF v_home_in AND v_away_in THEN
    NULL;
  ELSIF (v_home_in AND NOT v_away_in) OR (v_away_in AND NOT v_home_in) THEN
    v_window_end :=
      v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;
    IF now() < v_window_end THEN
      RAISE EXCEPTION 'Both clubs must check in before entering a result';
    END IF;

    BEGIN
      v_club := upper(nullif(btrim(public.my_club_shortname()), ''));
    EXCEPTION WHEN OTHERS THEN
      v_club := NULL;
    END;

    IF v_club IS NULL THEN
      RAISE EXCEPTION 'No club linked to this account';
    END IF;

    IF v_home_in THEN
      v_checked := upper(v_fixture.home_club_short_name);
      v_missed := upper(v_fixture.away_club_short_name);
    ELSE
      v_checked := upper(v_fixture.away_club_short_name);
      v_missed := upper(v_fixture.home_club_short_name);
    END IF;

    IF v_club <> v_checked THEN
      RAISE EXCEPTION
        'You missed check-in — only % can submit the result (your no-show penalty still applies)',
        v_checked;
    END IF;

    UPDATE public.competition_fixture_schedule s
    SET admin_result_unlock_at = coalesce(s.admin_result_unlock_at, now()),
        admin_result_unlock_note = coalesce(
          s.admin_result_unlock_note,
          format(
            'onesided_checkin_auto: %s may submit; %s missed check-in',
            v_checked,
            v_missed
          )
        ),
        updated_at = now()
    WHERE s.fixture_id = p_fixture_id;
  ELSIF NOT v_home_in AND NOT v_away_in THEN
    v_window_end :=
      v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;
    IF now() < v_window_end THEN
      RAISE EXCEPTION 'Both clubs must check in before entering a result';
    END IF;

    BEGIN
      v_club := upper(nullif(btrim(public.my_club_shortname()), ''));
    EXCEPTION WHEN OTHERS THEN
      v_club := NULL;
    END;

    IF v_club IS NULL THEN
      RAISE EXCEPTION 'No club linked to this account';
    END IF;

    IF v_club NOT IN (
         upper(v_fixture.home_club_short_name),
         upper(v_fixture.away_club_short_name)
       )
    THEN
      RAISE EXCEPTION 'Your club is not in this fixture';
    END IF;

    UPDATE public.competition_fixture_schedule s
    SET admin_result_unlock_at = coalesce(s.admin_result_unlock_at, now()),
        admin_result_unlock_note = coalesce(
          s.admin_result_unlock_note,
          'both_miss_auto: either club may submit; fines/strikes kept'
        ),
        updated_at = now()
    WHERE s.fixture_id = p_fixture_id;
  ELSE
    RAISE EXCEPTION 'Both clubs must check in before entering a result';
  END IF;

  IF NOT public.match_schedule_result_month_allows_submit(p_fixture_id) THEN
    RAISE EXCEPTION
      'Result entry is closed for this fixture until its GPSL month (or a later month) is open';
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_assert_ready_to_play(bigint)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.trg_play_now_on_fixture_played()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status = 'played' AND coalesce(OLD.status, '') IS DISTINCT FROM 'played' THEN
    IF to_regprocedure('public.match_schedule_play_now_mark_played(bigint)') IS NOT NULL THEN
      PERFORM public.match_schedule_play_now_mark_played(NEW.id);
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_play_now_on_fixture_played ON public.competition_fixtures;
CREATE TRIGGER trg_play_now_on_fixture_played
  AFTER UPDATE OF status ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_play_now_on_fixture_played();

DO $inj$
DECLARE
  v_oid oid;
  v_def text;
BEGIN
  v_oid := to_regprocedure('public.match_schedule_fixture_context(bigint)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'match_schedule_fixture_context missing';
  END IF;
  v_def := pg_get_functiondef(v_oid);

  IF position('match_schedule_play_now_session_tick' IN v_def) = 0 THEN
    IF position('PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);' IN v_def) = 0 THEN
      RAISE EXCEPTION 'Could not find forfeit call in fixture_context';
    END IF;
    v_def := replace(
      v_def,
      'PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);',
      $r$IF to_regprocedure('public.match_schedule_play_now_session_tick(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_play_now_session_tick(p_fixture_id);
  END IF;
  PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);$r$
    );
  END IF;

  IF position('play_now_session' IN v_def) = 0 THEN
    IF position('''mutual_override_options''' IN v_def) = 0 THEN
      RAISE EXCEPTION 'Could not find mutual_override_options in fixture_context';
    END IF;
    v_def := replace(
      v_def,
      '''mutual_override_options''',
      '''play_now_session'', public.match_schedule_play_now_session_json(p_fixture_id),
    ''mutual_override_options'''
    );
  END IF;

  EXECUTE v_def;
END;
$inj$;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.fixture_play_now_press(bigint)') IS NOT NULL AS press_ok,
  to_regprocedure('public.fixture_play_now_reset(bigint)') IS NOT NULL AS reset_ok,
  position('play_now_session' IN pg_get_functiondef('public.match_schedule_fixture_context(bigint)'::regprocedure)) > 0 AS ctx_ok,
  position('play_now_ko_suspended' IN pg_get_functiondef('public.fixture_try_checkin_forfeit(bigint)'::regprocedure)) > 0 AS forfeit_skip_ok;
