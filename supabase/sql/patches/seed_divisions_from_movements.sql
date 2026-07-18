-- Seed pre-season SuperLeague / Championship pool from a prior season's
-- promotion, relegation and playoff movements.
--
-- p_from_season_id: optional explicit source (e.g. Season 1).
-- When null: walk prior seasons (newest first) and use the first that has
-- movements, or can derive them from a finished Super League playoff final.
--
-- Result: 20 superleague + 40 championship_pool (A/B draw still required).

DROP FUNCTION IF EXISTS public.admin_competition_seed_divisions_from_movements(bigint);
DROP FUNCTION IF EXISTS public.admin_competition_seed_divisions_from_movements(bigint, bigint);
DROP FUNCTION IF EXISTS public.competition_seed_divisions_from_movements(bigint);
DROP FUNCTION IF EXISTS public.competition_seed_divisions_from_movements(bigint, bigint);

CREATE OR REPLACE FUNCTION public.competition_seed_divisions_from_movements(
  p_season_id bigint,
  p_from_season_id bigint DEFAULT NULL
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
  v_apply jsonb;
  v_applied_now boolean := false;
  v_cand record;
  v_sl_final_status text;
BEGIN
  PERFORM public.competition_assert_setup_season(p_season_id);

  IF p_from_season_id IS NOT NULL THEN
    IF p_from_season_id = p_season_id THEN
      RAISE EXCEPTION 'Source season must be different from the pre-season being configured';
    END IF;

    SELECT s.id, s.label
    INTO v_prev, v_prev_label
    FROM public.competition_seasons s
    WHERE s.id = p_from_season_id;

    IF v_prev IS NULL THEN
      RAISE EXCEPTION 'Source season % not found', p_from_season_id;
    END IF;
  ELSE
    -- Prefer a prior season that already has movements, else one with SL final played.
    FOR v_cand IN
      SELECT s.id, s.label
      FROM public.competition_seasons s
      WHERE s.id <> p_season_id
      ORDER BY s.id DESC
    LOOP
      SELECT count(*)::int INTO v_move_count
      FROM public.competition_season_movements
      WHERE season_id = v_cand.id;

      IF v_move_count > 0 THEN
        v_prev := v_cand.id;
        v_prev_label := v_cand.label;
        EXIT;
      END IF;

      SELECT t.status INTO v_sl_final_status
      FROM public.competition_playoff_ties t
      WHERE t.season_id = v_cand.id
        AND t.bracket = 'sl_final'
      LIMIT 1;

      IF v_sl_final_status = 'played' THEN
        v_prev := v_cand.id;
        v_prev_label := v_cand.label;
        EXIT;
      END IF;
    END LOOP;

    IF v_prev IS NULL THEN
      RAISE EXCEPTION
        'No prior season has movements or a finished Super League playoff final. Pick a source season explicitly, or Apply movements on that season first.';
    END IF;
  END IF;

  SELECT count(*)::int INTO v_move_count
  FROM public.competition_season_movements
  WHERE season_id = v_prev;

  IF v_move_count = 0 THEN
    IF to_regprocedure('public.competition_apply_playoff_movements(bigint)') IS NULL THEN
      RAISE EXCEPTION
        'No movements for source season "%" (id %), and apply-movements RPC is missing.',
        coalesce(v_prev_label, v_prev::text),
        v_prev;
    END IF;

    v_apply := public.competition_apply_playoff_movements(v_prev);

    IF NOT coalesce((v_apply->>'ok')::boolean, false) THEN
      RAISE EXCEPTION
        'No movements for source season "%" (id %). Finish the Super League playoff final, then Apply movements (or retry seed). Reason: %.',
        coalesce(v_prev_label, v_prev::text),
        v_prev,
        coalesce(v_apply->>'reason', 'unknown');
    END IF;

    SELECT count(*)::int INTO v_move_count
    FROM public.competition_season_movements
    WHERE season_id = v_prev;

    IF v_move_count = 0 THEN
      RAISE EXCEPTION
        'Apply movements reported ok for "%" but wrote no rows.',
        coalesce(v_prev_label, v_prev::text);
    END IF;

    v_applied_now := true;
  END IF;

  SELECT m.club_short_name INTO v_conflict
  FROM public.competition_season_movements m
  WHERE m.season_id = v_prev
  GROUP BY m.club_short_name
  HAVING count(DISTINCT m.to_division) > 1
  LIMIT 1;

  IF v_conflict IS NOT NULL THEN
    RAISE EXCEPTION
      'Conflicting movement destinations for % on source season %',
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
    )
  INTO v_sl, v_pool, v_other
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id;

  IF v_sl <> 20 OR v_pool <> 40 OR v_other <> 0 THEN
    RAISE EXCEPTION
      'Seed from "%" produced invalid counts (SL %, pool %, other %). Check that season''s divisions and movements.',
      coalesce(v_prev_label, v_prev::text),
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
    'movements_applied_now', v_applied_now,
    'superleague', v_sl,
    'championship_pool', v_pool
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_seed_divisions_from_movements(bigint, bigint)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_competition_seed_divisions_from_movements(
  p_season_id bigint,
  p_from_season_id bigint DEFAULT NULL
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
  RETURN public.competition_seed_divisions_from_movements(p_season_id, p_from_season_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_competition_seed_divisions_from_movements(bigint, bigint)
  TO authenticated;
