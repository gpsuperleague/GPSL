-- League schedule: break up long home/away runs (continental-conditions aware).
--
-- The circle-method generator previously decided home/away purely by array
-- side, so the fixed club played all 19 home then all 19 away, and every
-- other club ran ~10 home then ~10 away. This redefines ONLY the generator
-- function to flip the home side every other matchday. Result: max 2
-- consecutive home or away per club, still a valid double round-robin
-- (19 home / 19 away).
--
-- IMPORTANT: this version keeps the continental weather/pitch/kit rolling
-- (competition_roll_home_match_conditions) introduced in
-- competition_continental_conditions.sql. Conditions are rolled on the actual
-- home club for each fixture, so the venue flip picks the correct continent.
--
-- Run in the Supabase SQL editor, then regenerate league fixtures per
-- division. NOTE: regenerating DELETES + recreates that division's league
-- fixtures, so only do it before a season has played results. To fix an
-- EXISTING schedule's conditions without regenerating, run instead:
--   SELECT public.competition_admin_reapply_fixture_conditions();

CREATE OR REPLACE FUNCTION public.competition_generate_league_fixtures(
  p_season_id bigint,
  p_division text,
  p_shuffle_slots boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_teams text[];
  v_round int;
  v_matchday int;
  v_i int;
  v_home text;
  v_away text;
  v_a text;
  v_b text;
  v_cal record;
  v_cond jsonb;
  v_inserted bigint := 0;
BEGIN
  PERFORM public.competition_assert_fixture_season(p_season_id);
  PERFORM public.competition_assert_league_division(p_division);

  IF p_shuffle_slots THEN
    PERFORM public.competition_shuffle_division_slots(p_season_id, p_division);
  END IF;

  SELECT count(*) INTO v_i
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id
    AND division = p_division
    AND league_position BETWEEN 1 AND 20;

  IF v_i <> 20 THEN
    RAISE EXCEPTION 'Assign all 20 table slots before generating (have %)', v_i;
  END IF;

  SELECT array_agg(club_short_name ORDER BY league_position)
  INTO v_teams
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id
    AND division = p_division;

  DELETE FROM public.competition_fixtures
  WHERE season_id = p_season_id
    AND division = p_division
    AND competition_type = 'league';

  -- First leg: matchdays 1–19
  FOR v_round IN 1..19
  LOOP
    v_matchday := v_round;
    SELECT * INTO v_cal FROM public.competition_matchday_calendar(v_matchday);

    FOR v_i IN 1..10
    LOOP
      IF v_i = 1 THEN
        v_a := v_teams[1];
        v_b := v_teams[20];
      ELSE
        v_a := v_teams[v_i];
        v_b := v_teams[21 - v_i];
      END IF;

      -- Flip the home side every other matchday so no club gets long
      -- home/away runs (circle method otherwise bunches ~10 in a row).
      IF (v_round % 2) = 1 THEN
        v_home := v_a;
        v_away := v_b;
      ELSE
        v_home := v_b;
        v_away := v_a;
      END IF;

      v_cond := public.competition_roll_home_match_conditions(v_home, v_cal.gpsl_month);

      INSERT INTO public.competition_fixtures (
        season_id, division, competition_type, matchday,
        gpsl_month, week_in_month,
        home_club_short_name, away_club_short_name,
        weather, pitch_condition, kit_season
      )
      VALUES (
        p_season_id, p_division, 'league', v_matchday,
        v_cal.gpsl_month, v_cal.week_in_month,
        v_home, v_away,
        v_cond ->> 'weather',
        v_cond ->> 'pitch_condition',
        v_cond ->> 'kit_season'
      );

      v_inserted := v_inserted + 1;
    END LOOP;

    v_teams := ARRAY[v_teams[1], v_teams[20]] || v_teams[2:19];
  END LOOP;

  -- Second leg: matchdays 20–38 (exact mirror of leg 1 — venues swapped)
  v_teams := NULL;
  SELECT array_agg(club_short_name ORDER BY league_position)
  INTO v_teams
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id
    AND division = p_division;

  FOR v_round IN 1..19
  LOOP
    v_matchday := v_round + 19;
    SELECT * INTO v_cal FROM public.competition_matchday_calendar(v_matchday);

    FOR v_i IN 1..10
    LOOP
      IF v_i = 1 THEN
        v_a := v_teams[1];
        v_b := v_teams[20];
      ELSE
        v_a := v_teams[v_i];
        v_b := v_teams[21 - v_i];
      END IF;

      -- Mirror of leg 1: same pairing, opposite venue for each parity.
      IF (v_round % 2) = 1 THEN
        v_home := v_b;
        v_away := v_a;
      ELSE
        v_home := v_a;
        v_away := v_b;
      END IF;

      v_cond := public.competition_roll_home_match_conditions(v_home, v_cal.gpsl_month);

      INSERT INTO public.competition_fixtures (
        season_id, division, competition_type, matchday,
        gpsl_month, week_in_month,
        home_club_short_name, away_club_short_name,
        weather, pitch_condition, kit_season
      )
      VALUES (
        p_season_id, p_division, 'league', v_matchday,
        v_cal.gpsl_month, v_cal.week_in_month,
        v_home, v_away,
        v_cond ->> 'weather',
        v_cond ->> 'pitch_condition',
        v_cond ->> 'kit_season'
      );

      v_inserted := v_inserted + 1;
    END LOOP;

    v_teams := ARRAY[v_teams[1], v_teams[20]] || v_teams[2:19];
  END LOOP;

  RETURN jsonb_build_object(
    'division', p_division,
    'fixtures_created', v_inserted,
    'matchdays', 38
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_generate_league_fixtures(bigint, text, boolean) TO authenticated;
