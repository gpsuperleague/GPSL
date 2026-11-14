-- Accepting a kick-off that has already passed returns a plain clue
-- instead of a bare exception. The offer stays pending so they can counter.

DO $accept$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.fixture_schedule_accept(bigint)'::regprocedure
  ), E'\r\n', E'\n');

  IF position('kickoff_passed' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := replace($old$  IF v_proposal.proposed_by_club_short_name = v_club THEN
    RAISE EXCEPTION 'You cannot accept your own proposal';
  END IF;

  PERFORM public.match_schedule_assert_kickoff_valid(v_proposal.fixture_id, v_proposal.kickoff_at);$old$, E'\r\n', E'\n');
  v_new := replace($new$  IF v_proposal.proposed_by_club_short_name = v_club THEN
    RAISE EXCEPTION 'You cannot accept your own proposal';
  END IF;

  IF v_proposal.kickoff_at <= now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'kickoff_passed',
      'message', 'That kick-off has already passed, so it cannot be accepted. Press Counter / schedule and send a new time.'
    );
  END IF;

  PERFORM public.match_schedule_assert_kickoff_valid(v_proposal.fixture_id, v_proposal.kickoff_at);$new$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'accept: past-kickoff insert point not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$accept$;

SELECT position(
  'kickoff_passed' IN replace(pg_get_functiondef('public.fixture_schedule_accept(bigint)'::regprocedure), E'\r\n', E'\n')
) > 0 AS accept_clue;
