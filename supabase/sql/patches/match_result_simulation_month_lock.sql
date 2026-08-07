-- Match simulation: same GPSL month unlock / holiday-early rules as result submit.
-- Fixtures stay locked in preseason until their month is active, unless holiday early play applies.
-- Apply after match_result_simulation_stars_playback.sql (or any later simulate redefine).

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
BEGIN
  IF NOT public.match_result_simulation_enabled() THEN
    RAISE EXCEPTION 'Match result simulation is disabled';
  END IF;

  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  -- Month unlock / catch-up / holiday early (admins bypass inside assert)
  PERFORM public.competition_assert_fixture_month_unlocked(p_fixture_id, v_club);

  RETURN public.competition_simulate_fixture_result_core(p_fixture_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_simulate_fixture_result(bigint) TO authenticated;
-- Core is only reachable via the wrapper (SECURITY DEFINER); do not expose a bypass.
REVOKE ALL ON FUNCTION public.competition_simulate_fixture_result_core(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.competition_simulate_fixture_result_core(bigint) FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';
