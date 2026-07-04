-- =============================================================================
-- Match scheduling — Phase 3 response deadlines + missed-response fines
-- Run after: match_scheduling_catch_up.sql, match_scheduling_arrangement_fines.sql,
--            match_scheduling_inbox_proposer_sent.sql, fixture_schedule_accept_already.sql
-- =============================================================================
-- Rules:
--   • First home proposal (not catch-up): due at play-month unlock, unless proposed
--     in last 24h before play month → 48h from proposal.
--   • Each later counter/proposal: 24h from proposal time.
--   • Catch-up fixtures: always 24h per turn.
--   • Each miss: Missed scheduling response fine (default ₿2.5m) + extend 24h.
-- =============================================================================

INSERT INTO public.competition_fine_tariff (
  code, label, category, direction, amount, amount_mode, sort_order, is_active
)
VALUES (
  'match_response_deadline',
  'Missed scheduling response',
  'scheduling',
  'fine',
  2500000,
  'fixed',
  112,
  true
)
ON CONFLICT (code) DO UPDATE SET
  label = EXCLUDED.label,
  category = EXCLUDED.category,
  amount = EXCLUDED.amount,
  is_active = true,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- Schedule row: response deadline state
-- ---------------------------------------------------------------------------

ALTER TABLE public.competition_fixture_schedule
  ADD COLUMN IF NOT EXISTS response_due_at timestamptz,
  ADD COLUMN IF NOT EXISTS response_required_club_short_name text
    REFERENCES public."Clubs" ("ShortName"),
  ADD COLUMN IF NOT EXISTS response_miss_count smallint NOT NULL DEFAULT 0;

