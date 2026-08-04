-- =============================================================================
-- Fix seed SL 19 / pool 41 after season end
--
-- Cause: competition_apply_playoff_movements() read competition_standings_public,
-- which only returns the live active season. After End Season, re-applying
-- movements dropped auto_promotion / auto_relegation and kept only SL final +
-- 16v17 loser → next season seeds as 19 SL / 41 pool.
--
-- Fix:
--   1) Standings for any season_id (archive preferred, else fixtures)
--   2) Apply movements uses that helper
--   3) Seed always refreshes movements before assigning divisions
--
-- Run in Supabase SQL Editor, then Seed from season "2" again.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) League table rows for a specific season
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_league_standings_for_season(
  p_season_id bigint
)
RETURNS TABLE (
  season_id bigint,
  division text,
  club_short_name text,
  club_name text,
  table_position int,
  mp int,
  w int,
  d int,
  l int,
  gf int,
  ga int,
  gd int,
  pts int
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_season_id IS NULL THEN
    RETURN;
  END IF;

  -- Prefer frozen archive when it has a full league set (written while season was live)
  IF (
    SELECT count(*)::int
    FROM public.competition_club_season_archive a
    WHERE a.season_id = p_season_id
      AND a.division IN ('superleague', 'championship_a', 'championship_b')
  ) >= 60 THEN
    RETURN QUERY
    SELECT
      a.season_id,
      a.division,
      a.club_short_name,
      coalesce(c."Club", a.club_short_name) AS club_name,
      a.final_position::int AS table_position,
      coalesce(a.mp, 0)::int,
      coalesce(a.won, 0)::int,
      coalesce(a.drawn, 0)::int,
      coalesce(a.lost, 0)::int,
      coalesce(a.gf, 0)::int,
      coalesce(a.ga, 0)::int,
      coalesce(a.gd, 0)::int,
      coalesce(a.pts, 0)::int
    FROM public.competition_club_season_archive a
    LEFT JOIN public."Clubs" c ON c."ShortName" = a.club_short_name
    WHERE a.season_id = p_season_id
      AND a.division IN ('superleague', 'championship_a', 'championship_b')
    ORDER BY a.division, a.final_position;
    RETURN;
  END IF;

  -- Live compute from fixtures for this season (works after End Season too).
  -- Do NOT use competition_fixture_counts_in_tables here — that defers rows by the
  -- *live* calendar month and blanks finished-season tables used for movements.
  RETURN QUERY
  WITH registered AS (
    SELECT
      ccs.season_id,
      ccs.division,
      ccs.club_short_name,
      c."Club" AS club_name
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
  ),
  played AS (
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
  ),
  home_apps AS (
    SELECT
      season_id, division, home_club_short_name AS club_short_name,
      1 AS mp,
      CASE WHEN home_goals > away_goals THEN 1 ELSE 0 END AS w,
      CASE WHEN home_goals = away_goals THEN 1 ELSE 0 END AS d,
      CASE WHEN home_goals < away_goals THEN 1 ELSE 0 END AS l,
      home_goals AS gf, away_goals AS ga
    FROM played
  ),
  away_apps AS (
    SELECT
      season_id, division, away_club_short_name AS club_short_name,
      1 AS mp,
      CASE WHEN away_goals > home_goals THEN 1 ELSE 0 END AS w,
      CASE WHEN away_goals = home_goals THEN 1 ELSE 0 END AS d,
      CASE WHEN away_goals < home_goals THEN 1 ELSE 0 END AS l,
      away_goals AS gf, home_goals AS ga
    FROM played
  ),
  all_apps AS (
    SELECT * FROM home_apps UNION ALL SELECT * FROM away_apps
  ),
  totals AS (
    SELECT
      a.season_id, a.division, a.club_short_name,
      sum(a.mp)::int AS mp, sum(a.w)::int AS w, sum(a.d)::int AS d, sum(a.l)::int AS l,
      sum(a.gf)::int AS gf, sum(a.ga)::int AS ga, (sum(a.gf) - sum(a.ga))::int AS gd,
      (sum(a.w) * 3 + sum(a.d))::int AS pts
    FROM all_apps a
    GROUP BY a.season_id, a.division, a.club_short_name
  ),
  point_adj AS (
    SELECT a.season_id, a.club_short_name, sum(a.points_delta)::int AS adj_pts
    FROM public.competition_league_points_adjustments a
    WHERE a.season_id = p_season_id
    GROUP BY a.season_id, a.club_short_name
  ),
  combined AS (
    SELECT
      r.season_id, r.division, r.club_short_name, r.club_name,
      coalesce(t.mp, 0) AS mp, coalesce(t.w, 0) AS w, coalesce(t.d, 0) AS d,
      coalesce(t.l, 0) AS l, coalesce(t.gf, 0) AS gf, coalesce(t.ga, 0) AS ga,
      coalesce(t.gd, 0) AS gd,
      coalesce(t.pts, 0) + coalesce(pa.adj_pts, 0) AS pts
    FROM registered r
    LEFT JOIN totals t
      ON t.season_id = r.season_id
     AND t.division = r.division
     AND t.club_short_name = r.club_short_name
    LEFT JOIN point_adj pa
      ON pa.season_id = r.season_id
     AND pa.club_short_name = r.club_short_name
  )
  SELECT
    c.season_id,
    c.division,
    c.club_short_name,
    c.club_name,
    row_number() OVER (
      PARTITION BY c.season_id, c.division
      ORDER BY c.pts DESC, c.gd DESC, c.gf DESC, c.club_name ASC
    )::int AS table_position,
    c.mp, c.w, c.d, c.l, c.gf, c.ga, c.gd, c.pts
  FROM combined c;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_league_standings_for_season(bigint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2) Apply movements using any-season standings
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_apply_playoff_movements(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_n int := 0;
  v_auto_rel int := 0;
  v_auto_pro int := 0;
  r record;
  v_sl_final public.competition_playoff_ties%ROWTYPE;
  v_sl1617 public.competition_playoff_ties%ROWTYPE;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  SELECT * INTO v_sl_final
  FROM public.competition_playoff_ties
  WHERE season_id = v_season_id AND bracket = 'sl_final'
  LIMIT 1;

  SELECT * INTO v_sl1617
  FROM public.competition_playoff_ties
  WHERE season_id = v_season_id AND bracket = 'sl_1617'
  LIMIT 1;

  IF v_sl_final.status IS DISTINCT FROM 'played' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'sl_final_not_played');
  END IF;

  DELETE FROM public.competition_season_movements WHERE season_id = v_season_id;

  -- SL 18–20 auto relegated
  FOR r IN
    SELECT s.club_short_name, s.division
    FROM public.competition_league_standings_for_season(v_season_id) s
    WHERE s.division = 'superleague'
      AND s.table_position >= 18
  LOOP
    INSERT INTO public.competition_season_movements (
      season_id, club_short_name, from_division, to_division, reason
    ) VALUES (
      v_season_id, r.club_short_name, 'superleague', 'championship_pool', 'auto_relegation'
    );
    v_n := v_n + 1;
    v_auto_rel := v_auto_rel + 1;
  END LOOP;

  -- SL 16v17 loser relegated
  IF v_sl1617.loser_club_short_name IS NOT NULL THEN
    INSERT INTO public.competition_season_movements (
      season_id, club_short_name, from_division, to_division, reason
    ) VALUES (
      v_season_id, v_sl1617.loser_club_short_name, 'superleague', 'championship_pool', 'sl_1617_loser'
    )
    ON CONFLICT (season_id, club_short_name, reason) DO NOTHING;
    v_n := v_n + 1;
  END IF;

  -- SL final: winner SuperLeague, loser Championship
  INSERT INTO public.competition_season_movements (
    season_id, club_short_name, from_division, to_division, reason
  ) VALUES (
    v_season_id, v_sl_final.winner_club_short_name,
    CASE WHEN v_sl_final.winner_club_short_name = v_sl1617.winner_club_short_name
      THEN 'superleague' ELSE 'championship_pool' END,
    'superleague', 'sl_playoff_final_winner'
  )
  ON CONFLICT (season_id, club_short_name, reason) DO NOTHING;
  v_n := v_n + 1;

  INSERT INTO public.competition_season_movements (
    season_id, club_short_name, from_division, to_division, reason
  ) VALUES (
    v_season_id, v_sl_final.loser_club_short_name,
    CASE WHEN v_sl_final.loser_club_short_name = v_sl1617.winner_club_short_name
      THEN 'superleague' ELSE 'championship_pool' END,
    'championship_pool', 'sl_playoff_final_loser'
  )
  ON CONFLICT (season_id, club_short_name, reason) DO NOTHING;
  v_n := v_n + 1;

  -- CH top 2 each division → SuperLeague
  FOR r IN
    SELECT s.club_short_name, s.division
    FROM public.competition_league_standings_for_season(v_season_id) s
    WHERE s.division IN ('championship_a', 'championship_b')
      AND s.table_position <= 2
  LOOP
    INSERT INTO public.competition_season_movements (
      season_id, club_short_name, from_division, to_division, reason
    ) VALUES (
      v_season_id, r.club_short_name, r.division, 'superleague', 'auto_promotion'
    )
    ON CONFLICT (season_id, club_short_name, reason) DO NOTHING;
    v_n := v_n + 1;
    v_auto_pro := v_auto_pro + 1;
  END LOOP;

  IF v_auto_rel <> 3 OR v_auto_pro <> 4 THEN
    RAISE EXCEPTION
      'incomplete_table_movements for season %: auto_relegation=% (need 3), auto_promotion=% (need 4). Check archive/fixtures.',
      v_season_id, v_auto_rel, v_auto_pro;
  END IF;

  UPDATE public.competition_playoff_season_state
  SET movements_applied_at = now()
  WHERE season_id = v_season_id;

  BEGIN
    PERFORM public.owner_inbox_notify_all_clubs(
      'playoff_movements',
      '📋 End-of-season movements confirmed',
      'Promotion, relegation and playoff outcomes have been recorded for next season setup.',
      'playoffs.html',
      'playoff_movements:' || v_season_id::text,
      v_season_id
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'movements', v_n,
    'auto_relegation', v_auto_rel,
    'auto_promotion', v_auto_pro
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_apply_playoff_movements(bigint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3) Seed: always refresh movements, clearer error
-- ---------------------------------------------------------------------------

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
  v_auto_rel int;
  v_auto_pro int;
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

  -- Always rebuild movements so ended seasons are not stuck with a broken snapshot
  IF to_regprocedure('public.competition_apply_playoff_movements(bigint)') IS NULL THEN
    RAISE EXCEPTION 'Apply-movements RPC is missing';
  END IF;

  v_apply := public.competition_apply_playoff_movements(v_prev);

  IF NOT coalesce((v_apply->>'ok')::boolean, false) THEN
    RAISE EXCEPTION
      'Could not rebuild movements for source season "%" (id %). Reason: %. auto_rel=% auto_pro=%',
      coalesce(v_prev_label, v_prev::text),
      v_prev,
      coalesce(v_apply->>'reason', 'unknown'),
      coalesce(v_apply->>'auto_relegation', '?'),
      coalesce(v_apply->>'auto_promotion', '?');
  END IF;

  v_applied_now := true;

  SELECT count(*)::int INTO v_move_count
  FROM public.competition_season_movements
  WHERE season_id = v_prev;

  SELECT
    count(*) FILTER (WHERE reason = 'auto_relegation'),
    count(*) FILTER (WHERE reason = 'auto_promotion')
  INTO v_auto_rel, v_auto_pro
  FROM public.competition_season_movements
  WHERE season_id = v_prev;

  IF v_move_count = 0 THEN
    RAISE EXCEPTION
      'Apply movements reported ok for "%" but wrote no rows.',
      coalesce(v_prev_label, v_prev::text);
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
      'Seed from "%" produced invalid counts (SL %, pool %, other %). Movements: auto_rel=%, auto_pro=%. Re-run patches/seed_divisions_standings_any_season_fix.sql if auto counts are wrong.',
      coalesce(v_prev_label, v_prev::text),
      v_sl,
      v_pool,
      v_other,
      v_auto_rel,
      v_auto_pro;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'previous_season_id', v_prev,
    'previous_season_label', v_prev_label,
    'movements_used', v_move_count,
    'movements_applied_now', v_applied_now,
    'auto_relegation', v_auto_rel,
    'auto_promotion', v_auto_pro,
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
