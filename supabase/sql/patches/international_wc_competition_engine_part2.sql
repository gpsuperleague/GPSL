-- =============================================================================
-- World Cup competition engine — Part 2
-- Results, career stats, qualification, finals draw/fixtures, knockout, post-WC
--
-- Run AFTER international_wc_competition_engine.sql
-- =============================================================================

ALTER TABLE public.international_player_career
  ADD COLUMN IF NOT EXISTS clean_sheets integer NOT NULL DEFAULT 0;

-- ---------------------------------------------------------------------------
-- Apply international player career stats from a JSON array
-- Each item: { player_id, goals?, assists?, rating?, potm?, clean_sheet?, started? }
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.international_apply_player_stats(
  p_player_stats jsonb,
  p_record_appearances boolean DEFAULT true
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_item jsonb;
  v_pid text;
  v_goals int;
  v_assists int;
  v_rating numeric;
  v_potm int;
  v_cs int;
  v_count int := 0;
BEGIN
  IF p_player_stats IS NULL OR jsonb_typeof(p_player_stats) <> 'array' THEN
    RETURN 0;
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_player_stats)
  LOOP
    v_pid := nullif(btrim(coalesce(v_item->>'player_id', v_item->>'Konami_ID', '')), '');
    IF v_pid IS NULL THEN
      CONTINUE;
    END IF;

    v_goals := greatest(coalesce((v_item->>'goals')::int, 0), 0);
    v_assists := greatest(coalesce((v_item->>'assists')::int, 0), 0);
    v_rating := nullif(v_item->>'rating', '')::numeric;
    v_potm := CASE WHEN coalesce((v_item->>'potm')::boolean, false)
                      OR coalesce((v_item->>'potm')::int, 0) > 0
                 THEN 1 ELSE 0 END;
    v_cs := CASE WHEN coalesce((v_item->>'clean_sheet')::boolean, false)
                      OR coalesce((v_item->>'clean_sheets')::int, 0) > 0
                 THEN 1 ELSE 0 END;

    INSERT INTO public.international_player_career (
      player_id, caps, goals, assists, potm, clean_sheets,
      rating_sum, rating_count, updated_at
    )
    VALUES (
      v_pid, 1, v_goals, v_assists, v_potm, v_cs,
      coalesce(v_rating, 0), CASE WHEN v_rating IS NOT NULL THEN 1 ELSE 0 END, now()
    )
    ON CONFLICT (player_id) DO UPDATE
    SET caps = public.international_player_career.caps + 1,
        goals = public.international_player_career.goals + EXCLUDED.goals,
        assists = public.international_player_career.assists + EXCLUDED.assists,
        potm = public.international_player_career.potm + EXCLUDED.potm,
        clean_sheets = public.international_player_career.clean_sheets + EXCLUDED.clean_sheets,
        rating_sum = public.international_player_career.rating_sum + EXCLUDED.rating_sum,
        rating_count = public.international_player_career.rating_count + EXCLUDED.rating_count,
        updated_at = now();

    IF p_record_appearances
       AND to_regprocedure('public.international_record_callup_appearance(text)') IS NOT NULL THEN
      PERFORM public.international_record_callup_appearance(v_pid);
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Apply a confirmed fixture result (standings + knockout + career)
-- ---------------------------------------------------------------------------

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

  -- Knockout: prefer ET then pens for winner; group stages use 90' only
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
END;
$function$;

