-- Rain or snow → pitch must be wet (eFootball in-game rule).
-- Run after competition_continental_conditions.sql, then fix scheduled fixtures.

CREATE OR REPLACE FUNCTION public.competition_roll_home_match_conditions(
  p_home_club_short_name text,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_continent text;
  v_season text;
  v_cfg public.competition_continental_condition_config%rowtype;
  v_weather text;
  v_pitch text;
  v_kit text;
BEGIN
  v_continent := public.competition_club_continent(p_home_club_short_name);
  v_season := public.competition_gpsl_meteorological_season(v_continent, p_gpsl_month);
  v_kit := public.competition_efootball_kit_season(v_season);

  SELECT * INTO v_cfg
  FROM public.competition_continental_condition_config c
  WHERE c.continent = v_continent
    AND c.meteorological_season = v_season;

  IF NOT FOUND THEN
    v_weather := 'fine';
    v_pitch := 'normal';
  ELSE
    v_weather := public.competition_weighted_pick_3(
      'fine', v_cfg.weather_fine_pct,
      'rain', v_cfg.weather_rain_pct,
      'snow', v_cfg.weather_snow_pct
    );
    IF v_weather IN ('rain', 'snow') THEN
      v_pitch := 'wet';
    ELSE
      v_pitch := public.competition_weighted_pick_3(
        'normal', v_cfg.pitch_normal_pct,
        'dry', v_cfg.pitch_dry_pct,
        'wet', v_cfg.pitch_wet_pct
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'continent', v_continent,
    'meteorological_season', v_season,
    'weather', v_weather,
    'pitch_condition', v_pitch,
    'kit_season', v_kit
  );
END;
$function$;

COMMENT ON COLUMN public.competition_fixtures.pitch_condition IS
  'eFootball pitch: normal, dry, or wet. Rain/snow weather always forces wet (in-game rule).';

-- Align existing scheduled fixtures (played results unchanged)
UPDATE public.competition_fixtures f
SET pitch_condition = 'wet'
WHERE f.status = 'scheduled'
  AND f.weather IN ('rain', 'snow')
  AND f.pitch_condition IS DISTINCT FROM 'wet';

-- Or full re-roll: SELECT public.competition_admin_reapply_fixture_conditions(NULL);
