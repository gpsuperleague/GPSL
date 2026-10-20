-- Inject mutual availability guard into fixture_schedule_propose (idempotent).

DO $inj$
DECLARE
  v_oid oid;
  v_def text;
  v_marker text :=
    E'\n  PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, p_kickoff_at);';
  v_block text := $n$
  IF (to_regprocedure('public.competition_club_is_vacant(text)') IS NULL
      OR NOT public.competition_club_is_vacant(
           CASE
             WHEN v_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
             ELSE v_fixture.home_club_short_name
           END
         ))
     AND NOT public.match_schedule_club_available_at(
           v_fixture.season_id,
           CASE
             WHEN v_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
             ELSE v_fixture.home_club_short_name
           END,
           p_kickoff_at
         )
  THEN
    RAISE EXCEPTION
      'That time is not free for both clubs — pick a compatible slot from times that overlap both owners'' local availability';
  END IF;
$n$;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'fixture_schedule_propose'
  ORDER BY p.oid
  LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'fixture_schedule_propose missing';
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('not free for both clubs' IN v_def) > 0 THEN
    RAISE NOTICE 'already injected';
    RETURN;
  END IF;

  IF position(v_marker IN v_def) = 0 THEN
    RAISE EXCEPTION 'double-book marker missing';
  END IF;

  -- Insert mutual check immediately before the double-book assert
  v_def := overlay(
    v_def
    placing (E'\n' || v_block || v_marker)
    from position(v_marker IN v_def)
    for length(v_marker)
  );

  EXECUTE v_def;
  RAISE NOTICE 'mutual availability guard injected';
END;
$inj$;
