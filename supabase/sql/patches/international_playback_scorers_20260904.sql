-- =============================================================================
-- Intl sim playback: goal scorers + running score from player stats
-- Also rewires international_simulate_fixture_result to pass home/away stats.
-- Safe re-run.
-- =============================================================================

-- Remove prior 5-arg overload so calls resolve to the stats-aware function
DROP FUNCTION IF EXISTS public.match_sim_build_intl_playback(text, text, int, int, int);

CREATE OR REPLACE FUNCTION public.match_sim_build_intl_playback(
  p_home_name text,
  p_away_name text,
  p_home_goals int,
  p_away_goals int,
  p_duration_sec int DEFAULT 20,
  p_home_stats jsonb DEFAULT '[]'::jsonb,
  p_away_stats jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $function$
DECLARE
  v_dur numeric := greatest(8, least(60, coalesce(p_duration_sec, 20)))::numeric;
  v_events jsonb := '[]'::jsonb;
  v_hg int := 0;
  v_ag int := 0;
  v_n int := 0;
  v_i int := 0;
  v_t numeric;
  v_minute int;
  r record;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _intl_pb_ev (
    ord serial,
    kind text,
    side text,
    player_id text,
    player_name text,
    goals int DEFAULT 0,
    assists int DEFAULT 0
  ) ON COMMIT DROP;
  DELETE FROM _intl_pb_ev;

  -- Expand home goals / assists from sim stats
  FOR r IN
    SELECT
      coalesce(nullif(btrim(e->>'player_id'), ''), '') AS player_id,
      coalesce(
        nullif(btrim(e->>'name'), ''),
        nullif(btrim(p."Name"), ''),
        nullif(btrim(e->>'player_id'), ''),
        'Unknown'
      ) AS player_name,
      greatest(coalesce(nullif(e->>'goals', '')::int, 0), 0) AS goals,
      greatest(coalesce(nullif(e->>'assists', '')::int, 0), 0) AS assists
    FROM jsonb_array_elements(coalesce(p_home_stats, '[]'::jsonb)) e
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = e->>'player_id'
  LOOP
    IF r.player_id = '' THEN CONTINUE; END IF;
    IF r.goals > 0 THEN
      FOR v_i IN 1..r.goals LOOP
        INSERT INTO _intl_pb_ev (kind, side, player_id, player_name, goals)
        VALUES ('goal', 'home', r.player_id, r.player_name, 1);
      END LOOP;
    END IF;
    IF r.assists > 0 THEN
      FOR v_i IN 1..r.assists LOOP
        INSERT INTO _intl_pb_ev (kind, side, player_id, player_name, assists)
        VALUES ('assist', 'home', r.player_id, r.player_name, 1);
      END LOOP;
    END IF;
  END LOOP;

  FOR r IN
    SELECT
      coalesce(nullif(btrim(e->>'player_id'), ''), '') AS player_id,
      coalesce(
        nullif(btrim(e->>'name'), ''),
        nullif(btrim(p."Name"), ''),
        nullif(btrim(e->>'player_id'), ''),
        'Unknown'
      ) AS player_name,
      greatest(coalesce(nullif(e->>'goals', '')::int, 0), 0) AS goals,
      greatest(coalesce(nullif(e->>'assists', '')::int, 0), 0) AS assists
    FROM jsonb_array_elements(coalesce(p_away_stats, '[]'::jsonb)) e
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = e->>'player_id'
  LOOP
    IF r.player_id = '' THEN CONTINUE; END IF;
    IF r.goals > 0 THEN
      FOR v_i IN 1..r.goals LOOP
        INSERT INTO _intl_pb_ev (kind, side, player_id, player_name, goals)
        VALUES ('goal', 'away', r.player_id, r.player_name, 1);
      END LOOP;
    END IF;
    IF r.assists > 0 THEN
      FOR v_i IN 1..r.assists LOOP
        INSERT INTO _intl_pb_ev (kind, side, player_id, player_name, assists)
        VALUES ('assist', 'away', r.player_id, r.player_name, 1);
      END LOOP;
    END IF;
  END LOOP;

  -- Fallback when stats missing / empty: anonymous goals to match scoreline
  SELECT count(*) FILTER (WHERE kind = 'goal' AND side = 'home')::int INTO v_i FROM _intl_pb_ev;
  FOR v_n IN 1..greatest(coalesce(p_home_goals, 0) - coalesce(v_i, 0), 0) LOOP
    INSERT INTO _intl_pb_ev (kind, side, player_id, player_name, goals)
    VALUES ('goal', 'home', NULL, coalesce(p_home_name, 'Home'), 1);
  END LOOP;
  SELECT count(*) FILTER (WHERE kind = 'goal' AND side = 'away')::int INTO v_i FROM _intl_pb_ev;
  FOR v_n IN 1..greatest(coalesce(p_away_goals, 0) - coalesce(v_i, 0), 0) LOOP
    INSERT INTO _intl_pb_ev (kind, side, player_id, player_name, goals)
    VALUES ('goal', 'away', NULL, coalesce(p_away_name, 'Away'), 1);
  END LOOP;

  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', 0, 'type', 'kickoff', 'side', null, 'text', 'Kick-off', 'minute', 1
  ));

  SELECT count(*)::int INTO v_n FROM _intl_pb_ev;
  v_i := 0;
  FOR r IN
    SELECT * FROM _intl_pb_ev
    ORDER BY
      CASE kind WHEN 'goal' THEN 1 WHEN 'assist' THEN 2 ELSE 3 END,
      random()
  LOOP
    v_i := v_i + 1;
    v_t := round((0.08 + (0.84 * (v_i::numeric / (v_n + 1)::numeric)) + (random() * 0.03)) * v_dur, 2);
    v_t := least(v_dur - 0.4, greatest(0.5, v_t));
    v_minute := greatest(1, least(90, round((v_t / v_dur) * 90)::int));

    IF r.kind = 'goal' THEN
      IF r.side = 'home' THEN v_hg := v_hg + 1; ELSE v_ag := v_ag + 1; END IF;
      v_events := v_events || jsonb_build_array(jsonb_build_object(
        't', v_t,
        'type', 'goal',
        'side', r.side,
        'player', r.player_name,
        'player_id', r.player_id,
        'minute', v_minute,
        'score_home', v_hg,
        'score_away', v_ag,
        'text', format('%s'' GOAL — %s', v_minute, r.player_name),
        'pressure', 0.82
      ));
    ELSIF r.kind = 'assist' THEN
      v_events := v_events || jsonb_build_array(jsonb_build_object(
        't', v_t,
        'type', 'assist',
        'side', r.side,
        'player', r.player_name,
        'player_id', r.player_id,
        'minute', v_minute,
        'text', format('%s'' Assist — %s', v_minute, r.player_name)
      ));
    END IF;
  END LOOP;

  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', v_dur,
    'type', 'fulltime',
    'side', null,
    'text', format('FT %s–%s', coalesce(p_home_goals, 0), coalesce(p_away_goals, 0)),
    'minute', 90,
    'score_home', coalesce(p_home_goals, 0),
    'score_away', coalesce(p_away_goals, 0)
  ));

  RETURN jsonb_build_object(
    'duration_sec', v_dur,
    'events', v_events,
    'home_name', p_home_name,
    'away_name', p_away_name
  );
END;
$function$;

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
    v_playback_sec,
    v_home_stats,
    v_away_stats
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

GRANT EXECUTE ON FUNCTION public.match_sim_build_intl_playback(text, text, int, int, int, jsonb, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_simulate_fixture_result(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
