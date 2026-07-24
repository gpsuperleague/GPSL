-- =============================================================================
-- Clubs without a manager cannot play matches (check-in / result).
-- Hiring from Manager Transfer Market in August remains allowed when vacant.
--
-- Depends on: club_has_signed_manager (manager_market_block_if_has_manager.sql)
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_has_signed_manager(p_club_short text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT
    p_club_short IS NOT NULL
    AND btrim(p_club_short) <> ''
    AND (
      EXISTS (
        SELECT 1
        FROM public."Managers" m
        WHERE nullif(btrim(m.contracted_club), '') = p_club_short
      )
      OR EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = p_club_short
          AND c.manager_id IS NOT NULL
      )
    );
$function$;

CREATE OR REPLACE FUNCTION public.club_assert_has_manager_for_matches(p_club_short text)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.club_has_signed_manager(p_club_short) THEN
    RAISE EXCEPTION
      'Club % has no manager — sign one from the Manager Transfer Market before check-in or Match Day. You cannot play fixtures without a manager.',
      coalesce(nullif(btrim(p_club_short), ''), '?');
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_has_signed_manager(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_assert_has_manager_for_matches(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Check-in: caller's club must have a manager
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_check_in(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_window_end timestamptz;
  v_home_in boolean;
  v_away_in boolean;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  PERFORM public.club_assert_has_manager_for_matches(v_club);

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for check-in';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'Kick-off time is not agreed yet';
  END IF;

  v_window_end := v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;

  IF now() < v_kickoff THEN
    RAISE EXCEPTION 'Check-in opens at %', public.match_schedule_format_kickoff_uk(v_kickoff);
  END IF;

  IF now() >= v_window_end THEN
    PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
    RAISE EXCEPTION 'Check-in window has closed';
  END IF;

  INSERT INTO public.competition_fixture_checkin (fixture_id, club_short_name)
  VALUES (p_fixture_id, v_club)
  ON CONFLICT (fixture_id, club_short_name) DO NOTHING;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
  END IF;

  RETURN jsonb_build_object('ok', true, 'checked_in_at', now());
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_check_in(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Result entry: both clubs must have a manager
-- ---------------------------------------------------------------------------

DO $inject_submit$
DECLARE
  v_oid oid;
  v_src text;
  v_needle text := $n$IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;$n$;
  v_insert text := $n$IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  PERFORM public.club_assert_has_manager_for_matches(v_fixture.home_club_short_name);
  PERFORM public.club_assert_has_manager_for_matches(v_fixture.away_club_short_name);$n$;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'competition_submit_result'
  ORDER BY p.oid DESC
  LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE NOTICE 'competition_submit_result missing — skip manager inject';
    RETURN;
  END IF;

  v_src := pg_get_functiondef(v_oid);
  IF v_src LIKE '%club_assert_has_manager_for_matches%' THEN
    RAISE NOTICE 'competition_submit_result already has manager assert';
    RETURN;
  END IF;

  IF position(v_needle IN v_src) = 0 THEN
    RAISE WARNING 'competition_submit_result: inject needle not found — patch manually';
    RETURN;
  END IF;

  v_src := replace(v_src, v_needle, v_insert);
  EXECUTE v_src;
END;
$inject_submit$;

-- ---------------------------------------------------------------------------
-- Fixture context: fold manager into can_check_in / can_play + expose flags
-- ---------------------------------------------------------------------------

DO $inject_ctx$
DECLARE
  v_oid oid;
  v_src text;
  v_old_checkin text := $o$'can_check_in', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval AND NOT v_my_in), 'can_play', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND v_home_in AND v_away_in AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval)$o$;
  v_new_checkin text := $n$'can_check_in', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval AND NOT v_my_in AND public.club_has_signed_manager(v_club)), 'can_play', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND v_home_in AND v_away_in AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval AND public.club_has_signed_manager(v_home) AND public.club_has_signed_manager(v_away)), 'home_has_manager', public.club_has_signed_manager(v_home), 'away_has_manager', public.club_has_signed_manager(v_away), 'my_has_manager', public.club_has_signed_manager(v_club)$n$;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'match_schedule_fixture_context'
    AND pg_get_function_identity_arguments(p.oid) = 'bigint'
  ORDER BY p.oid DESC
  LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE NOTICE 'match_schedule_fixture_context(bigint) missing — skip';
    RETURN;
  END IF;

  v_src := pg_get_functiondef(v_oid);
  IF v_src LIKE '%my_has_manager%' THEN
    RAISE NOTICE 'match_schedule_fixture_context already has manager flags';
    RETURN;
  END IF;

  IF position(v_old_checkin IN v_src) = 0 THEN
    RAISE WARNING 'match_schedule_fixture_context: can_check_in needle not found — patch manually';
    RETURN;
  END IF;

  v_src := replace(v_src, v_old_checkin, v_new_checkin);
  EXECUTE v_src;
END;
$inject_ctx$;

-- Also patch live dashboard_matchday_synopsis if already deployed
DO $dash$
DECLARE
  v_oid oid;
  v_src text;
  v_old text := $o$v_can_check_in := (
      v_row.status = 'scheduled'
      AND now() >= v_kickoff
      AND now() < v_checkin_end
      AND NOT v_my_in
    );
    v_can_play := (
      v_row.status = 'scheduled'
      AND v_home_in AND v_away_in
      AND now() >= v_kickoff
      AND now() < v_closes
    );$o$;
  v_new text := $n$v_can_check_in := (
      v_row.status = 'scheduled'
      AND now() >= v_kickoff
      AND now() < v_checkin_end
      AND NOT v_my_in
      AND public.club_has_signed_manager(v_club)
    );
    v_can_play := (
      v_row.status = 'scheduled'
      AND v_home_in AND v_away_in
      AND now() >= v_kickoff
      AND now() < v_closes
      AND public.club_has_signed_manager(v_row.home_club_short_name)
      AND public.club_has_signed_manager(v_row.away_club_short_name)
    );$n$;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'dashboard_matchday_synopsis'
  ORDER BY p.oid DESC
  LIMIT 1;

  IF v_oid IS NULL THEN
    RETURN;
  END IF;

  v_src := pg_get_functiondef(v_oid);
  IF v_src LIKE '%club_has_signed_manager(v_club)%' THEN
    RETURN;
  END IF;

  IF position(v_old IN v_src) = 0 THEN
    RAISE WARNING 'dashboard_matchday_synopsis: manager inject needle not found';
    RETURN;
  END IF;

  EXECUTE replace(v_src, v_old, v_new);
END;
$dash$;

NOTIFY pgrst, 'reload schema';
