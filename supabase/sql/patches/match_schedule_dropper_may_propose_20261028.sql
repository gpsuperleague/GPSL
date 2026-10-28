-- =============================================================================
-- After Drop & reschedule / emergency drop: the club that dropped may propose
-- the next kick-off (not only home).
--
-- Bug: away owner drops with 24h+ notice, page reloads to unscheduled, slot
-- buttons render but can_propose_first is home-only → buttons disabled, clicks
-- do nothing (no console error).
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_club_opened_reschedule(
  p_fixture_id bigint,
  p_club text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_club_month_reschedule_use u
    WHERE u.fixture_id = p_fixture_id
      AND upper(u.club_short_name) = upper(btrim(coalesce(p_club, '')))
  )
  OR EXISTS (
    SELECT 1
    FROM public.competition_club_emergency_drop_use u
    WHERE u.fixture_id = p_fixture_id
      AND upper(u.club_short_name) = upper(btrim(coalesce(p_club, '')))
  );
$$;

REVOKE ALL ON FUNCTION public.match_schedule_club_opened_reschedule(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_club_opened_reschedule(bigint, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Propose: allow home OR the club that opened the reschedule
-- ---------------------------------------------------------------------------
DO $propose$
DECLARE
  v_oid oid;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_oid := to_regprocedure('public.fixture_schedule_propose(bigint,timestamptz)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'fixture_schedule_propose missing — skip';
    RETURN;
  END IF;

  v_def := pg_get_functiondef(v_oid);
  v_def := replace(replace(v_def, E'\r\n', E'\n'), E'\r', E'\n');

  IF position('match_schedule_club_opened_reschedule' IN v_def) > 0 THEN
    RAISE NOTICE 'fixture_schedule_propose already allows dropper propose';
    RETURN;
  END IF;

  v_old :=
    E'IF v_schedule.status = ''unscheduled'' THEN\n'
    || E'    IF v_club <> v_fixture.home_club_short_name THEN\n'
    || E'      RAISE EXCEPTION ''Home club must propose the first kick-off time'';\n'
    || E'    END IF;';

  IF position(v_old IN v_def) = 0 THEN
    -- tolerate slightly different quoting / spacing
    IF v_def !~ 'Home club must propose the first kick-off time' THEN
      RAISE EXCEPTION 'Could not find home-only propose guard in fixture_schedule_propose';
    END IF;
    v_def := regexp_replace(
      v_def,
      E'IF v_schedule\\.status = ''unscheduled'' THEN[[:space:]]*'
      || E'IF v_club <> v_fixture\\.home_club_short_name THEN[[:space:]]*'
      || E'RAISE EXCEPTION ''Home club must propose the first kick-off time'';[[:space:]]*'
      || E'END IF;',
      E'IF v_schedule.status = ''unscheduled'' THEN\n'
      || E'    IF v_club <> v_fixture.home_club_short_name\n'
      || E'       AND NOT public.match_schedule_club_opened_reschedule(p_fixture_id, v_club)\n'
      || E'    THEN\n'
      || E'      RAISE EXCEPTION ''Home club must propose the first kick-off time (or the club that dropped the previous agreed time)'';\n'
      || E'    END IF;',
      'n'
    );
  ELSE
    v_new :=
      E'IF v_schedule.status = ''unscheduled'' THEN\n'
      || E'    IF v_club <> v_fixture.home_club_short_name\n'
      || E'       AND NOT public.match_schedule_club_opened_reschedule(p_fixture_id, v_club)\n'
      || E'    THEN\n'
      || E'      RAISE EXCEPTION ''Home club must propose the first kick-off time (or the club that dropped the previous agreed time)'';\n'
      || E'    END IF;';
    v_def := replace(v_def, v_old, v_new);
  END IF;

  IF position('match_schedule_club_opened_reschedule' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Propose patch failed to insert dropper allow';
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'fixture_schedule_propose: dropper may propose first';
END;
$propose$;

-- ---------------------------------------------------------------------------
-- Context: can_propose_first includes dropper
-- ---------------------------------------------------------------------------
DO $ctx$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  v_oid := to_regprocedure('public.match_schedule_fixture_context(bigint)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'match_schedule_fixture_context missing — skip';
    RETURN;
  END IF;

  v_def := pg_get_functiondef(v_oid);
  v_def := replace(replace(v_def, E'\r\n', E'\n'), E'\r', E'\n');

  IF position('match_schedule_club_opened_reschedule' IN v_def) > 0 THEN
    RAISE NOTICE 'match_schedule_fixture_context already allows dropper propose';
    RETURN;
  END IF;

  -- Common live pattern: 'can_propose_first', (v_role = 'home' AND v_status = 'unscheduled'
  IF position('''can_propose_first'', (v_role = ''home'' AND v_status = ''unscheduled''' IN v_def) = 0
     AND position('''can_propose_first'', (' || E'\n' IN v_def) = 0 THEN
    -- try the multiline form from match_noshow ladder
    NULL;
  END IF;

  v_new := regexp_replace(
    v_def,
    E'''can_propose_first'', \\([[:space:]]*v_role = ''home'' AND v_status = ''unscheduled''',
    E'''can_propose_first'', (\n'
    || E'      (v_role = ''home'' OR public.match_schedule_club_opened_reschedule(p_fixture_id, v_club))\n'
    || E'      AND v_status = ''unscheduled''',
    'n'
  );

  IF v_new IS NOT DISTINCT FROM v_def
     OR position('match_schedule_club_opened_reschedule' IN v_new) = 0 THEN
    RAISE EXCEPTION
      'Could not patch can_propose_first in match_schedule_fixture_context. Tail:%',
      chr(10) || substring(v_def from position('can_propose_first' in v_def) for 400);
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'match_schedule_fixture_context: dropper may propose first';
END;
$ctx$;

NOTIFY pgrst, 'reload schema';

SELECT
  (to_regprocedure('public.match_schedule_club_opened_reschedule(bigint,text)') IS NOT NULL)
    AS helper,
  (position('match_schedule_club_opened_reschedule' IN pg_get_functiondef(
    'public.fixture_schedule_propose(bigint,timestamptz)'::regprocedure
  )) > 0) AS propose_patched,
  (position('match_schedule_club_opened_reschedule' IN pg_get_functiondef(
    'public.match_schedule_fixture_context(bigint)'::regprocedure
  )) > 0) AS context_patched;
