-- =============================================================================
-- Schedule: compromise midpoints support + block re-used kick-offs (2026-10-30)
--
-- 1) prior_proposed_kickoffs on match_schedule_fixture_context (pending +
--    superseded in the current negotiation)
-- 2) fixture_schedule_propose rejects a kick-off already offered this arrangement
-- 3) catch-up / replay reset withdraws open proposals so a new arrangement
--    starts with a clean suggestion slate
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_prior_proposed_kickoffs(p_fixture_id bigint)
RETURNS TABLE (kickoff_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT DISTINCT p.kickoff_at
  FROM public.competition_fixture_schedule_proposal p
  WHERE p.fixture_id = p_fixture_id
    AND p.status IN ('pending', 'superseded')
    AND p.kickoff_at IS NOT NULL
  ORDER BY 1;
$$;

REVOKE ALL ON FUNCTION public.match_schedule_prior_proposed_kickoffs(bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_prior_proposed_kickoffs(bigint)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.match_schedule_prior_proposed_kickoffs(bigint) IS
  'Kick-offs already offered in the current arrangement (pending / superseded).';

CREATE OR REPLACE FUNCTION public.match_schedule_kickoff_already_proposed(
  p_fixture_id bigint,
  p_kickoff_at timestamptz
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_fixture_schedule_proposal p
    WHERE p.fixture_id = p_fixture_id
      AND p.status IN ('pending', 'superseded')
      AND p.kickoff_at = p_kickoff_at
  );
$$;

REVOKE ALL ON FUNCTION public.match_schedule_kickoff_already_proposed(bigint, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_kickoff_already_proposed(bigint, timestamptz)
  TO authenticated, service_role;

-- Withdraw open proposals when arrangement resets (catch-up / replay / drop)
DO $reset$
DECLARE
  v_oid oid;
  v_def text;
  v_needle text;
  v_insert text;
BEGIN
  v_oid := to_regprocedure('public.match_schedule_reset_to_unscheduled(bigint)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'match_schedule_reset_to_unscheduled missing — skip withdraw inject';
    RETURN;
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');
  IF position('status = ''withdrawn''' IN v_def) > 0
     OR position('status IN (''pending'', ''superseded'')' IN v_def) > 0 THEN
    RAISE NOTICE 'reset already withdraws open proposals';
    RETURN;
  END IF;

  v_needle := E'DELETE FROM public.competition_fixture_checkin\n  WHERE fixture_id = p_fixture_id;';
  v_insert :=
    E'UPDATE public.competition_fixture_schedule_proposal\n'
    || E'  SET status = ''withdrawn''\n'
    || E'  WHERE fixture_id = p_fixture_id\n'
    || E'    AND status IN (''pending'', ''superseded'');\n\n'
    || E'  DELETE FROM public.competition_fixture_checkin\n'
    || E'  WHERE fixture_id = p_fixture_id;';

  IF position(v_needle IN v_def) = 0 THEN
    RAISE NOTICE 'Could not inject proposal withdraw into reset — patch manually if needed';
    RETURN;
  END IF;

  v_def := replace(v_def, v_needle, v_insert);
  EXECUTE v_def;
  RAISE NOTICE 'match_schedule_reset_to_unscheduled: withdraws open proposals';
END;
$reset$;

-- Propose: reject already-offered kick-off
DO $propose$
DECLARE
  v_oid oid;
  v_def text;
  v_needle text;
  v_insert text;
BEGIN
  v_oid := to_regprocedure('public.fixture_schedule_propose(bigint,timestamptz)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'fixture_schedule_propose missing';
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');
  IF position('match_schedule_kickoff_already_proposed' IN v_def) > 0 THEN
    RAISE NOTICE 'fixture_schedule_propose already blocks prior kickoffs';
    RETURN;
  END IF;

  v_needle := E'v_fixture := public.match_schedule_assert_kickoff_valid(p_fixture_id, p_kickoff_at);';
  IF position(v_needle IN v_def) = 0 THEN
    RAISE EXCEPTION 'Could not find assert_kickoff_valid in fixture_schedule_propose';
  END IF;

  v_insert :=
    v_needle || E'\n\n'
    || E'  IF public.match_schedule_kickoff_already_proposed(p_fixture_id, p_kickoff_at) THEN\n'
    || E'    RAISE EXCEPTION ''That kick-off was already suggested in this arrangement — pick a different time'';\n'
    || E'  END IF;';

  v_def := replace(v_def, v_needle, v_insert);
  EXECUTE v_def;
  RAISE NOTICE 'fixture_schedule_propose: blocks already-suggested kickoffs';
END;
$propose$;

-- Context: prior_proposed_kickoffs
DO $ctx$
DECLARE
  v_oid oid;
  v_def text;
BEGIN
  v_oid := to_regprocedure('public.match_schedule_fixture_context(bigint)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'match_schedule_fixture_context missing';
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');
  IF position('''prior_proposed_kickoffs''' IN v_def) > 0 THEN
    RAISE NOTICE 'context already has prior_proposed_kickoffs';
    RETURN;
  END IF;

  IF position('''poke_allowed''' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      E'''poke_allowed'', public.match_schedule_allow_free_propose(p_fixture_id),',
      E'''poke_allowed'', public.match_schedule_allow_free_propose(p_fixture_id),\n'
        || E'    ''prior_proposed_kickoffs'', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), ''[]''::jsonb)\n'
        || E'      FROM public.match_schedule_prior_proposed_kickoffs(p_fixture_id) i),'
    );
  ELSIF position('''intersection_slots''' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      E'''intersection_slots'',',
      E'''prior_proposed_kickoffs'', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), ''[]''::jsonb)\n'
        || E'      FROM public.match_schedule_prior_proposed_kickoffs(p_fixture_id) i),\n'
        || E'    ''intersection_slots'','
    );
  ELSE
    RAISE EXCEPTION 'Could not inject prior_proposed_kickoffs into context';
  END IF;

  IF position('''prior_proposed_kickoffs''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Context prior_proposed_kickoffs patch failed';
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'match_schedule_fixture_context: prior_proposed_kickoffs';
END;
$ctx$;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.match_schedule_prior_proposed_kickoffs(bigint)') IS NOT NULL
    AS prior_fn,
  to_regprocedure('public.match_schedule_kickoff_already_proposed(bigint,timestamptz)') IS NOT NULL
    AS already_fn,
  position('prior_proposed_kickoffs' IN pg_get_functiondef(
    'public.match_schedule_fixture_context(bigint)'::regprocedure
  )) > 0 AS context_has_prior,
  position('match_schedule_kickoff_already_proposed' IN pg_get_functiondef(
    'public.fixture_schedule_propose(bigint,timestamptz)'::regprocedure
  )) > 0 AS propose_blocks_prior;
