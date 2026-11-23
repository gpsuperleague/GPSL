-- Up to three ranked kick-off choices on one proposal.
-- One reply clock, one proposal count. Only the accepted time is booked.
-- Safe re-run.

ALTER TABLE public.competition_fixture_schedule_proposal
  ADD COLUMN IF NOT EXISTS kickoff_at_2 timestamptz,
  ADD COLUMN IF NOT EXISTS kickoff_at_3 timestamptz;

COMMENT ON COLUMN public.competition_fixture_schedule_proposal.kickoff_at IS
  'First-choice kick-off. After a 2nd or 3rd choice is accepted, this becomes the chosen time.';
COMMENT ON COLUMN public.competition_fixture_schedule_proposal.kickoff_at_2 IS
  'Optional second-choice kick-off on the same offer. Not a booking.';
COMMENT ON COLUMN public.competition_fixture_schedule_proposal.kickoff_at_3 IS
  'Optional third-choice kick-off on the same offer. Not a booking.';

-- Grey out every choice already offered, not only the first.
CREATE OR REPLACE FUNCTION public.match_schedule_prior_proposed_kickoffs(p_fixture_id bigint)
RETURNS TABLE (kickoff_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
  SELECT DISTINCT u.kickoff_at
  FROM public.competition_fixture_schedule_proposal p
  CROSS JOIN LATERAL (
    VALUES (p.kickoff_at), (p.kickoff_at_2), (p.kickoff_at_3)
  ) AS u(kickoff_at)
  WHERE p.fixture_id = p_fixture_id
    AND p.status IN ('pending', 'superseded')
    AND u.kickoff_at IS NOT NULL
  ORDER BY 1;
$gpsl$;

CREATE OR REPLACE FUNCTION public.match_schedule_kickoff_already_proposed(
  p_fixture_id bigint,
  p_kickoff_at timestamptz
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_fixture_schedule_proposal p
    CROSS JOIN LATERAL (
      VALUES (p.kickoff_at), (p.kickoff_at_2), (p.kickoff_at_3)
    ) AS u(kickoff_at)
    WHERE p.fixture_id = p_fixture_id
      AND p.status IN ('pending', 'superseded')
      AND u.kickoff_at = p_kickoff_at
  );
$gpsl$;

-- Final-play-day guard covers 2nd and 3rd choices as well as the first.
DO $trg$
DECLARE
  v_def text;
  v_start int;
  v_end int;
  v_mark_start text := 'IF TG_TABLE_NAME = ''competition_fixture_schedule_proposal'' THEN';
  v_mark_end text := 'ELSIF TG_TABLE_NAME = ''competition_fixture_mutual_override'' THEN';
  v_new text := $new$IF TG_TABLE_NAME = 'competition_fixture_schedule_proposal' THEN
    IF TG_OP = 'UPDATE'
       AND NEW.kickoff_at IS NOT DISTINCT FROM OLD.kickoff_at
       AND NEW.kickoff_at_2 IS NOT DISTINCT FROM OLD.kickoff_at_2
       AND NEW.kickoff_at_3 IS NOT DISTINCT FROM OLD.kickoff_at_3 THEN
      RETURN NEW;
    END IF;
    IF NEW.kickoff_at IS NOT NULL THEN
      PERFORM public.match_schedule_assert_not_final_play_day(NEW.fixture_id, NEW.kickoff_at);
    END IF;
    IF NEW.kickoff_at_2 IS NOT NULL THEN
      PERFORM public.match_schedule_assert_not_final_play_day(NEW.fixture_id, NEW.kickoff_at_2);
    END IF;
    IF NEW.kickoff_at_3 IS NOT NULL THEN
      PERFORM public.match_schedule_assert_not_final_play_day(NEW.fixture_id, NEW.kickoff_at_3);
    END IF;
    RETURN NEW;
  $new$;
BEGIN
  v_def := replace(replace(
    pg_get_functiondef('public.trg_reject_final_play_day_kickoff()'::regprocedure),
    E'\r\n', E'\n'), E'\r', E'\n');
  IF position('NEW.kickoff_at_2' IN v_def) > 0 THEN
    RAISE NOTICE 'final-play trigger already checks extra choices';
    RETURN;
  END IF;
  v_start := position(v_mark_start IN v_def);
  v_end := position(v_mark_end IN v_def);
  IF v_start = 0 OR v_end = 0 OR v_end <= v_start THEN
    RAISE EXCEPTION 'final-play trigger proposal branch not found';
  END IF;
  v_def := substring(v_def FROM 1 FOR v_start - 1)
    || v_new
    || substring(v_def FROM v_end);
  v_def := replace(v_def, '$function$', '$gpsl$');
  IF right(v_def, 1) <> ';' THEN
    v_def := v_def || ';';
  END IF;
  EXECUTE v_def;
END;
$trg$;

DROP TRIGGER IF EXISTS trg_proposal_reject_final_play_day ON public.competition_fixture_schedule_proposal;
CREATE TRIGGER trg_proposal_reject_final_play_day
  BEFORE INSERT OR UPDATE OF kickoff_at, kickoff_at_2, kickoff_at_3
  ON public.competition_fixture_schedule_proposal
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_reject_final_play_day_kickoff();

-- Inbox copy for the sender lists every choice on the row.
CREATE OR REPLACE FUNCTION public.match_schedule_notify_proposer_sent(
  p_fixture public.competition_fixtures,
  p_proposer_club text,
  p_opponent_club text,
  p_kickoff_at timestamp with time zone,
  p_proposal_id bigint,
  p_is_counter boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $gpsl$
DECLARE
  v_href text;
  v_fmt text;
  v_k2 timestamptz;
  v_k3 timestamptz;
  v_opponent_name text;
  v_title text;
  v_body text;
  v_msg_type text;
  v_inbox_title text;
  v_inbox_body text;
BEGIN
  v_fmt := public.match_schedule_format_kickoff_uk(p_kickoff_at);
  SELECT p.kickoff_at_2, p.kickoff_at_3
  INTO v_k2, v_k3
  FROM public.competition_fixture_schedule_proposal p
  WHERE p.id = p_proposal_id;
  IF v_k2 IS NOT NULL THEN
    v_fmt := '1st ' || v_fmt || ', 2nd ' || public.match_schedule_format_kickoff_uk(v_k2);
    IF v_k3 IS NOT NULL THEN
      v_fmt := v_fmt || ', 3rd ' || public.match_schedule_format_kickoff_uk(v_k3);
    END IF;
  END IF;

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
$gpsl$;

DO $drop_old$
BEGIN
  IF to_regprocedure('public.fixture_schedule_propose(bigint,timestamptz)') IS NOT NULL THEN
    DROP FUNCTION public.fixture_schedule_propose(bigint, timestamptz);
  END IF;
END;
$drop_old$;

CREATE OR REPLACE FUNCTION public.fixture_schedule_propose(
  p_fixture_id bigint,
  p_kickoff_at timestamp with time zone,
  p_kickoff_at_2 timestamp with time zone DEFAULT NULL,
  p_kickoff_at_3 timestamp with time zone DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '90s'
AS $gpsl$
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
  v_free_propose boolean;
  v_kickoffs timestamptz[];
  v_ko timestamptz;
  v_n int;
  v_rank text;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF to_regprocedure('public.club_assert_has_manager_for_matches(text)') IS NOT NULL THEN
    PERFORM public.club_assert_has_manager_for_matches(v_club);
  END IF;

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RAISE EXCEPTION 'Both clubs have GPSL match system OFF — arrange this fixture off-site (no in-app propose).';
  END IF;

  IF p_kickoff_at IS NULL THEN
    RAISE EXCEPTION 'Pick a kick-off time';
  END IF;
  IF p_kickoff_at_2 IS NULL AND p_kickoff_at_3 IS NOT NULL THEN
    RAISE EXCEPTION 'Add a second choice before a third';
  END IF;

  v_kickoffs := ARRAY[p_kickoff_at];
  IF p_kickoff_at_2 IS NOT NULL THEN
    v_kickoffs := v_kickoffs || p_kickoff_at_2;
  END IF;
  IF p_kickoff_at_3 IS NOT NULL THEN
    v_kickoffs := v_kickoffs || p_kickoff_at_3;
  END IF;

  IF (
    SELECT count(*) FROM (SELECT DISTINCT unnest(v_kickoffs)) s
  ) <> cardinality(v_kickoffs) THEN
    RAISE EXCEPTION 'Each choice must be a different kick-off';
  END IF;

  v_club_name := public.club_display_name(v_club);
  v_free_propose := public.match_schedule_allow_free_propose(p_fixture_id);

  v_n := 0;
  FOREACH v_ko IN ARRAY v_kickoffs
  LOOP
    v_n := v_n + 1;
    v_rank := CASE v_n WHEN 1 THEN '1st choice' WHEN 2 THEN '2nd choice' ELSE '3rd choice' END;
    DECLARE
      v_is_compromise boolean;
    BEGIN
      v_fixture := public.match_schedule_assert_kickoff_valid(p_fixture_id, v_ko);

      IF public.match_schedule_kickoff_already_proposed(p_fixture_id, v_ko) THEN
        RAISE EXCEPTION 'That kick-off was already suggested in this arrangement — pick a different time';
      END IF;

      PERFORM public.match_schedule_assert_not_final_play_day(p_fixture_id, v_ko);

      v_is_compromise := (NOT v_free_propose)
        AND public.match_schedule_kickoff_is_compromise_midpoint(p_fixture_id, v_ko);

      IF NOT v_free_propose
         AND NOT v_is_compromise
         AND NOT public.match_schedule_club_available_at(
               v_fixture.season_id, v_club, v_ko
             )
      THEN
        RAISE EXCEPTION 'You are not available at that time — set weekly availability on Owner Details first';
      END IF;

      IF NOT v_free_propose
         AND NOT v_is_compromise
         AND (to_regprocedure('public.competition_club_is_vacant(text)') IS NULL
          OR NOT public.competition_club_is_vacant(
               CASE
                 WHEN v_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
                 ELSE v_fixture.home_club_short_name
               END
             ))
         AND NOT public.match_schedule_club_available_at(
               v_fixture.season_id,
               CASE
                 WHEN v_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
                 ELSE v_fixture.home_club_short_name
               END,
               v_ko
             )
      THEN
        RAISE EXCEPTION
          'That time is not free for both clubs — pick a compatible slot from times that overlap both owners'' local availability';
      END IF;

      PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, v_ko);
    EXCEPTION
      WHEN OTHERS THEN
        IF cardinality(v_kickoffs) > 1 THEN
          RAISE EXCEPTION '% — %', v_rank, SQLERRM;
        ELSE
          RAISE;
        END IF;
    END;
  END LOOP;

  v_schedule := public.match_schedule_ensure_row(p_fixture_id);
  v_is_counter := v_schedule.status <> 'unscheduled';

  IF v_schedule.status = 'agreed' THEN
    RAISE EXCEPTION 'Kick-off is already agreed for this fixture';
  END IF;

  IF v_schedule.status = 'unscheduled' THEN
    IF v_club <> v_fixture.home_club_short_name
       AND NOT public.match_schedule_club_opened_reschedule(p_fixture_id, v_club)
       AND NOT public.match_schedule_away_may_open_proposal(p_fixture_id)
    THEN
      RAISE EXCEPTION 'Home club must propose the first kick-off time (or the club that dropped the previous agreed time)';
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
    fixture_id, proposed_by_club_short_name, kickoff_at, kickoff_at_2, kickoff_at_3, status
  )
  VALUES (
    p_fixture_id,
    v_club,
    v_kickoffs[1],
    v_kickoffs[2],
    v_kickoffs[3],
    'pending'
  )
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
  v_fmt := public.match_schedule_format_kickoff_uk(v_kickoffs[1]);
  IF v_kickoffs[2] IS NOT NULL THEN
    v_fmt := '1st ' || v_fmt || ', 2nd ' || public.match_schedule_format_kickoff_uk(v_kickoffs[2]);
    IF v_kickoffs[3] IS NOT NULL THEN
      v_fmt := v_fmt || ', 3rd ' || public.match_schedule_format_kickoff_uk(v_kickoffs[3]);
    END IF;
  END IF;

  v_title := CASE
    WHEN NOT v_is_counter AND v_free_propose
      THEN 'Availability poke'
    WHEN NOT v_is_counter THEN 'Match time proposed'
    WHEN v_free_propose
      THEN 'Availability poke (counter)'
    ELSE 'Counter-proposal received'
  END;
  v_body := v_club_name || CASE
    WHEN v_free_propose
      THEN ' poked a kick-off outside mutual availability: '
    ELSE ' proposed '
  END || v_fmt || CASE
    WHEN v_kickoffs[2] IS NOT NULL
      THEN E'.\nOpen Schedule to accept one of these, counter with up to three times, or update your weekly availability.'
    ELSE E'.\nOpen Schedule to accept, counter, or update your weekly availability.'
  END;

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
      v_kickoffs[1],
      v_proposal_id,
      v_is_counter
    );
  END IF;

  RETURN v_proposal_id;
