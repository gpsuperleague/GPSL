-- =============================================================================
-- WC knockout polish: 3rd-place playoff, admin dry-run force-play, champion
-- Safe re-run.
-- =============================================================================

-- Allow third_place stage on knockout nodes
DO $$
BEGIN
  ALTER TABLE public.international_knockout_nodes
    DROP CONSTRAINT IF EXISTS international_knockout_nodes_stage_check;
EXCEPTION WHEN undefined_object THEN
  NULL;
END $$;

ALTER TABLE public.international_knockout_nodes
  DROP CONSTRAINT IF EXISTS international_knockout_nodes_stage_check;

ALTER TABLE public.international_knockout_nodes
  ADD CONSTRAINT international_knockout_nodes_stage_check
  CHECK (stage IN ('r16', 'qf', 'sf', 'third_place', 'final'));

ALTER TABLE public.international_wc_cycles
  ADD COLUMN IF NOT EXISTS champion_nation text REFERENCES public.international_nations (code);

ALTER TABLE public.international_wc_cycles
  ADD COLUMN IF NOT EXISTS runner_up_nation text REFERENCES public.international_nations (code);

ALTER TABLE public.international_wc_cycles
  ADD COLUMN IF NOT EXISTS third_place_nation text REFERENCES public.international_nations (code);

