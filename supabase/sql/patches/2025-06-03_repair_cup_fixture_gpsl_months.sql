-- Cup fixtures drawn before competition_cup_schedule.sql kept gpsl_month = 'may'
-- (legacy competition_create_cup_fixture_for_node). Align with schedule + create
-- any missing leg-2 fixtures. Safe to re-run.

-- Cup fixtures: align months + continental conditions (run competition_cup_weather_from_schedule.sql first)
DO $repair$
DECLARE
  v_row record;
  v_cond jsonb;
BEGIN
  FOR v_row IN
    SELECT f.id, f.home_club_short_name, s.gpsl_month
    FROM public.competition_fixtures f
    JOIN public.competition_cup_round_schedule s
      ON f.competition_type = 'cup'
     AND s.cup_code = f.cup_code
     AND s.round_no = f.cup_round
     AND coalesce(f.cup_leg, 1) = s.cup_leg
    WHERE f.status = 'scheduled'
      AND (
        f.gpsl_month IS DISTINCT FROM s.gpsl_month
        OR f.pitch_condition IS NULL
        OR f.kit_season IS NULL
      )
  LOOP
    v_cond := public.competition_roll_home_match_conditions(
      v_row.home_club_short_name,
      v_row.gpsl_month
    );
    UPDATE public.competition_fixtures f
    SET
      gpsl_month = v_row.gpsl_month,
      weather = v_cond ->> 'weather',
      pitch_condition = v_cond ->> 'pitch_condition',
      kit_season = v_cond ->> 'kit_season'
    WHERE f.id = v_row.id;
  END LOOP;
END;
$repair$;

DO $repair$
DECLARE
  v_node_id bigint;
BEGIN
  FOR v_node_id IN
    SELECT n.id
    FROM public.competition_cup_bracket_nodes n
    JOIN public.competition_seasons s
      ON s.id = n.season_id
     AND s.status = 'active'
     AND s.is_current = true
    WHERE n.home_club_short_name IS NOT NULL
      AND n.away_club_short_name IS NOT NULL
      AND n.fixture_id IS NULL
  LOOP
    PERFORM public.competition_create_cup_fixture_for_node(v_node_id);
  END LOOP;
END;
$repair$;

-- Or one-shot for active season (after competition_cup_weather_from_schedule.sql):
-- SELECT public.competition_cup_sync_all_scheduled_cup_fixtures(
--   (SELECT id FROM public.competition_seasons WHERE is_current = true AND status = 'active' LIMIT 1),
--   NULL
-- );
