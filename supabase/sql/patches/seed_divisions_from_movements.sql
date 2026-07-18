-- Seed pre-season SuperLeague / Championship pool from previous season
-- promotion, relegation and playoff movements.
--
-- Prerequisites:
--   • Previous season has Apply movements (competition_season_movements).
--   • Target season is preseason/setup.
--
-- Result: 20 superleague + 40 championship_pool (A/B draw still required).
-- Overwrites any existing SL / pool / A/B assignments on the target season.

CREATE OR REPLACE FUNCTION public.competition_seed_divisions_from_movements(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_prev bigint;
  v_prev_label text;
  v_move_count int;
  v_conflict text;
  v_sl int;
  v_pool int;
  v_other int;
  v_unassigned int;
BEGIN
  PERFORM public.competition_assert_setup_season(p_season_id);

  SELECT s.id, s.label
  INTO v_prev, v_prev_label
  FROM public.competition_seasons s
  WHERE s.id < p_season_id
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_prev IS NULL THEN
    RAISE EXCEPTION 'No previous season to seed from';
  END IF;

  SELECT count(*)::int INTO v_move_count
  FROM public.competition_season_movements
  WHERE season_id = v_prev;

  IF v_move_count = 0 THEN
    RAISE EXCEPTION
      'No movements for previous season "%" (id %). Apply playoff movements first.',
      coalesce(v_prev_label, v_prev::text),
      v_prev;
  END IF;

  SELECT m.club_short_name INTO v_conflict
  FROM public.competition_season_movements m
  WHERE m.season_id = v_prev
  GROUP BY m.club_short_name
  HAVING count(DISTINCT m.to_division) > 1
  LIMIT 1;

  IF v_conflict IS NOT NULL THEN
    RAISE EXCEPTION
      'Conflicting movement destinations for % on previous season %',
      v_conflict,
      v_prev;
  END IF;

  WITH move AS (
    SELECT DISTINCT ON (m.club_short_name)
      m.club_short_name,
      m.to_division
    FROM public.competition_season_movements m
    WHERE m.season_id = v_prev
      AND m.to_division IN ('superleague', 'championship_pool')
    ORDER BY m.club_short_name, m.id DESC
  ),
  resolved AS (
    SELECT
      n.club_short_name,
      CASE
        WHEN move.to_division IS NOT NULL THEN move.to_division
        WHEN p.division = 'superleague' THEN 'superleague'
        WHEN p.division IN (
          'championship_a',
          'championship_b',
          'championship_pool'
        ) THEN 'championship_pool'
        ELSE 'unassigned'
      END AS division
    FROM public.competition_club_seasons n
    LEFT JOIN public.competition_club_seasons p
      ON p.season_id = v_prev
     AND p.club_short_name = n.club_short_name
    LEFT JOIN move
      ON move.club_short_name = n.club_short_name
    WHERE n.season_id = p_season_id
  )
  UPDATE public.competition_club_seasons n
  SET division = r.division
  FROM resolved r
  WHERE n.season_id = p_season_id
    AND n.club_short_name = r.club_short_name;

  SELECT
    count(*) FILTER (WHERE division = 'superleague'),
    count(*) FILTER (WHERE division = 'championship_pool'),
    count(*) FILTER (
      WHERE division NOT IN ('superleague', 'championship_pool')
    ),
    count(*) FILTER (WHERE division = 'unassigned')
  INTO v_sl, v_pool, v_other, v_unassigned
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id;

  IF v_sl <> 20 OR v_pool <> 40 OR v_other <> 0 THEN
    RAISE EXCEPTION
      'Seed produced invalid counts (SL %, pool %, other %). Check previous season divisions and movements.',
      v_sl,
      v_pool,
      v_other;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'previous_season_id', v_prev,
    'previous_season_label', v_prev_label,
    'movements_used', v_move_count,
    'superleague', v_sl,
    'championship_pool', v_pool
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_seed_divisions_from_movements(bigint)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_competition_seed_divisions_from_movements(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.competition_seed_divisions_from_movements(p_season_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_competition_seed_divisions_from_movements(bigint)
  TO authenticated;
