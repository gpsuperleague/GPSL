-- Cup fixtures drawn before competition_cup_schedule.sql kept gpsl_month = 'may'
-- (legacy competition_create_cup_fixture_for_node). Align with schedule + create
-- any missing leg-2 fixtures. Safe to re-run.

UPDATE public.competition_fixtures f
SET
  gpsl_month = s.gpsl_month,
  weather = public.competition_weather_for_gpsl_month(s.gpsl_month)
FROM public.competition_cup_round_schedule s
WHERE f.competition_type = 'cup'
  AND f.cup_code = s.cup_code
  AND f.cup_round = s.round_no
  AND coalesce(f.cup_leg, 1) = s.cup_leg
  AND (
    f.gpsl_month IS DISTINCT FROM s.gpsl_month
    OR f.weather IS DISTINCT FROM public.competition_weather_for_gpsl_month(s.gpsl_month)
  );

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
