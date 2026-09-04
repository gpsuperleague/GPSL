-- =============================================================================
-- HOTFIX (tiny): international simulate → invalid input syntax for type integer: "false"
--
-- Run THIS FILE ALONE in Supabase SQL Editor (whole file once).
-- Then hard-refresh and click Simulate again.
--
-- Cause: match_sim_build_club_stats writes "potm": false (JSON boolean).
-- international_apply_player_stats then did:
--   (potm)::boolean OR (potm)::int
-- When potm is false, Postgres still evaluates ::int on text "false" → 400.
--
-- This patch:
--   1) Fixes international_apply_player_stats potm/clean_sheet parsing
--   2) Sanitizes sim stats inside international_simulate_fixture_result
--      (potm boolean → 0/1) so even an old apply function cannot choke
-- =============================================================================

SET lock_timeout = '15s';
SET statement_timeout = '60s';

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
  v_potm_raw jsonb;
  v_cs_raw jsonb;
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

    v_goals := greatest(coalesce(nullif(v_item->>'goals', '')::int, 0), 0);
    v_assists := greatest(coalesce(nullif(v_item->>'assists', '')::int, 0), 0);
    BEGIN
      v_rating := nullif(v_item->>'rating', '')::numeric;
    EXCEPTION WHEN OTHERS THEN
      v_rating := NULL;
    END;

    -- Never cast JSON boolean "false"/"true" through ::int
    v_potm_raw := v_item->'potm';
    v_potm := CASE
      WHEN v_potm_raw IS NULL OR v_potm_raw = 'null'::jsonb THEN 0
      WHEN jsonb_typeof(v_potm_raw) = 'boolean' THEN
        CASE WHEN (v_item->>'potm')::boolean THEN 1 ELSE 0 END
      WHEN jsonb_typeof(v_potm_raw) = 'number' THEN
        CASE WHEN coalesce((v_item->>'potm')::numeric, 0) > 0 THEN 1 ELSE 0 END
      WHEN lower(coalesce(v_item->>'potm', '')) IN ('true', 't', 'yes', '1') THEN 1
      WHEN lower(coalesce(v_item->>'potm', '')) IN ('false', 'f', 'no', '0', '') THEN 0
      ELSE 0
    END;

    v_cs_raw := coalesce(v_item->'clean_sheet', v_item->'clean_sheets');
    v_cs := CASE
      WHEN v_cs_raw IS NULL OR v_cs_raw = 'null'::jsonb THEN 0
      WHEN jsonb_typeof(v_cs_raw) = 'boolean' THEN
        CASE WHEN (v_cs_raw #>> '{}')::boolean THEN 1 ELSE 0 END
      WHEN jsonb_typeof(v_cs_raw) = 'number' THEN
        CASE WHEN coalesce((v_cs_raw #>> '{}')::numeric, 0) > 0 THEN 1 ELSE 0 END
      WHEN lower(coalesce(v_cs_raw #>> '{}', '')) IN ('true', 't', 'yes', '1') THEN 1
      WHEN lower(coalesce(v_cs_raw #>> '{}', '')) IN ('false', 'f', 'no', '0', '') THEN 0
      ELSE 0
    END;

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

-- Re-assert simulate with potm sanitization before apply
CREATE OR REPLACE FUNCTION public.international_simulate_fixture_result(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fix public.international_fixtures;
  v_my text;
  v_home_club text;
  v_away_club text;
  v_staff boolean;
  v_settings jsonb;
  v_home jsonb;
  v_away jsonb;
  v_home_str numeric;
  v_away_str numeric;
  v_diff numeric;
  v_home_star_json jsonb;
  v_away_star_json jsonb;
  v_home_star_def numeric;
  v_home_star_create numeric;
  v_home_star_fin numeric;
  v_away_star_def numeric;
  v_away_star_create numeric;
  v_away_star_fin numeric;
  v_home_star_pwr numeric;
  v_away_star_pwr numeric;
  v_outcome text;
  v_score int[];
  v_hg int;
  v_ag int;
  v_et_h smallint := NULL;
  v_et_a smallint := NULL;
  v_pen_h smallint := NULL;
  v_pen_a smallint := NULL;
  v_home_won boolean;
  v_away_won boolean;
  v_draw boolean;
  v_motm_home boolean;
  v_home_stats jsonb;
  v_away_stats jsonb;
  v_all_stats jsonb;
  v_playback jsonb;
  v_playback_sec int;
  v_home_name text;
  v_away_name text;
BEGIN
  IF NOT public.match_result_simulation_enabled() THEN
    RAISE EXCEPTION 'Match simulation is turned off (Admin → Match simulation settings)';
  END IF;

  SELECT f.* INTO v_fix
  FROM public.international_fixtures f
  WHERE f.id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'International fixture not found';
  END IF;

  IF v_fix.played THEN
    RAISE EXCEPTION 'Fixture already played';
  END IF;

  v_my := public.international_my_nation_code();
  v_home_club := public.international_club_for_nation(v_fix.home_nation);
  v_away_club := public.international_club_for_nation(v_fix.away_nation);
  v_staff := public.is_gpsl_admin();
  IF NOT v_staff AND to_regprocedure('public.is_gpsl_admin_or_mod()') IS NOT NULL THEN
    v_staff := public.is_gpsl_admin_or_mod();
  END IF;

  IF NOT (
    v_staff
    OR (v_my IS NOT NULL AND v_my IN (v_fix.home_nation, v_fix.away_nation))
  ) THEN
    RAISE EXCEPTION 'Only a nation owner (or staff) can simulate this fixture';
  END IF;

  IF v_home_club IS NULL AND v_away_club IS NULL AND NOT v_staff THEN
    RAISE EXCEPTION 'Staff only can simulate vacant vs vacant internationals';
  END IF;

  PERFORM public.international_assert_fixture_month_unlocked(p_fixture_id);

  v_settings := public.match_sim_settings();
  BEGIN
    v_playback_sec := greatest(8, least(60, coalesce((v_settings->>'playback_seconds')::int, 20)));
  EXCEPTION WHEN OTHERS THEN
    v_playback_sec := 20;
  END;

  v_home := public.match_sim_load_nation_side(v_fix.home_nation);
  v_away := public.match_sim_load_nation_side(v_fix.away_nation);

  v_home_str := public.match_sim_side_strength(v_home);
  v_away_str := public.match_sim_side_strength(v_away);
  v_diff := v_home_str - v_away_str;

  v_home_star_json := public.match_sim_side_star_powers(v_home);
  v_away_star_json := public.match_sim_side_star_powers(v_away);
  v_home_star_def := coalesce((v_home_star_json->>'def')::numeric, 0);
  v_home_star_create := coalesce((v_home_star_json->>'create')::numeric, 0);
  v_home_star_fin := coalesce((v_home_star_json->>'fin')::numeric, 0);
  v_away_star_def := coalesce((v_away_star_json->>'def')::numeric, 0);
  v_away_star_create := coalesce((v_away_star_json->>'create')::numeric, 0);
  v_away_star_fin := coalesce((v_away_star_json->>'fin')::numeric, 0);
  v_home_star_pwr := coalesce((v_home_star_json->>'total')::numeric, 0);
  v_away_star_pwr := coalesce((v_away_star_json->>'total')::numeric, 0);

  v_outcome := public.match_sim_pick_outcome_with_stars(
    v_home_str, v_away_str, v_home_star_pwr, v_away_star_pwr
  );
  v_score := public.match_sim_sample_goals(
    v_outcome,
    v_diff,
    public.match_sim_side_attack(v_home),
    public.match_sim_side_attack(v_away),
    public.match_sim_side_defence(v_home),
    public.match_sim_side_defence(v_away),
    v_home_star_def,
    v_away_star_def,
    v_home_star_create,
    v_away_star_create,
    v_home_star_fin,
    v_away_star_fin
  );
  v_hg := v_score[1];
  v_ag := v_score[2];

  IF v_fix.phase = 'knockout' AND v_hg = v_ag THEN
    IF random() < 0.5 THEN
      v_et_h := (v_hg + 1)::smallint;
      v_et_a := v_ag::smallint;
    ELSE
      v_et_h := v_hg::smallint;
      v_et_a := (v_ag + 1)::smallint;
    END IF;
  END IF;

  v_home_won := CASE
    WHEN v_et_h IS NOT NULL THEN v_et_h > v_et_a
    ELSE v_hg > v_ag
  END;
  v_away_won := CASE
    WHEN v_et_h IS NOT NULL THEN v_et_a > v_et_h
    ELSE v_ag > v_hg
  END;
  v_draw := NOT v_home_won AND NOT v_away_won;
  v_motm_home := CASE
    WHEN v_home_won THEN true
    WHEN v_away_won THEN false
    ELSE random() < 0.5
  END;

  v_home_stats := public.match_sim_build_club_stats(
    v_home, v_hg, v_ag, v_home_won, v_draw, v_motm_home
  );
  v_away_stats := public.match_sim_build_club_stats(
    v_away, v_ag, v_hg, v_away_won, v_draw, NOT v_motm_home
  );
  v_all_stats := coalesce(v_home_stats, '[]'::jsonb) || coalesce(v_away_stats, '[]'::jsonb);

  -- Belt-and-suspenders: coerce potm / clean_sheet JSON booleans → 0/1 ints
  -- so international_apply_player_stats cannot hit "false"::int.
  SELECT coalesce(
    jsonb_agg(
      (
        e
        || CASE
             WHEN jsonb_typeof(e->'potm') = 'boolean' THEN
               jsonb_build_object(
                 'potm', CASE WHEN (e->>'potm')::boolean THEN 1 ELSE 0 END
               )
             ELSE '{}'::jsonb
           END
        || CASE
             WHEN jsonb_typeof(e->'clean_sheet') = 'boolean' THEN
               jsonb_build_object(
                 'clean_sheet', CASE WHEN (e->>'clean_sheet')::boolean THEN 1 ELSE 0 END
               )
             ELSE '{}'::jsonb
           END
        || CASE
             WHEN jsonb_typeof(e->'clean_sheets') = 'boolean' THEN
               jsonb_build_object(
                 'clean_sheets', CASE WHEN (e->>'clean_sheets')::boolean THEN 1 ELSE 0 END
               )
             ELSE '{}'::jsonb
           END
      )
    ),
    '[]'::jsonb
  )
  INTO v_all_stats
  FROM jsonb_array_elements(v_all_stats) e;

  UPDATE public.international_result_submissions
  SET status = 'rejected',
      resolved_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  PERFORM public.international_apply_fixture_result(
    p_fixture_id,
    v_hg::smallint,
    v_ag::smallint,
    v_all_stats,
    v_et_h,
    v_et_a,
    v_pen_h,
    v_pen_a
  );

  SELECT hn.name, an.name
  INTO v_home_name, v_away_name
  FROM public.international_nations hn
  CROSS JOIN public.international_nations an
  WHERE hn.code = v_fix.home_nation
    AND an.code = v_fix.away_nation;

  v_playback := public.match_sim_build_intl_playback(
    coalesce(v_home_name, v_fix.home_nation),
    coalesce(v_away_name, v_fix.away_nation),
    v_hg,
    v_ag,
    v_playback_sec
  );

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'home_goals', v_hg,
    'away_goals', v_ag,
    'home_goals_et', v_et_h,
    'away_goals_et', v_et_a,
    'home_name', coalesce(v_home_name, v_fix.home_nation),
    'away_name', coalesce(v_away_name, v_fix.away_nation),
    'home_nation', v_fix.home_nation,
    'away_nation', v_fix.away_nation,
    'outcome', v_outcome,
    'home_strength', v_home_str,
    'away_strength', v_away_str,
    'playback', v_playback,
    'simulated', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_apply_player_stats(jsonb, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_simulate_fixture_result(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Optional check (should return "fixed" style body snippet):
-- SELECT left(pg_get_functiondef('public.international_apply_player_stats(jsonb,boolean)'::regprocedure), 400);
