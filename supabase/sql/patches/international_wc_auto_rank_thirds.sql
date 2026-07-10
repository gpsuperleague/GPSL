-- =============================================================================
-- Auto-rank best 8 qualifying thirds when the last qual fixture is confirmed.
-- Also exposes an internal ranker (no admin gate) used by apply + admin RPC.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.international_rank_qual_thirds_internal(p_cycle_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_unplayed int;
BEGIN
  IF p_cycle_id IS NULL THEN
    RAISE EXCEPTION 'cycle_id required';
  END IF;

  SELECT count(*) INTO v_unplayed
  FROM public.international_fixtures f
  WHERE f.cycle_id = p_cycle_id AND f.phase = 'qualifying' AND f.played = false;

  IF v_unplayed > 0 THEN
    RAISE EXCEPTION 'All qualifying fixtures must be played first (% remaining)', v_unplayed;
  END IF;

  UPDATE public.international_qual_group_members m
  SET qualified = false, third_place_rank = NULL
  FROM public.international_qual_groups g
  WHERE m.group_id = g.id AND g.cycle_id = p_cycle_id;

  WITH ranked AS (
    SELECT
      m.id,
      m.points,
      (m.goals_for - m.goals_against) AS gd,
      m.goals_for,
      m.nation_code,
      row_number() OVER (
        PARTITION BY m.group_id
        ORDER BY m.points DESC,
                 (m.goals_for - m.goals_against) DESC,
                 m.goals_for DESC,
                 m.nation_code
      ) AS pos
    FROM public.international_qual_group_members m
    JOIN public.international_qual_groups g ON g.id = m.group_id
    WHERE g.cycle_id = p_cycle_id
  ),
  top2 AS (
    UPDATE public.international_qual_group_members m
    SET qualified = true
    FROM ranked r
    WHERE m.id = r.id AND r.pos <= 2
    RETURNING m.id
  ),
  thirds AS (
    SELECT
      r.id,
      row_number() OVER (
        ORDER BY r.points DESC, r.gd DESC, r.goals_for DESC, r.nation_code
      ) AS rnk
    FROM ranked r
    WHERE r.pos = 3
  )
  UPDATE public.international_qual_group_members m
  SET third_place_rank = t.rnk::smallint,
      qualified = (t.rnk <= 8)
  FROM thirds t
  WHERE m.id = t.id;

  RETURN jsonb_build_object(
    'ok', true,
    'qualified', (
      SELECT count(*) FROM public.international_qual_group_members m
      JOIN public.international_qual_groups g ON g.id = m.group_id
      WHERE g.cycle_id = p_cycle_id AND m.qualified
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_rank_qual_thirds(p_cycle_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.international_assert_cycle_admin(p_cycle_id);
  RETURN public.international_rank_qual_thirds_internal(p_cycle_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_apply_fixture_result(
  p_fixture_id bigint,
  p_home_goals smallint,
  p_away_goals smallint,
  p_player_stats jsonb DEFAULT '[]'::jsonb,
  p_home_goals_et smallint DEFAULT NULL,
  p_away_goals_et smallint DEFAULT NULL,
  p_home_pens smallint DEFAULT NULL,
  p_away_pens smallint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fix public.international_fixtures;
  v_hg smallint;
  v_ag smallint;
  v_winner text;
  v_unplayed int;
BEGIN
  SELECT * INTO v_fix
  FROM public.international_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fix.played THEN
    RAISE EXCEPTION 'Fixture already played';
  END IF;

  IF v_fix.phase = 'knockout' THEN
    v_hg := coalesce(p_home_goals_et, p_home_goals);
    v_ag := coalesce(p_away_goals_et, p_away_goals);
    IF v_hg = v_ag THEN
      IF p_home_pens IS NULL OR p_away_pens IS NULL OR p_home_pens = p_away_pens THEN
        RAISE EXCEPTION 'Knockout match needs a winner (ET or penalties)';
      END IF;
      v_winner := CASE WHEN p_home_pens > p_away_pens THEN v_fix.home_nation ELSE v_fix.away_nation END;
    ELSE
      v_winner := CASE WHEN v_hg > v_ag THEN v_fix.home_nation ELSE v_fix.away_nation END;
    END IF;
  END IF;

  UPDATE public.international_fixtures
  SET home_goals = p_home_goals,
      away_goals = p_away_goals,
      played = true,
      played_at = now(),
      status = 'played'
  WHERE id = p_fixture_id;

  IF v_fix.phase IN ('qualifying', 'finals_group') AND v_fix.group_id IS NOT NULL THEN
    PERFORM public.international_recompute_group_standings(v_fix.group_id, v_fix.phase);
  END IF;

  IF v_fix.phase = 'knockout' AND v_fix.knockout_node_id IS NOT NULL THEN
    UPDATE public.international_knockout_nodes
    SET goals_a = p_home_goals,
        goals_b = p_away_goals,
        winner_nation = v_winner,
        played = true
    WHERE id = v_fix.knockout_node_id;

    PERFORM public.international_advance_knockout_winner(v_fix.cycle_id, v_fix.knockout_node_id, v_winner);
  END IF;

  PERFORM public.international_apply_player_stats(p_player_stats, true);

  -- When the last qualifying fixture is confirmed, lock top 2 + best 8 thirds
  -- so they are ready for the finals draw.
  IF v_fix.phase = 'qualifying' THEN
    SELECT count(*) INTO v_unplayed
    FROM public.international_fixtures f
    WHERE f.cycle_id = v_fix.cycle_id
      AND f.phase = 'qualifying'
      AND f.played = false;

    IF v_unplayed = 0 THEN
      PERFORM public.international_rank_qual_thirds_internal(v_fix.cycle_id);
    END IF;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_rank_qual_thirds(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_apply_fixture_result(bigint, smallint, smallint, jsonb, smallint, smallint, smallint, smallint) TO authenticated;

-- Internal ranker is only called from SECURITY DEFINER functions (apply / admin RPC).
REVOKE ALL ON FUNCTION public.international_rank_qual_thirds_internal(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.international_rank_qual_thirds_internal(bigint) FROM authenticated;

NOTIFY pgrst, 'reload schema';