END;
$gpsl$;

REVOKE ALL ON FUNCTION public.fixture_schedule_propose(bigint, timestamptz, timestamptz, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fixture_schedule_propose(bigint, timestamptz, timestamptz, timestamptz)
  TO authenticated, service_role;

-- Accept 2nd or 3rd choice by promoting it to kickoff_at, then the existing accept.
-- Choice 1 goes straight to fixture_schedule_accept. A failed accept restores the first time.
CREATE OR REPLACE FUNCTION public.fixture_schedule_accept_choice(
  p_proposal_id bigint,
  p_choice integer DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $gpsl$
DECLARE
  v_choice int := coalesce(p_choice, 1);
  v_proposal public.competition_fixture_schedule_proposal;
  v_kick timestamptz;
  v_original timestamptz;
  v_result jsonb;
BEGIN
  IF v_choice NOT IN (1, 2, 3) THEN
    RAISE EXCEPTION 'Pick first, second, or third choice';
  END IF;

  IF v_choice = 1 THEN
    RETURN public.fixture_schedule_accept(p_proposal_id);
  END IF;

  SELECT * INTO v_proposal
  FROM public.competition_fixture_schedule_proposal
  WHERE id = p_proposal_id
    AND status = 'pending';

  IF NOT FOUND THEN
    RETURN public.fixture_schedule_accept(p_proposal_id);
  END IF;

  v_kick := CASE v_choice
    WHEN 2 THEN v_proposal.kickoff_at_2
    ELSE v_proposal.kickoff_at_3
  END;

  IF v_kick IS NULL THEN
    RAISE EXCEPTION 'That choice is not on this proposal';
  END IF;

  IF v_kick <= now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'kickoff_passed',
      'message', 'That kick-off has already passed, so it cannot be accepted. Press Counter / schedule and send a new time.'
    );
  END IF;

  v_original := v_proposal.kickoff_at;

  UPDATE public.competition_fixture_schedule_proposal
  SET kickoff_at = v_kick
  WHERE id = p_proposal_id
    AND status = 'pending';

  v_result := public.fixture_schedule_accept(p_proposal_id);

  IF coalesce(v_result->>'ok', 'false') <> 'true' THEN
    UPDATE public.competition_fixture_schedule_proposal
    SET kickoff_at = v_original
    WHERE id = p_proposal_id
      AND status = 'pending';
  END IF;

  RETURN v_result;
END;
$gpsl$;

REVOKE ALL ON FUNCTION public.fixture_schedule_accept_choice(bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fixture_schedule_accept_choice(bigint, integer)
  TO authenticated, service_role;

-- Schedule page reads the extra choices off the pending proposal.
DO $ctx$
DECLARE
  v_def text;
  v_old text := $old$'kickoff_at', v_pending.kickoff_at)$old$;
  v_new text := $new$'kickoff_at', v_pending.kickoff_at, 'kickoff_at_2', v_pending.kickoff_at_2, 'kickoff_at_3', v_pending.kickoff_at_3)$new$;
