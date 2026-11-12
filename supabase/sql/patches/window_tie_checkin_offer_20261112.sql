-- Unplayed-window tie after equal strikes.
-- Proposal count favoured the home club (home must open; an accept is not a
-- proposal). Same steps for league and cup:
--   agreed kick-off and only one club checked in → the other loses
--   both checked in, or neither → skip
--   a kick-off still waiting on a reply, and the reply deadline had
--   already passed before this lock → the club that left it sitting loses
--   (same 48-hour reply clock; a lock during those 48 hours does not count)
--   nobody proposed → skip
-- Then the existing activity list (logins, matches, forfeits, other reply
-- fines, check-ins). Still level → void.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.match_schedule_window_tie_loser(
  p_fixture_id bigint,
  p_closed_gpsl_month text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_sched public.competition_fixture_schedule;
  v_has_schedule boolean := false;
  v_home_in boolean := false;
  v_away_in boolean := false;
  v_by text;
  v_proposal_id bigint;
  v_proposed_at timestamptz;
  v_due timestamptz;
  v_lock timestamptz;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_sched
  FROM public.competition_fixture_schedule
  WHERE fixture_id = p_fixture_id;
  v_has_schedule := FOUND;

  IF v_has_schedule AND v_sched.agreed_kickoff_at IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = p_fixture_id
        AND c.club_short_name = v_f.home_club_short_name
    ) INTO v_home_in;
    SELECT EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = p_fixture_id
        AND c.club_short_name = v_f.away_club_short_name
    ) INTO v_away_in;

    IF v_home_in AND NOT v_away_in THEN
      RETURN v_f.away_club_short_name;
    END IF;
    IF v_away_in AND NOT v_home_in THEN
      RETURN v_f.home_club_short_name;
    END IF;
    RETURN NULL;
  END IF;

  SELECT p.id, p.created_at, p.proposed_by_club_short_name
  INTO v_proposal_id, v_proposed_at, v_by
  FROM public.competition_fixture_schedule_proposal p
  WHERE p.fixture_id = p_fixture_id
    AND p.status = 'pending'
  ORDER BY p.created_at DESC, p.id DESC
  LIMIT 1;

  IF v_by IS NULL OR v_proposed_at IS NULL THEN
    RETURN NULL;
  END IF;

  v_due := public.match_schedule_compute_response_due_at(
    p_fixture_id, v_proposal_id, v_proposed_at, v_by
  );
  SELECT cal.lock_at INTO v_lock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_f.season_id
    AND cal.gpsl_month = p_closed_gpsl_month;

  IF v_due IS NULL OR v_lock IS NULL OR v_due > v_lock THEN
    RETURN NULL;
  END IF;

  IF upper(btrim(v_by)) = upper(btrim(v_f.home_club_short_name)) THEN
    RETURN v_f.away_club_short_name;
  END IF;
  IF upper(btrim(v_by)) = upper(btrim(v_f.away_club_short_name)) THEN
    RETURN v_f.home_club_short_name;
  END IF;

  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_window_tie_loser(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_schedule_window_tie_loser(bigint, text) TO service_role;

DO $patch$
DECLARE
  v_def text;
  v_old text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.match_schedule_pick_window_loser(bigint,bigint,text)'::regprocedure
  ), E'\r\n', E'\n');

  IF position('match_schedule_window_tie_loser' IN v_def) > 0
     AND position('neg_proposals' IN v_def) = 0 THEN
    IF position('match_schedule_window_tie_loser(v_f.id, p_closed_gpsl_month)' IN v_def) = 0 THEN
      IF position('match_schedule_window_tie_loser(v_f.id)' IN v_def) = 0 THEN
        RAISE EXCEPTION 'window loser: tie call not found';
      END IF;
      v_def := replace(
        v_def,
        'match_schedule_window_tie_loser(v_f.id)',
        'match_schedule_window_tie_loser(v_f.id, p_closed_gpsl_month)'
      );
      EXECUTE v_def;
    END IF;
    RETURN;
  END IF;

  IF position('v_away jsonb;' IN v_def) = 0 THEN
    RAISE EXCEPTION 'window loser: declare block not found';
  END IF;
  IF position('v_tie text;' IN v_def) = 0 THEN
    v_def := replace(v_def, 'v_away jsonb;', E'v_away jsonb;\n  v_tie text;');
  END IF;

  IF position('v_home := public.match_schedule_club_activity_tuple(' IN v_def) = 0 THEN
    RAISE EXCEPTION 'window loser: activity step not found';
  END IF;
  IF position('match_schedule_window_tie_loser' IN v_def) = 0 THEN
    v_def := replace(
      v_def,
      'v_home := public.match_schedule_club_activity_tuple(',
      E'v_tie := public.match_schedule_window_tie_loser(v_f.id, p_closed_gpsl_month);\n'
      || E'  IF v_tie IS NOT NULL THEN\n'
      || E'    RETURN v_tie;\n'
      || E'  END IF;\n\n'
      || E'  v_home := public.match_schedule_club_activity_tuple('
    );
  END IF;

  v_old := replace($old$  IF (v_home->>'neg_proposals')::int IS DISTINCT FROM (v_away->>'neg_proposals')::int THEN
    RETURN CASE WHEN (v_home->>'neg_proposals')::int < (v_away->>'neg_proposals')::int
      THEN v_f.home_club_short_name ELSE v_f.away_club_short_name END;
  END IF;
$old$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'window loser: proposal-count step not found';
  END IF;
  v_def := replace(v_def, v_old, '');

  IF position('neg_proposals' IN v_def) > 0 THEN
    RAISE EXCEPTION 'window loser: proposal count still present';
  END IF;
  IF position('match_schedule_window_tie_loser' IN v_def) = 0 THEN
    RAISE EXCEPTION 'window loser: new step was not inserted';
  END IF;

  EXECUTE v_def;
END;
$patch$;

DO $copy$
DECLARE
  v_def text;
  v_old text := 'a missed check-in or a kick-off left sitting';
  v_new text := 'a missed check-in, or a kick-off left sitting after the 48-hour reply';
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.owner_personal_deadlines(text)'::regprocedure
  ), E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 AND position(v_old IN v_def) > 0 THEN
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
  v_def := replace(pg_get_functiondef(
    'public.club_wire_cutoffs()'::regprocedure
  ), E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 AND position(v_old IN v_def) > 0 THEN
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$copy$;

DROP FUNCTION IF EXISTS public.match_schedule_window_tie_loser(bigint);

SELECT jsonb_build_object(
  'tie_fn', to_regprocedure('public.match_schedule_window_tie_loser(bigint,text)') IS NOT NULL,
  'old_fn_gone', to_regprocedure('public.match_schedule_window_tie_loser(bigint)') IS NULL,
  'uses_reply_deadline', position('match_schedule_compute_response_due_at' IN pg_get_functiondef(
    'public.match_schedule_window_tie_loser(bigint,text)'::regprocedure
  )) > 0,
  'called_with_month', position('match_schedule_window_tie_loser(v_f.id, p_closed_gpsl_month)' IN pg_get_functiondef(
    'public.match_schedule_pick_window_loser(bigint,bigint,text)'::regprocedure
  )) > 0
);
