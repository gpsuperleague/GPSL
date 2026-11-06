-- =============================================================================
-- Put play_now_session back on match_schedule_fixture_context
--
-- A later full replace of fixture context drops the key. The Play now row
-- still exists, so a closed window (miss_open) hides the button and the
-- schedule page never draws "Play now — window closed" / Reset.
--
-- Safe re-run.
-- =============================================================================

DO $inj$
DECLARE
  v_oid oid;
  v_def text;
BEGIN
  v_oid := to_regprocedure('public.match_schedule_fixture_context(bigint)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'match_schedule_fixture_context missing';
  END IF;

  IF to_regprocedure('public.match_schedule_play_now_session_json(bigint)') IS NULL THEN
    RAISE EXCEPTION 'match_schedule_play_now_session_json missing';
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('play_now_session' IN v_def) > 0 THEN
    RAISE NOTICE 'fixture context already returns play_now_session';
    RETURN;
  END IF;

  IF position('''mutual_override_options''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Could not find mutual_override_options in fixture_context';
  END IF;

  v_def := replace(
    v_def,
    '''mutual_override_options''',
    '''play_now_session'', public.match_schedule_play_now_session_json(p_fixture_id),'
    || E'\n    ''mutual_override_options'''
  );

  EXECUTE v_def;
  RAISE NOTICE 'fixture context: play_now_session restored';
END;
$inj$;

NOTIFY pgrst, 'reload schema';