-- ---------------------------------------------------------------------------
-- Deadline calculation
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.match_schedule_compute_response_due_at(
  p_fixture_id bigint,
  p_proposal_id bigint,
  p_proposed_at timestamptz,
  p_proposer_club text
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_play_unlock timestamptz;
  v_is_first_proposal boolean;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN p_proposed_at + interval '24 hours';
  END IF;

  IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    RETURN p_proposed_at + interval '24 hours';
  END IF;

  SELECT cal.unlock_at INTO v_play_unlock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_fixture.season_id
    AND cal.gpsl_month = v_fixture.gpsl_month;

  SELECT NOT EXISTS (
    SELECT 1
    FROM public.competition_fixture_schedule_proposal p
    WHERE p.fixture_id = p_fixture_id
      AND p.id <> p_proposal_id
      AND p.status <> 'withdrawn'
  )
  INTO v_is_first_proposal;

  IF NOT v_is_first_proposal THEN
    RETURN p_proposed_at + interval '24 hours';
  END IF;

  IF v_play_unlock IS NOT NULL
     AND p_proposed_at >= v_play_unlock - interval '24 hours'
     AND p_proposed_at < v_play_unlock
  THEN
    RETURN p_proposed_at + interval '48 hours';
  END IF;

  IF v_play_unlock IS NOT NULL THEN
    RETURN v_play_unlock;
  END IF;

  RETURN p_proposed_at + interval '24 hours';
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_set_response_deadline(
  p_fixture_id bigint,
  p_proposal_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_proposal public.competition_fixture_schedule_proposal;
  v_fixture public.competition_fixtures;
  v_respondent text;
  v_due timestamptz;
BEGIN
  SELECT * INTO v_proposal
  FROM public.competition_fixture_schedule_proposal
  WHERE id = p_proposal_id
    AND fixture_id = p_fixture_id
    AND status = 'pending';

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  v_respondent := public.competition_fixture_opponent(
    p_fixture_id,
    v_proposal.proposed_by_club_short_name
  );

  v_due := public.match_schedule_compute_response_due_at(
    p_fixture_id,
    p_proposal_id,
    v_proposal.created_at,
    v_proposal.proposed_by_club_short_name
  );

  UPDATE public.competition_fixture_schedule
  SET
    response_due_at = v_due,
    response_required_club_short_name = v_respondent,
    response_miss_count = 0,
    updated_at = now()
  WHERE fixture_id = p_fixture_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_clear_response_deadline(p_fixture_id bigint)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.competition_fixture_schedule
  SET
    response_due_at = NULL,
    response_required_club_short_name = NULL,
    response_miss_count = 0,
    updated_at = now()
  WHERE fixture_id = p_fixture_id;
$$;

CREATE OR REPLACE FUNCTION public.match_schedule_response_deadline_json(
  p_fixture_id bigint,
  p_club text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s public.competition_fixture_schedule;
BEGIN
  SELECT * INTO v_s
  FROM public.competition_fixture_schedule
  WHERE fixture_id = p_fixture_id;

  IF NOT FOUND OR v_s.response_due_at IS NULL OR v_s.status <> 'negotiating' THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'due_at', v_s.response_due_at,
    'required_club_short_name', v_s.response_required_club_short_name,
    'miss_count', coalesce(v_s.response_miss_count, 0),
    'my_turn', (
      p_club IS NOT NULL
      AND p_club = v_s.response_required_club_short_name
    ),
    'overdue', v_s.response_due_at < now(),
    'due_at_uk', to_char(
      v_s.response_due_at AT TIME ZONE 'Europe/London',
      'Dy DD Mon YYYY HH24:MI'
    ) || ' UK'
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Enforce missed response deadlines (runs every cron tick)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_process_scheduling_response_deadlines(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_note_key text;
  v_note_body text;
  v_apply jsonb;
  v_miss_num smallint;
  v_fined jsonb := '[]'::jsonb;
  v_count int := 0;
BEGIN
  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_due_at,
      s.response_required_club_short_name,
      s.response_miss_count,
      f.gpsl_month,
      f.matchday,
      f.home_club_short_name,
      f.away_club_short_name
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'scheduled'
      AND s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND s.response_due_at IS NOT NULL
      AND s.response_required_club_short_name IS NOT NULL
      AND s.response_due_at < now()
      AND EXISTS (
        SELECT 1
        FROM public.competition_fixture_schedule_proposal p
        WHERE p.id = s.pending_proposal_id
          AND p.status = 'pending'
      )
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = s.response_required_club_short_name
          AND c.owner_id IS NOT NULL
      )
  LOOP
    WHILE v_row.response_due_at < now() LOOP
      v_miss_num := coalesce(v_row.response_miss_count, 0) + 1;

      v_note_key := format(
        'sched_response:%s:%s:%s',
        v_row.fixture_id,
        v_row.pending_proposal_id,
        v_miss_num
      );

      IF EXISTS (
        SELECT 1
        FROM public.competition_fine_applied fa
        WHERE fa.fixture_id = v_row.fixture_id
          AND fa.tariff_code = 'match_response_deadline'
          AND fa.note LIKE v_note_key || '%'
      ) THEN
        UPDATE public.competition_fixture_schedule
        SET
          response_due_at = response_due_at + interval '24 hours',
          response_miss_count = v_miss_num,
          updated_at = now()
        WHERE fixture_id = v_row.fixture_id;
        v_row.response_due_at := v_row.response_due_at + interval '24 hours';
        v_row.response_miss_count := v_miss_num;
        EXIT;
      END IF;

      v_note_body := format(
        '%s|Response deadline missed · %s fixture · MD%s · extended 24h (miss #%s)',
        v_note_key,
        public.competition_gpsl_month_label(v_row.gpsl_month),
        v_row.matchday,
        v_miss_num
      );

      v_apply := public.competition_apply_club_fine_tariff(
        v_row.response_required_club_short_name,
        'match_response_deadline',
        NULL,
        v_note_body,
        v_row.fixture_id,
        p_season_id
      );

      UPDATE public.competition_fixture_schedule
      SET
        response_due_at = response_due_at + interval '24 hours',
        response_miss_count = v_miss_num,
        updated_at = now()
      WHERE fixture_id = v_row.fixture_id;

      v_row.response_due_at := v_row.response_due_at + interval '24 hours';
      v_row.response_miss_count := v_miss_num;
      v_count := v_count + 1;

      v_fined := v_fined || jsonb_build_array(
        jsonb_build_object(
          'fixture_id', v_row.fixture_id,
          'club', v_row.response_required_club_short_name,
          'miss', v_miss_num,
          'apply', v_apply
        )
      );
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'fines_applied', v_count,
    'fined', v_fined
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Reset helper — clear response deadline
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.match_schedule_reset_to_unscheduled(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public.competition_fixture_schedule
  SET
    status = 'unscheduled',
    agreed_kickoff_at = NULL,
    pending_proposal_id = NULL,
    response_due_at = NULL,
    response_required_club_short_name = NULL,
    response_miss_count = 0,
    updated_at = now()
  WHERE fixture_id = p_fixture_id;

  DELETE FROM public.competition_fixture_checkin
  WHERE fixture_id = p_fixture_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Propose — set deadline after new pending proposal
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

  PERFORM public.match_schedule_set_response_deadline(p_fixture_id, v_proposal_id);

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

-- ---------------------------------------------------------------------------
-- Accept — clear deadline
-- ---------------------------------------------------------------------------

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

  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Fixture context — response_deadline (re-apply catch_up context with Phase 3 fields)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_context(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_schedule_found boolean := false;
  v_pending public.competition_fixture_schedule_proposal;
  v_override public.competition_fixture_mutual_override;
  v_role text;
  v_home text;
  v_away text;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_prop_unlock timestamptz;
  v_prop_lock timestamptz;
  v_prop_month text;
  v_prop_catch_up boolean := false;
  v_is_catch_up boolean := false;
  v_slots jsonb;
  v_status text;
  v_agreed timestamptz;
  v_home_count smallint;
  v_away_count smallint;
  v_discord_hint boolean;
  v_pending_id bigint;
  v_mutual_used boolean := false;
  v_kickoff timestamptz;
  v_home_in boolean := false;
  v_away_in boolean := false;
  v_my_in boolean := false;
  v_emergency_used integer;
  v_reschedule_used boolean;
  v_play_now_kickoff timestamptz;
  v_can_play_now boolean := false;
  v_can_mutual_new_time boolean := false;
  v_my_override_confirmed boolean := false;
  v_can_confirm_override boolean := false;
  v_can_cancel_override boolean := false;
  v_can_catch_up_reset boolean := false;
BEGIN
  PERFORM public.match_schedule_mutual_override_expire();
  v_club := public.my_club_shortname();
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fixture not found'; END IF;
  IF NOT public.is_gpsl_admin()
     AND v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name)
  THEN RAISE EXCEPTION 'You are not in this fixture'; END IF;
  PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  v_is_catch_up := public.match_schedule_fixture_is_catch_up(p_fixture_id);
  v_home := v_fixture.home_club_short_name;
  v_away := v_fixture.away_club_short_name;
  IF v_club = v_home THEN v_role := 'home';
  ELSIF v_club = v_away THEN v_role := 'away';
  ELSE v_role := 'admin'; END IF;
  SELECT * INTO v_schedule FROM public.competition_fixture_schedule WHERE fixture_id = p_fixture_id;
  v_schedule_found := FOUND;
  IF v_schedule_found THEN
    v_status := v_schedule.status;
    v_agreed := v_schedule.agreed_kickoff_at;
    v_home_count := v_schedule.home_proposal_count;
    v_away_count := v_schedule.away_proposal_count;
    v_discord_hint := v_schedule.discord_hint_shown;
    v_pending_id := v_schedule.pending_proposal_id;
    v_mutual_used := COALESCE(v_schedule.mutual_override_used, false);
  ELSE
    v_status := 'unscheduled'; v_agreed := NULL;
    v_home_count := 0; v_away_count := 0; v_discord_hint := false;
    v_pending_id := NULL; v_mutual_used := false;
  END IF;
  IF v_pending_id IS NOT NULL THEN
    SELECT * INTO v_pending FROM public.competition_fixture_schedule_proposal WHERE id = v_pending_id;
  END IF;
  SELECT * INTO v_override FROM public.competition_fixture_mutual_override
  WHERE fixture_id = p_fixture_id AND status = 'pending' ORDER BY created_at DESC LIMIT 1;
  SELECT w.unlock_at, w.lock_at INTO v_unlock, v_lock FROM public.match_schedule_fixture_month_window(p_fixture_id) w;
  SELECT w.unlock_at, w.lock_at, w.gpsl_month, w.is_catch_up
  INTO v_prop_unlock, v_prop_lock, v_prop_month, v_prop_catch_up
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('iso_dow', s.iso_dow, 'hour', s.slot_minute / 60, 'minute', s.slot_minute % 60) ORDER BY s.iso_dow, s.slot_minute), '[]'::jsonb)
  INTO v_slots FROM public.club_owner_availability_slot s
  WHERE s.season_id = v_fixture.season_id AND s.club_short_name = v_club;
  v_kickoff := v_agreed;
  IF v_kickoff IS NOT NULL THEN
    SELECT EXISTS (SELECT 1 FROM public.competition_fixture_checkin c WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_home) INTO v_home_in;
    SELECT EXISTS (SELECT 1 FROM public.competition_fixture_checkin c WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_away) INTO v_away_in;
    IF v_club IS NOT NULL THEN
      SELECT EXISTS (SELECT 1 FROM public.competition_fixture_checkin c WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_club) INTO v_my_in;
    END IF;
  END IF;
  v_emergency_used := public.match_schedule_emergency_drops_used(v_fixture.season_id, v_club);
  v_reschedule_used := public.match_schedule_reschedule_used_this_month(v_fixture.season_id, v_club, v_fixture.gpsl_month);
  IF v_is_catch_up AND v_fixture.status = 'scheduled' THEN
    v_can_catch_up_reset := v_status IN ('agreed', 'negotiating')
      AND (v_kickoff IS NULL OR v_kickoff < now() OR NOT public.match_schedule_kickoff_in_proposal_window(p_fixture_id, v_kickoff))
      AND v_override.id IS NULL;
  END IF;
  IF v_fixture.status = 'scheduled' AND v_status = 'agreed' AND v_agreed IS NOT NULL AND NOT v_mutual_used AND v_override.id IS NULL THEN
    BEGIN
      v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
      v_can_play_now := true;
    EXCEPTION WHEN OTHERS THEN
      v_can_play_now := false; v_play_now_kickoff := NULL;
    END;
    v_can_mutual_new_time := now() < v_agreed;
  END IF;
  IF v_override.id IS NOT NULL AND v_club IS NOT NULL THEN
    IF v_club = v_home THEN v_my_override_confirmed := v_override.home_confirmed_at IS NOT NULL;
    ELSE v_my_override_confirmed := v_override.away_confirmed_at IS NOT NULL; END IF;
    v_can_confirm_override := NOT v_my_override_confirmed AND v_override.requested_by_club <> v_club;
    v_can_cancel_override := v_my_override_confirmed OR v_override.requested_by_club = v_club;
  END IF;
  RETURN jsonb_build_object(
    'fixture', jsonb_build_object('id', v_fixture.id, 'gpsl_month', v_fixture.gpsl_month, 'division', v_fixture.division, 'cup_code', v_fixture.cup_code, 'home_club_short_name', v_home, 'away_club_short_name', v_away, 'status', v_fixture.status, 'competition_type', v_fixture.competition_type, 'is_forfeit', v_fixture.is_forfeit, 'is_catch_up', v_is_catch_up),
    'schedule', jsonb_build_object('status', v_status, 'agreed_kickoff_at', v_agreed, 'home_proposal_count', v_home_count, 'away_proposal_count', v_away_count, 'discord_hint_shown', v_discord_hint, 'mutual_override_used', v_mutual_used, 'response_due_at', CASE WHEN v_schedule_found THEN v_schedule.response_due_at ELSE NULL END, 'response_required_club_short_name', CASE WHEN v_schedule_found THEN v_schedule.response_required_club_short_name ELSE NULL END, 'response_miss_count', CASE WHEN v_schedule_found THEN coalesce(v_schedule.response_miss_count, 0) ELSE 0 END),
    'pending_proposal', CASE WHEN v_pending.id IS NULL THEN NULL ELSE jsonb_build_object('id', v_pending.id, 'proposed_by_club_short_name', v_pending.proposed_by_club_short_name, 'kickoff_at', v_pending.kickoff_at) END,
    'mutual_override', CASE WHEN v_override.id IS NULL THEN NULL ELSE jsonb_build_object('id', v_override.id, 'kind', v_override.kind, 'proposed_kickoff_at', v_override.proposed_kickoff_at, 'requested_by_club_short_name', v_override.requested_by_club, 'expires_at', v_override.expires_at, 'my_confirmed', v_my_override_confirmed, 'can_confirm', v_can_confirm_override, 'can_cancel', v_can_cancel_override) END,
    'my_role', v_role, 'is_catch_up', v_is_catch_up,
    'month_window', jsonb_build_object('unlock_at', v_unlock, 'lock_at', v_lock),
    'proposal_window', jsonb_build_object('unlock_at', v_prop_unlock, 'lock_at', v_prop_lock, 'gpsl_month', v_prop_month, 'is_catch_up', coalesce(v_prop_catch_up, false)),
    'my_timezone', public.match_schedule_club_timezone(v_club),
    'home_timezone', public.match_schedule_club_timezone(v_home),
    'away_timezone', public.match_schedule_club_timezone(v_away),
    'my_weekly_slots', v_slots,
    'intersection_slots', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), '[]'::jsonb) FROM public.match_schedule_intersection_slots(p_fixture_id) i),
    'can_propose_first', (v_role = 'home' AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled'),
    'can_respond', (v_pending.id IS NOT NULL AND v_pending.proposed_by_club_short_name <> v_club AND v_status = 'negotiating'),
    'response_deadline', public.match_schedule_response_deadline_json(p_fixture_id, v_club),
    'mutual_override_options', jsonb_build_object('can_request_play_now', v_can_play_now, 'play_now_kickoff_at', v_play_now_kickoff, 'can_request_new_time', v_can_mutual_new_time),
    'checkin', jsonb_build_object('home_checked_in', v_home_in, 'away_checked_in', v_away_in, 'my_checked_in', v_my_in, 'window_opens_at', v_kickoff, 'window_closes_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval END, 'play_block_ends_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval END, 'can_check_in', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval AND NOT v_my_in), 'can_play', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND v_home_in AND v_away_in AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval)),
    'allowances', jsonb_build_object('emergency_drops_used', v_emergency_used, 'emergency_drops_remaining', greatest(0, 2 - v_emergency_used), 'reschedule_used_this_month', v_reschedule_used, 'can_voluntary_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() <= v_kickoff - interval '24 hours' AND NOT v_reschedule_used AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_emergency_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() < v_kickoff AND now() > v_kickoff - interval '24 hours' AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_catch_up_reset', v_can_catch_up_reset)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Fixtures view — expose response deadline on list
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.competition_cup_qualified_public;
DROP VIEW IF EXISTS public.competition_cup_bracket_public;
DROP VIEW IF EXISTS public.competition_fixtures_public;

