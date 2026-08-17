-- =============================================================================
-- Popup single-season World Cup (test format)
--
-- Adds cycle_mode: 'standard' | 'popup_single_season'
-- Popup: one season June→May — qualifying single RR (play once), then finals
-- groups + knockout later in the same season (not pre-season).
--
-- Safe re-run. Apply after international_wc_ko_third_and_dryrun.sql (and prior WC patches).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
ALTER TABLE public.international_wc_cycles
  ADD COLUMN IF NOT EXISTS cycle_mode text NOT NULL DEFAULT 'standard';

DO $$
BEGIN
  ALTER TABLE public.international_wc_cycles
    DROP CONSTRAINT IF EXISTS international_wc_cycles_cycle_mode_check;
EXCEPTION WHEN undefined_object THEN
  NULL;
END $$;

ALTER TABLE public.international_wc_cycles
  ADD CONSTRAINT international_wc_cycles_cycle_mode_check
  CHECK (cycle_mode IN ('standard', 'popup_single_season'));

COMMENT ON COLUMN public.international_wc_cycles.cycle_mode IS
  'standard = 2-season double-RR qual + pre-season finals; '
  'popup_single_season = one season, single-RR qual + in-season finals (June–May test).';

-- ---------------------------------------------------------------------------
-- Calendars
-- ---------------------------------------------------------------------------
-- Standard (unchanged): match_no 1–5 / 6–10 → Aug/Oct/Dec/Feb/Apr
CREATE OR REPLACE FUNCTION public.international_qual_match_calendar(p_match_no integer)
RETURNS TABLE (gpsl_month text, week_in_month smallint)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    CASE ((CASE WHEN p_match_no <= 5 THEN p_match_no ELSE p_match_no - 5 END))
      WHEN 1 THEN 'august'
      WHEN 2 THEN 'october'
      WHEN 3 THEN 'december'
      WHEN 4 THEN 'february'
      WHEN 5 THEN 'april'
      ELSE 'may'
    END,
    2::smallint;
$$;

-- Popup single-season: one single RR only (match_no 1–5) across early/mid season
CREATE OR REPLACE FUNCTION public.international_popup_qual_match_calendar(p_match_no integer)
RETURNS TABLE (gpsl_month text, week_in_month smallint)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    CASE p_match_no
      WHEN 1 THEN 'june'
      WHEN 2 THEN 'august'
      WHEN 3 THEN 'october'
      WHEN 4 THEN 'december'
      WHEN 5 THEN 'february'
      ELSE 'february'
    END,
    2::smallint;
$$;

COMMENT ON FUNCTION public.international_popup_qual_match_calendar(integer) IS
  'Popup WC: single RR windows June/Aug/Oct/Dec/Feb (one bye each round; 4 games/nation).';

-- Finals group months: standard = june/july pre-season; popup = march/april same season
CREATE OR REPLACE FUNCTION public.international_finals_group_calendar(
  p_round integer,
  p_cycle_mode text DEFAULT 'standard'
)
RETURNS TABLE (gpsl_month text, week_in_month smallint)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    CASE
      WHEN lower(coalesce(p_cycle_mode, 'standard')) = 'popup_single_season' THEN
        CASE p_round
          WHEN 1 THEN 'march'
          WHEN 2 THEN 'march'
          ELSE 'april'
        END
      ELSE
        CASE p_round WHEN 1 THEN 'june' WHEN 2 THEN 'june' ELSE 'july' END
    END,
    CASE
      WHEN lower(coalesce(p_cycle_mode, 'standard')) = 'popup_single_season' THEN
        CASE WHEN p_round = 2 THEN 2::smallint ELSE 1::smallint END
      ELSE
        1::smallint
    END;
$$;

-- Knockout months: standard = july; popup = may
CREATE OR REPLACE FUNCTION public.international_knockout_calendar(
  p_stage text,
  p_cycle_mode text DEFAULT 'standard'
)
RETURNS TABLE (gpsl_month text, week_in_month smallint)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    CASE
      WHEN lower(coalesce(p_cycle_mode, 'standard')) = 'popup_single_season' THEN 'may'
      ELSE 'july'
    END,
    CASE
      WHEN lower(coalesce(p_cycle_mode, 'standard')) = 'popup_single_season' THEN
        CASE lower(coalesce(p_stage, ''))
          WHEN 'r16' THEN 1::smallint
          WHEN 'qf' THEN 2::smallint
          WHEN 'sf' THEN 3::smallint
          ELSE 4::smallint
        END
      ELSE
        CASE WHEN lower(coalesce(p_stage, '')) = 'r16' THEN 1::smallint ELSE 2::smallint END
    END;
$$;

