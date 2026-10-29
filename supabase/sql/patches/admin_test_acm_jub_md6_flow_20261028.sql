-- =============================================================================
-- Admin test flow: AC Milan (ACM) ↔ Jubilo (JUB) league MD6
--
-- You are Jubilo in the UI. This RPC acts as ACM (or HOME for first propose).
--
-- Important: first kick-off must be proposed by HOME. If JUB is home, propose
-- acts as JUB so ACM (away) can accept — or you propose yourself as Jubilo.
--
-- Steps: lookup | propose | play_now | checkin | submit_result | accept
--
--   select public.admin_test_acm_jub_md6('lookup');
--   select public.admin_test_acm_jub_md6('propose');
--   -- accepter (away) accepts in UI, OR: select public.admin_test_acm_jub_md6('accept');
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_test_fixture_act(
  p_act_club text,
  p_opp_club text,
  p_matchday int,
  p_step text,
  p_kickoff_at timestamptz DEFAULT NULL,
  p_home_goals int DEFAULT 2,
  p_away_goals int DEFAULT 1,
  p_division text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '180s'
AS $function$
DECLARE
  v_act text := upper(nullif(btrim(coalesce(p_act_club, '')), ''));
  v_opp text := upper(nullif(btrim(coalesce(p_opp_club, '')), ''));
  v_step text := lower(nullif(btrim(coalesce(p_step, '')), ''));
  v_div text := lower(nullif(btrim(coalesce(p_division, '')), ''));
  v_season bigint;
  v_fixture public.competition_fixtures;
  v_sched public.competition_fixture_schedule;
  v_ko timestamptz;
  v_proposal_id bigint;
  v_expected int;
  v_stats jsonb;
  v_out jsonb;
  v_err text := NULL;
  v_mo jsonb;
  v_chk jsonb;
  v_sub_id bigint;
  v_home text;
  v_away text;
  v_as_club text;
  v_accept jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_act IS NULL OR v_opp IS NULL THEN
    RAISE EXCEPTION 'act club and opp club required';
  END IF;

  IF v_step IS NULL THEN
    RAISE EXCEPTION 'step required: lookup|propose|accept|play_now|checkin|submit_result';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  SELECT f.*
  INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season
    AND coalesce(f.competition_type, 'league') = 'league'
    AND (p_matchday IS NULL OR f.matchday = p_matchday)
    AND (v_div IS NULL OR f.division = v_div)
    AND (
      (upper(btrim(f.home_club_short_name)) = v_act
       AND upper(btrim(f.away_club_short_name)) = v_opp)
      OR (upper(btrim(f.home_club_short_name)) = v_opp
          AND upper(btrim(f.away_club_short_name)) = v_act)
    )
  ORDER BY f.id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'fixture_not_found',
      'act', v_act,
      'opp', v_opp,
      'matchday', p_matchday,
      'division', v_div
    );
  END IF;

  v_home := upper(btrim(v_fixture.home_club_short_name));
  v_away := upper(btrim(v_fixture.away_club_short_name));

  SELECT * INTO v_sched
  FROM public.competition_fixture_schedule
  WHERE fixture_id = v_fixture.id;

  IF v_step = 'lookup' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'step', 'lookup',
      'fixture_id', v_fixture.id,
      'division', v_fixture.division,
      'matchday', v_fixture.matchday,
      'gpsl_month', v_fixture.gpsl_month,
      'home', v_home,
      'away', v_away,
      'status', v_fixture.status,
      'act_is_home', v_home = v_act,
      'schedule_status', coalesce(v_sched.status, 'unscheduled'),
      'pending_proposal_id', v_sched.pending_proposal_id,
      'agreed_kickoff_at', v_sched.agreed_kickoff_at,
      'pending_proposal', (
        SELECT jsonb_build_object(
          'id', p.id,
          'proposed_by', p.proposed_by_club_short_name,
          'kickoff_at', p.kickoff_at,
          'status', p.status
        )
        FROM public.competition_fixture_schedule_proposal p
        WHERE p.fixture_id = v_fixture.id
        ORDER BY p.id DESC
        LIMIT 1
      ),
      'note', CASE
        WHEN v_home <> v_act THEN
          format(
            'HOME is %s (not %s). First propose must be by home — propose step will act as %s; %s accepts.',
            v_home, v_act, v_home, v_away
          )
        ELSE format('HOME is %s — can propose; %s accepts.', v_home, v_away)
      END,
      'next', 'propose'
    );
  END IF;

  IF to_regprocedure('public.gpsl_sim_set_acting_club(text)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_gpsl_sim_set_acting_club');
  END IF;

  BEGIN
    IF v_step = 'propose' THEN
      -- Always propose as HOME for the first kick-off
      v_as_club := v_home;
      PERFORM public.gpsl_sim_set_acting_club(v_as_club);

      v_ko := coalesce(
        p_kickoff_at,
        ((timestamp '2026-10-29 20:00:00') AT TIME ZONE 'Europe/London')
      );

      IF to_regprocedure('public.fixture_schedule_propose(bigint,timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'fixture_schedule_propose missing';
      END IF;

      v_proposal_id := public.fixture_schedule_propose(v_fixture.id, v_ko);

      v_out := jsonb_build_object(
        'ok', true,
        'step', 'propose',
        'fixture_id', v_fixture.id,
        'proposal_id', v_proposal_id,
        'proposed_as', v_as_club,
        'accept_as', v_away,
        'kickoff_at', v_ko,
        'kickoff_uk', to_char(v_ko AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI'),
        'home', v_home,
        'away', v_away,
        'next', format(
          'Accept as %s on Schedule / Matchday checklist — or run step accept',
          v_away
        )
      );

    ELSIF v_step = 'accept' THEN
      -- Away accepts the pending home proposal
      v_as_club := v_away;
      PERFORM public.gpsl_sim_set_acting_club(v_as_club);

      SELECT p.id INTO v_proposal_id
      FROM public.competition_fixture_schedule_proposal p
      WHERE p.fixture_id = v_fixture.id
        AND p.status = 'pending'
      ORDER BY p.id DESC
      LIMIT 1;

      IF v_proposal_id IS NULL THEN
        RAISE EXCEPTION 'No pending proposal to accept on fixture %', v_fixture.id;
      END IF;

      IF to_regprocedure('public.fixture_schedule_accept(bigint)') IS NULL THEN
        RAISE EXCEPTION 'fixture_schedule_accept missing';
      END IF;

      v_accept := public.fixture_schedule_accept(v_proposal_id);

      v_out := jsonb_build_object(
        'ok', true,
        'step', 'accept',
        'fixture_id', v_fixture.id,
        'proposal_id', v_proposal_id,
        'accepted_as', v_as_club,
        'result', v_accept,
        'next', 'Run play_now as ACM when ready'
      );

    ELSIF v_step = 'play_now' THEN
      v_as_club := v_act;
      PERFORM public.gpsl_sim_set_acting_club(v_as_club);

      IF to_regprocedure(
           'public.fixture_mutual_override_request(bigint,text,timestamptz)'
         ) IS NULL THEN
        RAISE EXCEPTION 'fixture_mutual_override_request missing';
      END IF;

      v_mo := public.fixture_mutual_override_request(v_fixture.id, 'play_now', NULL);

      v_out := jsonb_build_object(
        'ok', true,
        'step', 'play_now',
        'fixture_id', v_fixture.id,
        'request', v_mo,
        'act', v_as_club,
        'next', 'Confirm Play now as Jubilo'
      );

    ELSIF v_step = 'checkin' THEN
      v_as_club := v_act;
      PERFORM public.gpsl_sim_set_acting_club(v_as_club);

      IF to_regprocedure('public.fixture_check_in(bigint)') IS NULL THEN
        RAISE EXCEPTION 'fixture_check_in missing';
      END IF;

      v_chk := public.fixture_check_in(v_fixture.id);

      v_out := jsonb_build_object(
        'ok', true,
        'step', 'checkin',
        'fixture_id', v_fixture.id,
        'checkin', v_chk,
        'act', v_as_club,
        'next', 'Check in as Jubilo, then play'
      );

    ELSIF v_step = 'submit_result' THEN
      v_as_club := v_act;
      PERFORM public.gpsl_sim_set_acting_club(v_as_club);

      IF to_regprocedure(
           'public.admin_testing_build_club_match_stats(text,int,bigint)'
         ) IS NULL THEN
        RAISE EXCEPTION 'admin_testing_build_club_match_stats missing';
      END IF;

      v_expected := CASE
        WHEN v_home = v_act THEN coalesce(p_home_goals, 2)
        ELSE coalesce(p_away_goals, 1)
      END;

      v_stats := public.admin_testing_build_club_match_stats(
        v_as_club, v_expected, v_fixture.id
      );

      IF to_regprocedure(
           'public.competition_submit_result(bigint,integer,integer,jsonb,integer,integer,text)'
         ) IS NOT NULL THEN
        PERFORM public.competition_submit_result(
          v_fixture.id,
          coalesce(p_home_goals, 2),
          coalesce(p_away_goals, 1),
          v_stats,
          NULL, NULL, NULL
        );
      ELSIF to_regprocedure(
              'public.competition_submit_result(bigint,integer,integer,jsonb)'
            ) IS NOT NULL THEN
        PERFORM public.competition_submit_result(
          v_fixture.id,
          coalesce(p_home_goals, 2),
          coalesce(p_away_goals, 1),
          v_stats
        );
      ELSE
        RAISE EXCEPTION 'competition_submit_result overload not found';
      END IF;

      SELECT rs.id INTO v_sub_id
      FROM public.competition_result_submissions rs
      WHERE rs.fixture_id = v_fixture.id
        AND rs.status = 'pending'
      ORDER BY rs.id DESC
      LIMIT 1;

      v_out := jsonb_build_object(
        'ok', true,
        'step', 'submit_result',
        'fixture_id', v_fixture.id,
        'submission_id', v_sub_id,
        'score', format('%s-%s', coalesce(p_home_goals, 2), coalesce(p_away_goals, 1)),
        'submitted_by', v_as_club,
        'stat_rows', jsonb_array_length(coalesce(v_stats, '[]'::jsonb)),
        'next', 'Confirm the result as Jubilo (timeout test)'
      );

    ELSE
      RAISE EXCEPTION
        'Unknown step % (use lookup|propose|accept|play_now|checkin|submit_result)',
        v_step;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    v_out := jsonb_build_object(
      'ok', false,
      'step', v_step,
      'fixture_id', v_fixture.id,
      'home', v_home,
      'away', v_away,
      'act', v_act,
      'error', v_err
    );
  END;

  BEGIN
    PERFORM public.gpsl_sim_set_acting_club(NULL);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN coalesce(v_out, jsonb_build_object('ok', false, 'error', 'no_result'));
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_test_fixture_act(text, text, int, text, timestamptz, int, int, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_test_fixture_act(text, text, int, text, timestamptz, int, int, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_test_acm_jub_md6(p_step text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.admin_test_fixture_act(
    'ACM', 'JUB', 6, p_step, NULL, 2, 1, NULL
  );
$$;

REVOKE ALL ON FUNCTION public.admin_test_acm_jub_md6(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_test_acm_jub_md6(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