CREATE VIEW public.competition_fixtures_public
WITH (security_invoker = false)
AS
SELECT
  f.id,
  f.season_id,
  f.division,
  f.competition_type,
  f.cup_code,
  f.cup_round,
  f.cup_match,
  f.matchday,
  f.gpsl_month,
  f.week_in_month,
  f.home_club_short_name,
  hc."Club" AS home_club_name,
  f.away_club_short_name,
  ac."Club" AS away_club_name,
  f.weather,
  f.pitch_condition,
  f.kit_season,
  public.competition_club_continent(f.home_club_short_name) AS home_continent,
  f.home_goals,
  f.away_goals,
  f.status,
  f.is_forfeit,
  public.match_schedule_fixture_is_catch_up(f.id) AS is_catch_up,
  sub.submission_id,
  sub.submission_status,
  sub.submitted_by_club,
  sub.proposed_home_goals,
  sub.proposed_away_goals,
  sub.proposed_et_home_goals,
  sub.proposed_et_away_goals,
  sub.proposed_pen_winner_club,
  COALESCE(sch.status, 'unscheduled') AS schedule_status,
  sch.agreed_kickoff_at,
  sch.pending_proposal_id AS schedule_pending_proposal_id,
  sch.home_proposal_count AS schedule_home_proposal_count,
  sch.away_proposal_count AS schedule_away_proposal_count,
  COALESCE(sch.discord_hint_shown, false) AS schedule_discord_hint,
  sch.response_due_at AS schedule_response_due_at,
  sch.response_required_club_short_name AS schedule_response_required_club,
  chk.home_checked_in,
  chk.away_checked_in
