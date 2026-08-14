-- =============================================================================
-- Staff (admin/mod) can Instant result / Simulate vacant vs vacant fixtures
--
-- League Fixtures UI shows those buttons for staff; the RPC previously required
-- the caller’s club to be in the fixture, so the click would fail.
--
-- Approach:
--   1) my_club_shortname() honours transaction-local GUC gpsl.sim_acting_club
--   2) competition_simulate_fixture_result wrapper sets that GUC to the home
--      club when staff simulate a vacant vs vacant fixture
--   3) Month unlock still applies (see match_sim_month_lock_all_roles_20260814.sql)
--
-- Run after match_result_simulation_month_lock.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.my_club_shortname()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_override text;
BEGIN
  BEGIN
    v_override := nullif(btrim(current_setting('gpsl.sim_acting_club', true)), '');
  EXCEPTION
    WHEN OTHERS THEN
      v_override := NULL;
  END;

  IF v_override IS NOT NULL THEN
    RETURN v_override;
  END IF;

  RETURN (
    SELECT c."ShortName"
    FROM public."Clubs" c
    WHERE c.owner_id = auth.uid()
    LIMIT 1
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.my_club_shortname() TO authenticated;

-- Ensure fat simulate body lives as _core (same pattern as month_lock patch)
DO $$
BEGIN
  IF to_regprocedure('public.competition_simulate_fixture_result_core(bigint)') IS NULL
     AND to_regprocedure('public.competition_simulate_fixture_result(bigint)') IS NOT NULL THEN
    ALTER FUNCTION public.competition_simulate_fixture_result(bigint)
      RENAME TO competition_simulate_fixture_result_core;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.competition_simulate_fixture_result(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '60s'
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_home text;
  v_away text;
  v_home_owned boolean;
  v_away_owned boolean;
  v_staff boolean := public.is_gpsl_admin_or_mod();
BEGIN
  IF NOT public.match_result_simulation_enabled() THEN
    RAISE EXCEPTION 'Match result simulation is disabled';
  END IF;

  SELECT f.home_club_short_name, f.away_club_short_name
  INTO v_home, v_away
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  SELECT coalesce(
    (SELECT c.owner_id IS NOT NULL FROM public."Clubs" c WHERE c."ShortName" = v_home),
    false
  )
  INTO v_home_owned;

  SELECT coalesce(
    (SELECT c.owner_id IS NOT NULL FROM public."Clubs" c WHERE c."ShortName" = v_away),
    false
  )
  INTO v_away_owned;

  -- Admin/mod: vacant vs vacant (neither club has an owner)
  IF v_staff AND NOT v_home_owned AND NOT v_away_owned THEN
    PERFORM set_config('gpsl.sim_acting_club', v_home, true);
    PERFORM public.competition_assert_fixture_month_unlocked(p_fixture_id, v_home);
    RETURN public.competition_simulate_fixture_result_core(p_fixture_id);
  END IF;

  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  -- Month unlock / catch-up / holiday early (admins are NOT exempt)
  PERFORM public.competition_assert_fixture_month_unlocked(p_fixture_id, v_club);

  RETURN public.competition_simulate_fixture_result_core(p_fixture_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_simulate_fixture_result(bigint) TO authenticated;
REVOKE ALL ON FUNCTION public.competition_simulate_fixture_result_core(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.competition_simulate_fixture_result_core(bigint) FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';
