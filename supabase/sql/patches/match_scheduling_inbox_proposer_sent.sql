-- =============================================================================
-- Match scheduling inbox — confirmation to the club that proposed / countered
-- Run after match_scheduling_inbox_respondent_only.sql
-- =============================================================================

ALTER TABLE public.competition_inbox
  DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

ALTER TABLE public.competition_inbox
  ADD CONSTRAINT competition_inbox_message_type_check
  CHECK (
    message_type IN (
      'welcome_gpsl',
      'result_submitted',
      'result_to_confirm',
      'result_rejected',
      'result_confirmed',
      'transfer_signed',
      'transfer_sold',
      'transfer_upcoming',
      'draft_scheduled',
      'fine_applied',
      'points_deduction',
      'nation_pick_turn',
      'nation_selection_open',
      'season_expectations',
      'season_overview',
      'player_awards',
      'monthly_fixtures',
      'match_time_proposed',
      'match_time_countered',
      'match_time_proposal_sent',
      'match_time_counter_sent',
      'match_time_accepted',
      'match_rescheduled',
      'match_emergency_drop',
      'match_forfeit_applied',
      'match_checkin_open',
      'match_mutual_override_requested',
      'match_mutual_override_applied'
    )
  ) NOT VALID;

ALTER TABLE public.competition_inbox
  VALIDATE CONSTRAINT competition_inbox_message_type_check;

CREATE OR REPLACE FUNCTION public.match_schedule_notify_proposer_sent(
  p_fixture public.competition_fixtures,
  p_proposer_club text,
  p_opponent_club text,
  p_kickoff_at timestamptz,
  p_proposal_id bigint,
  p_is_counter boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_href text;
  v_fmt text;
  v_opponent_name text;
  v_title text;
  v_body text;
  v_msg_type text;
  v_inbox_title text;
  v_inbox_body text;
BEGIN
  v_fmt := public.match_schedule_format_kickoff_uk(p_kickoff_at);
  v_opponent_name := public.club_display_name(p_opponent_club);
  v_href := 'fixture_schedule.html?fixture=' || p_fixture.id::text;

  IF p_is_counter THEN
    v_msg_type := 'match_time_counter_sent';
    v_title := 'Counter-proposal sent';
    v_body := 'You counter-proposed ' || v_fmt || ' to ' || v_opponent_name
      || E'.\nWaiting for their response.';
  ELSE
    v_msg_type := 'match_time_proposal_sent';
    v_title := 'Match time sent';
    v_body := 'You proposed ' || v_fmt || ' to ' || v_opponent_name
      || E'.\nWaiting for their response.';
  END IF;

  v_inbox_title := public.competition_fixture_inbox_title(p_fixture.id, v_title);
  v_inbox_body := public.competition_fixture_inbox_body(p_fixture.id, v_body);

  PERFORM public.owner_inbox_send(
    v_msg_type,
    v_inbox_title,
    v_inbox_body,
    p_proposer_club,
    NULL,
    p_fixture.id,
    NULL, NULL, NULL,
    v_href,
    'prop-sent:' || p_proposal_id::text || ':' || p_proposer_club,
    p_fixture.gpsl_month,
    p_fixture.season_id,
    NULL
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.fixture_schedule_propose(
  p_fixture_id bigint,
  p_kickoff_at timestamptz
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_club_name text;
  v_opponent text;
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_proposal_id bigint;
  v_title text;
  v_body text;
  v_fmt text;
  v_is_counter boolean;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_club_name := public.club_display_name(v_club);

  v_fixture := public.match_schedule_assert_kickoff_valid(p_fixture_id, p_kickoff_at);
  v_schedule := public.match_schedule_ensure_row(p_fixture_id);
  v_is_counter := v_schedule.status <> 'unscheduled';

  IF v_schedule.status = 'agreed' THEN
    RAISE EXCEPTION 'Kick-off is already agreed for this fixture';
  END IF;

  IF v_schedule.status = 'unscheduled' THEN
    IF v_club <> v_fixture.home_club_short_name THEN
      RAISE EXCEPTION 'Home club must propose the first kick-off time';
    END IF;
  ELSE
    IF v_schedule.pending_proposal_id IS NULL THEN
      RAISE EXCEPTION 'No pending proposal to respond to';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.competition_fixture_schedule_proposal p
      WHERE p.id = v_schedule.pending_proposal_id
        AND p.proposed_by_club_short_name = v_club
    ) THEN
      RAISE EXCEPTION 'Wait for your opponent to respond to your proposal';
    END IF;
  END IF;

  IF v_schedule.pending_proposal_id IS NOT NULL THEN
    UPDATE public.competition_fixture_schedule_proposal
    SET status = 'superseded'
    WHERE id = v_schedule.pending_proposal_id
      AND status = 'pending';
  END IF;

  INSERT INTO public.competition_fixture_schedule_proposal (
    fixture_id, proposed_by_club_short_name, kickoff_at, status
  )
  VALUES (p_fixture_id, v_club, p_kickoff_at, 'pending')
  RETURNING id INTO v_proposal_id;

  UPDATE public.competition_fixture_schedule
  SET
    status = 'negotiating',
    pending_proposal_id = v_proposal_id,
    home_proposal_count = home_proposal_count + CASE WHEN v_club = v_fixture.home_club_short_name THEN 1 ELSE 0 END,
    away_proposal_count = away_proposal_count + CASE WHEN v_club = v_fixture.away_club_short_name THEN 1 ELSE 0 END,
    discord_hint_shown = (
      (home_proposal_count + CASE WHEN v_club = v_fixture.home_club_short_name THEN 1 ELSE 0 END) >= 2
      AND (away_proposal_count + CASE WHEN v_club = v_fixture.away_club_short_name THEN 1 ELSE 0 END) >= 2
    ),
    updated_at = now()
  WHERE fixture_id = p_fixture_id;

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);
  v_fmt := public.match_schedule_format_kickoff_uk(p_kickoff_at);
  v_title := CASE
    WHEN NOT v_is_counter THEN 'Match time proposed'
    ELSE 'Counter-proposal received'
  END;
  v_body := v_club_name || ' proposed ' || v_fmt || E'.\nOpen Schedule to accept or suggest another time.';

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    CASE WHEN NOT v_is_counter THEN 'match_time_proposed' ELSE 'match_time_countered' END,
    v_title,
    v_body,
    v_opponent,
    'prop:' || v_proposal_id::text || ':' || v_opponent,
    v_proposal_id
  );

  PERFORM public.match_schedule_notify_proposer_sent(
    v_fixture,
    v_club,
    v_opponent,
    p_kickoff_at,
    v_proposal_id,
    v_is_counter
  );

  RETURN v_proposal_id;
END;
$function$;

NOTIFY pgrst, 'reload schema';