FROM public.competition_fixtures f
JOIN public.competition_seasons s ON s.id = f.season_id
JOIN public."Clubs" hc ON hc."ShortName" = f.home_club_short_name
JOIN public."Clubs" ac ON ac."ShortName" = f.away_club_short_name
LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
LEFT JOIN LATERAL (
  SELECT
    EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
    ) AS home_checked_in,
    EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
    ) AS away_checked_in
) chk ON true
LEFT JOIN LATERAL (
  SELECT
    rs.id AS submission_id,
    rs.status AS submission_status,
    rs.submitted_by_club,
    rs.home_goals AS proposed_home_goals,
    rs.away_goals AS proposed_away_goals,
    rs.et_home_goals AS proposed_et_home_goals,
    rs.et_away_goals AS proposed_et_away_goals,
    rs.pen_winner_club_short_name AS proposed_pen_winner_club
  FROM public.competition_result_submissions rs
  WHERE rs.fixture_id = f.id
    AND rs.status = 'pending'
    AND (
      public.is_gpsl_admin()
      OR public.my_club_shortname() = f.home_club_short_name
      OR public.my_club_shortname() = f.away_club_short_name
    )
  LIMIT 1
) sub ON true
WHERE s.status = 'active' AND s.is_current = true;

CREATE VIEW public.competition_cup_bracket_public
WITH (security_invoker = false)
AS
SELECT
  n.id,
  n.season_id,
  n.cup_code,
  n.round_no,
  n.match_no,
  n.cup_leg,
  n.leg1_node_id,
  sch.round_label,
  sch.gpsl_month AS round_gpsl_month,
  n.home_club_short_name,
  hc."Club" AS home_club_name,
  n.away_club_short_name,
  ac."Club" AS away_club_name,
  n.winner_club_short_name,
  wc."Club" AS winner_club_name,
  n.fixture_id,
  f.status AS fixture_status,
  f.home_goals,
  f.away_goals,
  f.gpsl_month AS fixture_gpsl_month,
  f.weather,
  f.pitch_condition,
  f.kit_season,
  public.competition_club_continent(n.home_club_short_name) AS home_continent,
  n.child_node_id,
  n.child_slot