-- ---------------------------------------------------------------------------
-- Seed R16 + empty QF/SF/3rd/Final
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_seed_knockout_bracket(p_cycle_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_winners text[] := ARRAY[]::text[];
  v_runners text[] := ARRAY[]::text[];
  v_g text;
  v_w text;
  v_r text;
  v_node_id bigint;
  v_fid bigint;
  v_season_id bigint;
  v_r16_a int[] := ARRAY[1,3,5,7,2,4,6,8];
  v_r16_b int[] := ARRAY[2,4,6,8,1,3,5,7];
  v_i int;
BEGIN
  PERFORM public.international_assert_cycle_admin(p_cycle_id);
  PERFORM public.international_mark_finals_knockout_qualifiers(p_cycle_id);

  SELECT finals_after_season_id INTO v_season_id
  FROM public.international_wc_cycles WHERE id = p_cycle_id;

  FOREACH v_g IN ARRAY ARRAY['A','B','C','D','E','F','G','H'] LOOP
    SELECT m.nation_code INTO v_w
    FROM public.international_finals_group_members m
    JOIN public.international_finals_groups g ON g.id = m.group_id
    WHERE g.cycle_id = p_cycle_id AND g.group_code = v_g AND m.qualified_knockout
    ORDER BY m.points DESC, (m.goals_for - m.goals_against) DESC, m.goals_for DESC, m.nation_code
    LIMIT 1;

    SELECT m.nation_code INTO v_r
    FROM public.international_finals_group_members m
    JOIN public.international_finals_groups g ON g.id = m.group_id
    WHERE g.cycle_id = p_cycle_id AND g.group_code = v_g AND m.qualified_knockout
      AND m.nation_code IS DISTINCT FROM v_w
    ORDER BY m.points DESC, (m.goals_for - m.goals_against) DESC, m.goals_for DESC, m.nation_code
    LIMIT 1;

    v_winners := v_winners || v_w;
    v_runners := v_runners || v_r;
  END LOOP;

  DELETE FROM public.international_fixtures WHERE cycle_id = p_cycle_id AND phase = 'knockout';
  DELETE FROM public.international_knockout_nodes WHERE cycle_id = p_cycle_id;

  FOR v_i IN 1..8 LOOP
    INSERT INTO public.international_knockout_nodes (
      cycle_id, stage, match_no, nation_a, nation_b, played
    )
    VALUES (
      p_cycle_id, 'r16', v_i,
      v_winners[v_r16_a[v_i]],
      v_runners[v_r16_b[v_i]],
      false
    )
    RETURNING id INTO v_node_id;

    INSERT INTO public.international_fixtures (
      cycle_id, season_id, phase, knockout_node_id,
      home_nation, away_nation, match_no, gpsl_month, week_in_month, status, played
    )
    VALUES (
      p_cycle_id, v_season_id, 'knockout', v_node_id,
      v_winners[v_r16_a[v_i]], v_runners[v_r16_b[v_i]],
      v_i, 'july', 1, 'scheduled', false
    )
    RETURNING id INTO v_fid;

    INSERT INTO public.international_fixture_schedule (fixture_id, status)
    VALUES (v_fid, 'unscheduled') ON CONFLICT DO NOTHING;
  END LOOP;

  FOR v_i IN 1..4 LOOP
    INSERT INTO public.international_knockout_nodes (cycle_id, stage, match_no, played)
    VALUES (p_cycle_id, 'qf', v_i, false);
  END LOOP;
  FOR v_i IN 1..2 LOOP
    INSERT INTO public.international_knockout_nodes (cycle_id, stage, match_no, played)
    VALUES (p_cycle_id, 'sf', v_i, false);
  END LOOP;
  INSERT INTO public.international_knockout_nodes (cycle_id, stage, match_no, played)
  VALUES (p_cycle_id, 'third_place', 1, false);
  INSERT INTO public.international_knockout_nodes (cycle_id, stage, match_no, played)
  VALUES (p_cycle_id, 'final', 1, false);

  RETURN jsonb_build_object('ok', true, 'r16', 8, 'third_place', true);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Advance winners; SF losers → 3rd place; Final sets champion
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_advance_knockout_winner(
  p_cycle_id bigint,
  p_node_id bigint,
  p_winner text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_node public.international_knockout_nodes;
  v_next public.international_knockout_nodes;
  v_third public.international_knockout_nodes;
  v_next_stage text;
  v_next_match smallint;
  v_slot text;
  v_fid bigint;
  v_season_id bigint;
  v_loser text;
BEGIN
  SELECT * INTO v_node FROM public.international_knockout_nodes WHERE id = p_node_id;
  IF NOT FOUND THEN RETURN; END IF;

  IF v_node.stage = 'final' THEN
    v_loser := CASE
      WHEN p_winner = v_node.nation_a THEN v_node.nation_b
      ELSE v_node.nation_a
    END;
    UPDATE public.international_wc_cycles
    SET champion_nation = p_winner,
        runner_up_nation = v_loser
    WHERE id = p_cycle_id;
    -- Status stays 'finals' until admin runs Complete WC + re-selection
    -- (allows 3rd-place playoff to finish first).
    RETURN;
  END IF;

  IF v_node.stage = 'third_place' THEN
    UPDATE public.international_wc_cycles
    SET third_place_nation = p_winner
    WHERE id = p_cycle_id;
    RETURN;
  END IF;

  IF v_node.stage = 'r16' THEN
    v_next_stage := 'qf';
    v_next_match := ((v_node.match_no + 1) / 2)::smallint;
    v_slot := CASE WHEN (v_node.match_no % 2) = 1 THEN 'a' ELSE 'b' END;
  ELSIF v_node.stage = 'qf' THEN
    v_next_stage := 'sf';
    v_next_match := ((v_node.match_no + 1) / 2)::smallint;
    v_slot := CASE WHEN (v_node.match_no % 2) = 1 THEN 'a' ELSE 'b' END;
  ELSIF v_node.stage = 'sf' THEN
    v_next_stage := 'final';
    v_next_match := 1;
    v_slot := CASE WHEN v_node.match_no = 1 THEN 'a' ELSE 'b' END;
  ELSE
    RETURN;
  END IF;

  SELECT * INTO v_next
  FROM public.international_knockout_nodes
  WHERE cycle_id = p_cycle_id AND stage = v_next_stage AND match_no = v_next_match;

  IF NOT FOUND THEN RETURN; END IF;

  IF v_slot = 'a' THEN
    UPDATE public.international_knockout_nodes SET nation_a = p_winner WHERE id = v_next.id;
  ELSE
    UPDATE public.international_knockout_nodes SET nation_b = p_winner WHERE id = v_next.id;
  END IF;

  -- Semi-final losers → third-place playoff
  IF v_node.stage = 'sf' THEN
    v_loser := CASE
      WHEN p_winner = v_node.nation_a THEN v_node.nation_b
      ELSE v_node.nation_a
    END;
    SELECT * INTO v_third
    FROM public.international_knockout_nodes
    WHERE cycle_id = p_cycle_id AND stage = 'third_place' AND match_no = 1;

    IF FOUND THEN
      IF v_node.match_no = 1 THEN
        UPDATE public.international_knockout_nodes SET nation_a = v_loser WHERE id = v_third.id;
      ELSE
        UPDATE public.international_knockout_nodes SET nation_b = v_loser WHERE id = v_third.id;
      END IF;

      SELECT * INTO v_third FROM public.international_knockout_nodes WHERE id = v_third.id;
      IF v_third.nation_a IS NOT NULL AND v_third.nation_b IS NOT NULL
         AND NOT EXISTS (
           SELECT 1 FROM public.international_fixtures f WHERE f.knockout_node_id = v_third.id
         ) THEN
        SELECT finals_after_season_id INTO v_season_id
        FROM public.international_wc_cycles WHERE id = p_cycle_id;

        INSERT INTO public.international_fixtures (
          cycle_id, season_id, phase, knockout_node_id,
          home_nation, away_nation, match_no, gpsl_month, week_in_month, status, played
        )
        VALUES (
          p_cycle_id, v_season_id, 'knockout', v_third.id,
          v_third.nation_a, v_third.nation_b, 1,
          'july', 2, 'scheduled', false
        )
        RETURNING id INTO v_fid;

        INSERT INTO public.international_fixture_schedule (fixture_id, status)
        VALUES (v_fid, 'unscheduled') ON CONFLICT DO NOTHING;
      END IF;
    END IF;
  END IF;

  SELECT * INTO v_next FROM public.international_knockout_nodes WHERE id = v_next.id;

  IF v_next.nation_a IS NOT NULL AND v_next.nation_b IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.international_fixtures f WHERE f.knockout_node_id = v_next.id
     ) THEN
    SELECT finals_after_season_id INTO v_season_id
    FROM public.international_wc_cycles WHERE id = p_cycle_id;

    INSERT INTO public.international_fixtures (
      cycle_id, season_id, phase, knockout_node_id,
      home_nation, away_nation, match_no, gpsl_month, week_in_month, status, played
    )
    VALUES (
      p_cycle_id, v_season_id, 'knockout', v_next.id,
      v_next.nation_a, v_next.nation_b, v_next.match_no,
      'july', 2, 'scheduled', false
    )
    RETURNING id INTO v_fid;

    INSERT INTO public.international_fixture_schedule (fixture_id, status)
    VALUES (v_fid, 'unscheduled') ON CONFLICT DO NOTHING;
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin dry-run: force-play remaining fixtures in a phase (deterministic scores)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_admin_force_play_remaining(
  p_cycle_id bigint,
  p_phase text DEFAULT 'qualifying',
  p_limit int DEFAULT 500
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fix record;
  v_n int := 0;
  v_hg smallint;
  v_ag smallint;
  v_pass int;
  v_batch int;
BEGIN
  PERFORM public.international_assert_cycle_admin(p_cycle_id);

  IF p_phase NOT IN ('qualifying', 'finals_group', 'knockout', 'all') THEN
    RAISE EXCEPTION 'phase must be qualifying, finals_group, knockout, or all';
  END IF;

  -- Group stages first (skip knockout here — handled in advance loop below)
  IF p_phase IN ('qualifying', 'finals_group', 'all') THEN
    FOR v_fix IN
      SELECT f.id, f.home_nation, f.away_nation, f.phase
      FROM public.international_fixtures f
      WHERE f.cycle_id = p_cycle_id
        AND f.played = false
        AND f.phase = CASE
          WHEN p_phase = 'all' THEN f.phase
          ELSE p_phase
        END
        AND f.phase IN ('qualifying', 'finals_group')
        AND (p_phase = 'all' OR f.phase = p_phase)
      ORDER BY
        CASE f.phase WHEN 'qualifying' THEN 1 ELSE 2 END,
        f.match_no NULLS LAST,
        f.id
      LIMIT greatest(1, least(coalesce(p_limit, 500), 2000))
    LOOP
      v_hg := (abs(hashtext(v_fix.id::text || ':h')) % 4)::smallint;
      v_ag := (abs(hashtext(v_fix.id::text || ':a')) % 4)::smallint;

      PERFORM public.international_apply_fixture_result(
        v_fix.id, v_hg, v_ag, '[]'::jsonb, NULL, NULL, NULL, NULL
      );
      v_n := v_n + 1;
    END LOOP;
  END IF;

  IF p_phase IN ('knockout', 'all') THEN
    -- Knockout creates later-round fixtures as winners advance — loop until quiet
    FOR v_pass IN 1..24 LOOP
      v_batch := 0;
      FOR v_fix IN
        SELECT f.id
        FROM public.international_fixtures f
        WHERE f.cycle_id = p_cycle_id
          AND f.played = false
          AND f.phase = 'knockout'
        ORDER BY f.match_no NULLS LAST, f.id
        LIMIT 50
      LOOP
        v_hg := (abs(hashtext(v_fix.id::text || ':h')) % 4)::smallint;
        v_ag := (abs(hashtext(v_fix.id::text || ':a')) % 4)::smallint;
        IF v_hg = v_ag THEN
          v_hg := v_hg + 1;
        END IF;
        PERFORM public.international_apply_fixture_result(
          v_fix.id, v_hg, v_ag, '[]'::jsonb, NULL, NULL, NULL, NULL
        );
        v_n := v_n + 1;
        v_batch := v_batch + 1;
      END LOOP;
      EXIT WHEN v_batch = 0;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('ok', true, 'played', v_n, 'phase', p_phase);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_seed_knockout_bracket(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_advance_knockout_winner(bigint, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_force_play_remaining(bigint, text, int) TO authenticated;

-- Refresh cycle public view with champions
DROP VIEW IF EXISTS public.international_wc_cycle_public;
CREATE VIEW public.international_wc_cycle_public
WITH (security_invoker = false)
AS
SELECT
  wc.id,
  wc.cycle_no,
  wc.label,
  wc.status,
  s1.label AS qual_season_1_label,
  s2.label AS qual_season_2_label,
  sf.label AS finals_after_season_label,
  public.competition_season_ordinal(wc.finals_after_season_id) AS finals_after_season_ordinal,
  wc.champion_nation,
  cn.name AS champion_name,
  cn.flag_emoji AS champion_flag,
  wc.runner_up_nation,
  rn.name AS runner_up_name,
  rn.flag_emoji AS runner_up_flag,
  wc.third_place_nation,
  tn.name AS third_place_name,
  tn.flag_emoji AS third_place_flag
FROM public.international_wc_cycles wc
LEFT JOIN public.competition_seasons s1 ON s1.id = wc.qual_season_id_1
LEFT JOIN public.competition_seasons s2 ON s2.id = wc.qual_season_id_2
LEFT JOIN public.competition_seasons sf ON sf.id = wc.finals_after_season_id
LEFT JOIN public.international_nations cn ON cn.code = wc.champion_nation
LEFT JOIN public.international_nations rn ON rn.code = wc.runner_up_nation
LEFT JOIN public.international_nations tn ON tn.code = wc.third_place_nation
ORDER BY wc.cycle_no DESC;

GRANT SELECT ON public.international_wc_cycle_public TO authenticated;

-- Ensure matchday squad players readable for owners
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'international_matchday_squad_player'
  ) THEN
    EXECUTE 'GRANT SELECT ON public.international_matchday_squad_player TO authenticated';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
