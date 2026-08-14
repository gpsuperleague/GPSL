-- =============================================================================
-- Block double-booking of agreed / pending kick-off slots
--
-- A club cannot propose, accept, or mutually rebook a kick-off that overlaps
-- another of their (or the opponent’s) agreed matches or pending proposals
-- in the same season (30-minute play block).
--
-- Run after: match_avail_home_propose_owner_perpetual_20260814.sql
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_intervals_overlap(
  p_a timestamptz,
  p_b timestamptz,
  p_block_minutes integer DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    p_a IS NOT NULL
    AND p_b IS NOT NULL
    AND p_a < (p_b + make_interval(mins => coalesce(p_block_minutes, 30)))
    AND p_b < (p_a + make_interval(mins => coalesce(p_block_minutes, 30)));
$$;

/** True if this club already has an agreed or pending kick-off overlapping p_kickoff. */
CREATE OR REPLACE FUNCTION public.match_schedule_club_busy_at(
  p_club_short_name text,
  p_kickoff timestamptz,
  p_except_fixture_id bigint DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(p_club_short_name), '');
  v_block integer := coalesce(public.match_schedule_block_minutes(), 30);
BEGIN
  IF v_club IS NULL OR p_kickoff IS NULL THEN
    RETURN false;
  END IF;

  -- Agreed kick-offs on other still-scheduled fixtures
  IF EXISTS (
    SELECT 1
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE s.status = 'agreed'
      AND s.agreed_kickoff_at IS NOT NULL
      AND f.status = 'scheduled'
      AND (p_except_fixture_id IS NULL OR f.id <> p_except_fixture_id)
      AND (p_season_id IS NULL OR f.season_id = p_season_id)
      AND v_club IN (f.home_club_short_name, f.away_club_short_name)
      AND public.match_schedule_intervals_overlap(
            s.agreed_kickoff_at, p_kickoff, v_block
          )
  ) THEN
    RETURN true;
  END IF;

  -- Pending proposals on other fixtures involving this club
  IF EXISTS (
    SELECT 1
    FROM public.competition_fixture_schedule_proposal p
    JOIN public.competition_fixtures f ON f.id = p.fixture_id
    WHERE p.status = 'pending'
      AND p.kickoff_at IS NOT NULL
      AND f.status = 'scheduled'
      AND (p_except_fixture_id IS NULL OR f.id <> p_except_fixture_id)
      AND (p_season_id IS NULL OR f.season_id = p_season_id)
      AND v_club IN (f.home_club_short_name, f.away_club_short_name)
      AND public.match_schedule_intervals_overlap(
            p.kickoff_at, p_kickoff, v_block
          )
  ) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_assert_kickoff_not_double_booked(
  p_fixture_id bigint,
  p_kickoff timestamptz
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home_busy boolean;
  v_away_busy boolean;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  v_home_busy := public.match_schedule_club_busy_at(
    v_fixture.home_club_short_name,
    p_kickoff,
    p_fixture_id,
    v_fixture.season_id
  );
  v_away_busy := public.match_schedule_club_busy_at(
    v_fixture.away_club_short_name,
    p_kickoff,
    p_fixture_id,
    v_fixture.season_id
  );

  IF v_home_busy AND v_away_busy THEN
    RAISE EXCEPTION 'Both clubs already have a match overlapping that kick-off';
  END IF;
  IF v_home_busy THEN
    RAISE EXCEPTION '% already has a match overlapping that kick-off',
      public.club_display_name(v_fixture.home_club_short_name);
  END IF;
  IF v_away_busy THEN
    RAISE EXCEPTION '% already has a match overlapping that kick-off',
      public.club_display_name(v_fixture.away_club_short_name);
  END IF;
END;
$function$;

-- Hide busy slots from the proposer’s pick list
CREATE OR REPLACE FUNCTION public.match_schedule_club_window_slots(
  p_fixture_id bigint,
  p_club_short_name text
)
RETURNS TABLE (kickoff_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_cursor timestamptz;
  v_now timestamptz := now();
  v_club text := nullif(btrim(p_club_short_name), '');
BEGIN
  IF v_club IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT w.unlock_at, w.lock_at
  INTO v_unlock, v_lock
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  IF v_unlock IS NULL OR v_lock IS NULL THEN
    RETURN;
  END IF;

  v_cursor := public.match_schedule_align_kickoff_up(greatest(v_unlock, v_now));

  WHILE v_cursor IS NOT NULL
    AND v_cursor + interval '30 minutes' <= v_lock
  LOOP
    IF v_cursor > v_now
       AND public.match_schedule_kickoff_is_slot(v_cursor)
       AND public.match_schedule_club_available_at(
             v_fixture.season_id, v_club, v_cursor
           )
       AND NOT public.match_schedule_club_busy_at(
             v_club, v_cursor, p_fixture_id, v_fixture.season_id
           )
    THEN
      kickoff_at := v_cursor;
      RETURN NEXT;
    END IF;
    v_cursor := v_cursor + interval '30 minutes';
  END LOOP;
END;
$function$;

-- Mutual slots also exclude times either club is already booked
CREATE OR REPLACE FUNCTION public.match_schedule_intersection_slots(p_fixture_id bigint)
RETURNS TABLE (kickoff_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_cursor timestamptz;
  v_now timestamptz := now();
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT w.unlock_at, w.lock_at
  INTO v_unlock, v_lock
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  IF v_unlock IS NULL OR v_lock IS NULL THEN
    RETURN;
  END IF;

  v_cursor := public.match_schedule_align_kickoff_up(greatest(v_unlock, v_now));

  WHILE v_cursor IS NOT NULL
    AND v_cursor + interval '30 minutes' <= v_lock
  LOOP
    IF v_cursor > v_now
       AND public.match_schedule_kickoff_is_slot(v_cursor)
       AND public.match_schedule_club_available_at(
             v_fixture.season_id, v_fixture.home_club_short_name, v_cursor
           )
       AND public.match_schedule_club_available_at(
             v_fixture.season_id, v_fixture.away_club_short_name, v_cursor
           )
       AND NOT public.match_schedule_club_busy_at(
             v_fixture.home_club_short_name, v_cursor, p_fixture_id, v_fixture.season_id
           )
       AND NOT public.match_schedule_club_busy_at(
             v_fixture.away_club_short_name, v_cursor, p_fixture_id, v_fixture.season_id
           )
    THEN
      kickoff_at := v_cursor;
      RETURN NEXT;
    END IF;
    v_cursor := v_cursor + interval '30 minutes';
  END LOOP;
END;
$function$;

-- Propose: block if either club already booked (opponent may have another match)
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

  IF to_regprocedure('public.club_assert_has_manager_for_matches(text)') IS NOT NULL THEN
    PERFORM public.club_assert_has_manager_for_matches(v_club);
  END IF;

  v_club_name := public.club_display_name(v_club);

  v_fixture := public.match_schedule_assert_kickoff_valid(p_fixture_id, p_kickoff_at);

  IF NOT public.match_schedule_club_available_at(
       v_fixture.season_id, v_club, p_kickoff_at
     )
  THEN
    RAISE EXCEPTION 'You are not available at that time — set weekly availability on Owner Details first';
  END IF;

  PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, p_kickoff_at);

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

  IF to_regprocedure('public.match_schedule_set_response_deadline(bigint, bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_set_response_deadline(p_fixture_id, v_proposal_id);
  END IF;

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

  IF to_regprocedure(
       'public.match_schedule_notify_proposer_sent(public.competition_fixtures, text, text, timestamptz, bigint, boolean)'
     ) IS NOT NULL
  THEN
    PERFORM public.match_schedule_notify_proposer_sent(
      v_fixture,
      v_club,
      v_opponent,
      p_kickoff_at,
      v_proposal_id,
      v_is_counter
    );
  END IF;

  RETURN v_proposal_id;
END;
$function$;

-- Accept: re-check clash (other bookings may have landed while pending)
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

  RETURN jsonb_build_object('ok', true, 'code', 'accepted');
END;
$function$;

-- Mutual override new time / play now: same clash rule
DO $$
DECLARE
  v_src text;
BEGIN
  -- Patch request function if present: inject busy assert after kickoff_valid
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'fixture_mutual_override_request'
  LIMIT 1;

  -- Always redefine a thin wrapper check used from a REPLACE below if needed.
  NULL;
END $$;

CREATE OR REPLACE FUNCTION public.match_schedule_assert_mutual_kickoff_ok(
  p_fixture_id bigint,
  p_kickoff timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.match_schedule_assert_kickoff_valid(p_fixture_id, p_kickoff);
  PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, p_kickoff);
END;
$function$;

-- Re-apply mutual override request body from latest known shape with clash check
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
    PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, v_kickoff);
  ELSE
    IF p_kickoff_at IS NULL THEN
      RAISE EXCEPTION 'New kick-off time is required';
    END IF;
    IF p_kickoff_at = v_schedule.agreed_kickoff_at THEN
      RAISE EXCEPTION 'Choose a different kick-off time';
    END IF;
    v_kickoff := p_kickoff_at;
    PERFORM public.match_schedule_assert_mutual_kickoff_ok(p_fixture_id, v_kickoff);
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
  v_title := CASE
    WHEN p_kind = 'play_now' THEN 'Play now requested'
    ELSE 'New kick-off requested'
  END;
  v_body := public.club_display_name(v_club) || CASE
    WHEN p_kind = 'play_now' THEN ' proposed play now at '
    ELSE ' proposed a new kick-off at '
  END || v_fmt || E'.\nConfirm in your inbox or on Schedule match. No reschedule allowance is used when both agree.';

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    'match_mutual_override_requested',
    v_title,
    v_body,
    v_opponent,
    'mutual:' || v_override_id::text || ':' || v_opponent,
    NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'override_id', v_override_id,
    'kind', p_kind,
    'proposed_kickoff_at', v_kickoff
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_club_busy_at(text, timestamptz, bigint, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_assert_kickoff_not_double_booked(bigint, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_assert_mutual_kickoff_ok(bigint, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_schedule_propose(bigint, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_schedule_accept(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_mutual_override_request(bigint, text, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_club_window_slots(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_intersection_slots(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