FROM public.competition_cup_bracket_nodes n
JOIN public.competition_seasons s ON s.id = n.season_id
LEFT JOIN public.competition_cup_round_schedule sch
  ON sch.cup_code = n.cup_code
 AND sch.round_no = n.round_no
 AND sch.cup_leg = coalesce(n.cup_leg, 1)
LEFT JOIN public."Clubs" hc ON hc."ShortName" = n.home_club_short_name
LEFT JOIN public."Clubs" ac ON ac."ShortName" = n.away_club_short_name
LEFT JOIN public."Clubs" wc ON wc."ShortName" = n.winner_club_short_name
LEFT JOIN public.competition_fixtures f ON f.id = n.fixture_id
WHERE s.status = 'active' AND s.is_current = true;

CREATE VIEW public.competition_cup_qualified_public
WITH (security_invoker = false)
AS
SELECT s.id AS season_id, cup.cup_code, q.club_short_name
FROM public.competition_seasons s
CROSS JOIN (VALUES ('super8'), ('plate'), ('shield'), ('spoon'), ('league_cup')) AS cup(cup_code)
CROSS JOIN LATERAL unnest(public.competition_qualify_cup_clubs(s.id, cup.cup_code)) AS q(club_short_name)
WHERE s.is_current = true AND s.status = 'active';

