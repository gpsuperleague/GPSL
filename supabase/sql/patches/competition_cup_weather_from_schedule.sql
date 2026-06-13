-- =============================================================================
-- Cup fixtures: GPSL month from competition_cup_round_schedule + home-venue
-- weather/pitch/kit at draw (all known pairings) and when winners advance.
-- Run after competition_cup_schedule.sql + competition_continental_conditions.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_cup_sync_all_scheduled_cup_fixtures(
  p_season_id bigint,
  p_cup_code text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_node_id bigint;
  v_row record;
  v_cond jsonb;
  v_materialized int := 0;
  v_synced int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Create fixtures for every bracket node that already has both clubs (R1, leg 2, byes, etc.)
  FOR v_node_id IN
    SELECT n.id
    FROM public.competition_cup_bracket_nodes n
    WHERE n.season_id = p_season_id
      AND (p_cup_code IS NULL OR n.cup_code = p_cup_code)
      AND n.home_club_short_name IS NOT NULL
      AND n.away_club_short_name IS NOT NULL
      AND n.fixture_id IS NULL
    ORDER BY n.cup_code, n.round_no, n.cup_leg, n.match_no
  LOOP
    PERFORM public.competition_create_cup_fixture_for_node(v_node_id);
    v_materialized := v_materialized + 1;
  END LOOP;

  -- Align gpsl_month to cup schedule and roll home-venue conditions
  FOR v_row IN
    SELECT
      f.id,
      f.home_club_short_name,
      s.gpsl_month
    FROM public.competition_fixtures f
    JOIN public.competition_cup_bracket_nodes n ON n.fixture_id = f.id
    JOIN public.competition_cup_round_schedule s
      ON s.cup_code = f.cup_code
     AND s.round_no = f.cup_round
     AND s.cup_leg = coalesce(f.cup_leg, 1)
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'cup'
      AND f.status = 'scheduled'
      AND (p_cup_code IS NULL OR f.cup_code = p_cup_code)
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

    v_synced := v_synced + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'cup_code', p_cup_code,
    'fixtures_materialized', v_materialized,
    'fixtures_conditions_synced', v_synced
  );
END;
$function$;


-- After cup draw: materialize all known pairings + set month/weather from schedule
CREATE OR REPLACE FUNCTION public.competition_draw_prestige_cup(
  p_season_id bigint,
  p_cup_code text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_clubs text[];
  v_byes text[];
  v_result jsonb;
  v_sync jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_cup_code NOT IN ('super8', 'plate', 'shield', 'spoon') THEN
    RAISE EXCEPTION 'Invalid prestige cup code';
  END IF;

  v_clubs := public.competition_qualify_cup_clubs(p_season_id, p_cup_code);

  IF coalesce(array_length(v_clubs, 1), 0) < 2 THEN
    RAISE EXCEPTION 'Not enough qualified clubs for % (% found)', p_cup_code, coalesce(array_length(v_clubs, 1), 0);
  END IF;

  v_byes := public.competition_cup_load_saved_byes(p_season_id, p_cup_code);

  v_result := public.competition_build_knockout_bracket(
    p_season_id,
    p_cup_code,
    v_clubs,
    CASE WHEN coalesce(array_length(v_byes, 1), 0) > 0 THEN v_byes ELSE NULL END
  );

  v_sync := public.competition_cup_sync_all_scheduled_cup_fixtures(p_season_id, p_cup_code);

  RETURN v_result || v_sync;
END;
$function$;


CREATE OR REPLACE FUNCTION public.competition_draw_league_cup(
  p_season_id bigint,
  p_byes smallint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_clubs text[];
  v_byes text[];
  v_result jsonb;
  v_sync jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_clubs := public.competition_qualify_cup_clubs(p_season_id, 'league_cup');

  IF coalesce(array_length(v_clubs, 1), 0) < 8 THEN
    RAISE EXCEPTION 'Need at least 8 clubs in season for league cup';
  END IF;

  v_byes := public.competition_cup_load_saved_byes(p_season_id, 'league_cup');

  v_result := public.competition_build_knockout_bracket(
    p_season_id,
    'league_cup',
    v_clubs,
    CASE WHEN coalesce(array_length(v_byes, 1), 0) > 0 THEN v_byes ELSE NULL END
  );

  v_sync := public.competition_cup_sync_all_scheduled_cup_fixtures(p_season_id, 'league_cup');

  RETURN v_result || v_sync;
END;
$function$;


-- Cup bracket view: scheduled month per round + fixture conditions when drawn
DROP VIEW IF EXISTS public.competition_cup_bracket_public;

CREATE VIEW public.competition_cup_bracket_public
WITH (security_invoker = false)
AS
SELECT
  n.id,
  n.season_id,
  n.cup_code,
  n.round_no,
  n.match_no,
  n.cup_leg,
  n.leg1_node_id,
  sch.round_label,
  sch.gpsl_month AS round_gpsl_month,
  n.home_club_short_name,
  hc."Club" AS home_club_name,
  n.away_club_short_name,
  ac."Club" AS away_club_name,
  n.winner_club_short_name,
  wc."Club" AS winner_club_name,
  n.fixture_id,
  f.status AS fixture_status,
  f.home_goals,
  f.away_goals,
  f.gpsl_month AS fixture_gpsl_month,
  f.weather,
  f.pitch_condition,
  f.kit_season,
  public.competition_club_continent(n.home_club_short_name) AS home_continent,
  n.child_node_id,
  n.child_slot
FROM public.competition_cup_bracket_nodes n
JOIN public.competition_seasons s ON s.id = n.season_id
LEFT JOIN public.competition_cup_round_schedule sch
  ON sch.cup_code = n.cup_code
 AND sch.round_no = n.round_no
 AND sch.cup_leg = coalesce(n.cup_leg, 1)
LEFT JOIN public."Clubs" hc ON hc."ShortName" = n.home_club_short_name
LEFT JOIN public."Clubs" ac ON ac."ShortName" = n.away_club_short_name
LEFT JOIN public."Clubs" wc ON wc."ShortName" = n.winner_club_short_name
LEFT JOIN public.competition_fixtures f ON f.id = n.fixture_id
WHERE s.status = 'active' AND s.is_current = true;

GRANT SELECT ON public.competition_cup_bracket_public TO authenticated;
GRANT SELECT ON public.competition_cup_bracket_public TO anon;
GRANT EXECUTE ON FUNCTION public.competition_cup_sync_all_scheduled_cup_fixtures(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
