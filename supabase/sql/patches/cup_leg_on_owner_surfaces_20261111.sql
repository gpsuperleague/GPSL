-- Pass cup_leg (and cup_round on the schedule context) so owner screens
-- can tell a one-leg cup from each leg of a Super8 / Bowl quarter-final.
-- Safe re-run.

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
  v_n int;
BEGIN
  SELECT replace(pg_get_functiondef('public.match_schedule_fixture_context(bigint)'::regprocedure), E'\r\n', E'\n')
  INTO v_def;

  v_old := replace($n$'cup_code', v_fixture.cup_code$n$, E'\r\n', E'\n');
  v_new := replace($n$'cup_code', v_fixture.cup_code, 'cup_round', v_fixture.cup_round, 'cup_leg', v_fixture.cup_leg$n$, E'\r\n', E'\n');

  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'schedule context already has cup_leg';
  ELSE
    v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'schedule context cup_code needle count %', v_n;
    END IF;
    v_def := replace(v_def, v_old, v_new);
    EXECUTE v_def;
  END IF;
END;
$patch$;

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
  v_n int;
BEGIN
  SELECT replace(pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure), E'\r\n', E'\n')
  INTO v_def;

  v_old := replace($n$'cup_round', r.cup_round,$n$, E'\r\n', E'\n');
  v_new := replace($n$'cup_round', r.cup_round,
      'cup_leg', r.cup_leg,$n$, E'\r\n', E'\n');

  IF position('''cup_leg'', r.cup_leg' IN v_def) > 0 THEN
    RAISE NOTICE 'checklist already has cup_leg';
  ELSE
    v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'checklist cup_round needle count %', v_n;
    END IF;
    v_def := replace(v_def, v_old, v_new);
    EXECUTE v_def;
  END IF;
END;
$patch$;

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
  v_n int;
BEGIN
  SELECT replace(pg_get_functiondef('public.competition_match_report(bigint)'::regprocedure), E'\r\n', E'\n')
  INTO v_def;

  IF position('f.cup_leg' IN v_def) > 0 AND position('''cup_leg'', v_fx.cup_leg' IN v_def) > 0 THEN
    RAISE NOTICE 'match report already has cup_leg';
  ELSE
    v_old := replace($n$f.cup_match,$n$, E'\r\n', E'\n');
    v_new := replace($n$f.cup_match,
    f.cup_leg,$n$, E'\r\n', E'\n');
    v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'match report select needle count %', v_n;
    END IF;
    v_def := replace(v_def, v_old, v_new);

    v_old := replace($n$'cup_match', v_fx.cup_match,$n$, E'\r\n', E'\n');
    v_new := replace($n$'cup_match', v_fx.cup_match,
      'cup_leg', v_fx.cup_leg,$n$, E'\r\n', E'\n');
    v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'match report json needle count %', v_n;
    END IF;
    v_def := replace(v_def, v_old, v_new);
    EXECUTE v_def;
  END IF;
END;
$patch$;

NOTIFY pgrst, 'reload schema';
