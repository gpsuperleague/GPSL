-- =============================================================================
-- Match sim: ~90% of goals get an assister
-- Hotfix for match_sim_build_club_stats assist target only.
-- Run after match_result_simulation_star_roles.sql
-- =============================================================================

SET lock_timeout = '15s';

CREATE OR REPLACE FUNCTION public.match_sim_build_club_stats(
  p_side jsonb,
  p_goals int,
  p_conceded int,
  p_won boolean,
  p_drew boolean,
  p_is_motm_side boolean
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $function$
DECLARE
  r record;
  v_goal_pool numeric := 0;
  v_assist_pool numeric := 0;
  v_goals_left int := greatest(p_goals, 0);
  v_assists_target int := 0;
  v_assists_left int;
  v_pick text;
  v_roll numeric;
  v_acc numeric;
  v_base numeric;
  v_rating numeric;
  v_best_id text;
  v_best_r numeric := -1;
  v_out jsonb := '[]'::jsonb;
  v_goals_map jsonb := '{}'::jsonb;
  v_assists_map jsonb := '{}'::jsonb;
  v_ratings jsonb := '{}'::jsonb;
  v_id text;
  v_role text;
  v_pr numeric;
  v_started boolean;
  v_i int;
  v_scorer text;
  v_goal_scorers text[] := ARRAY[]::text[];
BEGIN
  FOR r IN
    SELECT * FROM jsonb_to_recordset(p_side) AS x(
      player_id text, name text, rating numeric, role text,
      pitch_slot text, profile_pos text, on_natural boolean, started boolean, subbed_on boolean, is_star boolean
    )
  LOOP
    IF coalesce(r.started, false) THEN
      v_goal_pool := v_goal_pool
        + public.match_sim_goal_weight(r.role) * (r.rating / 70.0)
        * public.match_sim_star_goal_mult(r.is_star, r.role, r.rating, coalesce(r.on_natural, false));
      v_assist_pool := v_assist_pool
        + public.match_sim_assist_weight(r.role) * (r.rating / 70.0)
        * public.match_sim_star_assist_mult(r.is_star, r.role, r.rating, coalesce(r.on_natural, false));
    END IF;
    v_goals_map := v_goals_map || jsonb_build_object(r.player_id, 0);
    v_assists_map := v_assists_map || jsonb_build_object(r.player_id, 0);
  END LOOP;

  IF v_goal_pool <= 0 THEN
    v_goal_pool := 1;
  END IF;
  IF v_assist_pool <= 0 THEN
    v_assist_pool := 1;
  END IF;

  -- Distribute goals (track scorers so assists prefer a different player)
  WHILE v_goals_left > 0 LOOP
    v_roll := random() * v_goal_pool;
    v_acc := 0;
    v_pick := NULL;
    FOR r IN
      SELECT * FROM jsonb_to_recordset(p_side) AS x(
        player_id text, name text, rating numeric, role text,
        pitch_slot text, profile_pos text, on_natural boolean, started boolean, subbed_on boolean, is_star boolean
      )
      WHERE coalesce(started, false)
    LOOP
      v_acc := v_acc + public.match_sim_goal_weight(r.role) * (r.rating / 70.0)
        * public.match_sim_star_goal_mult(r.is_star, r.role, r.rating, coalesce(r.on_natural, false));
      IF v_roll <= v_acc THEN
        v_pick := r.player_id;
        EXIT;
      END IF;
    END LOOP;
    IF v_pick IS NULL THEN
      SELECT e->>'player_id' INTO v_pick
      FROM jsonb_array_elements(p_side) e
      WHERE coalesce((e->>'started')::boolean, false)
      ORDER BY random()
      LIMIT 1;
    END IF;
    v_goals_map := jsonb_set(
      v_goals_map,
      ARRAY[v_pick],
      to_jsonb(coalesce((v_goals_map->>v_pick)::int, 0) + 1)
    );
    v_goal_scorers := v_goal_scorers || v_pick;
    v_goals_left := v_goals_left - 1;
  END LOOP;

  -- Each goal independently has a 90% chance of an assist
  v_assists_target := 0;
  IF p_goals > 0 THEN
    FOR v_i IN 1..p_goals LOOP
      IF random() < 0.90 THEN
        v_assists_target := v_assists_target + 1;
      END IF;
    END LOOP;
  END IF;

  v_assists_left := v_assists_target;
  v_i := 0;
  WHILE v_assists_left > 0 LOOP
    v_i := v_i + 1;
    v_scorer := CASE
      WHEN v_i <= coalesce(array_length(v_goal_scorers, 1), 0) THEN v_goal_scorers[v_i]
      ELSE NULL
    END;

    v_roll := random() * v_assist_pool;
    v_acc := 0;
    v_pick := NULL;
    FOR r IN
      SELECT * FROM jsonb_to_recordset(p_side) AS x(
        player_id text, name text, rating numeric, role text,
        pitch_slot text, profile_pos text, on_natural boolean, started boolean, subbed_on boolean, is_star boolean
      )
      WHERE coalesce(started, false)
        AND (v_scorer IS NULL OR player_id IS DISTINCT FROM v_scorer)
    LOOP
      v_acc := v_acc + public.match_sim_assist_weight(r.role) * (r.rating / 70.0)
        * public.match_sim_star_assist_mult(r.is_star, r.role, r.rating, coalesce(r.on_natural, false));
      IF v_roll <= v_acc THEN
        v_pick := r.player_id;
        EXIT;
      END IF;
    END LOOP;

    -- Fallback if only one starter / pool empty after excluding scorer
    IF v_pick IS NULL THEN
      SELECT e->>'player_id' INTO v_pick
      FROM jsonb_array_elements(p_side) e
      WHERE coalesce((e->>'started')::boolean, false)
        AND (v_scorer IS NULL OR e->>'player_id' IS DISTINCT FROM v_scorer)
      ORDER BY random()
      LIMIT 1;
    END IF;
    IF v_pick IS NULL THEN
      SELECT e->>'player_id' INTO v_pick
      FROM jsonb_array_elements(p_side) e
      WHERE coalesce((e->>'started')::boolean, false)
      ORDER BY random()
      LIMIT 1;
    END IF;

    IF v_pick IS NOT NULL THEN
      v_assists_map := jsonb_set(
        v_assists_map,
        ARRAY[v_pick],
        to_jsonb(coalesce((v_assists_map->>v_pick)::int, 0) + 1)
      );
    END IF;
    v_assists_left := v_assists_left - 1;
  END LOOP;

  -- Ratings
  FOR r IN
    SELECT * FROM jsonb_to_recordset(p_side) AS x(
      player_id text, name text, rating numeric, role text,
      pitch_slot text, profile_pos text, on_natural boolean, started boolean, subbed_on boolean, is_star boolean
    )
  LOOP
    v_id := r.player_id;
    v_role := r.role;
    v_pr := coalesce(r.rating, 70);
    v_started := coalesce(r.started, false) OR coalesce(r.subbed_on, false);
    v_base := 6.0;

    IF p_won THEN
      v_base := v_base + 0.35 + (random() * 0.45);
    ELSIF p_drew THEN
      v_base := v_base + (random() * 0.35) - 0.05;
    ELSE
      v_base := v_base - 0.25 + (random() * 0.35);
    END IF;

    v_base := v_base + ((v_pr - 75) / 40.0) * 0.35;

    IF NOT coalesce(r.started, false) AND coalesce(r.subbed_on, false) THEN
      v_base := v_base - 0.15;
    END IF;

    v_base := v_base
      + coalesce((v_goals_map->>v_id)::int, 0) * 0.55
      + coalesce((v_assists_map->>v_id)::int, 0) * 0.35;

    IF p_conceded = 0 AND v_role IN ('gk', 'def', 'fb', 'dmf') AND coalesce(r.started, false) THEN
      v_base := v_base + 0.35 + random() * 0.25;
    END IF;

    IF p_conceded >= 3 AND v_role IN ('gk', 'def') AND coalesce(r.started, false) THEN
      v_base := v_base - 0.35;
    END IF;

    IF random() < 0.012 AND p_won AND coalesce((v_goals_map->>v_id)::int, 0) >= 2 THEN
      v_base := greatest(v_base, 9.2);
    END IF;

    v_rating := round(greatest(4.5, least(9.7, v_base))::numeric, 1);
    v_ratings := v_ratings || jsonb_build_object(v_id, v_rating);

    IF v_started AND v_rating > v_best_r THEN
      v_best_r := v_rating;
      v_best_id := v_id;
    END IF;
  END LOOP;

  IF NOT p_is_motm_side THEN
    v_best_id := NULL;
  END IF;

  FOR r IN
    SELECT * FROM jsonb_to_recordset(p_side) AS x(
      player_id text, name text, rating numeric, role text,
      pitch_slot text, profile_pos text, on_natural boolean, started boolean, subbed_on boolean, is_star boolean
    )
  LOOP
    v_out := v_out || jsonb_build_array(
      jsonb_build_object(
        'player_id', r.player_id,
        'started', coalesce(r.started, false),
        'subbed_on', coalesce(r.subbed_on, false) AND NOT coalesce(r.started, false),
        'goals', coalesce((v_goals_map->>r.player_id)::int, 0),
        'assists', coalesce((v_assists_map->>r.player_id)::int, 0),
        'rating', coalesce((v_ratings->>r.player_id)::numeric, 6.0),
        'potm', (v_best_id IS NOT NULL AND r.player_id = v_best_id),
        'yellow_card', false,
        'red_card', false
      )
    );
  END LOOP;

  RETURN v_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_build_club_stats(jsonb, int, int, boolean, boolean, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
