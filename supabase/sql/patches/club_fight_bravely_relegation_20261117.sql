-- Low clubs expected 18th–20th are told to finish in the drop.
-- Matching that place is on target. They are not required to stay up.
-- 16th–17th stays "Avoid relegation" (survive the playoff).

CREATE OR REPLACE FUNCTION public.club_league_expectation_band(
  p_club_short_name text,
  p_season_id bigint,
  p_expected_pos int,
  p_actual_pos int,
  p_division text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_slight int;
  v_bad int;
  v_exp int := greatest(1, least(20, coalesce(p_expected_pos, 10)));
  v_act int := greatest(1, coalesce(p_actual_pos, 10));
  v_gap int;
  v_band text;
  v_moves_exist boolean := false;
  v_relegated boolean := false;
  v_promoted boolean := false;
  v_playoff_pending boolean := false;
  v_tier text;
BEGIN
  SELECT coalesce(g.club_expect_slight_places, 2), coalesce(g.club_expect_bad_places, 5)
  INTO v_slight, v_bad
  FROM public.global_settings g
  WHERE g.id = 1;
  v_slight := coalesce(v_slight, 2);
  v_bad := greatest(coalesce(v_bad, 5), v_slight);

  v_gap := v_act - v_exp;
  v_band := CASE
    WHEN v_gap <= 0 THEN 'on_target'
    WHEN v_gap <= v_slight THEN 'slight'
    WHEN v_gap <= v_bad THEN 'bad'
    ELSE 'abysmal'
  END;

  IF p_season_id IS NOT NULL AND to_regclass('public.competition_season_movements') IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.competition_season_movements m WHERE m.season_id = p_season_id
    ) INTO v_moves_exist;

    SELECT
      coalesce(bool_or(m.from_division = 'superleague' AND m.to_division <> 'superleague'), false),
      coalesce(bool_or(m.to_division = 'superleague' AND m.from_division <> 'superleague'), false)
    INTO v_relegated, v_promoted
    FROM public.competition_season_movements m
    WHERE m.season_id = p_season_id
      AND m.club_short_name = p_club_short_name;
  END IF;

  IF coalesce(p_division, '') = 'superleague' THEN
    v_tier := public.competition_club_tier(p_club_short_name);
    -- Expected drop place: the number is the target, not survival.
    IF v_exp >= 18 AND v_tier = 'low' THEN
      RETURN v_band;
    END IF;

    v_relegated := coalesce(v_relegated, false) OR v_act >= 18;
    v_playoff_pending := v_act IN (16, 17) AND NOT v_moves_exist;

    IF v_exp >= 16 THEN
      IF NOT v_relegated THEN
        RETURN CASE WHEN v_playoff_pending THEN 'slight' ELSE 'on_target' END;
      END IF;
      IF v_act <= 17 OR v_gap <= 0 THEN
        RETURN 'slight';
      END IF;
      RETURN CASE WHEN v_gap <= 2 THEN 'bad' ELSE 'abysmal' END;
    END IF;

    IF v_relegated AND v_band IN ('on_target', 'slight') THEN
      v_band := 'bad';
    END IF;
    IF v_act >= 18 AND v_exp <= 10 THEN
      v_band := 'abysmal';
    END IF;
    RETURN v_band;
  END IF;

  IF coalesce(p_division, '') IN ('championship_a', 'championship_b') THEN
    IF v_act <= 2 OR coalesce(v_promoted, false) THEN
      RETURN 'on_target';
    END IF;
  END IF;

  RETURN v_band;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_league_expectation_band(text, bigint, int, int, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.competition_club_expectation_label(p_position smallint)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_position IS NULL THEN NULL
    WHEN p_position <= 1 THEN 'Win the league'
    WHEN p_position <= 2 THEN 'Finish top 2'
    WHEN p_position <= 4 THEN 'Finish top 4'
    WHEN p_position <= 6 THEN 'Finish top 6'
    WHEN p_position <= 10 THEN 'Finish top 10'
    WHEN p_position <= 14 THEN 'Mid-table finish'
    WHEN p_position <= 15 THEN 'Lower mid-table'
    WHEN p_position <= 17 THEN 'Avoid relegation'
    ELSE 'Fight bravely against relegation'
  END;
$$;

GRANT EXECUTE ON FUNCTION public.competition_club_expectation_label(smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_expectation_label(smallint) TO anon;

SELECT public.club_league_expectation_band('JUB', 1, 19, 16, 'superleague') AS jub_16_vs_19,
       public.club_league_expectation_band('ATA', 1, 18, 20, 'superleague') AS ata_20_vs_18,
       public.competition_club_expectation_label(19::smallint) AS label_19,
       public.competition_club_expectation_label(16::smallint) AS label_16;
