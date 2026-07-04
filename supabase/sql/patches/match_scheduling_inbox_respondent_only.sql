-- =============================================================================
-- Match scheduling inbox — proposal actions only for the responding club
-- Run after match_scheduling_inbox_club_names.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_notify_opponent(
  p_fixture public.competition_fixtures,
  p_message_type text,
  p_title text,
  p_body text,
  p_opponent_club text,
  p_dedupe_suffix text,
  p_proposal_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_href text;
  v_title text;
  v_body text;
BEGIN
  v_href := 'fixture_schedule.html?fixture=' || p_fixture.id::text;
  v_title := public.competition_fixture_inbox_title(p_fixture.id, p_title);
  v_body := public.competition_fixture_inbox_body(p_fixture.id, p_body);

  PERFORM public.owner_inbox_send(
    p_message_type,
    v_title,
    v_body,
    p_opponent_club,
    NULL,
    p_fixture.id,
    NULL, NULL, NULL,
    v_href,
    'schedule:' || p_fixture.id::text || ':' || p_dedupe_suffix,
    p_fixture.gpsl_month,
    p_fixture.season_id,
    p_proposal_id
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
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_club_name := public.club_display_name(v_club);

  v_fixture := public.match_schedule_assert_kickoff_valid(p_fixture_id, p_kickoff_at);
  v_schedule := public.match_schedule_ensure_row(p_fixture_id);

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
    WHEN v_schedule.status = 'unscheduled' THEN 'Match time proposed'
    ELSE 'Counter-proposal received'
  END;
  v_body := v_club_name || ' proposed ' || v_fmt || E'.\nOpen Schedule to accept or suggest another time.';

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    CASE WHEN v_schedule.status = 'unscheduled' THEN 'match_time_proposed' ELSE 'match_time_countered' END,
    v_title,
    v_body,
    v_opponent,
    'prop:' || v_proposal_id::text || ':' || v_opponent,
    v_proposal_id
  );

  RETURN v_proposal_id;
END;
$function$;

NOTIFY pgrst, 'reload schema';
