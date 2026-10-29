-- =============================================================================
-- Play now (once kick-off is agreed):
--   • Always offered while agreed KO is still in the future
--   • Clubs pick any earlier UK 30-minute kick-off (or default "now" slot)
--   • Does NOT require mutual weekly availability / common times
--   • Still: proposal window, not double-booked, holiday-early squad if needed
--   • Both clubs still confirm (Inbox / Schedule)
--
-- Safe re-run. Apply after holiday_fixture_corridor / play_now_block_reason if used.
-- =============================================================================

-- Free earlier KO: window + slot rules only (no availability intersection)
CREATE OR REPLACE FUNCTION public.match_schedule_assert_play_now_kickoff_ok(
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
  v_schedule public.competition_fixture_schedule;
  v_unlock timestamptz;
  v_lock timestamptz;
BEGIN
  SELECT * INTO v_schedule
  FROM public.competition_fixture_schedule
  WHERE fixture_id = p_fixture_id;

  IF NOT FOUND OR v_schedule.status <> 'agreed' OR v_schedule.agreed_kickoff_at IS NULL THEN
    RAISE EXCEPTION 'Fixture does not have an agreed kick-off';
  END IF;

  IF now() >= v_schedule.agreed_kickoff_at THEN
    RAISE EXCEPTION 'Play now is only available before the agreed kick-off';
  END IF;

  IF p_kickoff IS NULL THEN
    RAISE EXCEPTION 'Play-now kick-off is required';
  END IF;

  IF NOT public.match_schedule_kickoff_is_slot(p_kickoff) THEN
    RAISE EXCEPTION 'Kick-off must be on a 30-minute boundary (UK time)';
  END IF;

  IF p_kickoff <= now() THEN
    RAISE EXCEPTION 'That kick-off time has already passed';
  END IF;

  IF p_kickoff >= v_schedule.agreed_kickoff_at THEN
    RAISE EXCEPTION 'Play-now kick-off must be earlier than the agreed kick-off';
  END IF;

  IF to_regprocedure('public.match_schedule_assert_holiday_early_squad_ready(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_assert_holiday_early_squad_ready(p_fixture_id);
  END IF;

  SELECT w.unlock_at, w.lock_at
  INTO v_unlock, v_lock
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  IF v_unlock IS NULL THEN
    RAISE EXCEPTION 'No GPSL month window for this fixture';
  END IF;

  IF p_kickoff < v_unlock OR p_kickoff + interval '30 minutes' > v_lock THEN
    RAISE EXCEPTION 'Play-now kick-off must fall within the GPSL arrange window (% – % UK)',
      public.match_schedule_format_kickoff_uk(v_unlock),
      public.match_schedule_format_kickoff_uk(v_lock);
  END IF;

  IF to_regprocedure('public.match_schedule_assert_kickoff_not_double_booked(bigint,timestamptz)') IS NOT NULL THEN
    PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, p_kickoff);
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_assert_play_now_kickoff_ok(bigint, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_assert_play_now_kickoff_ok(bigint, timestamptz)
  TO authenticated, service_role;

-- Suggested "now" slot (optional default for the picker)
CREATE OR REPLACE FUNCTION public.match_schedule_play_now_kickoff(p_fixture_id bigint)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_schedule public.competition_fixture_schedule;
  v_slot timestamptz;
  v_checkin interval;
BEGIN
  SELECT * INTO v_schedule
  FROM public.competition_fixture_schedule
  WHERE fixture_id = p_fixture_id;

  IF NOT FOUND OR v_schedule.status <> 'agreed' OR v_schedule.agreed_kickoff_at IS NULL THEN
    RAISE EXCEPTION 'Fixture does not have an agreed kick-off';
  END IF;

  IF now() >= v_schedule.agreed_kickoff_at THEN
    RAISE EXCEPTION 'Play now is only available before the agreed kick-off';
  END IF;

  v_checkin := (public.match_schedule_checkin_minutes() || ' minutes')::interval;
  v_slot := public.match_schedule_current_uk_slot();

  IF now() >= v_slot + v_checkin THEN
    v_slot := v_slot + interval '30 minutes';
  END IF;

  IF v_slot >= v_schedule.agreed_kickoff_at THEN
    RAISE EXCEPTION 'No earlier play slot is available before the agreed kick-off';
  END IF;

  PERFORM public.match_schedule_assert_play_now_kickoff_ok(p_fixture_id, v_slot);
  RETURN v_slot;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_play_now_kickoff(bigint)
  TO authenticated, service_role;

-- Status: can_request whenever agreed KO is still ahead (picker may choose time)
CREATE OR REPLACE FUNCTION public.match_schedule_play_now_status(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_schedule public.competition_fixture_schedule;
  v_kickoff timestamptz;
BEGIN
  SELECT * INTO v_schedule
  FROM public.competition_fixture_schedule
  WHERE fixture_id = p_fixture_id;

  IF NOT FOUND OR v_schedule.status <> 'agreed' OR v_schedule.agreed_kickoff_at IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'can_request', false,
      'kickoff_at', NULL,
      'reason', 'Fixture does not have an agreed kick-off'
    );
  END IF;

  IF now() >= v_schedule.agreed_kickoff_at THEN
    RETURN jsonb_build_object(
      'ok', false,
      'can_request', false,
      'kickoff_at', NULL,
      'reason', 'Play now is only available before the agreed kick-off'
    );
  END IF;

  BEGIN
    v_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
  EXCEPTION WHEN OTHERS THEN
    v_kickoff := NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'can_request', true,
    'kickoff_at', v_kickoff,
    'reason', NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_play_now_status(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_play_now_status(bigint)
  TO authenticated, service_role;

-- Play now accepts optional p_kickoff_at (free earlier time; no availability)
DO $req$
DECLARE
  v_oid oid;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_oid := to_regprocedure(
    'public.fixture_mutual_override_request(bigint,text,timestamp with time zone)'
  );
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'fixture_mutual_override_request missing';
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('match_schedule_assert_play_now_kickoff_ok' IN v_def) > 0 THEN
    RAISE NOTICE 'fixture_mutual_override_request already uses play-now free kickoff assert';
    RETURN;
  END IF;

  v_old :=
    E'IF p_kind = ''play_now'' THEN\n'
    || E'      v_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);\n'
    || E'      IF to_regprocedure(''public.match_schedule_assert_kickoff_not_double_booked(bigint,timestamptz)'') IS NOT NULL THEN\n'
    || E'        PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, v_kickoff);\n'
    || E'      END IF;';

  v_new :=
    E'IF p_kind = ''play_now'' THEN\n'
    || E'      IF p_kickoff_at IS NOT NULL THEN\n'
    || E'        PERFORM public.match_schedule_assert_play_now_kickoff_ok(p_fixture_id, p_kickoff_at);\n'
    || E'        v_kickoff := p_kickoff_at;\n'
    || E'      ELSE\n'
    || E'        v_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);\n'
    || E'      END IF;';

  IF position(v_old IN v_def) = 0 THEN
    -- Looser match: replace from play_now IF through END IF before ELSE new_time
    v_def := regexp_replace(
      v_def,
      E'IF p_kind = ''play_now'' THEN[[:space:]]*'
      || E'v_kickoff := public\\.match_schedule_play_now_kickoff\\(p_fixture_id\\);[[:space:]]*'
      || E'(IF to_regprocedure\\(''public\\.match_schedule_assert_kickoff_not_double_booked\\(bigint,timestamptz\\)''\\) IS NOT NULL THEN[[:space:]]*'
      || E'PERFORM public\\.match_schedule_assert_kickoff_not_double_booked\\(p_fixture_id, v_kickoff\\);[[:space:]]*'
      || E'END IF;[[:space:]]*)?',
      v_new || E'\n    ',
      'n'
    );
  ELSE
    v_def := replace(v_def, v_old, v_new);
  END IF;

  IF position('match_schedule_assert_play_now_kickoff_ok' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Could not patch play_now branch in fixture_mutual_override_request';
  END IF;

  EXECUTE v_def;
END;
$req$;

-- Context: treat play-now as available whenever status.can_request (even without default slot)
DO $ctx$
DECLARE
  v_oid oid;
  v_def text;
BEGIN
  v_oid := to_regprocedure('public.match_schedule_fixture_context(bigint)');
  IF v_oid IS NULL THEN
    RETURN;
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  -- Ensure play_now_status helper path exists (from play_now_block_reason patch)
  IF position('match_schedule_play_now_status(p_fixture_id)' IN v_def) = 0
     AND position('v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);' IN v_def) > 0
  THEN
    -- Soft-gate: agreed future ⇒ can_request; suggested slot optional
    v_def := replace(
      v_def,
      E'BEGIN\n'
      || E'      v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);\n'
      || E'      v_can_play_now := true;\n'
      || E'    EXCEPTION WHEN OTHERS THEN\n'
      || E'      v_can_play_now := false; v_play_now_kickoff := NULL;\n'
      || E'    END;',
      E'BEGIN\n'
      || E'      IF to_regprocedure(''public.match_schedule_play_now_status(bigint)'') IS NOT NULL THEN\n'
      || E'        v_play_now_json := public.match_schedule_play_now_status(p_fixture_id);\n'
      || E'        v_can_play_now := coalesce((v_play_now_json->>''can_request'')::boolean, false);\n'
      || E'        v_play_now_kickoff := (v_play_now_json->>''kickoff_at'')::timestamptz;\n'
      || E'        v_play_now_reason := v_play_now_json->>''reason'';\n'
      || E'      ELSE\n'
      || E'        v_can_play_now := true;\n'
      || E'        BEGIN\n'
      || E'          v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);\n'
      || E'        EXCEPTION WHEN OTHERS THEN\n'
      || E'          v_play_now_kickoff := NULL;\n'
      || E'        END;\n'
      || E'      END IF;\n'
      || E'    EXCEPTION WHEN OTHERS THEN\n'
      || E'      v_can_play_now := true; v_play_now_kickoff := NULL; v_play_now_reason := SQLERRM;\n'
      || E'    END;'
    );

    IF position('v_play_now_reason' IN v_def) = 0
       AND position('v_play_now_kickoff timestamptz;' IN v_def) > 0
    THEN
      v_def := replace(
        v_def,
        'v_play_now_kickoff timestamptz;',
        E'v_play_now_kickoff timestamptz;\n  v_play_now_reason text;\n  v_play_now_json jsonb;'
      );
    END IF;

    IF position(
         '''play_now_block_reason'', v_play_now_reason'
         IN v_def
       ) = 0
       AND position(
         '''can_request_new_time'', v_can_mutual_new_time)'
         IN v_def
       ) > 0
    THEN
      v_def := replace(
        v_def,
        '''mutual_override_options'', jsonb_build_object(''can_request_play_now'', v_can_play_now, ''play_now_kickoff_at'', v_play_now_kickoff, ''can_request_new_time'', v_can_mutual_new_time)',
        '''mutual_override_options'', jsonb_build_object(''can_request_play_now'', v_can_play_now, ''play_now_kickoff_at'', v_play_now_kickoff, ''can_request_new_time'', v_can_mutual_new_time, ''play_now_block_reason'', v_play_now_reason)'
      );
    END IF;

    EXECUTE v_def;
  END IF;
END;
$ctx$;

NOTIFY pgrst, 'reload schema';

SELECT
  (to_regprocedure('public.match_schedule_assert_play_now_kickoff_ok(bigint,timestamptz)') IS NOT NULL)
    AS assert_fn,
  (position('match_schedule_assert_play_now_kickoff_ok' IN pg_get_functiondef(
    'public.fixture_mutual_override_request(bigint,text,timestamptz)'::regprocedure
  )) > 0) AS request_uses_free_play_now;
