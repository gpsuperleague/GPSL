-- =============================================================================
-- Clear stale no-show flags when mutual kick-off is applied (2026-10-25)
-- =============================================================================
-- Follow-up from no-show ladder work: mutual override wiped check-ins but left
-- no_show_club_short_name / no_show_kickoff_at set, which could still forfeit
-- at month lock after a successful rearrange (attempts 1–2 path).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_mutual_override_apply(p_override_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_override public.competition_fixture_mutual_override;
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_fmt text;
  v_body text;
  v_was_agreed boolean;
BEGIN
  SELECT * INTO v_override
  FROM public.competition_fixture_mutual_override
  WHERE id = p_override_id
    AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Mutual override not found or no longer pending';
  END IF;

  IF v_override.home_confirmed_at IS NULL OR v_override.away_confirmed_at IS NULL THEN
    RAISE EXCEPTION 'Both clubs must confirm before applying';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = v_override.fixture_id;
  v_schedule := public.match_schedule_ensure_row(v_override.fixture_id);
  v_was_agreed := coalesce(v_schedule.status, '') = 'agreed'
    AND v_schedule.agreed_kickoff_at IS NOT NULL;

  UPDATE public.competition_fixture_schedule_proposal
  SET status = 'superseded'
  WHERE fixture_id = v_override.fixture_id
    AND status = 'pending';

  UPDATE public.competition_fixture_schedule
  SET
    status = 'agreed',
    agreed_kickoff_at = v_override.proposed_kickoff_at,
    pending_proposal_id = NULL,
    response_due_at = NULL,
    response_required_club_short_name = NULL,
    response_miss_count = 0,
    response_deadline_warned_at = NULL,
    -- Stale one-sided no-show from a previous KO must not survive a new lock
    no_show_club_short_name = NULL,
    no_show_kickoff_at = NULL,
    mutual_override_used = CASE
      WHEN v_was_agreed AND v_override.kind = 'new_time' THEN true
      ELSE coalesce(mutual_override_used, false)
    END,
    updated_at = now()
  WHERE fixture_id = v_override.fixture_id;

  DELETE FROM public.competition_fixture_checkin
  WHERE fixture_id = v_override.fixture_id;

  UPDATE public.competition_fixture_mutual_override
  SET status = 'applied', applied_at = now()
  WHERE id = p_override_id;

  UPDATE public.competition_fixture_mutual_override
  SET status = 'cancelled'
  WHERE fixture_id = v_override.fixture_id
    AND status = 'pending'
    AND id <> p_override_id;

  v_fmt := public.match_schedule_format_kickoff_uk(v_override.proposed_kickoff_at);
  IF NOT v_was_agreed THEN
    v_body := 'Both clubs locked kick-off (Discord / mutual confirm): '
      || v_fmt
      || E'.\nCheck-in opens 10 minutes before kick-off.';
  ELSIF v_override.kind = 'play_now' THEN
    v_body := 'Both clubs agreed to play now. New kick-off: '
      || v_fmt
      || E'.\nNo reschedule or emergency allowance was used.';
  ELSE
    v_body := 'Both clubs agreed a new kick-off: '
      || v_fmt
      || E'.\nNo reschedule or emergency allowance was used.';
  END IF;

  PERFORM public.match_schedule_notify_pair(
    v_fixture,
    'match_mutual_override_applied',
    CASE WHEN v_was_agreed THEN 'Kick-off updated (mutual agreement)' ELSE 'Kick-off locked (mutual agreement)' END,
    v_body,
    NULL,
    'mutual-applied:' || p_override_id::text
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_mutual_override_apply(bigint) TO authenticated;


-- Also clear on proposal accept (new agreed KO)
CREATE OR REPLACE FUNCTION public.fixture_schedule_accept(p_proposal_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_club text;
  v_proposal public.competition_fixture_schedule_proposal;
  v_any_proposal public.competition_fixture_schedule_proposal;
  v_fixture public.competition_fixtures;
  v_fmt text;
  v_body text;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF to_regprocedure('public.club_assert_has_manager_for_matches(text)') IS NOT NULL THEN
    PERFORM public.club_assert_has_manager_for_matches(v_club);
  END IF;

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.competition_fixture_schedule_proposal p
       WHERE p.id = p_proposal_id
         AND public.fixture_is_manual_black_box(p.fixture_id)
     ) THEN
    RAISE EXCEPTION 'Both clubs have GPSL match system OFF 窶・arrange this fixture off-site (no in-app accept).';
  END IF;

  SELECT * INTO v_proposal
  FROM public.competition_fixture_schedule_proposal
  WHERE id = p_proposal_id
    AND status = 'pending';

  IF NOT FOUND THEN
    SELECT * INTO v_any_proposal
    FROM public.competition_fixture_schedule_proposal
    WHERE id = p_proposal_id;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'ok', false,
        'code', 'not_found',
        'message', 'Proposal not found.'
      );
    END IF;

    IF v_any_proposal.status = 'accepted' THEN
      RETURN jsonb_build_object(
        'ok', true,
        'code', 'already_accepted',
        'message', 'This kick-off was already agreed.'
      );
    END IF;

    IF v_any_proposal.status = 'superseded' THEN
      RETURN jsonb_build_object(
        'ok', false,
        'code', 'superseded',
        'message', 'This proposal is no longer available.'
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
  PERFORM public.match_schedule_assert_kickoff_not_double_booked(
    v_proposal.fixture_id,
    v_proposal.kickoff_at
  );

  IF to_regprocedure('public.match_schedule_clear_response_deadline(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_clear_response_deadline(v_proposal.fixture_id);
  END IF;

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
    response_due_at = NULL,
    response_required_club_short_name = NULL,
    response_miss_count = 0,
    no_show_club_short_name = NULL,
    no_show_kickoff_at = NULL,
    updated_at = now()
  WHERE fixture_id = v_proposal.fixture_id;

  DELETE FROM public.competition_fixture_checkin
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

  RETURN jsonb_build_object('ok', true, 'code', 'accepted');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_schedule_accept(bigint) TO authenticated;
