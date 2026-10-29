-- =============================================================================
-- Schedule poke: when mutual (intersection) slots are empty, allow a free
-- date/time propose / counter (still inside the GPSL proposal window, UK
-- 30‑minute boundary, not double‑booked). Normal reply deadlines apply.
--
-- Also expose opponent window slots on match_schedule_fixture_context so the
-- Schedule UI can show their availability while home picks a poke time.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_allow_free_propose(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- Free propose / poke only when there is no future mutual slot.
  SELECT NOT EXISTS (
    SELECT 1
    FROM public.match_schedule_intersection_slots(p_fixture_id) s
    WHERE s.kickoff_at > now()
  );
$$;

REVOKE ALL ON FUNCTION public.match_schedule_allow_free_propose(bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_allow_free_propose(bigint)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.match_schedule_allow_free_propose(bigint) IS
  'True when fixture has no future mutual availability slots — propose may use a free poke time.';

-- ---------------------------------------------------------------------------
-- Propose: skip own + opponent weekly-availability guards when poke allowed
-- ---------------------------------------------------------------------------
DO $propose$
DECLARE
  v_oid oid;
  v_def text;
  v_old_own text;
  v_new_own text;
  v_old_mutual text;
  v_new_mutual text;
BEGIN
  v_oid := to_regprocedure('public.fixture_schedule_propose(bigint,timestamptz)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'fixture_schedule_propose missing';
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  -- Own availability (proposer must be free) — allow poke bypass (idempotent)
  IF position('You are not available at that time' IN v_def) > 0
     AND position(
           E'match_schedule_allow_free_propose(p_fixture_id)\n'
           || E'     AND NOT public.match_schedule_club_available_at'
           IN v_def
         ) = 0
  THEN
    v_old_own :=
      E'IF NOT public.match_schedule_club_available_at(\n'
      || E'       v_fixture.season_id, v_club, p_kickoff_at\n'
      || E'     )\n'
      || E'  THEN\n'
      || E'    RAISE EXCEPTION ''You are not available at that time — set weekly availability on Owner Details first'';\n'
      || E'  END IF;';

    v_new_own :=
      E'IF NOT public.match_schedule_allow_free_propose(p_fixture_id)\n'
      || E'     AND NOT public.match_schedule_club_available_at(\n'
      || E'           v_fixture.season_id, v_club, p_kickoff_at\n'
      || E'         )\n'
      || E'  THEN\n'
      || E'    RAISE EXCEPTION ''You are not available at that time — set weekly availability on Owner Details first'';\n'
      || E'  END IF;';

    IF position(v_old_own IN v_def) > 0 THEN
      v_def := replace(v_def, v_old_own, v_new_own);
    ELSE
      v_def := regexp_replace(
        v_def,
        E'IF NOT public\\.match_schedule_club_available_at\\([[:space:]]*'
        || E'v_fixture\\.season_id,[[:space:]]*v_club,[[:space:]]*p_kickoff_at[[:space:]]*\\)[[:space:]]*'
        || E'THEN[[:space:]]*'
        || E'RAISE EXCEPTION ''You are not available at that time[^\']*'';[[:space:]]*'
        || E'END IF;',
        v_new_own,
        'n'
      );
    END IF;

    IF position(
         E'match_schedule_allow_free_propose(p_fixture_id)\n'
         || E'     AND NOT public.match_schedule_club_available_at'
         IN v_def
       ) = 0 THEN
      RAISE EXCEPTION 'Could not inject poke bypass into own-availability guard';
    END IF;
  END IF;

  -- Mutual (opponent must be free) — allow poke bypass (idempotent)
  IF position('not free for both clubs' IN v_def) > 0
     AND position(
           E'match_schedule_allow_free_propose(p_fixture_id)\n'
           || E'     AND (to_regprocedure(''public.competition_club_is_vacant'
           IN v_def
         ) = 0
  THEN
    v_old_mutual :=
      E'IF (to_regprocedure(''public.competition_club_is_vacant(text)'') IS NULL';

    IF position(v_old_mutual IN v_def) = 0 THEN
      RAISE EXCEPTION 'Could not find mutual availability IF in fixture_schedule_propose';
    END IF;

    v_def := replace(
      v_def,
      v_old_mutual,
      E'IF NOT public.match_schedule_allow_free_propose(p_fixture_id)\n'
      || E'     AND (to_regprocedure(''public.competition_club_is_vacant(text)'') IS NULL'
    );
  END IF;

  -- Soften inbox copy when this propose is a poke (optional — only if marker missing)
  IF position('Availability poke' IN v_def) = 0
     AND position('Match time proposed' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      E'v_title := CASE\n'
      || E'    WHEN NOT v_is_counter THEN ''Match time proposed''\n'
      || E'    ELSE ''Counter-proposal received''\n'
      || E'  END;',
      E'v_title := CASE\n'
      || E'    WHEN NOT v_is_counter AND public.match_schedule_allow_free_propose(p_fixture_id)\n'
      || E'      THEN ''Availability poke''\n'
      || E'    WHEN NOT v_is_counter THEN ''Match time proposed''\n'
      || E'    WHEN public.match_schedule_allow_free_propose(p_fixture_id)\n'
      || E'      THEN ''Availability poke (counter)''\n'
      || E'    ELSE ''Counter-proposal received''\n'
      || E'  END;'
    );
    v_def := replace(
      v_def,
      E'v_body := v_club_name || '' proposed '' || v_fmt || E''.\\nOpen Schedule to accept or suggest another time.'';',
      E'v_body := v_club_name || CASE\n'
      || E'    WHEN public.match_schedule_allow_free_propose(p_fixture_id)\n'
      || E'      THEN '' poked a kick-off outside mutual availability: ''\n'
      || E'    ELSE '' proposed ''\n'
      || E'  END || v_fmt || E''.\\nOpen Schedule to accept, counter, or update your weekly availability.'';'
    );
  END IF;

  IF position('match_schedule_allow_free_propose(p_fixture_id)' IN v_def) = 0 THEN
    RAISE EXCEPTION
      'Poke propose patch did not land. Tail:%',
      chr(10) || substring(v_def from greatest(1, position('available_at' in v_def)) for 600);
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'fixture_schedule_propose: free poke when no mutual slots';
END;
$propose$;

-- ---------------------------------------------------------------------------
-- Context: opp_window_slots + poke_allowed
-- ---------------------------------------------------------------------------
DO $ctx$
DECLARE
  v_oid oid;
  v_def text;
  v_needle text;
  v_insert text;
BEGIN
  v_oid := to_regprocedure('public.match_schedule_fixture_context(bigint)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'match_schedule_fixture_context missing';
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('''opp_window_slots''' IN v_def) > 0
     AND position('''poke_allowed''' IN v_def) > 0 THEN
    RAISE NOTICE 'match_schedule_fixture_context already has poke fields';
    RETURN;
  END IF;

  v_needle :=
    E'''my_window_slots'', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), ''[]''::jsonb) FROM public.match_schedule_club_window_slots(p_fixture_id, v_club) i),';

  v_insert :=
    E'''my_window_slots'', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), ''[]''::jsonb) FROM public.match_schedule_club_window_slots(p_fixture_id, v_club) i),\n'
    || E'    ''opp_window_slots'', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), ''[]''::jsonb)\n'
    || E'      FROM public.match_schedule_club_window_slots(\n'
    || E'        p_fixture_id,\n'
    || E'        CASE WHEN v_club = v_home THEN v_away ELSE v_home END\n'
    || E'      ) i),\n'
    || E'    ''poke_allowed'', public.match_schedule_allow_free_propose(p_fixture_id),';

  IF position(v_needle IN v_def) = 0 THEN
    RAISE EXCEPTION
      'Could not find my_window_slots in match_schedule_fixture_context. Tail:%',
      chr(10) || substring(v_def from position('my_window_slots' in v_def) for 400);
  END IF;

  IF position('''opp_window_slots''' IN v_def) = 0 THEN
    v_def := replace(v_def, v_needle, v_insert);
  ELSIF position('''poke_allowed''' IN v_def) = 0 THEN
    v_def := replace(
      v_def,
      E'''intersection_slots'',',
      E'''poke_allowed'', public.match_schedule_allow_free_propose(p_fixture_id),\n'
      || E'    ''intersection_slots'','
    );
  END IF;

  IF position('''opp_window_slots''' IN v_def) = 0
     OR position('''poke_allowed''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Context poke fields patch failed';
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'match_schedule_fixture_context: opp_window_slots + poke_allowed';
END;
$ctx$;

NOTIFY pgrst, 'reload schema';

SELECT
  (to_regprocedure('public.match_schedule_allow_free_propose(bigint)') IS NOT NULL)
    AS helper_ok,
  (position('match_schedule_allow_free_propose' IN pg_get_functiondef(
    'public.fixture_schedule_propose(bigint,timestamptz)'::regprocedure
  )) > 0) AS propose_patched,
  (position('opp_window_slots' IN pg_get_functiondef(
    'public.match_schedule_fixture_context(bigint)'::regprocedure
  )) > 0) AS context_opp_slots,
  (position('poke_allowed' IN pg_get_functiondef(
    'public.match_schedule_fixture_context(bigint)'::regprocedure
  )) > 0) AS context_poke_flag;
