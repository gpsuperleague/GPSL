-- =============================================================================
-- Scheduling flexibility: Discord kick-off lock + softer fines (2026-10-18)
--
-- • Mutual override new_time works before kick-off is agreed (Discord lock path)
--   — does not burn mutual_override_used; sets status=agreed on apply
-- • No-show record → Inbox warning to both clubs; tariff ₿2.5m
-- • Tariffs: no-proposal ₿2.5m, late arrangement ₿1m, no-show ₿2.5m
-- • First overdue reply at month lock → warning only; later locks → ₿2.5m
--
-- Safe re-run. Apply in Supabase after merge.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.competition_fixture_schedule
  ADD COLUMN IF NOT EXISTS response_deadline_warned_at timestamptz;

-- ---------------------------------------------------------------------------
-- Inbox message types
-- ---------------------------------------------------------------------------
DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NOT NULL
     AND position('''match_noshow_recorded''' IN v_def) > 0
     AND position('''match_response_deadline_warning''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t) INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t FROM public.competition_inbox WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION SELECT 'match_noshow_recorded'
    UNION SELECT 'match_response_deadline_warning'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;
  EXECUTE format(
    'ALTER TABLE public.competition_inbox ADD CONSTRAINT competition_inbox_message_type_check CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );
  ALTER TABLE public.competition_inbox VALIDATE CONSTRAINT competition_inbox_message_type_check;
END
$inbox_types$;

-- ---------------------------------------------------------------------------
-- Tariffs
-- ---------------------------------------------------------------------------
UPDATE public.competition_fine_tariff
SET
  amount = 2500000,
  label = 'Match Management Fine (no proposal)',
  is_active = true,
  updated_at = now()
WHERE code = 'match_mgmt_no_proposal';

UPDATE public.competition_fine_tariff
SET
  amount = 1000000,
  label = 'Late Arrangement Fee',
  is_active = true,
  updated_at = now()
WHERE code = 'match_late_arrangement';

UPDATE public.competition_fine_tariff
SET
  amount = 2500000,
  label = 'No-show at agreed kick-off',
  is_active = true,
  updated_at = now()
WHERE code = 'match_agreed_no_show';

UPDATE public.competition_fine_tariff
SET
  amount = 2500000,
  label = 'Missed scheduling response',
  is_active = true,
  updated_at = now()
WHERE code = 'match_response_deadline';

-- ---------------------------------------------------------------------------
-- Discord / pre-agree mutual lock: request
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
  v_pre_agree boolean;
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
  v_pre_agree := coalesce(v_schedule.status, 'unscheduled') <> 'agreed'
    OR v_schedule.agreed_kickoff_at IS NULL;

  IF p_kind NOT IN ('play_now', 'new_time') THEN
    RAISE EXCEPTION 'Invalid mutual override kind';
  END IF;

  IF v_pre_agree THEN
    -- Discord / first lock: only new_time (datetime pick). Does not use mutual allowance.
    IF p_kind <> 'new_time' THEN
      RAISE EXCEPTION 'Agree a kick-off on the schedule page first (or use Discord lock with a chosen time)';
    END IF;
    IF p_kickoff_at IS NULL THEN
      RAISE EXCEPTION 'Kick-off time is required';
    END IF;
    PERFORM public.match_schedule_assert_mutual_kickoff_ok(p_fixture_id, p_kickoff_at);
    v_kickoff := p_kickoff_at;
  ELSE
    IF v_schedule.mutual_override_used THEN
      RAISE EXCEPTION 'This fixture has already used its one mutual kick-off change';
    END IF;

    IF p_kind = 'play_now' THEN
      v_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
      IF to_regprocedure('public.match_schedule_assert_kickoff_not_double_booked(bigint,timestamptz)') IS NOT NULL THEN
        PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, v_kickoff);
      END IF;
    ELSE
      IF p_kickoff_at IS NULL THEN
        RAISE EXCEPTION 'New kick-off time is required';
      END IF;
      IF p_kickoff_at = v_schedule.agreed_kickoff_at THEN
        RAISE EXCEPTION 'Choose a different kick-off time';
      END IF;
      v_kickoff := p_kickoff_at;
      IF to_regprocedure('public.match_schedule_assert_mutual_kickoff_ok(bigint,timestamptz)') IS NOT NULL THEN
        PERFORM public.match_schedule_assert_mutual_kickoff_ok(p_fixture_id, v_kickoff);
      ELSE
        PERFORM public.match_schedule_assert_kickoff_valid(p_fixture_id, v_kickoff);
      END IF;
    END IF;
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

  IF v_pre_agree THEN
    v_title := 'Discord kick-off — confirm?';
    v_body := coalesce(public.club_display_name(v_club), v_club)
      || ' wants to lock the Discord-agreed kick-off at '
      || v_fmt
      || E'.\nConfirm in your inbox or on Schedule match. Reply and arrangement deadlines keep running until both lock.';
  ELSIF p_kind = 'play_now' THEN
    v_title := 'Play now requested';
    v_body := coalesce(public.club_display_name(v_club), v_club)
      || ' proposed play now at '
      || v_fmt
      || E'.\nConfirm in your inbox or on Schedule match. No reschedule allowance is used when both agree.';
  ELSE
    v_title := 'New kick-off requested';
    v_body := coalesce(public.club_display_name(v_club), v_club)
      || ' proposed a new kick-off at '
      || v_fmt
      || E'.\nConfirm in your inbox or on Schedule match. No reschedule allowance is used when both agree.';
  END IF;

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
    'proposed_kickoff_at', v_kickoff,
    'pre_agree_lock', v_pre_agree,
    'awaiting_opponent', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_mutual_override_request(bigint, text, timestamptz) TO authenticated;

-- ---------------------------------------------------------------------------
-- Apply: first lock sets agreed without burning mutual; change burns it
-- ---------------------------------------------------------------------------
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

  -- Supersede any open proposals when locking from Discord / negotiation
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
    mutual_override_used = CASE
      WHEN v_was_agreed THEN true
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

-- ---------------------------------------------------------------------------
-- No-show record → Inbox both clubs
-- ---------------------------------------------------------------------------
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
  v_prev text;
  v_fmt text;
  v_href text;
  v_body text;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RETURN false;
  END IF;

  PERFORM public.match_schedule_clear_no_show_if_played(p_fixture_id);

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
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  IF NOT v_home_in AND NOT v_away_in THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  IF v_home_in AND NOT v_away_in THEN
    v_loser := v_fixture.away_club_short_name;
    v_winner := v_fixture.home_club_short_name;
  ELSE
    v_loser := v_fixture.home_club_short_name;
    v_winner := v_fixture.away_club_short_name;
  END IF;

  SELECT s.no_show_club_short_name
  INTO v_prev
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id;

  UPDATE public.competition_fixture_schedule
  SET
    no_show_club_short_name = v_loser,
    no_show_kickoff_at = v_kickoff,
    updated_at = now()
  WHERE fixture_id = p_fixture_id;

  -- Notify both clubs once when first recorded (or loser changes)
  IF v_prev IS DISTINCT FROM v_loser THEN
    v_fmt := public.match_schedule_format_kickoff_uk(v_kickoff);
    v_href := 'fixture_schedule.html?fixture=' || p_fixture_id::text;
    v_body :=
      'A one-sided no-show was recorded for kick-off '
      || v_fmt
      || E'.\n'
      || coalesce(public.club_display_name(v_loser), v_loser)
      || ' did not check in; '
      || coalesce(public.club_display_name(v_winner), v_winner)
      || E' did.\nYou can still play and confirm a normal result to clear this. '
      || E'If the match is still unfinished at the next GPSL month lock, the no-show club gets 3–0 and a ₿2.5m fine.';

    PERFORM public.owner_inbox_send(
      'match_noshow_recorded',
      'No-show recorded — still playable',
      v_body,
      v_fixture.home_club_short_name,
      NULL,
      p_fixture_id,
      NULL, NULL, NULL,
      v_href,
      'noshow:' || p_fixture_id::text || ':' || v_loser || ':home',
      v_fixture.gpsl_month,
      v_fixture.season_id,
      NULL
    );
    PERFORM public.owner_inbox_send(
      'match_noshow_recorded',
      'No-show recorded — still playable',
      v_body,
      v_fixture.away_club_short_name,
      NULL,
      p_fixture_id,
      NULL, NULL, NULL,
      v_href,
      'noshow:' || p_fixture_id::text || ':' || v_loser || ':away',
      v_fixture.gpsl_month,
      v_fixture.season_id,
      NULL
    );
  END IF;

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Clear response warning when clocks reset
-- ---------------------------------------------------------------------------
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
    response_deadline_warned_at = NULL,
    updated_at = now()
  WHERE fixture_id = p_fixture_id;
$$;

-- ---------------------------------------------------------------------------
-- Month lock: first overdue reply = warning; later locks = fine
-- Based on fine_note_summaries + rules (overdue only, holiday suppress, catch-up)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_enforce_scheduling_response_fines(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_lock timestamptz;
  v_note_key text;
  v_note_body text;
  v_apply jsonb;
  v_fined jsonb := '[]'::jsonb;
  v_warned jsonb := '[]'::jsonb;
  v_count int := 0;
  v_warn_count int := 0;
  v_skipped int := 0;
  v_holiday int := 0;
  v_side text;
  v_opponent text;
  v_reason text;
  v_href text;
  v_warn_body text;
BEGIN
  SELECT c.lock_at
  INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = p_closed_gpsl_month;

  IF v_lock IS NULL OR v_lock > now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_not_closed',
      'closed_gpsl_month', p_closed_gpsl_month
    );
  END IF;

  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_required_club_short_name,
      s.response_miss_count,
      s.response_due_at,
      s.response_deadline_warned_at,
      f.gpsl_month,
      f.matchday,
      f.home_club_short_name,
      f.away_club_short_name
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = p_season_id
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND s.response_required_club_short_name IS NOT NULL
      AND s.response_due_at IS NOT NULL
      AND s.response_due_at < v_lock
      AND (
        f.gpsl_month = p_closed_gpsl_month
        OR public.match_schedule_fixture_is_catch_up(f.id)
      )
      AND (
        to_regprocedure('public.match_schedule_fixture_within_play_window(bigint,timestamptz)') IS NULL
        OR public.match_schedule_fixture_within_play_window(f.id, v_lock)
      )
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
    IF to_regprocedure('public.match_schedule_club_on_holiday_for_month(bigint,text,text)') IS NOT NULL
       AND public.match_schedule_club_on_holiday_for_month(
         p_season_id, v_row.response_required_club_short_name, p_closed_gpsl_month
       ) THEN
      v_holiday := v_holiday + 1;
      CONTINUE;
    END IF;

    v_href := 'fixture_schedule.html?fixture=' || v_row.fixture_id::text;

    -- First lock while overdue: warning only (same-lock re-run skips fine)
    IF v_row.response_deadline_warned_at IS NULL THEN
      v_note_key := format(
        'sched_response_warn:%s:%s',
        p_closed_gpsl_month,
        v_row.fixture_id
      );

      UPDATE public.competition_fixture_schedule
      SET
        response_deadline_warned_at = coalesce(response_deadline_warned_at, now()),
        updated_at = now()
      WHERE fixture_id = v_row.fixture_id;

      v_warn_body :=
        'Your scheduling reply was still overdue when '
        || public.competition_gpsl_month_label(p_closed_gpsl_month)
        || E' locked.\nThis is a warning only — no fine this lock. '
        || E'Reply on Schedule / Inbox. If you are still overdue at a later month lock, you will be fined ₿2.5m.';

      PERFORM public.owner_inbox_send(
        'match_response_deadline_warning',
        'Scheduling reply overdue — warning',
        v_warn_body,
        v_row.response_required_club_short_name,
        NULL,
        v_row.fixture_id,
        NULL, NULL, NULL,
        v_href,
        v_note_key || ':' || v_row.response_required_club_short_name,
        p_closed_gpsl_month,
        p_season_id,
        NULL
      );

      v_warn_count := v_warn_count + 1;
      v_warned := v_warned || jsonb_build_array(
        jsonb_build_object(
          'fixture_id', v_row.fixture_id,
          'club', v_row.response_required_club_short_name
        )
      );
      CONTINUE;
    END IF;

    IF v_row.response_deadline_warned_at >= v_lock THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- Already warned at a prior lock → fine
    v_note_key := format(
      'sched_response_lock:%s:%s',
      p_closed_gpsl_month,
      v_row.fixture_id
    );

    IF EXISTS (
      SELECT 1
      FROM public.competition_fine_applied fa
      WHERE fa.fixture_id = v_row.fixture_id
        AND fa.tariff_code = 'match_response_deadline'
        AND fa.note LIKE v_note_key || '%'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF upper(btrim(v_row.response_required_club_short_name))
         = upper(btrim(v_row.home_club_short_name)) THEN
      v_side := 'home';
      v_reason := 'home reply fail';
      v_opponent := coalesce(
        public.club_display_name(v_row.away_club_short_name),
        v_row.away_club_short_name
      );
    ELSE
      v_side := 'away';
      v_reason := 'Away reply fail';
      v_opponent := coalesce(
        public.club_display_name(v_row.home_club_short_name),
        v_row.home_club_short_name
      );
    END IF;

    v_note_body := format(
      '%s|%s · MD%s vs %s · after prior warning',
      v_note_key,
      v_reason,
      v_row.matchday,
      coalesce(v_opponent, '?')
    );

    v_apply := public.competition_apply_club_fine_tariff(
      v_row.response_required_club_short_name,
      'match_response_deadline',
      NULL,
      v_note_body,
      v_row.fixture_id,
      p_season_id
    );

    v_count := v_count + 1;
    v_fined := v_fined || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_row.fixture_id,
        'club', v_row.response_required_club_short_name,
        'side', v_side,
        'apply', v_apply
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'fines_applied', v_count,
    'warnings_sent', v_warn_count,
    'skipped', v_skipped,
    'holiday_suppressed', v_holiday,
    'fined', v_fined,
    'warned', v_warned
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_enforce_scheduling_response_fines(bigint, text) TO service_role;

CREATE OR REPLACE FUNCTION public.match_schedule_on_response_clock_reset()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.response_due_at IS NULL
     AND NEW.response_required_club_short_name IS NULL
     AND coalesce(NEW.response_miss_count, 0) = 0 THEN
    NEW.response_deadline_warned_at := NULL;
  END IF;
  -- Fresh turn: new due / required club clears prior warning
  IF TG_OP = 'UPDATE'
     AND (
       NEW.response_due_at IS DISTINCT FROM OLD.response_due_at
       OR NEW.response_required_club_short_name IS DISTINCT FROM OLD.response_required_club_short_name
     )
     AND NEW.response_due_at IS NOT NULL THEN
    NEW.response_deadline_warned_at := NULL;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_match_schedule_response_warn_reset ON public.competition_fixture_schedule;
CREATE TRIGGER trg_match_schedule_response_warn_reset
  BEFORE UPDATE ON public.competition_fixture_schedule
  FOR EACH ROW
  EXECUTE FUNCTION public.match_schedule_on_response_clock_reset();

NOTIFY pgrst, 'reload schema';
