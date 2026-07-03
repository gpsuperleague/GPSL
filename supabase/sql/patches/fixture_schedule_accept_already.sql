-- Idempotent accept: already-agreed returns HTTP 200 + jsonb (no console 400).
-- Run after match_scheduling_phase1.sql (replaces fixture_schedule_accept_already.sql).

DROP FUNCTION IF EXISTS public.fixture_schedule_accept(bigint);

CREATE OR REPLACE FUNCTION public.fixture_schedule_accept(p_proposal_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_proposal public.competition_fixture_schedule_proposal;
  v_any_proposal public.competition_fixture_schedule_proposal;
  v_schedule public.competition_fixture_schedule;
  v_fixture public.competition_fixtures;
  v_fmt text;
  v_body text;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_proposal
  FROM public.competition_fixture_schedule_proposal p
  WHERE p.id = p_proposal_id
    AND p.status = 'pending';

  IF NOT FOUND THEN
    SELECT * INTO v_any_proposal
    FROM public.competition_fixture_schedule_proposal p
    WHERE p.id = p_proposal_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Proposal not found';
    END IF;

    SELECT * INTO v_schedule
    FROM public.competition_fixture_schedule s
    WHERE s.fixture_id = v_any_proposal.fixture_id;

    IF v_any_proposal.status = 'accepted'
      OR (
        v_schedule.status = 'agreed'
        AND v_schedule.agreed_kickoff_at IS NOT NULL
        AND v_schedule.agreed_kickoff_at = v_any_proposal.kickoff_at
      )
    THEN
      v_fmt := public.match_schedule_format_kickoff_uk(v_any_proposal.kickoff_at);
      RETURN jsonb_build_object(
        'ok', false,
        'code', 'already_accepted',
        'message', format('This match time was already accepted (%s).', v_fmt)
      );
    END IF;

    IF v_schedule.status = 'agreed' AND v_schedule.agreed_kickoff_at IS NOT NULL THEN
      v_fmt := public.match_schedule_format_kickoff_uk(v_schedule.agreed_kickoff_at);
      RETURN jsonb_build_object(
        'ok', false,
        'code', 'already_agreed',
        'message', format('A kick-off time is already agreed for this match (%s).', v_fmt)
      );
    END IF;

    IF v_any_proposal.status = 'superseded' THEN
      RETURN jsonb_build_object(
        'ok', false,
        'code', 'superseded',
        'message', 'This proposal was replaced — open Schedule to see the latest offer.'
      );
    END IF;

    IF v_any_proposal.status = 'withdrawn' THEN
      RETURN jsonb_build_object(
        'ok', false,
        'code', 'withdrawn',
        'message', 'This proposal is no longer available.'
      );
    END IF;

    RETURN jsonb_build_object(
      'ok', false,
      'code', 'not_pending',
      'message', 'Proposal not found or no longer pending.'
    );
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = v_proposal.fixture_id;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'You are not in this fixture';
  END IF;

  IF v_proposal.proposed_by_club_short_name = v_club THEN
    RAISE EXCEPTION 'You cannot accept your own proposal';
  END IF;

  PERFORM public.match_schedule_assert_kickoff_valid(v_proposal.fixture_id, v_proposal.kickoff_at);

  UPDATE public.competition_fixture_schedule_proposal
  SET status = 'accepted'
  WHERE id = p_proposal_id;

  UPDATE public.competition_fixture_schedule_proposal
  SET status = 'superseded'
  WHERE fixture_id = v_proposal.fixture_id
    AND status = 'pending'
    AND id <> p_proposal_id;

  UPDATE public.competition_fixture_schedule
  SET
    status = 'agreed',
    agreed_kickoff_at = v_proposal.kickoff_at,
    pending_proposal_id = NULL,
    updated_at = now()
  WHERE fixture_id = v_proposal.fixture_id;

  v_fmt := public.match_schedule_format_kickoff_uk(v_proposal.kickoff_at);
  v_body := 'Kick-off agreed: ' || v_fmt || E'.\nBoth clubs confirmed this time.';

  PERFORM public.match_schedule_notify_pair(
    v_fixture,
    'match_time_accepted',
    'Match time agreed',
    v_body,
    p_proposal_id,
    'accept:' || p_proposal_id::text
  );

  RETURN jsonb_build_object('ok', true);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_schedule_accept(bigint) TO authenticated;