GRANT SELECT ON public.competition_fixtures_public TO authenticated;
GRANT SELECT ON public.competition_fixtures_public TO anon;
GRANT SELECT ON public.competition_cup_bracket_public TO authenticated;
GRANT SELECT ON public.competition_cup_bracket_public TO anon;
GRANT SELECT ON public.competition_cup_qualified_public TO authenticated;

-- Backfill deadlines for existing pending proposals
DO $$
DECLARE
  v_row record;
BEGIN
  FOR v_row IN
    SELECT s.fixture_id, s.pending_proposal_id
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND f.status = 'scheduled'
      AND f.competition_type = 'league'
  LOOP
    PERFORM public.match_schedule_set_response_deadline(
      v_row.fixture_id,
      v_row.pending_proposal_id
    );
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Month tick — response deadline enforcement (every minute)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_calendar_month_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_month_sort smallint;
  v_august_sort constant smallint := public.competition_gpsl_month_sort('august');
  v_job_id bigint;
  v_enforcement jsonb;
  v_totm jsonb;
  v_sched_fines jsonb;
  v_response_fines jsonb;
  v_out jsonb;
BEGIN
  SELECT id
  INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
    AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_season_id
  ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_calendar',
      'season_id', v_season_id
    );
  END IF;

  v_month := public.competition_active_gpsl_month(v_season_id, now());
  v_month_sort := public.competition_gpsl_month_sort(v_month);

  v_out := jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'calendar_phase', CASE
      WHEN v_month IS NULL THEN 'between_months'
      ELSE 'in_month'
    END
  );

  IF to_regprocedure('public.competition_process_month_team_awards(bigint)') IS NOT NULL THEN
    v_totm := public.competition_process_month_team_awards(v_season_id);
    v_out := v_out || jsonb_build_object('team_of_month', v_totm);
  END IF;

  v_response_fines := public.competition_process_scheduling_response_deadlines(v_season_id);
  v_out := v_out || jsonb_build_object('scheduling_response_deadlines', v_response_fines);

  v_sched_fines := public.competition_process_scheduling_arrangement_fines(v_season_id);
  v_out := v_out || jsonb_build_object('scheduling_arrangement_fines', v_sched_fines);

  IF v_month IS NULL OR v_month_sort IS NULL OR v_month_sort < v_august_sort THEN
    RETURN v_out || jsonb_build_object(
      'squad_minimum_august', jsonb_build_object('skipped', true, 'reason', 'before_august')
    );
  END IF;

  INSERT INTO public.competition_season_calendar_jobs (
    season_id, job_key, gpsl_month, result
  )
  VALUES (
    v_season_id,
    'squad_minimum_august',
    v_month,
    jsonb_build_object('status', 'running')
  )
  ON CONFLICT (season_id, job_key) DO NOTHING
  RETURNING id INTO v_job_id;

  IF v_job_id IS NULL THEN
    RETURN v_out || jsonb_build_object(
      'squad_minimum_august', jsonb_build_object('skipped', true, 'reason', 'already_ran')
    );
  END IF;

  v_enforcement := public.competition_enforce_squad_minimum_august(v_season_id);

  UPDATE public.competition_season_calendar_jobs
  SET result = v_enforcement,
      gpsl_month = v_month,
      ran_at = now()
  WHERE id = v_job_id;

  RETURN v_out || jsonb_build_object('squad_minimum_august', v_enforcement);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_process_scheduling_response_deadlines(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.match_schedule_response_deadline_json(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
