-- =============================================================================
-- Match scheduling inbox — full club names in message bodies (not ShortName)
-- Run after competition_fixture_inbox_competition.sql, match_scheduling_mutual_notify_competition.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_display_name(p_short text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT c."Club"
      FROM public."Clubs" c
      WHERE c."ShortName" = nullif(btrim(p_short), '')
      LIMIT 1
    ),
    nullif(btrim(p_short), '')
  );
$$;

-- ---------------------------------------------------------------------------
-- Propose / counter-propose kick-off
-- ---------------------------------------------------------------------------

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

  v_fmt := public.match_schedule_format_kickoff_uk(p_kickoff_at);
  v_title := CASE
    WHEN v_schedule.status = 'unscheduled' THEN 'Match time proposed'
    ELSE 'Counter-proposal received'
  END;
  v_body := v_club_name || ' proposed ' || v_fmt || E'.\nOpen Schedule to accept or suggest another time.';

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);

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

-- ---------------------------------------------------------------------------
-- Voluntary reschedule drop / emergency drop / forfeit (competition-aware bodies)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_voluntary_reschedule_drop(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_club_name text;
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_opponent text;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_club_name := public.club_display_name(v_club);

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture not open for reschedule';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'No agreed kick-off to drop';
  END IF;

  IF now() > v_kickoff - interval '24 hours' THEN
    RAISE EXCEPTION 'Within 24 hours of kick-off — use emergency drop instead';
  END IF;

  IF public.match_schedule_reschedule_used_this_month(
    v_fixture.season_id, v_club, v_fixture.gpsl_month
  ) THEN
    RAISE EXCEPTION 'You have already used your reschedule allowance for GPSL %',
      public.competition_gpsl_month_label(v_fixture.gpsl_month);
  END IF;

  INSERT INTO public.competition_club_month_reschedule_use (
    season_id, club_short_name, gpsl_month, fixture_id
  )
  VALUES (v_fixture.season_id, v_club, v_fixture.gpsl_month, p_fixture_id);

  PERFORM public.match_schedule_reset_to_unscheduled(p_fixture_id);

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    'match_rescheduled',
    'Match returned to scheduling',
    v_club_name || ' dropped the agreed time (24h+ notice). Propose a new kick-off on the schedule page.',
    v_opponent,
    'reschedule:' || p_fixture_id::text || ':' || v_club
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.fixture_emergency_drop(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_club_name text;
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_opponent text;
  v_used integer;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_club_name := public.club_display_name(v_club);

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture not open';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'No agreed kick-off';
  END IF;

  IF now() <= v_kickoff - interval '24 hours' THEN
    RAISE EXCEPTION 'More than 24 hours before kick-off — use voluntary drop instead';
  END IF;

  IF now() >= v_kickoff THEN
    RAISE EXCEPTION 'Kick-off has passed';
  END IF;

  v_used := public.match_schedule_emergency_drops_used(v_fixture.season_id, v_club);
  IF v_used >= 2 THEN
    RAISE EXCEPTION 'No emergency drops remaining this season';
  END IF;

  INSERT INTO public.competition_club_emergency_drop_use (
    season_id, club_short_name, fixture_id
  )
  VALUES (v_fixture.season_id, v_club, p_fixture_id);

  PERFORM public.match_schedule_reset_to_unscheduled(p_fixture_id);

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    'match_emergency_drop',
    'Emergency drop — reschedule needed',
    v_club_name || ' used an emergency drop (<24h). The match is back on the schedule page.',
    v_opponent,
    'emergency:' || p_fixture_id::text || ':' || v_club
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.fixture_apply_forfeit(
  p_fixture_id bigint,
  p_loser_club text,
  p_tariff_code text,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home_goals smallint;
  v_away_goals smallint;
  v_winner text;
  v_loser_name text;
  v_title text;
  v_body text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status = 'played' THEN
    RETURN;
  END IF;

  IF p_loser_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Loser must be a club in this fixture';
  END IF;

  v_loser_name := public.club_display_name(p_loser_club);

  v_winner := CASE
    WHEN p_loser_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
    ELSE v_fixture.home_club_short_name
  END;

  IF v_winner = v_fixture.home_club_short_name THEN
    v_home_goals := 3;
    v_away_goals := 0;
  ELSE
    v_home_goals := 0;
    v_away_goals := 3;
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by forfeit',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_fixtures
  SET
    home_goals = v_home_goals,
    away_goals = v_away_goals,
    status = 'played',
    is_forfeit = true,
    forfeit_loser_club = p_loser_club
  WHERE id = p_fixture_id;

  PERFORM public.competition_apply_club_fine_tariff(
    p_loser_club,
    p_tariff_code,
    NULL,
    coalesce(p_reason, 'Match forfeit'),
    p_fixture_id,
    v_fixture.season_id
  );

  IF v_fixture.competition_type = 'cup' THEN
    PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
  ELSIF v_fixture.competition_type = 'league' THEN
    PERFORM public.competition_try_pay_league_division_prizes(
      v_fixture.season_id,
      v_fixture.division
    );
  END IF;

  v_title := public.competition_fixture_inbox_title(p_fixture_id, 'Match forfeited');
  v_body := public.competition_fixture_inbox_body(
    p_fixture_id,
    format('%s forfeited 3–0. %s', v_loser_name, coalesce(p_reason, ''))
  );

  PERFORM public.owner_inbox_send(
    'match_forfeit_applied', v_title, v_body,
    v_fixture.home_club_short_name, NULL, p_fixture_id,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=' || p_fixture_id::text,
    'forfeit:' || p_fixture_id::text || ':home',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
  PERFORM public.owner_inbox_send(
    'match_forfeit_applied', v_title, v_body,
    v_fixture.away_club_short_name, NULL, p_fixture_id,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=' || p_fixture_id::text,
    'forfeit:' || p_fixture_id::text || ':away',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Mutual override request — opponent notification
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_mutual_override_request(
  p_fixture_id bigint,
  p_kind text,
  p_kickoff_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_club_name text;
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_kickoff timestamptz;
  v_override_id bigint;
  v_opponent text;
  v_fmt text;
  v_title text;
  v_body text;
  v_home_confirm timestamptz;
  v_away_confirm timestamptz;
BEGIN
  PERFORM public.match_schedule_mutual_override_expire();

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_club_name := public.club_display_name(v_club);

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'You are not in this fixture';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for scheduling';
  END IF;

  v_schedule := public.match_schedule_ensure_row(p_fixture_id);

  IF v_schedule.status <> 'agreed' OR v_schedule.agreed_kickoff_at IS NULL THEN
    RAISE EXCEPTION 'Kick-off must be agreed before a mutual override';
  END IF;

  IF v_schedule.mutual_override_used THEN
    RAISE EXCEPTION 'This fixture has already used its one mutual kick-off change';
  END IF;

  IF p_kind NOT IN ('play_now', 'new_time') THEN
    RAISE EXCEPTION 'Invalid mutual override kind';
  END IF;

  IF p_kind = 'play_now' THEN
    v_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
  ELSE
    IF p_kickoff_at IS NULL THEN
      RAISE EXCEPTION 'New kick-off time is required';
    END IF;
    PERFORM public.match_schedule_assert_kickoff_valid(p_fixture_id, p_kickoff_at);
    IF p_kickoff_at = v_schedule.agreed_kickoff_at THEN
      RAISE EXCEPTION 'Choose a different kick-off time';
    END IF;
    v_kickoff := p_kickoff_at;
  END IF;

  UPDATE public.competition_fixture_mutual_override
  SET status = 'cancelled'
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  IF v_club = v_fixture.home_club_short_name THEN
    v_home_confirm := now();
    v_away_confirm := NULL;
  ELSE
    v_home_confirm := NULL;
    v_away_confirm := now();
  END IF;

  INSERT INTO public.competition_fixture_mutual_override (
    fixture_id,
    requested_by_club,
    kind,
    proposed_kickoff_at,
    status,
    home_confirmed_at,
    away_confirmed_at,
    expires_at
  )
  VALUES (
    p_fixture_id,
    v_club,
    p_kind,
    v_kickoff,
    'pending',
    v_home_confirm,
    v_away_confirm,
    now() + interval '24 hours'
  )
  RETURNING id INTO v_override_id;

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);
  v_fmt := public.match_schedule_format_kickoff_uk(v_kickoff);
  v_title := CASE p_kind
    WHEN 'play_now' THEN 'Play now — confirm?'
    ELSE 'New kick-off — confirm?'
  END;
  v_body := v_club_name || CASE p_kind
    WHEN 'play_now' THEN ' wants to play now at '
    ELSE ' proposed a new kick-off at '
  END || v_fmt || E'.\nConfirm in your inbox or on Schedule match. No reschedule allowance is used when both agree.';

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    'match_mutual_override_requested',
    v_title,
    v_body,
    v_opponent,
    'mutual:' || p_fixture_id::text || ':req:' || v_override_id::text || ':' || v_opponent
  );

  RETURN jsonb_build_object(
    'ok', true,
    'override_id', v_override_id,
    'proposed_kickoff_at', v_kickoff,
    'awaiting_opponent', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_display_name(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_schedule_propose(bigint, timestamptz) TO authenticated;

NOTIFY pgrst, 'reload schema';