-- ---------------------------------------------------------------------------
-- Submit / confirm / reject (nation owners)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.international_submit_result(
  p_fixture_id bigint,
  p_home_goals smallint,
  p_away_goals smallint,
  p_player_stats jsonb DEFAULT '[]'::jsonb,
  p_home_goals_et smallint DEFAULT NULL,
  p_away_goals_et smallint DEFAULT NULL,
  p_home_pens smallint DEFAULT NULL,
  p_away_pens smallint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_fix public.international_fixtures;
  v_opp text;
  v_opp_club text;
  v_sub_id bigint;
  v_home_name text;
  v_away_name text;
BEGIN
  IF v_nation IS NULL OR v_nation = '' THEN
    RAISE EXCEPTION 'No national team linked to your club';
  END IF;

  IF p_home_goals IS NULL OR p_away_goals IS NULL OR p_home_goals < 0 OR p_away_goals < 0 THEN
    RAISE EXCEPTION 'Invalid score';
  END IF;

  SELECT * INTO v_fix
  FROM public.international_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fix.played OR v_fix.status = 'played' THEN
    RAISE EXCEPTION 'Fixture already played';
  END IF;

  IF v_nation NOT IN (v_fix.home_nation, v_fix.away_nation) THEN
    RAISE EXCEPTION 'Your nation is not in this fixture';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.international_result_submissions s
    WHERE s.fixture_id = p_fixture_id AND s.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A result is already awaiting confirmation';
  END IF;

  v_opp := CASE WHEN v_nation = v_fix.home_nation THEN v_fix.away_nation ELSE v_fix.home_nation END;
  v_opp_club := public.international_club_for_nation(v_opp);

  INSERT INTO public.international_result_submissions (
    fixture_id, submitted_by_nation, home_goals, away_goals,
    home_goals_et, away_goals_et, home_pens, away_pens,
    player_stats, status
  )
  VALUES (
    p_fixture_id, v_nation, p_home_goals, p_away_goals,
    p_home_goals_et, p_away_goals_et, p_home_pens, p_away_pens,
    coalesce(p_player_stats, '[]'::jsonb), 'pending'
  )
  RETURNING id INTO v_sub_id;

  SELECT name INTO v_home_name FROM public.international_nations WHERE code = v_fix.home_nation;
  SELECT name INTO v_away_name FROM public.international_nations WHERE code = v_fix.away_nation;

  IF v_opp_club IS NOT NULL THEN
    PERFORM public.owner_inbox_send(
      'intl_result_to_confirm',
      format('Confirm international result: %s vs %s', v_home_name, v_away_name),
      format(
        E'%s submitted %s %s Es %s.\nConfirm or reject on International matchday.',
        v_nation, v_home_name, p_home_goals, p_away_goals, v_away_name
      ),
      v_opp_club,
      NULL,
      NULL, NULL, NULL, NULL,
      'international_matchday.html?fixture=' || p_fixture_id::text,
      'intl_result:' || v_sub_id::text,
      v_fix.gpsl_month,
      v_fix.season_id
    );
  END IF;

  RETURN v_sub_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_confirm_result(
  p_submission_id bigint,
  p_confirmer_player_stats jsonb DEFAULT '[]'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_sub public.international_result_submissions;
  v_fix public.international_fixtures;
  v_merged jsonb;
BEGIN
  IF v_nation IS NULL THEN
    RAISE EXCEPTION 'No national team linked to your club';
  END IF;

  SELECT * INTO v_sub
  FROM public.international_result_submissions
  WHERE id = p_submission_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission not found';
  END IF;

  IF v_sub.status <> 'pending' THEN
    RAISE EXCEPTION 'Submission is not pending';
  END IF;

  SELECT * INTO v_fix FROM public.international_fixtures WHERE id = v_sub.fixture_id;

  IF v_nation NOT IN (v_fix.home_nation, v_fix.away_nation) THEN
    RAISE EXCEPTION 'Your nation is not in this fixture';
  END IF;

  IF v_nation = v_sub.submitted_by_nation AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Opponent must confirm the result';
  END IF;

  v_merged := coalesce(v_sub.player_stats, '[]'::jsonb);
  IF p_confirmer_player_stats IS NOT NULL
     AND jsonb_typeof(p_confirmer_player_stats) = 'array'
     AND jsonb_array_length(p_confirmer_player_stats) > 0 THEN
    v_merged := v_merged || p_confirmer_player_stats;
  END IF;

  PERFORM public.international_apply_fixture_result(
    v_sub.fixture_id,
    v_sub.home_goals,
    v_sub.away_goals,
    v_merged,
    v_sub.home_goals_et,
    v_sub.away_goals_et,
    v_sub.home_pens,
    v_sub.away_pens
  );

  UPDATE public.international_result_submissions
  SET status = 'confirmed', resolved_at = now()
  WHERE id = p_submission_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_reject_result(p_submission_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_sub public.international_result_submissions;
  v_fix public.international_fixtures;
BEGIN
  SELECT * INTO v_sub FROM public.international_result_submissions WHERE id = p_submission_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Submission not found'; END IF;
  IF v_sub.status <> 'pending' THEN RAISE EXCEPTION 'Submission is not pending'; END IF;

  SELECT * INTO v_fix FROM public.international_fixtures WHERE id = v_sub.fixture_id;
  IF v_nation NOT IN (v_fix.home_nation, v_fix.away_nation)
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  UPDATE public.international_result_submissions
  SET status = 'rejected', resolved_at = now()
  WHERE id = p_submission_id;
END;
$function$;

-- Admin force-confirm (bypass opponent)
CREATE OR REPLACE FUNCTION public.international_admin_force_result(
  p_fixture_id bigint,
  p_home_goals smallint,
  p_away_goals smallint,
  p_player_stats jsonb DEFAULT '[]'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  PERFORM public.international_apply_fixture_result(
    p_fixture_id, p_home_goals, p_away_goals, p_player_stats
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Qualification: top 2 + 8 best thirds ↁE32
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.international_rank_qual_thirds(p_cycle_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cycle public.international_wc_cycles;
  v_unplayed int;
BEGIN
  v_cycle := public.international_assert_cycle_admin(p_cycle_id);

  SELECT count(*) INTO v_unplayed
  FROM public.international_fixtures f
  WHERE f.cycle_id = p_cycle_id AND f.phase = 'qualifying' AND f.played = false;

  IF v_unplayed > 0 THEN
    RAISE EXCEPTION 'All qualifying fixtures must be played first (% remaining)', v_unplayed;
  END IF;

  -- Reset flags
  UPDATE public.international_qual_group_members m
  SET qualified = false, third_place_rank = NULL
  FROM public.international_qual_groups g
  WHERE m.group_id = g.id AND g.cycle_id = p_cycle_id;

  -- Rank within each group, qualify top 2, then rank all 3rds globally
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

-- ---------------------------------------------------------------------------
-- Finals draw  E32 qualified into 8 groups of 4 via seed pots
-- Pot 1 = seeds 1 E among qualified (by nation seed_rank), etc.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.international_admin_draw_finals_groups(p_cycle_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cycle public.international_wc_cycles;
  v_nations text[];
  v_pot text[];
  v_groups text[] := ARRAY['A','B','C','D','E','F','G','H'];
  v_group_ids bigint[] := ARRAY[]::bigint[];
  v_gid bigint;
  v_i int;
  v_pot_no int;
  v_code text;
  v_qual_count int;
BEGIN
  v_cycle := public.international_assert_cycle_admin(p_cycle_id);

  SELECT count(*) INTO v_qual_count
  FROM public.international_qual_group_members m
  JOIN public.international_qual_groups g ON g.id = m.group_id
  WHERE g.cycle_id = p_cycle_id AND m.qualified = true;

  IF v_qual_count <> 32 THEN
    -- Auto-run ranking if not done
    PERFORM public.international_rank_qual_thirds(p_cycle_id);
    SELECT count(*) INTO v_qual_count
    FROM public.international_qual_group_members m
    JOIN public.international_qual_groups g ON g.id = m.group_id
    WHERE g.cycle_id = p_cycle_id AND m.qualified = true;
  END IF;

  IF v_qual_count <> 32 THEN
    RAISE EXCEPTION 'Need 32 qualified nations (have %)', v_qual_count;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.international_fixtures f
    WHERE f.cycle_id = p_cycle_id AND f.phase IN ('finals_group', 'knockout') AND f.played = true
  ) THEN
    RAISE EXCEPTION 'Cannot re-draw finals: fixtures already played';
  END IF;

  SELECT array_agg(x.code ORDER BY x.seed_rank, x.code)
  INTO v_nations
  FROM (
    SELECT n.code, n.seed_rank
    FROM public.international_qual_group_members m
    JOIN public.international_qual_groups g ON g.id = m.group_id
    JOIN public.international_nations n ON n.code = m.nation_code
    WHERE g.cycle_id = p_cycle_id AND m.qualified = true
    ORDER BY n.seed_rank ASC, n.code ASC
  ) x;

  DELETE FROM public.international_fixtures
  WHERE cycle_id = p_cycle_id AND phase IN ('finals_group', 'knockout');
  DELETE FROM public.international_knockout_nodes WHERE cycle_id = p_cycle_id;
  DELETE FROM public.international_finals_group_members m
  USING public.international_finals_groups g
  WHERE m.group_id = g.id AND g.cycle_id = p_cycle_id;
  DELETE FROM public.international_finals_groups WHERE cycle_id = p_cycle_id;

  FOREACH v_code IN ARRAY v_groups LOOP
    INSERT INTO public.international_finals_groups (cycle_id, group_code)
    VALUES (p_cycle_id, v_code)
    RETURNING id INTO v_gid;
    v_group_ids := v_group_ids || v_gid;
  END LOOP;

  -- 4 pots of 8
  FOR v_pot_no IN 1..4 LOOP
    v_pot := v_nations[((v_pot_no - 1) * 8 + 1):(v_pot_no * 8)];
    v_pot := public.international_shuffle_text_array(v_pot);
    FOR v_i IN 1..8 LOOP
      INSERT INTO public.international_finals_group_members (group_id, nation_code)
      VALUES (v_group_ids[v_i], v_pot[v_i]);
    END LOOP;
  END LOOP;

  UPDATE public.international_wc_cycles SET status = 'finals' WHERE id = p_cycle_id;

  RETURN jsonb_build_object('ok', true, 'cycle_id', p_cycle_id, 'groups', 8, 'nations', 32);
END;
$function$;

-- Finals group fixtures: single round-robin (3 matchdays ÁE2 games = 6 per group)
CREATE OR REPLACE FUNCTION public.international_generate_finals_group_fixtures(p_cycle_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cycle public.international_wc_cycles;
  v_group record;
  v_teams text[];
  v_slots text[];
  v_round int;
  v_i int;
  v_a text;
  v_b text;
  v_home text;
  v_away text;
  v_tmp text;
  v_fid bigint;
  v_inserted bigint := 0;
  v_season_id bigint;
BEGIN
  v_cycle := public.international_assert_cycle_admin(p_cycle_id);
  v_season_id := v_cycle.finals_after_season_id;

  IF NOT EXISTS (SELECT 1 FROM public.international_finals_groups WHERE cycle_id = p_cycle_id) THEN
    RAISE EXCEPTION 'Draw finals groups first';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.international_fixtures f
    WHERE f.cycle_id = p_cycle_id AND f.phase = 'finals_group' AND f.played = true
  ) THEN
    RAISE EXCEPTION 'Cannot regenerate: finals group fixtures already played';
  END IF;

  DELETE FROM public.international_fixtures
  WHERE cycle_id = p_cycle_id AND phase = 'finals_group';

  FOR v_group IN
    SELECT g.id, g.group_code FROM public.international_finals_groups g
    WHERE g.cycle_id = p_cycle_id ORDER BY g.group_code
  LOOP
    SELECT array_agg(m.nation_code ORDER BY m.nation_code)
    INTO v_teams
    FROM public.international_finals_group_members m
    WHERE m.group_id = v_group.id;

    IF coalesce(array_length(v_teams, 1), 0) <> 4 THEN
      RAISE EXCEPTION 'Finals group % must have 4 nations', v_group.group_code;
    END IF;

    -- Circle method for 4 teams: 3 rounds, 2 matches each
    v_slots := v_teams;
    FOR v_round IN 1..3 LOOP
      FOR v_i IN 1..2 LOOP
        v_a := v_slots[v_i];
        v_b := v_slots[5 - v_i];
        IF (v_round % 2) = 1 THEN
          v_home := v_a; v_away := v_b;
        ELSE
          v_home := v_b; v_away := v_a;
        END IF;

        INSERT INTO public.international_fixtures (
          cycle_id, season_id, phase, group_id,
          home_nation, away_nation, match_no,
          gpsl_month, week_in_month, status, played
        )
        VALUES (
          p_cycle_id, v_season_id, 'finals_group', v_group.id,
          v_home, v_away, v_round,
          CASE v_round WHEN 1 THEN 'june' WHEN 2 THEN 'june' ELSE 'july' END,
          CASE WHEN v_i = 1 THEN 1 ELSE 2 END,
          'scheduled', false
        )
        RETURNING id INTO v_fid;

        INSERT INTO public.international_fixture_schedule (fixture_id, status)
        VALUES (v_fid, 'unscheduled')
        ON CONFLICT DO NOTHING;

        v_inserted := v_inserted + 1;
      END LOOP;

      v_tmp := v_slots[4];
      FOR v_i IN REVERSE 4..3 LOOP
        v_slots[v_i] := v_slots[v_i - 1];
      END LOOP;
      v_slots[2] := v_tmp;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'fixtures', v_inserted);
END;
$function$;

-- Mark top 2 from each finals group for knockout
CREATE OR REPLACE FUNCTION public.international_mark_finals_knockout_qualifiers(p_cycle_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_unplayed int;
BEGIN
  PERFORM public.international_assert_cycle_admin(p_cycle_id);

  SELECT count(*) INTO v_unplayed
  FROM public.international_fixtures f
  WHERE f.cycle_id = p_cycle_id AND f.phase = 'finals_group' AND f.played = false;

  IF v_unplayed > 0 THEN
    RAISE EXCEPTION 'All finals group fixtures must be played (% remaining)', v_unplayed;
  END IF;

  UPDATE public.international_finals_group_members m
  SET qualified_knockout = false
  FROM public.international_finals_groups g
  WHERE m.group_id = g.id AND g.cycle_id = p_cycle_id;

  WITH ranked AS (
    SELECT m.id,
           row_number() OVER (
             PARTITION BY m.group_id
             ORDER BY m.points DESC,
                      (m.goals_for - m.goals_against) DESC,
                      m.goals_for DESC,
                      m.nation_code
           ) AS pos
    FROM public.international_finals_group_members m
    JOIN public.international_finals_groups g ON g.id = m.group_id
    WHERE g.cycle_id = p_cycle_id
  )
  UPDATE public.international_finals_group_members m
  SET qualified_knockout = true
  FROM ranked r
  WHERE m.id = r.id AND r.pos <= 2;

  RETURN jsonb_build_object('ok', true, 'qualified', 16);
END;
$function$;

-- Seed R16 bracket from group winners/runners-up (standard WC pairing)
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
  -- R16: 1A vs 2B, 1C vs 2D, 1E vs 2F, 1G vs 2H, 1B vs 2A, 1D vs 2C, 1F vs 2E, 1H vs 2G
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

  -- Create all knockout nodes (empty QF/SF/Final slots filled as winners advance)
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
  VALUES (p_cycle_id, 'final', 1, false);

  RETURN jsonb_build_object('ok', true, 'r16', 8);
END;
$function$;

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
  v_next_stage text;
  v_next_match smallint;
  v_slot text;
  v_fid bigint;
  v_season_id bigint;
BEGIN
  SELECT * INTO v_node FROM public.international_knockout_nodes WHERE id = p_node_id;
  IF NOT FOUND THEN RETURN; END IF;

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
    UPDATE public.international_wc_cycles SET status = 'complete' WHERE id = p_cycle_id;
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
-- Schedule propose / accept (nation owners)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.international_propose_kickoff(
  p_fixture_id bigint,
  p_kickoff_at timestamptz
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_fix public.international_fixtures;
  v_sched public.international_fixture_schedule;
  v_prop_id bigint;
  v_opp text;
  v_opp_club text;
BEGIN
  IF v_nation IS NULL THEN RAISE EXCEPTION 'No national team'; END IF;
  IF p_kickoff_at IS NULL THEN RAISE EXCEPTION 'Kickoff required'; END IF;

  SELECT * INTO v_fix FROM public.international_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fixture not found'; END IF;
  IF v_nation NOT IN (v_fix.home_nation, v_fix.away_nation) THEN
    RAISE EXCEPTION 'Not your fixture';
  END IF;
  IF v_fix.played THEN RAISE EXCEPTION 'Already played'; END IF;

  INSERT INTO public.international_fixture_schedule (fixture_id, status)
  VALUES (p_fixture_id, 'unscheduled')
  ON CONFLICT (fixture_id) DO NOTHING;

  SELECT * INTO v_sched FROM public.international_fixture_schedule WHERE fixture_id = p_fixture_id FOR UPDATE;

  UPDATE public.international_fixture_schedule_proposal
  SET status = 'superseded'
  WHERE fixture_id = p_fixture_id AND status = 'pending';

  INSERT INTO public.international_fixture_schedule_proposal (
    fixture_id, proposed_by_nation, kickoff_at, status
  )
  VALUES (p_fixture_id, v_nation, p_kickoff_at, 'pending')
  RETURNING id INTO v_prop_id;

  UPDATE public.international_fixture_schedule
  SET status = 'negotiating',
      pending_proposal_id = v_prop_id,
      home_proposal_count = home_proposal_count
        + CASE WHEN v_nation = v_fix.home_nation THEN 1 ELSE 0 END,
      away_proposal_count = away_proposal_count
        + CASE WHEN v_nation = v_fix.away_nation THEN 1 ELSE 0 END,
      updated_at = now()
  WHERE fixture_id = p_fixture_id;

  v_opp := CASE WHEN v_nation = v_fix.home_nation THEN v_fix.away_nation ELSE v_fix.home_nation END;
  v_opp_club := public.international_club_for_nation(v_opp);
  IF v_opp_club IS NOT NULL THEN
    PERFORM public.owner_inbox_send(
      'intl_kickoff_proposal',
      'International kickoff proposed',
      format('A kickoff time was proposed for %s vs %s.', v_fix.home_nation, v_fix.away_nation),
      v_opp_club, NULL, NULL, NULL, NULL, NULL,
      'international_matchday.html?fixture=' || p_fixture_id::text,
      'intl_ko:' || v_prop_id::text,
      v_fix.gpsl_month, v_fix.season_id
    );
  END IF;

  RETURN v_prop_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_accept_kickoff(p_proposal_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_prop public.international_fixture_schedule_proposal;
  v_fix public.international_fixtures;
BEGIN
  SELECT * INTO v_prop FROM public.international_fixture_schedule_proposal WHERE id = p_proposal_id FOR UPDATE;
  IF NOT FOUND OR v_prop.status <> 'pending' THEN
    RAISE EXCEPTION 'Proposal not available';
  END IF;

  SELECT * INTO v_fix FROM public.international_fixtures WHERE id = v_prop.fixture_id;
  IF v_nation NOT IN (v_fix.home_nation, v_fix.away_nation) THEN
    RAISE EXCEPTION 'Not your fixture';
  END IF;
  IF v_nation = v_prop.proposed_by_nation AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Opponent must accept';
  END IF;

  UPDATE public.international_fixture_schedule_proposal
  SET status = 'accepted' WHERE id = p_proposal_id;

  UPDATE public.international_fixture_schedule_proposal
  SET status = 'superseded'
  WHERE fixture_id = v_prop.fixture_id AND id <> p_proposal_id AND status = 'pending';

  UPDATE public.international_fixture_schedule
  SET status = 'agreed',
      agreed_kickoff_at = v_prop.kickoff_at,
      pending_proposal_id = NULL,
      updated_at = now()
  WHERE fixture_id = v_prop.fixture_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Nation matchday squad save
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.international_save_matchday_squad(
  p_players jsonb,
  p_pitch_layout jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_item jsonb;
  v_pid text;
  v_kind text;
  v_slot text;
  v_ord smallint;
  v_mirror text;
BEGIN
  IF v_nation IS NULL THEN RAISE EXCEPTION 'No national team'; END IF;

  IF to_regprocedure('public.validate_pitch_layout_mirroring(jsonb)') IS NOT NULL THEN
    v_mirror := public.validate_pitch_layout_mirroring(p_pitch_layout);
    IF v_mirror IS NOT NULL THEN
      RAISE EXCEPTION '%', v_mirror;
    END IF;
  END IF;

  INSERT INTO public.international_matchday_squad (nation_code, pitch_layout, updated_at)
  VALUES (v_nation, coalesce(p_pitch_layout, '{}'::jsonb), now())
  ON CONFLICT (nation_code) DO UPDATE
  SET pitch_layout = EXCLUDED.pitch_layout, updated_at = now();

  DELETE FROM public.international_matchday_squad_player WHERE nation_code = v_nation;

  IF p_players IS NULL OR jsonb_typeof(p_players) <> 'array' THEN
    RETURN;
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_players)
  LOOP
    v_pid := nullif(btrim(coalesce(v_item->>'player_id', '')), '');
    v_kind := lower(btrim(coalesce(v_item->>'slot_kind', '')));
    v_slot := nullif(btrim(coalesce(v_item->>'pitch_slot', '')), '');
    v_ord := coalesce((v_item->>'sort_order')::smallint, 0);

    IF v_pid IS NULL OR v_kind NOT IN ('pitch', 'bench', 'reserve') THEN
      CONTINUE;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.international_squad_callups c
      WHERE c.nation_code = v_nation AND c.player_id = v_pid AND c.is_active
    ) THEN
      RAISE EXCEPTION 'Player % is not in your national squad', v_pid;
    END IF;

    INSERT INTO public.international_matchday_squad_player (
      nation_code, player_id, slot_kind, pitch_slot, sort_order
    )
    VALUES (
      v_nation, v_pid, v_kind,
      CASE WHEN v_kind = 'pitch' THEN v_slot ELSE NULL END,
      v_ord
    );
  END LOOP;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Post-WC: release nations + open re-selection
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.international_admin_complete_wc_and_open_reselection(
  p_cycle_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cycle public.international_wc_cycles;
  v_cleared int;
  v_window_id bigint;
BEGIN
  v_cycle := public.international_assert_cycle_admin(p_cycle_id);

  UPDATE public.international_wc_cycles SET status = 'complete' WHERE id = p_cycle_id;

  -- Recompute owner rankings so draft order is fresh
  IF to_regprocedure('public.competition_owner_ranking_recompute_all()') IS NOT NULL THEN
    PERFORM public.competition_owner_ranking_recompute_all();
  END IF;

  UPDATE public.international_owner_nations
  SET is_active = false, released_at = now()
  WHERE is_active = true;
  GET DIAGNOSTICS v_cleared = ROW_COUNT;

  UPDATE public.international_selection_windows
  SET is_open = false, closes_at = coalesce(closes_at, now())
  WHERE is_open = true;

  INSERT INTO public.international_selection_windows (phase, is_open, opens_at, current_pick_rank)
  VALUES ('post_world_cup', true, now(), 1)
  RETURNING id INTO v_window_id;

  -- Notify owners (best-effort)
  IF to_regprocedure('public.owner_inbox_notify_all_clubs(text,text,text,text,text,bigint)') IS NOT NULL THEN
    PERFORM public.owner_inbox_notify_all_clubs(
      'nation_selection_open',
      'Post–World Cup nation re-selection is open',
      E'The World Cup is complete. All nations are free  Epick again in ranking order.',
      'nation_select.html',
      'post_wc_open:' || v_window_id::text,
      NULL
    );
  END IF;

  IF to_regprocedure('public.owner_inbox_notify_nation_pick_turn(integer)') IS NOT NULL THEN
    PERFORM public.owner_inbox_notify_nation_pick_turn(1);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'cycle_id', p_cycle_id,
    'nations_released', v_cleared,
    'selection_window_id', v_window_id
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Public views for fixtures + knockout
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.international_fixtures_public;
CREATE VIEW public.international_fixtures_public
WITH (security_invoker = false)
AS
SELECT
  f.id,
  f.cycle_id,
  wc.cycle_no,
  wc.label AS cycle_label,
  f.season_id,
  f.phase,
  f.group_id,
  COALESCE(qg.group_code, fg.group_code) AS group_code,
  f.knockout_node_id,
  kn.stage AS knockout_stage,
  kn.match_no AS knockout_match_no,
  f.home_nation,
  hn.name AS home_nation_name,
  hn.flag_emoji AS home_flag,
  f.away_nation,
  an.name AS away_nation_name,
  an.flag_emoji AS away_flag,
  f.home_goals,
  f.away_goals,
  f.match_no,
  f.gpsl_month,
  f.week_in_month,
  f.status,
  f.played,
  f.played_at,
  sch.status AS schedule_status,
  sch.agreed_kickoff_at,
  f.created_at
FROM public.international_fixtures f
JOIN public.international_wc_cycles wc ON wc.id = f.cycle_id
JOIN public.international_nations hn ON hn.code = f.home_nation
JOIN public.international_nations an ON an.code = f.away_nation
LEFT JOIN public.international_qual_groups qg
  ON qg.id = f.group_id AND f.phase = 'qualifying'
LEFT JOIN public.international_finals_groups fg
  ON fg.id = f.group_id AND f.phase = 'finals_group'
LEFT JOIN public.international_knockout_nodes kn ON kn.id = f.knockout_node_id
LEFT JOIN public.international_fixture_schedule sch ON sch.fixture_id = f.id;

GRANT SELECT ON public.international_fixtures_public TO authenticated;

DROP VIEW IF EXISTS public.international_knockout_public;
CREATE VIEW public.international_knockout_public
WITH (security_invoker = false)
AS
SELECT
  kn.id,
  kn.cycle_id,
  wc.cycle_no,
  kn.stage,
  kn.match_no,
  kn.nation_a,
  na.name AS nation_a_name,
  na.flag_emoji AS nation_a_flag,
  kn.nation_b,
  nb.name AS nation_b_name,
  nb.flag_emoji AS nation_b_flag,
  kn.goals_a,
  kn.goals_b,
  kn.winner_nation,
  kn.played
FROM public.international_knockout_nodes kn
JOIN public.international_wc_cycles wc ON wc.id = kn.cycle_id
LEFT JOIN public.international_nations na ON na.code = kn.nation_a
LEFT JOIN public.international_nations nb ON nb.code = kn.nation_b;

GRANT SELECT ON public.international_knockout_public TO authenticated;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.international_club_for_nation(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_create_wc_cycle(text, bigint, bigint, bigint, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_update_wc_cycle(bigint, text, bigint, bigint, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_set_wc_cycle_status(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_draw_qual_groups(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_generate_qual_fixtures(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_recompute_group_standings(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_apply_player_stats(jsonb, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_apply_fixture_result(bigint, smallint, smallint, jsonb, smallint, smallint, smallint, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_submit_result(bigint, smallint, smallint, jsonb, smallint, smallint, smallint, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_confirm_result(bigint, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_reject_result(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_force_result(bigint, smallint, smallint, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_rank_qual_thirds(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_draw_finals_groups(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_generate_finals_group_fixtures(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_mark_finals_knockout_qualifiers(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_seed_knockout_bracket(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_advance_knockout_winner(bigint, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_propose_kickoff(bigint, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_accept_kickoff(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_save_matchday_squad(jsonb, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_complete_wc_and_open_reselection(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

