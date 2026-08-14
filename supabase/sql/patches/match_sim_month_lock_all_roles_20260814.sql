-- =============================================================================
-- GPSL month unlock applies to everyone (including admins) for play / simulate
--
-- Removes the is_gpsl_admin() early-return bypass from
-- competition_assert_fixture_month_unlocked so Instant result, Simulate match,
-- and result submit stay locked until the fixture’s GPSL month is active
-- (holiday early-play and catch-up rules unchanged).
--
-- Also: vacant vs vacant staff sim must pass the same month assert.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- After match_sim_vacant_vs_vacant_staff_20260814.sql (or replaces its wrapper).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_assert_fixture_month_unlocked(
  p_fixture_id bigint,
  p_club_short_name text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_active text;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_club text;
BEGIN
  -- No admin bypass — owners and staff wait for GPSL month unlock together.
  v_club := nullif(btrim(coalesce(p_club_short_name, '')), '');

  IF public.match_schedule_fixture_is_holiday_early(p_fixture_id) THEN
    PERFORM public.match_schedule_assert_holiday_early_squad_ready(p_fixture_id);
    RETURN;
  END IF;

  IF v_club IS NOT NULL AND public.club_holiday_allows_fixture_early(p_fixture_id, v_club) THEN
    RETURN;
  END IF;

  SELECT f.* INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_fixture.season_id
  ) THEN
    RETURN;
  END IF;

  v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());

  IF v_active IS NOT NULL AND v_active = v_fixture.gpsl_month THEN
    RETURN;
  END IF;

  IF public.match_schedule_fixture_is_catch_up(p_fixture_id) AND v_active IS NOT NULL THEN
    RETURN;
  END IF;

  SELECT unlock_at, lock_at
  INTO v_unlock, v_lock
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_fixture.season_id
    AND m.gpsl_month = v_fixture.gpsl_month;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No calendar window for GPSL %', public.competition_gpsl_month_label(v_fixture.gpsl_month);
  END IF;

  IF now() < v_unlock THEN
    RAISE EXCEPTION '% matches unlock at % UK (Fri 19:00 week)',
      public.competition_gpsl_month_label(v_fixture.gpsl_month),
      to_char(v_unlock AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI');
  END IF;

  RAISE EXCEPTION '% matches locked since % UK',
    public.competition_gpsl_month_label(v_fixture.gpsl_month),
    to_char(v_lock AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_assert_fixture_month_unlocked(bigint, text) TO authenticated;

-- Vacant vs vacant staff path: same month lock as everyone else
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
  v_acting text;
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

  -- Admin/mod: vacant vs vacant — still gated by GPSL month unlock
  IF v_staff AND NOT v_home_owned AND NOT v_away_owned THEN
    PERFORM set_config('gpsl.sim_acting_club', v_home, true);
    v_acting := v_home;
    PERFORM public.competition_assert_fixture_month_unlocked(p_fixture_id, v_acting);
    RETURN public.competition_simulate_fixture_result_core(p_fixture_id);
  END IF;

  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  PERFORM public.competition_assert_fixture_month_unlocked(p_fixture_id, v_club);

  RETURN public.competition_simulate_fixture_result_core(p_fixture_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_simulate_fixture_result(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