BEGIN
  v_def := replace(replace(
    pg_get_functiondef('public.match_schedule_fixture_context(bigint)'::regprocedure),
    E'\r\n', E'\n'), E'\r', E'\n');
  IF position('v_pending.kickoff_at_2' IN v_def) > 0 THEN
    RAISE NOTICE 'context already returns extra choices';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'context pending kickoff needle missing';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'context pending kickoff needle was not unique';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  v_def := replace(v_def, '$function$', '$gpsl$');
  IF right(v_def, 1) <> ';' THEN
    v_def := v_def || ';';
  END IF;
  EXECUTE v_def;
END;
$ctx$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'propose', to_regprocedure('public.fixture_schedule_propose(bigint,timestamptz,timestamptz,timestamptz)') IS NOT NULL,
  'old_propose_gone', to_regprocedure('public.fixture_schedule_propose(bigint,timestamptz)') IS NULL,
  'accept_choice', to_regprocedure('public.fixture_schedule_accept_choice(bigint,integer)') IS NOT NULL,
  'choice_cols', (
    SELECT count(*)
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'competition_fixture_schedule_proposal'
      AND column_name IN ('kickoff_at_2', 'kickoff_at_3')
  ),
  'context_lists_2nd', position(
    'kickoff_at_2' IN pg_get_functiondef('public.match_schedule_fixture_context(bigint)'::regprocedure)
  ) > 0
) AS ready;
