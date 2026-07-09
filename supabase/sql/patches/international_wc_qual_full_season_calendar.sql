-- =============================================================================
-- WC qualifying calendar + docs: 4 games per nation per season (8 total)
--
-- Groups of 5 (double RR): each nation plays the other four home & away = 8.
-- Circle method needs 5 rounds per single RR (2 games + 1 bye each round).
-- So: 5 international *windows* per season, but each nation plays only 4 times.
--
-- Spread windows across full season Aug–May (not pre-season).
-- Run once. Regenerate unplayed qual fixtures after if already generated.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.international_qual_match_calendar(p_match_no integer)
RETURNS TABLE (gpsl_month text, week_in_month smallint)
LANGUAGE sql
IMMUTABLE
AS $$
  -- match_no 1–5 = season 1 windows; 6–10 = season 2 (same months).
  -- One bye each window; each nation plays in 4 of the 5 windows.
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

COMMENT ON FUNCTION public.international_qual_match_calendar(integer) IS
  'WC qual windows: match_no 1–5 (season 1) and 6–10 (season 2). '
  'Five calendar windows per season (Aug/Oct/Dec/Feb/Apr); each nation plays 4 games '
  '(one bye per single RR). Full double RR = 8 games to qualify.';

-- Clarify generator return metadata (same algorithm; clearer labels)
CREATE OR REPLACE FUNCTION public.international_generate_qual_fixtures(p_cycle_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cycle public.international_wc_cycles;
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
BEGIN
  v_cycle := public.international_assert_cycle_admin(p_cycle_id);

  IF v_cycle.qual_season_id_1 IS NULL OR v_cycle.qual_season_id_2 IS NULL THEN
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

    -- Single RR (rounds 1–5, one bye each) then reverse fixtures (6–10)
    FOR v_first_leg IN SELECT true UNION ALL SELECT false LOOP
      v_slots := v_teams || ARRAY[NULL::text];
      FOR v_round IN 1..5 LOOP
        v_match_no := CASE WHEN v_first_leg THEN v_round ELSE v_round + 5 END;
        v_season_id := CASE
          WHEN v_match_no <= 5 THEN v_cycle.qual_season_id_1
          ELSE v_cycle.qual_season_id_2
        END;
        SELECT * INTO v_cal FROM public.international_qual_match_calendar(v_match_no);

        FOR v_i IN 1..3 LOOP
          v_a := v_slots[v_i];
          v_b := v_slots[7 - v_i];
          IF v_a IS NULL OR v_b IS NULL THEN
            CONTINUE; -- bye
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

  RETURN jsonb_build_object(
    'ok', true,
    'cycle_id', p_cycle_id,
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

GRANT EXECUTE ON FUNCTION public.international_qual_match_calendar(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_generate_qual_fixtures(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
