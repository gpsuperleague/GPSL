-- Injury roll on the admin health check.
-- Wired: confirm calls the injury serve, and that serve calls the roll.
-- Last call: a roll recorded in the last 3 days.
-- Safe re-run.

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef('public.admin_mechanism_health()'::regprocedure), E'\r\n', E'\n');
  IF position('Injury rolls' IN v_def) > 0 THEN
    RAISE NOTICE 'injury health check already present';
    RETURN;
  END IF;
  v_old := replace($old$  RETURN jsonb_build_object(
    'ok', true,$old$, E'\r\n', E'\n');
  v_new := replace($new$  v_checks := v_checks || jsonb_build_array((
    WITH s AS (
      SELECT
        to_regprocedure('public.competition_confirm_result(bigint,jsonb)') IS NOT NULL
          AND position(
            'competition_serve_injuries_for_fixture'
            IN pg_get_functiondef('public.competition_confirm_result(bigint,jsonb)'::regprocedure)
          ) > 0 AS confirm_ok,
        to_regprocedure('public.competition_serve_injuries_for_fixture(bigint)') IS NOT NULL
          AND position(
            'competition_injury_roll_for_fixture'
            IN pg_get_functiondef('public.competition_serve_injuries_for_fixture(bigint)'::regprocedure)
          ) > 0 AS serve_ok,
        (SELECT max(rolled_at) FROM public.competition_fixture_injury_roll) AS last_roll,
        (SELECT max(created_at) FROM public.competition_player_injuries) AS last_injury,
        (SELECT count(*)::int FROM public.competition_player_injuries i
          JOIN public.competition_seasons cs ON cs.id = i.season_id AND cs.is_current) AS season_injuries
    )
    SELECT jsonb_build_object(
      'group', 'Medical',
      'label', 'Injury rolls',
      'wired', s.confirm_ok AND s.serve_ok,
      'fired', s.last_roll IS NOT NULL AND s.last_roll >= now() - interval '3 days',
      'fire_state', CASE
        WHEN s.last_roll IS NOT NULL AND s.last_roll >= now() - interval '3 days' THEN 'ok'
        ELSE 'miss'
      END,
      'tone', CASE
        WHEN s.confirm_ok AND s.serve_ok
          AND s.last_roll IS NOT NULL AND s.last_roll >= now() - interval '3 days' THEN 'green'
        WHEN s.confirm_ok AND s.serve_ok THEN 'amber'
        ELSE 'red'
      END,
      'detail', format(
        'Confirming a result calls the injury roll. Last roll %s. Last new injury %s. %s this season.',
        CASE WHEN s.last_roll IS NULL THEN 'never'
          ELSE to_char(s.last_roll AT TIME ZONE 'Europe/London', 'DD Mon HH24:MI') || ' UK' END,
        CASE WHEN s.last_injury IS NULL THEN 'never'
          ELSE to_char(s.last_injury AT TIME ZONE 'Europe/London', 'DD Mon HH24:MI') || ' UK' END,
        s.season_injuries
      )
    )
    FROM s
  ));

  RETURN jsonb_build_object(
    'ok', true,$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'health return block not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;
