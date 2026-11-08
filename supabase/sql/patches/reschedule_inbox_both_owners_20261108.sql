-- =============================================================================
-- Reschedule inbox: both owners (2026-11-08)
--
-- These currently told only the other club. After this, both owners get the
-- same inbox note:
--   • Agreed on Discord (request, lock applied already did both, decline/cancel)
--   • Mutual new time / bring kick-off forward
--   • Play now press, and Play now reset
--   • Voluntary drop, emergency drop, catch-up / replay reset
--   • Already played press (the waiting note)
--
-- Normal GPSL propose / counter is unchanged: the other club still gets the
-- request, and the sender still gets the existing "you sent this" note.
--
-- Safe re-run. Does not move a kick-off.
-- =============================================================================

-- Play now press uses this type. If it is missing from the inbox check,
-- the note is thrown away.
DO $inbox$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NULL OR position('''match_play_now_pressed''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t) INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION SELECT 'match_play_now_pressed'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;
  EXECUTE format(
    'ALTER TABLE public.competition_inbox ADD CONSTRAINT competition_inbox_message_type_check CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );
  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END
$inbox$;

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
  v_actor text;
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

  -- Reschedule / mutual time changes: the club who started it gets a copy too.
  IF p_message_type IN (
    'match_mutual_override_requested',
    'match_mutual_override_cancelled',
    'match_rescheduled',
    'match_emergency_drop',
    'match_play_now_pressed',
    'match_already_played'
  ) THEN
    v_actor := CASE
      WHEN p_opponent_club = p_fixture.home_club_short_name THEN p_fixture.away_club_short_name
      WHEN p_opponent_club = p_fixture.away_club_short_name THEN p_fixture.home_club_short_name
      ELSE NULL
    END;

    IF v_actor IS NOT NULL AND v_actor IS DISTINCT FROM p_opponent_club THEN
      PERFORM public.owner_inbox_send(
        p_message_type,
        v_title,
        v_body,
        v_actor,
        NULL,
        p_fixture.id,
        NULL, NULL, NULL,
        v_href,
        'schedule:' || p_fixture.id::text || ':' || p_dedupe_suffix || ':both',
        p_fixture.gpsl_month,
        p_fixture.season_id,
        p_proposal_id
      );
    END IF;
  END IF;
END;
$function$;

-- Discord / mutual cancel told only the other club, and only on a decline.
CREATE OR REPLACE FUNCTION public.fixture_mutual_override_cancel(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_override public.competition_fixture_mutual_override;
  v_n integer;
  v_fmt text;
  v_declined boolean;
  v_title text;
  v_body text;
BEGIN
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

  SELECT * INTO v_override
  FROM public.competition_fixture_mutual_override
  WHERE fixture_id = p_fixture_id
    AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'no_pending',
      'message', 'No pending mutual override to cancel.'
    );
  END IF;

  v_declined := v_override.requested_by_club IS DISTINCT FROM v_club;

  UPDATE public.competition_fixture_mutual_override
  SET status = 'cancelled'
  WHERE id = v_override.id
    AND status = 'pending';

  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'no_pending',
      'message', 'No pending mutual override to cancel.'
    );
  END IF;

  BEGIN
    v_fmt := to_char(
      timezone('Europe/London', v_override.proposed_kickoff_at),
      'Dy DD Mon YYYY HH24:MI'
    ) || ' UK';
  EXCEPTION WHEN OTHERS THEN
    v_fmt := coalesce(v_override.proposed_kickoff_at::text, 'the proposed time');
  END;

  v_title := CASE
    WHEN v_declined THEN 'Discord kick-off declined'
    ELSE 'Discord kick-off cancelled'
  END;
  v_body := coalesce(public.club_display_name(v_club), v_club)
    || CASE WHEN v_declined THEN ' declined' ELSE ' cancelled' END
    || ' the Discord lock for '
    || v_fmt
    || E'.\nPropose a time on Schedule match, or agree on Discord and lock again.';

  BEGIN
    PERFORM public.match_schedule_notify_pair(
      v_fixture,
      'match_mutual_override_cancelled',
      v_title,
      v_body,
      NULL,
      'mutual_cancel:' || v_override.id::text
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'mutual cancel inbox failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'declined', v_declined,
    'message', CASE
      WHEN v_declined THEN 'Declined — Discord lock cancelled. Propose or agree a different time.'
      ELSE 'Mutual override cancelled.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_mutual_override_cancel(bigint) TO authenticated;

-- Play now reset had no inbox note.
CREATE OR REPLACE FUNCTION public.fixture_play_now_reset(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_sess public.competition_fixture_play_now_session;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture not open';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_result_submissions rs
    WHERE rs.fixture_id = p_fixture_id AND rs.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A result is pending confirmation — confirm or reject it before resetting Play now';
  END IF;

  SELECT * INTO v_sess
  FROM public.competition_fixture_play_now_session
  WHERE fixture_id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND OR v_sess.status NOT IN ('open', 'both_ready', 'miss_open') THEN
    RAISE EXCEPTION 'No active Play now session to reset';
  END IF;

  DELETE FROM public.competition_fixture_checkin WHERE fixture_id = p_fixture_id;

  UPDATE public.competition_fixture_play_now_session
  SET status = 'resolved_reset',
      ko_forfeit_suspended = false,
      updated_at = now()
  WHERE fixture_id = p_fixture_id;

  BEGIN
    PERFORM public.match_schedule_notify_pair(
      v_fixture,
      'match_play_now_pressed',
      'Play now cleared',
      coalesce(public.club_display_name(v_club), v_club)
        || ' cleared Play now. The original agreed kick-off still stands.',
      NULL,
      'playnow_reset:' || p_fixture_id::text || ':' || v_sess.updated_at::text
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'play now reset inbox failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'message', 'Play now cleared — original agreed kick-off still stands'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fixture_play_now_reset(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fixture_play_now_reset(bigint) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

SELECT
  position(
    'match_play_now_pressed'
    IN pg_get_functiondef(
      'public.match_schedule_notify_opponent(public.competition_fixtures,text,text,text,text,text,bigint)'::regprocedure
    )
  ) > 0 AS opponent_copies_reschedules,
  position(
    'match_schedule_notify_pair'
    IN pg_get_functiondef('public.fixture_mutual_override_cancel(bigint)'::regprocedure)
  ) > 0 AS cancel_notifies_both,
  position(
    'Play now cleared'
    IN pg_get_functiondef('public.fixture_play_now_reset(bigint)'::regprocedure)
  ) > 0 AS play_now_reset_notifies;
