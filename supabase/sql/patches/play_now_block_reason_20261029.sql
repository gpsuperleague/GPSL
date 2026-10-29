-- =============================================================================
-- Play now: expose why the button is hidden (holiday early squad, no earlier
-- slot, outside proposal window, etc.) on match_schedule_fixture_context.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_play_now_status(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_kickoff timestamptz;
BEGIN
  BEGIN
    v_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
    RETURN jsonb_build_object(
      'ok', true,
      'can_request', true,
      'kickoff_at', v_kickoff,
      'reason', NULL
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'ok', false,
      'can_request', false,
      'kickoff_at', NULL,
      'reason', SQLERRM
    );
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_play_now_status(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_play_now_status(bigint)
  TO authenticated, service_role;

-- Patch fixture context: capture play-now status + reason (idempotent)
DO $ctx$
DECLARE
  v_oid oid;
  v_def text;
  v_old text;
  v_new text;
  v_old_opts text;
  v_new_opts text;
BEGIN
  v_oid := to_regprocedure('public.match_schedule_fixture_context(bigint)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'match_schedule_fixture_context(bigint) missing';
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  -- Prefer helper when present
  IF position('match_schedule_play_now_status(p_fixture_id)' IN v_def) = 0
     AND position('v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);' IN v_def) > 0
  THEN
    v_old :=
      E'BEGIN\n'
      || E'      v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);\n'
      || E'      v_can_play_now := true;\n'
      || E'    EXCEPTION WHEN OTHERS THEN\n'
      || E'      v_can_play_now := false; v_play_now_kickoff := NULL;\n'
      || E'    END;';

    v_new :=
      E'BEGIN\n'
      || E'      IF to_regprocedure(''public.match_schedule_play_now_status(bigint)'') IS NOT NULL THEN\n'
      || E'        v_play_now_json := public.match_schedule_play_now_status(p_fixture_id);\n'
      || E'        v_can_play_now := coalesce((v_play_now_json->>''can_request'')::boolean, false);\n'
      || E'        v_play_now_kickoff := (v_play_now_json->>''kickoff_at'')::timestamptz;\n'
      || E'        v_play_now_reason := v_play_now_json->>''reason'';\n'
      || E'      ELSE\n'
      || E'        v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);\n'
      || E'        v_can_play_now := true;\n'
      || E'        v_play_now_reason := NULL;\n'
      || E'      END IF;\n'
      || E'    EXCEPTION WHEN OTHERS THEN\n'
      || E'      v_can_play_now := false; v_play_now_kickoff := NULL; v_play_now_reason := SQLERRM;\n'
      || E'    END;';

    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'Could not find play-now BEGIN/EXCEPTION block in fixture context';
    END IF;

    -- Declare helpers if missing
    IF position('v_play_now_reason' IN v_def) = 0 THEN
      IF position('v_play_now_kickoff timestamptz;' IN v_def) > 0 THEN
        v_def := replace(
          v_def,
          'v_play_now_kickoff timestamptz;',
          E'v_play_now_kickoff timestamptz;\n  v_play_now_reason text;\n  v_play_now_json jsonb;'
        );
      ELSE
        RAISE EXCEPTION 'Could not declare v_play_now_reason';
      END IF;
    ELSIF position('v_play_now_json' IN v_def) = 0 THEN
      v_def := replace(
        v_def,
        'v_play_now_reason text;',
        E'v_play_now_reason text;\n  v_play_now_json jsonb;'
      );
    END IF;

    v_def := replace(v_def, v_old, v_new);
  END IF;

  -- Add reason into mutual_override_options
  v_old_opts :=
    '''mutual_override_options'', jsonb_build_object(''can_request_play_now'', v_can_play_now, ''play_now_kickoff_at'', v_play_now_kickoff, ''can_request_new_time'', v_can_mutual_new_time)';

  v_new_opts :=
    '''mutual_override_options'', jsonb_build_object(''can_request_play_now'', v_can_play_now, ''play_now_kickoff_at'', v_play_now_kickoff, ''can_request_new_time'', v_can_mutual_new_time, ''play_now_block_reason'', v_play_now_reason)';

  IF position(v_new_opts IN v_def) = 0 THEN
    IF position(v_old_opts IN v_def) = 0 THEN
      RAISE EXCEPTION 'Could not find mutual_override_options in fixture context';
    END IF;
    v_def := replace(v_def, v_old_opts, v_new_opts);
  END IF;

  -- Ensure variable exists even if first block was already patched
  IF position('v_play_now_reason' IN v_def) = 0 THEN
    RAISE EXCEPTION 'v_play_now_reason missing after patch';
  END IF;

  EXECUTE v_def;
END;
$ctx$;

NOTIFY pgrst, 'reload schema';

SELECT
  (to_regprocedure('public.match_schedule_play_now_status(bigint)') IS NOT NULL) AS status_fn,
  (position('play_now_block_reason' IN pg_get_functiondef(
    'public.match_schedule_fixture_context(bigint)'::regprocedure
  )) > 0) AS context_has_reason;