-- ---------------------------------------------------------------------------
-- Create cycle (optional mode)
-- Drop older signatures so PostgREST sees one function (extra DEFAULT arg).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.international_admin_create_wc_cycle(text, bigint, bigint, bigint);
DROP FUNCTION IF EXISTS public.international_admin_create_wc_cycle(text, bigint, bigint, bigint, smallint);
DROP FUNCTION IF EXISTS public.international_admin_create_wc_cycle(text, bigint, bigint, bigint, smallint, text);

CREATE OR REPLACE FUNCTION public.international_admin_create_wc_cycle(
  p_label text,
  p_qual_season_id_1 bigint,
  p_qual_season_id_2 bigint,
  p_finals_after_season_id bigint,
  p_cycle_no smallint DEFAULT NULL,
  p_cycle_mode text DEFAULT 'standard'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_no smallint;
  v_id bigint;
  v_label text := nullif(btrim(p_label), '');
  v_mode text := lower(nullif(btrim(p_cycle_mode), ''));
  v_q1 bigint := p_qual_season_id_1;
  v_q2 bigint := p_qual_season_id_2;
  v_fin bigint := p_finals_after_season_id;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_label IS NULL THEN
    RAISE EXCEPTION 'Label required';
  END IF;

  IF v_mode IS NULL THEN
    v_mode := 'standard';
  END IF;
  IF v_mode NOT IN ('standard', 'popup_single_season') THEN
    RAISE EXCEPTION 'cycle_mode must be standard or popup_single_season';
  END IF;

  IF v_mode = 'popup_single_season' THEN
    -- Single season for qual + finals; accept any of the three and mirror.
    IF v_q1 IS NULL AND v_q2 IS NULL AND v_fin IS NULL THEN
      RAISE EXCEPTION 'Popup WC requires a season id';
    END IF;
    v_q1 := coalesce(v_q1, v_q2, v_fin);
    v_q2 := v_q1;
    v_fin := v_q1;
  ELSE
    IF v_q1 IS NULL OR v_q2 IS NULL OR v_fin IS NULL THEN
      RAISE EXCEPTION 'Qualifying season 1, season 2, and finals-after season are required';
    END IF;
    IF v_q1 = v_q2 THEN
      RAISE EXCEPTION 'Qualifying seasons must be different';
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.competition_seasons WHERE id = v_q1) THEN
    RAISE EXCEPTION 'Qualifying season 1 not found';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.competition_seasons WHERE id = v_q2) THEN
    RAISE EXCEPTION 'Qualifying season 2 not found';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.competition_seasons WHERE id = v_fin) THEN
    RAISE EXCEPTION 'Finals-after season not found';
  END IF;

  IF p_cycle_no IS NOT NULL THEN
    v_no := p_cycle_no;
  ELSE
    SELECT coalesce(max(cycle_no), 0) + 1 INTO v_no FROM public.international_wc_cycles;
  END IF;

  INSERT INTO public.international_wc_cycles (
    cycle_no, label, qual_season_id_1, qual_season_id_2, finals_after_season_id,
    status, cycle_mode
  )
  VALUES (
    v_no, v_label, v_q1, v_q2, v_fin, 'setup', v_mode
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'cycle_id', v_id,
    'cycle_no', v_no,
    'label', v_label,
    'status', 'setup',
    'cycle_mode', v_mode
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Qual fixtures: standard double RR (2 seasons) OR popup single RR (1 season)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_generate_qual_fixtures(p_cycle_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cycle public.international_wc_cycles;
  v_mode text;
  v_popup boolean;
  v_group record;
  v_teams text[];
  v_n int;
  v_slots text[];
  v_round int;
  v_match_no int;
  v_i int;
  v_a text;
  v_b text;
  v_home text;
  v_away text;
  v_tmp text;
  v_cal record;
  v_season_id bigint;
  v_inserted bigint := 0;
  v_first_leg boolean;
  v_fid bigint;
  v_legs boolean[];
BEGIN
  v_cycle := public.international_assert_cycle_admin(p_cycle_id);
  v_mode := lower(coalesce(v_cycle.cycle_mode, 'standard'));
  v_popup := (v_mode = 'popup_single_season');

  IF v_popup THEN
    IF v_cycle.qual_season_id_1 IS NULL THEN
      RAISE EXCEPTION 'Set the popup season on the cycle first';
    END IF;
  ELSIF v_cycle.qual_season_id_1 IS NULL OR v_cycle.qual_season_id_2 IS NULL THEN
    RAISE EXCEPTION 'Set both qualifying seasons on the cycle first';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.international_qual_groups g WHERE g.cycle_id = p_cycle_id
  ) THEN
    RAISE EXCEPTION 'Draw qualifying groups first';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.international_fixtures f
    WHERE f.cycle_id = p_cycle_id AND f.phase = 'qualifying' AND f.played = true
  ) THEN
    RAISE EXCEPTION 'Cannot regenerate: qualifying fixtures already played';
  END IF;

  DELETE FROM public.international_fixtures
  WHERE cycle_id = p_cycle_id AND phase = 'qualifying';

  IF v_popup THEN
    v_legs := ARRAY[true];
  ELSE
    v_legs := ARRAY[true, false];
  END IF;

  FOR v_group IN
    SELECT g.id, g.group_code
    FROM public.international_qual_groups g
    WHERE g.cycle_id = p_cycle_id
    ORDER BY g.group_code
  LOOP
    SELECT array_agg(m.nation_code ORDER BY m.nation_code)
    INTO v_teams
    FROM public.international_qual_group_members m
    WHERE m.group_id = v_group.id;

    v_n := coalesce(array_length(v_teams, 1), 0);
    IF v_n <> 5 THEN
      RAISE EXCEPTION 'Group % must have 5 nations (has %)', v_group.group_code, v_n;
    END IF;

    FOREACH v_first_leg IN ARRAY v_legs LOOP
      v_slots := v_teams || ARRAY[NULL::text];
      FOR v_round IN 1..5 LOOP
        v_match_no := CASE WHEN v_first_leg THEN v_round ELSE v_round + 5 END;
        v_season_id := CASE
          WHEN v_popup THEN v_cycle.qual_season_id_1
          WHEN v_match_no <= 5 THEN v_cycle.qual_season_id_1
          ELSE v_cycle.qual_season_id_2
        END;

        IF v_popup THEN
          SELECT * INTO v_cal FROM public.international_popup_qual_match_calendar(v_match_no);
        ELSE
          SELECT * INTO v_cal FROM public.international_qual_match_calendar(v_match_no);
        END IF;

        FOR v_i IN 1..3 LOOP
          v_a := v_slots[v_i];
          v_b := v_slots[7 - v_i];
          IF v_a IS NULL OR v_b IS NULL THEN
            CONTINUE;
          END IF;

          IF (v_round % 2) = 1 THEN
            v_home := v_a;
            v_away := v_b;
          ELSE
            v_home := v_b;
            v_away := v_a;
          END IF;

          IF NOT v_first_leg THEN
            v_tmp := v_home;
            v_home := v_away;
            v_away := v_tmp;
          END IF;

          INSERT INTO public.international_fixtures (
            cycle_id, season_id, phase, group_id,
            home_nation, away_nation, match_no,
            gpsl_month, week_in_month, status, played
          )
          VALUES (
            p_cycle_id, v_season_id, 'qualifying', v_group.id,
            v_home, v_away, v_match_no,
            v_cal.gpsl_month, v_cal.week_in_month, 'scheduled', false
          )
          RETURNING id INTO v_fid;

          INSERT INTO public.international_fixture_schedule (fixture_id, status)
          VALUES (v_fid, 'unscheduled')
          ON CONFLICT (fixture_id) DO NOTHING;

          v_inserted := v_inserted + 1;
        END LOOP;

        v_tmp := v_slots[6];
        FOR v_i IN REVERSE 6..3 LOOP
          v_slots[v_i] := v_slots[v_i - 1];
        END LOOP;
        v_slots[2] := v_tmp;
      END LOOP;
    END LOOP;
  END LOOP;

  IF v_cycle.status = 'setup' THEN
    UPDATE public.international_wc_cycles SET status = 'qualifying' WHERE id = p_cycle_id;
  END IF;

  IF v_popup THEN
    RETURN jsonb_build_object(
      'ok', true,
      'cycle_id', p_cycle_id,
      'cycle_mode', v_mode,
      'fixtures', v_inserted,
      'per_group', 10,
      'games_per_nation', 4,
      'calendar_windows', 5,
      'note',
        'Popup WC: each nation plays 4 games (single RR). '
        'Windows June/Aug/Oct/Dec/Feb (one bye each round).'
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'cycle_id', p_cycle_id,
    'cycle_mode', v_mode,
    'fixtures', v_inserted,
    'per_group', 20,
    'games_per_nation', 8,
    'games_per_nation_per_season', 4,
    'calendar_windows_per_season', 5,
    'note',
      'Each nation plays 4 games per season (8 total). '
      '5 calendar windows per season because groups of 5 need one bye each round.'
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Finals group fixtures (popup months)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_generate_finals_group_fixtures(p_cycle_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cycle public.international_wc_cycles;
  v_mode text;
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
  v_cal record;
BEGIN
  v_cycle := public.international_assert_cycle_admin(p_cycle_id);
  v_mode := lower(coalesce(v_cycle.cycle_mode, 'standard'));
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

    v_slots := v_teams;
    FOR v_round IN 1..3 LOOP
      SELECT * INTO v_cal
      FROM public.international_finals_group_calendar(v_round, v_mode);

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
          v_cal.gpsl_month,
          CASE
            WHEN v_mode = 'popup_single_season' THEN v_cal.week_in_month
            WHEN v_i = 1 THEN 1
            ELSE 2
          END,
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

  RETURN jsonb_build_object(
    'ok', true,
    'fixtures', v_inserted,
    'cycle_mode', v_mode
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Knockout seed + advance (popup → May)
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
  v_mode text;
  v_cal record;
  v_r16_a int[] := ARRAY[1,3,5,7,2,4,6,8];
  v_r16_b int[] := ARRAY[2,4,6,8,1,3,5,7];
  v_i int;
BEGIN
  PERFORM public.international_assert_cycle_admin(p_cycle_id);
  PERFORM public.international_mark_finals_knockout_qualifiers(p_cycle_id);

  SELECT finals_after_season_id, lower(coalesce(cycle_mode, 'standard'))
  INTO v_season_id, v_mode
  FROM public.international_wc_cycles WHERE id = p_cycle_id;

  SELECT * INTO v_cal FROM public.international_knockout_calendar('r16', v_mode);

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
      v_i, v_cal.gpsl_month, v_cal.week_in_month, 'scheduled', false
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

  RETURN jsonb_build_object('ok', true, 'r16', 8, 'third_place', true, 'cycle_mode', v_mode);
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
  v_third public.international_knockout_nodes;
  v_next_stage text;
  v_next_match smallint;
  v_slot text;
  v_fid bigint;
  v_season_id bigint;
  v_mode text;
  v_cal record;
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

  SELECT finals_after_season_id, lower(coalesce(cycle_mode, 'standard'))
  INTO v_season_id, v_mode
  FROM public.international_wc_cycles WHERE id = p_cycle_id;

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
        SELECT * INTO v_cal
        FROM public.international_knockout_calendar('third_place', v_mode);

        INSERT INTO public.international_fixtures (
          cycle_id, season_id, phase, knockout_node_id,
          home_nation, away_nation, match_no, gpsl_month, week_in_month, status, played
        )
        VALUES (
          p_cycle_id, v_season_id, 'knockout', v_third.id,
          v_third.nation_a, v_third.nation_b, 1,
          v_cal.gpsl_month, v_cal.week_in_month, 'scheduled', false
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
    SELECT * INTO v_cal
    FROM public.international_knockout_calendar(v_next_stage, v_mode);

    INSERT INTO public.international_fixtures (
      cycle_id, season_id, phase, knockout_node_id,
      home_nation, away_nation, match_no, gpsl_month, week_in_month, status, played
    )
    VALUES (
      p_cycle_id, v_season_id, 'knockout', v_next.id,
      v_next.nation_a, v_next.nation_b, v_next.match_no,
      v_cal.gpsl_month, v_cal.week_in_month, 'scheduled', false
    )
    RETURNING id INTO v_fid;

    INSERT INTO public.international_fixture_schedule (fixture_id, status)
    VALUES (v_fid, 'unscheduled') ON CONFLICT DO NOTHING;
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Public view: expose id + cycle_mode
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.international_wc_cycle_public;
CREATE VIEW public.international_wc_cycle_public
WITH (security_invoker = false)
AS
SELECT
  wc.id,
  wc.cycle_no,
  wc.label,
  wc.status,
  wc.cycle_mode,
  wc.qual_season_id_1,
  wc.qual_season_id_2,
  wc.finals_after_season_id,
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

DROP VIEW IF EXISTS public.international_fixtures_public;
CREATE VIEW public.international_fixtures_public
WITH (security_invoker = false)
AS
SELECT
  f.id,
  f.cycle_id,
  wc.cycle_no,
  wc.label AS cycle_label,
  wc.cycle_mode,
  f.season_id,
  cs.label AS season_label,
  public.competition_season_ordinal(f.season_id) AS season_ordinal,
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
LEFT JOIN public.competition_seasons cs ON cs.id = f.season_id
LEFT JOIN public.international_qual_groups qg
  ON qg.id = f.group_id AND f.phase = 'qualifying'
LEFT JOIN public.international_finals_groups fg
  ON fg.id = f.group_id AND f.phase = 'finals_group'
LEFT JOIN public.international_knockout_nodes kn ON kn.id = f.knockout_node_id
LEFT JOIN public.international_fixture_schedule sch ON sch.fixture_id = f.id;

GRANT SELECT ON public.international_fixtures_public TO authenticated;

GRANT EXECUTE ON FUNCTION public.international_popup_qual_match_calendar(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_finals_group_calendar(integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_knockout_calendar(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_create_wc_cycle(text, bigint, bigint, bigint, smallint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_generate_qual_fixtures(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_generate_finals_group_fixtures(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_seed_knockout_bracket(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_advance_knockout_winner(bigint, bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
