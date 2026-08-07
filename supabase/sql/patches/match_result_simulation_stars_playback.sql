-- =============================================================================
-- Match sim: star rating impact (79+) + 20s playback narrative + club colours
-- Run after match_result_simulation_cards_per_match.sql
-- UI: match_sim_ui.js (Instant result / Simulate match)
-- =============================================================================

SET lock_timeout = '15s';
SET statement_timeout = '120s';

-- Seed star-impact settings
UPDATE public.global_settings
SET match_result_simulation_settings =
  coalesce(match_result_simulation_settings, '{}'::jsonb)
  || jsonb_build_object(
    'star_min_rating', coalesce((match_result_simulation_settings->>'star_min_rating')::int, 79),
    'star_outcome_pct', coalesce((match_result_simulation_settings->>'star_outcome_pct')::numeric, 8),
    'star_goal_boost_pct', coalesce((match_result_simulation_settings->>'star_goal_boost_pct')::numeric, 12),
    'star_concede_cut_pct', coalesce((match_result_simulation_settings->>'star_concede_cut_pct')::numeric, 10),
    'star_assist_boost_pct', coalesce((match_result_simulation_settings->>'star_assist_boost_pct')::numeric, 12),
    'playback_seconds', coalesce((match_result_simulation_settings->>'playback_seconds')::int, 20)
  )
WHERE id = 1;

CREATE OR REPLACE FUNCTION public.match_sim_star_min_rating()
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (g.match_result_simulation_settings->>'star_min_rating')::numeric,
    g.star_tax_min_rating::numeric,
    79
  )
  FROM public.global_settings g
  WHERE g.id = 1;
$$;

CREATE OR REPLACE FUNCTION public.match_sim_is_star(p_rating numeric)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(p_rating, 0) >= public.match_sim_star_min_rating();
$$;

-- 0..1 quality: floor ~0.15 at threshold, 1.0 near 100
CREATE OR REPLACE FUNCTION public.match_sim_star_quality(p_rating numeric)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN NOT public.match_sim_is_star(p_rating) THEN 0::numeric
    ELSE least(
      1.0,
      greatest(
        0.15,
        (coalesce(p_rating, 0) - public.match_sim_star_min_rating()) / 21.0
      )
    )
  END;
$$;

-- Side star powers by role bucket (started XI only)
CREATE OR REPLACE FUNCTION public.match_sim_side_star_powers(p_side jsonb)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'def', coalesce(sum(q) FILTER (WHERE role IN ('gk', 'def', 'dmf')), 0),
    'create', coalesce(sum(q) FILTER (WHERE role IN ('fb', 'mf')), 0),
    'fin', coalesce(sum(q) FILTER (WHERE role = 'fw'), 0),
    'total', coalesce(sum(q), 0),
    'count', coalesce(count(*) FILTER (WHERE q > 0), 0)
  )
  FROM (
    SELECT
      e->>'role' AS role,
      CASE
        WHEN coalesce((e->>'started')::boolean, false)
             AND coalesce((e->>'is_star')::boolean, false)
        THEN public.match_sim_star_quality((e->>'rating')::numeric)
        ELSE 0
      END AS q
    FROM jsonb_array_elements(coalesce(p_side, '[]'::jsonb)) e
  ) x;
$$;

CREATE OR REPLACE FUNCTION public.match_sim_settings()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'yellow_per_match', coalesce((s->>'yellow_per_match')::int, 3),
    'red_chance_pct', coalesce((s->>'red_chance_pct')::numeric, 5),
    'cards_enabled', coalesce((s->>'cards_enabled')::boolean, true),
    'injuries_enabled', coalesce((s->>'injuries_enabled')::boolean, true),
    'max_subs_on', greatest(0, least(5, coalesce((s->>'max_subs_on')::int, 5))),
    'outcome_bands', public.match_sim_normalize_outcome_bands(s->'outcome_bands'),
    'star_min_rating', coalesce((s->>'star_min_rating')::int, 79),
    'star_outcome_pct', coalesce((s->>'star_outcome_pct')::numeric, 8),
    'star_goal_boost_pct', coalesce((s->>'star_goal_boost_pct')::numeric, 12),
    'star_concede_cut_pct', coalesce((s->>'star_concede_cut_pct')::numeric, 10),
    'star_assist_boost_pct', coalesce((s->>'star_assist_boost_pct')::numeric, 12),
    'playback_seconds', greatest(8, least(60, coalesce((s->>'playback_seconds')::int, 20)))
  )
  FROM (
    SELECT coalesce(g.match_result_simulation_settings, '{}'::jsonb) AS s
    FROM public.global_settings g
    WHERE g.id = 1
  ) x;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_match_sim_settings(p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_in jsonb := coalesce(p_settings, '{}'::jsonb);
  v_out jsonb;
  v_yellow int;
  v_red_chance numeric;
  v_max_subs int;
  v_bands jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_yellow := greatest(0, least(22, coalesce((v_in->>'yellow_per_match')::int, 3)));
  v_red_chance := greatest(0, least(100, coalesce((v_in->>'red_chance_pct')::numeric, 5)));
  v_max_subs := greatest(0, least(5, coalesce((v_in->>'max_subs_on')::int, 5)));
  v_bands := public.match_sim_normalize_outcome_bands(v_in->'outcome_bands');

  v_out := jsonb_build_object(
    'yellow_per_match', v_yellow,
    'red_chance_pct', v_red_chance,
    'cards_enabled', coalesce((v_in->>'cards_enabled')::boolean, true),
    'injuries_enabled', coalesce((v_in->>'injuries_enabled')::boolean, true),
    'max_subs_on', v_max_subs,
    'outcome_bands', v_bands,
    'star_min_rating', greatest(70, least(99, coalesce((v_in->>'star_min_rating')::int, 79))),
    'star_outcome_pct', greatest(0, least(25, coalesce((v_in->>'star_outcome_pct')::numeric, 8))),
    'star_goal_boost_pct', greatest(0, least(30, coalesce((v_in->>'star_goal_boost_pct')::numeric, 12))),
    'star_concede_cut_pct', greatest(0, least(30, coalesce((v_in->>'star_concede_cut_pct')::numeric, 10))),
    'star_assist_boost_pct', greatest(0, least(30, coalesce((v_in->>'star_assist_boost_pct')::numeric, 12))),
    'playback_seconds', greatest(8, least(60, coalesce((v_in->>'playback_seconds')::int, 20)))
  );

  UPDATE public.global_settings
  SET match_result_simulation_settings = v_out,
      updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'settings', public.match_sim_settings(),
    'enabled', public.match_result_simulation_enabled()
  );
END;
$function$;

-- Nudge home/draw/away % by relative star power (higher rating → more quality → more swing)
CREATE OR REPLACE FUNCTION public.match_sim_nudge_odds_by_stars(
  p_odds jsonb,
  p_home_star_pwr numeric,
  p_away_star_pwr numeric
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s jsonb := public.match_sim_settings();
  v_max numeric := coalesce((v_s->>'star_outcome_pct')::numeric, 8);
  v_home numeric := coalesce((p_odds->>'home_pct')::numeric, 33);
  v_draw numeric := coalesce((p_odds->>'draw_pct')::numeric, 34);
  v_away numeric := coalesce((p_odds->>'away_pct')::numeric, 33);
  v_hp numeric := greatest(coalesce(p_home_star_pwr, 0), 0);
  v_ap numeric := greatest(coalesce(p_away_star_pwr, 0), 0);
  v_sum numeric := v_hp + v_ap;
  v_delta numeric := 0;
  v_take numeric;
BEGIN
  IF v_max <= 0 OR v_sum < 0.05 THEN
    RETURN p_odds || jsonb_build_object('star_nudge', 0, 'star_home_pwr', v_hp, 'star_away_pwr', v_ap);
  END IF;

  -- Relative star edge × max swing (e.g. ±8%)
  v_delta := ((v_hp - v_ap) / v_sum) * v_max;

  IF v_delta > 0 THEN
    v_take := least(v_away + v_draw * 0.35, v_delta);
    v_home := v_home + v_take;
    v_away := greatest(0, v_away - v_take * 0.65);
    v_draw := greatest(0, 100 - v_home - v_away);
  ELSIF v_delta < 0 THEN
    v_take := least(v_home + v_draw * 0.35, abs(v_delta));
    v_away := v_away + v_take;
    v_home := greatest(0, v_home - v_take * 0.65);
    v_draw := greatest(0, 100 - v_home - v_away);
  END IF;

  -- Renormalise
  v_sum := v_home + v_draw + v_away;
  IF v_sum > 0 THEN
    v_home := round(v_home * 100.0 / v_sum, 1);
    v_draw := round(v_draw * 100.0 / v_sum, 1);
    v_away := round(100.0 - v_home - v_draw, 1);
  END IF;

  RETURN p_odds || jsonb_build_object(
    'home_pct', v_home,
    'draw_pct', v_draw,
    'away_pct', v_away,
    'star_nudge', round(v_delta, 2),
    'star_home_pwr', round(v_hp, 2),
    'star_away_pwr', round(v_ap, 2)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_sim_pick_outcome_with_stars(
  p_home_str numeric,
  p_away_str numeric,
  p_home_star_pwr numeric,
  p_away_star_pwr numeric
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_odds jsonb;
  v_roll numeric := random() * 100.0;
  v_home numeric;
  v_draw numeric;
BEGIN
  v_odds := public.match_sim_nudge_odds_by_stars(
    public.match_sim_outcome_odds(p_home_str, p_away_str),
    p_home_star_pwr,
    p_away_star_pwr
  );
  v_home := coalesce((v_odds->>'home_pct')::numeric, 20);
  v_draw := coalesce((v_odds->>'draw_pct')::numeric, 60);

  IF v_roll < v_home THEN
    RETURN 'home';
  ELSIF v_roll < (v_home + v_draw) THEN
    RETURN 'draw';
  ELSE
    RETURN 'away';
  END IF;
END;
$function$;

-- Goal sampling with rating-scaled star powers + admin % settings
CREATE OR REPLACE FUNCTION public.match_sim_sample_goals(
  p_outcome text,
  p_diff numeric,
  p_home_atk numeric,
  p_away_atk numeric,
  p_home_def numeric,
  p_away_def numeric,
  p_home_star_def numeric,
  p_away_star_def numeric,
  p_home_star_create numeric,
  p_away_star_create numeric,
  p_home_star_fin numeric,
  p_away_star_fin numeric
)
RETURNS int[]
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s jsonb := public.match_sim_settings();
  v_cut numeric := coalesce((v_s->>'star_concede_cut_pct')::numeric, 10) / 100.0;
  v_boost numeric := coalesce((v_s->>'star_goal_boost_pct')::numeric, 12) / 100.0;
  v_home_xg numeric;
  v_away_xg numeric;
  v_hg int;
  v_ag int;
  v_blowout boolean := abs(coalesce(p_diff, 0)) >= 80;
  v_mod_h numeric := 1.0;
  v_mod_a numeric := 1.0;
  i int;
BEGIN
  -- Defensive stars cut opponent scoring chance; creators/finishers boost own
  v_mod_h := v_mod_h * power(greatest(0.70, 1.0 - v_cut), greatest(coalesce(p_away_star_def, 0), 0));
  v_mod_a := v_mod_a * power(greatest(0.70, 1.0 - v_cut), greatest(coalesce(p_home_star_def, 0), 0));
  v_mod_h := v_mod_h * power(
    1.0 + v_boost,
    greatest(coalesce(p_home_star_create, 0) + coalesce(p_home_star_fin, 0), 0) * 0.55
  );
  v_mod_a := v_mod_a * power(
    1.0 + v_boost,
    greatest(coalesce(p_away_star_create, 0) + coalesce(p_away_star_fin, 0), 0) * 0.55
  );

  v_home_xg := greatest(0.35, least(3.8, (p_home_atk / greatest(p_away_def, 1)) * 1.6)) * v_mod_h;
  v_away_xg := greatest(0.35, least(3.8, (p_away_atk / greatest(p_home_def, 1)) * 1.6)) * v_mod_a;

  IF p_outcome = 'home' THEN
    v_home_xg := greatest(v_home_xg, v_away_xg + 0.55);
    IF v_blowout THEN
      v_home_xg := greatest(v_home_xg, 2.4);
      v_away_xg := least(v_away_xg, 0.9);
    END IF;
  ELSIF p_outcome = 'away' THEN
    v_away_xg := greatest(v_away_xg, v_home_xg + 0.55);
    IF v_blowout THEN
      v_away_xg := greatest(v_away_xg, 2.4);
      v_home_xg := least(v_home_xg, 0.9);
    END IF;
  ELSE
    v_home_xg := (v_home_xg + v_away_xg) / 2.0;
    v_away_xg := v_home_xg;
    v_home_xg := least(v_home_xg, 2.2);
    v_away_xg := least(v_away_xg, 2.2);
  END IF;

  v_hg := 0;
  v_ag := 0;
  FOR i IN 1..6 LOOP
    IF random() < least(0.92, v_home_xg / 6.0) THEN v_hg := v_hg + 1; END IF;
    IF random() < least(0.92, v_away_xg / 6.0) THEN v_ag := v_ag + 1; END IF;
  END LOOP;

  IF p_outcome = 'home' AND v_hg <= v_ag THEN
    v_hg := v_ag + 1 + CASE WHEN v_blowout AND random() < 0.45 THEN 1 ELSE 0 END;
  ELSIF p_outcome = 'away' AND v_ag <= v_hg THEN
    v_ag := v_hg + 1 + CASE WHEN v_blowout AND random() < 0.45 THEN 1 ELSE 0 END;
  ELSIF p_outcome = 'draw' THEN
    v_hg := least(v_hg, 4);
    v_ag := v_hg;
  END IF;

  v_hg := least(v_hg, CASE WHEN v_blowout THEN 6 ELSE 5 END);
  v_ag := least(v_ag, CASE WHEN v_blowout THEN 6 ELSE 5 END);

  RETURN ARRAY[v_hg, v_ag];
END;
$function$;

-- Goal/assist attribution: star boost scales with rating quality
CREATE OR REPLACE FUNCTION public.match_sim_star_goal_mult(p_is_star boolean, p_role text, p_rating numeric)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s jsonb := public.match_sim_settings();
  v_boost numeric := coalesce((v_s->>'star_goal_boost_pct')::numeric, 12) / 100.0;
  v_q numeric;
BEGIN
  IF NOT coalesce(p_is_star, false) THEN
    RETURN 1.0;
  END IF;
  IF coalesce(p_role, '') <> 'fw' THEN
    RETURN 1.0;
  END IF;
  v_q := public.match_sim_star_quality(p_rating);
  RETURN 1.0 + v_boost * (0.6 + 0.8 * v_q);
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_sim_star_assist_mult(p_is_star boolean, p_role text, p_rating numeric)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s jsonb := public.match_sim_settings();
  v_boost numeric := coalesce((v_s->>'star_assist_boost_pct')::numeric, 12) / 100.0;
  v_q numeric;
BEGIN
  IF NOT coalesce(p_is_star, false) THEN
    RETURN 1.0;
  END IF;
  IF coalesce(p_role, '') NOT IN ('mf', 'fb') THEN
    RETURN 1.0;
  END IF;
  v_q := public.match_sim_star_quality(p_rating);
  RETURN 1.0 + v_boost * (0.55 + 0.85 * v_q);
END;
$function$;

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
  v_assists_target int;
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
BEGIN
  FOR r IN
    SELECT * FROM jsonb_to_recordset(p_side) AS x(
      player_id text, name text, rating numeric, role text,
      pitch_slot text, started boolean, subbed_on boolean, is_star boolean
    )
  LOOP
    IF coalesce(r.started, false) THEN
      v_goal_pool := v_goal_pool
        + public.match_sim_goal_weight(r.role) * (r.rating / 70.0)
        * public.match_sim_star_goal_mult(r.is_star, r.role, r.rating);
      v_assist_pool := v_assist_pool
        + public.match_sim_assist_weight(r.role) * (r.rating / 70.0)
        * public.match_sim_star_assist_mult(r.is_star, r.role, r.rating);
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

  -- Distribute goals
  WHILE v_goals_left > 0 LOOP
    v_roll := random() * v_goal_pool;
    v_acc := 0;
    v_pick := NULL;
    FOR r IN
      SELECT * FROM jsonb_to_recordset(p_side) AS x(
        player_id text, name text, rating numeric, role text,
        pitch_slot text, started boolean, subbed_on boolean, is_star boolean
      )
      WHERE coalesce(started, false)
    LOOP
      v_acc := v_acc + public.match_sim_goal_weight(r.role) * (r.rating / 70.0)
        * public.match_sim_star_goal_mult(r.is_star, r.role, r.rating);
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
    v_goals_left := v_goals_left - 1;
  END LOOP;

  -- Assists: typically a bit fewer than goals
  v_assists_target := CASE
    WHEN p_goals <= 0 THEN 0
    ELSE greatest(0, least(p_goals, floor(p_goals * (0.55 + random() * 0.35))::int))
  END;
  v_assists_left := v_assists_target;
  WHILE v_assists_left > 0 LOOP
    v_roll := random() * v_assist_pool;
    v_acc := 0;
    v_pick := NULL;
    FOR r IN
      SELECT * FROM jsonb_to_recordset(p_side) AS x(
        player_id text, name text, rating numeric, role text,
        pitch_slot text, started boolean, subbed_on boolean, is_star boolean
      )
      WHERE coalesce(started, false)
    LOOP
      v_acc := v_acc + public.match_sim_assist_weight(r.role) * (r.rating / 70.0)
        * public.match_sim_star_assist_mult(r.is_star, r.role, r.rating);
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
    v_assists_map := jsonb_set(
      v_assists_map,
      ARRAY[v_pick],
      to_jsonb(coalesce((v_assists_map->>v_pick)::int, 0) + 1)
    );
    v_assists_left := v_assists_left - 1;
  END LOOP;

  -- Ratings: 6.0 base; winners slightly higher; contributions bump; clean sheet bump
  FOR r IN
    SELECT * FROM jsonb_to_recordset(p_side) AS x(
      player_id text, name text, rating numeric, role text,
      pitch_slot text, started boolean, subbed_on boolean, is_star boolean
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

    -- Ability relative to 75
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

    -- Rare highs; clamp
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

  -- Prefer MOTM from winning side; if draw, either side eligible via caller flag
  IF NOT p_is_motm_side THEN
    v_best_id := NULL;
  END IF;

  FOR r IN
    SELECT * FROM jsonb_to_recordset(p_side) AS x(
      player_id text, name text, rating numeric, role text,
      pitch_slot text, started boolean, subbed_on boolean, is_star boolean
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

-- Club colours for momentum graphic (security definer bypasses theme RLS)
CREATE OR REPLACE FUNCTION public.match_sim_club_colours(
  p_home text,
  p_away text
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'home', jsonb_build_object(
      'short', p_home,
      'primary', coalesce(
        nullif(public._normalize_theme_hex(h.color_primary), ''),
        '#3b82f6'
      ),
      'secondary', coalesce(
        nullif(public._normalize_theme_hex(h.color_secondary), ''),
        '#1e3a5f'
      )
    ),
    'away', jsonb_build_object(
      'short', p_away,
      'primary', coalesce(
        nullif(public._normalize_theme_hex(a.color_primary), ''),
        '#ef4444'
      ),
      'secondary', coalesce(
        nullif(public._normalize_theme_hex(a.color_secondary), ''),
        '#7f1d1d'
      )
    )
  )
  FROM (SELECT 1) dummy
  LEFT JOIN public.club_dashboard_theme h ON h.club_short_name = p_home
  LEFT JOIN public.club_dashboard_theme a ON a.club_short_name = p_away;
$$;

-- Build timed event list for ~20s client playback
CREATE OR REPLACE FUNCTION public.match_sim_build_playback(
  p_fixture_id bigint,
  p_duration_sec int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_dur numeric := greatest(8, least(60, coalesce(p_duration_sec, 20)))::numeric;
  v_fixture record;
  v_events jsonb := '[]'::jsonb;
  v_row record;
  v_t numeric;
  v_minute int;
  v_hg int := 0;
  v_ag int := 0;
  v_i int := 0;
  v_n int;
BEGIN
  SELECT
    f.home_club_short_name,
    f.away_club_short_name,
    f.home_goals,
    f.away_goals
  INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('duration_sec', v_dur, 'events', '[]'::jsonb);
  END IF;

  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', 0,
    'type', 'kickoff',
    'side', null,
    'text', 'Kick-off',
    'minute', 1
  ));

  -- Collect raw events then assign times across the match
  CREATE TEMP TABLE IF NOT EXISTS _ms_ev (
    ord serial,
    kind text,
    side text,
    player_id text,
    player_name text,
    goals int DEFAULT 0,
    assists int DEFAULT 0
  ) ON COMMIT DROP;
  DELETE FROM _ms_ev;

  FOR v_row IN
    SELECT
      m.club_short_name AS side,
      m.player_id,
      coalesce(p."Name", m.player_id) AS player_name,
      coalesce(m.goals, 0) AS goals,
      coalesce(m.assists, 0) AS assists,
      coalesce(m.yellow_card, false) AS yellow_card,
      coalesce(m.red_card, false) AS red_card
    FROM public.competition_match_player_stats m
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
    WHERE m.fixture_id = p_fixture_id
  LOOP
    IF v_row.goals > 0 THEN
      FOR v_i IN 1..v_row.goals LOOP
        INSERT INTO _ms_ev (kind, side, player_id, player_name, goals)
        VALUES ('goal', v_row.side, v_row.player_id, v_row.player_name, 1);
      END LOOP;
    END IF;
    IF v_row.assists > 0 THEN
      FOR v_i IN 1..v_row.assists LOOP
        INSERT INTO _ms_ev (kind, side, player_id, player_name, assists)
        VALUES ('assist', v_row.side, v_row.player_id, v_row.player_name, 1);
      END LOOP;
    END IF;
    IF v_row.yellow_card THEN
      INSERT INTO _ms_ev (kind, side, player_id, player_name)
      VALUES ('yellow', v_row.side, v_row.player_id, v_row.player_name);
    END IF;
    IF v_row.red_card THEN
      INSERT INTO _ms_ev (kind, side, player_id, player_name)
      VALUES ('red', v_row.side, v_row.player_id, v_row.player_name);
    END IF;
  END LOOP;

  -- Injuries from roll table when present
  BEGIN
    FOR v_row IN
      SELECT
        r.club_short_name AS side,
        i.player_id,
        coalesce(p."Name", i.player_id) AS player_name,
        coalesce(c.name, 'Injury') AS injury_name
      FROM public.competition_fixture_injury_roll r
      JOIN public.competition_player_injuries i ON i.id = r.injury_id
      LEFT JOIN public.competition_injury_catalogue c ON c.id = i.catalogue_id
      LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id
      WHERE r.fixture_id = p_fixture_id
        AND r.did_injure
    LOOP
      INSERT INTO _ms_ev (kind, side, player_id, player_name)
      VALUES ('injury', v_row.side, v_row.player_id, v_row.player_name || ' - ' || v_row.injury_name);
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  SELECT count(*)::int INTO v_n FROM _ms_ev;
  v_i := 0;
  IF v_n = 0 THEN
    -- Pure momentum sway when no discrete events
    v_events := v_events || jsonb_build_array(
      jsonb_build_object('t', round(v_dur * 0.25, 2), 'type', 'momentum', 'side', 'home', 'pressure', 0.62, 'text', 'Home pressing'),
      jsonb_build_object('t', round(v_dur * 0.55, 2), 'type', 'momentum', 'side', 'away', 'pressure', 0.58, 'text', 'Away on the break'),
      jsonb_build_object('t', round(v_dur * 0.78, 2), 'type', 'momentum', 'side', 'home', 'pressure', 0.55, 'text', 'End-to-end')
    );
  ELSE
    FOR v_row IN
      SELECT * FROM _ms_ev ORDER BY
        CASE kind WHEN 'goal' THEN 1 WHEN 'assist' THEN 2 WHEN 'yellow' THEN 3 WHEN 'red' THEN 4 ELSE 5 END,
        random()
    LOOP
      v_i := v_i + 1;
      -- Spread across 8%..92% of playback
      v_t := round((0.08 + (0.84 * (v_i::numeric / (v_n + 1)::numeric)) + (random() * 0.03)) * v_dur, 2);
      v_t := least(v_dur - 0.4, greatest(0.5, v_t));
      v_minute := greatest(1, least(90, round((v_t / v_dur) * 90)::int));

      IF v_row.kind = 'goal' THEN
        IF v_row.side = v_fixture.home_club_short_name THEN
          v_hg := v_hg + 1;
        ELSE
          v_ag := v_ag + 1;
        END IF;
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t,
          'type', 'goal',
          'side', CASE WHEN v_row.side = v_fixture.home_club_short_name THEN 'home' ELSE 'away' END,
          'player', v_row.player_name,
          'player_id', v_row.player_id,
          'minute', v_minute,
          'score_home', v_hg,
          'score_away', v_ag,
          'text', format('%s'' GOAL — %s', v_minute, v_row.player_name),
          'pressure', 0.82
        ));
        -- Momentum arrow swings to scoring side
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', least(v_dur - 0.2, v_t + 0.15),
          'type', 'momentum',
          'side', CASE WHEN v_row.side = v_fixture.home_club_short_name THEN 'home' ELSE 'away' END,
          'pressure', 0.78,
          'text', 'Momentum'
        ));
      ELSIF v_row.kind = 'assist' THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t,
          'type', 'assist',
          'side', CASE WHEN v_row.side = v_fixture.home_club_short_name THEN 'home' ELSE 'away' END,
          'player', v_row.player_name,
          'minute', v_minute,
          'text', format('%s'' Assist — %s', v_minute, v_row.player_name)
        ));
      ELSIF v_row.kind = 'yellow' THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t,
          'type', 'yellow',
          'side', CASE WHEN v_row.side = v_fixture.home_club_short_name THEN 'home' ELSE 'away' END,
          'player', v_row.player_name,
          'minute', v_minute,
          'text', format('%s'' Yellow — %s', v_minute, v_row.player_name)
        ));
      ELSIF v_row.kind = 'red' THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t,
          'type', 'red',
          'side', CASE WHEN v_row.side = v_fixture.home_club_short_name THEN 'home' ELSE 'away' END,
          'player', v_row.player_name,
          'minute', v_minute,
          'text', format('%s'' RED — %s', v_minute, v_row.player_name),
          'pressure', 0.7
        ));
      ELSIF v_row.kind = 'injury' THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t,
          'type', 'injury',
          'side', CASE WHEN v_row.side = v_fixture.home_club_short_name THEN 'home' ELSE 'away' END,
          'player', v_row.player_name,
          'minute', v_minute,
          'text', format('%s'' Injury — %s', v_minute, v_row.player_name)
        ));
      END IF;
    END LOOP;

    -- Extra momentum beats between events
    v_events := v_events || jsonb_build_array(
      jsonb_build_object('t', round(v_dur * 0.18, 2), 'type', 'momentum', 'side', 'home', 'pressure', 0.55 + random()*0.2, 'text', 'Home attack'),
      jsonb_build_object('t', round(v_dur * 0.42, 2), 'type', 'momentum', 'side', 'away', 'pressure', 0.55 + random()*0.2, 'text', 'Away attack'),
      jsonb_build_object('t', round(v_dur * 0.68, 2), 'type', 'momentum', 'side', CASE WHEN random() < 0.5 THEN 'home' ELSE 'away' END, 'pressure', 0.5 + random()*0.25, 'text', 'Pressure')
    );
  END IF;

  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', v_dur,
    'type', 'fulltime',
    'side', null,
    'score_home', coalesce(v_fixture.home_goals, v_hg),
    'score_away', coalesce(v_fixture.away_goals, v_ag),
    'text', format('Full time %s–%s', coalesce(v_fixture.home_goals, v_hg), coalesce(v_fixture.away_goals, v_ag)),
    'minute', 90
  ));

  -- Sort events by t
  SELECT coalesce(jsonb_agg(e.obj ORDER BY (e.obj->>'t')::numeric, e.ord), '[]'::jsonb)
  INTO v_events
  FROM (
    SELECT value AS obj, ordinality AS ord
    FROM jsonb_array_elements(v_events) WITH ORDINALITY
  ) e;

  RETURN jsonb_build_object(
    'duration_sec', v_dur,
    'events', v_events
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_simulate_fixture_result(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '60s'
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_fixture public.competition_fixtures;
  v_home jsonb;
  v_away jsonb;
  v_home_str numeric;
  v_away_str numeric;
  v_diff numeric;
  v_outcome text;
  v_score int[];
  v_hg int;
  v_ag int;
  v_home_stats jsonb;
  v_away_stats jsonb;
  v_home_won boolean;
  v_away_won boolean;
  v_draw boolean;
  v_motm_home boolean;
  v_home_star_def numeric;
  v_away_star_def numeric;
  v_home_star_create numeric;
  v_away_star_create numeric;
  v_home_star_fin numeric;
  v_away_star_fin numeric;
  v_home_star_pwr numeric;
  v_away_star_pwr numeric;
  v_home_star_json jsonb;
  v_away_star_json jsonb;
  v_odds jsonb;
  v_playback jsonb;
  v_colours jsonb;
  v_playback_sec int := 20;
  v_home_name text;
  v_away_name text;
  v_cards jsonb;
  v_injuries jsonb;
  v_settings jsonb;
  v_yellow_per_match int := 3;
  v_red_chance_pct numeric := 5;
  v_cards_enabled boolean := true;
  v_injuries_enabled boolean := true;
BEGIN
  IF NOT public.match_result_simulation_enabled() THEN
    RAISE EXCEPTION 'Match result simulation is disabled';
  END IF;

  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_settings := public.match_sim_settings();
  v_yellow_per_match := coalesce((v_settings->>'yellow_per_match')::int, 3);
  v_red_chance_pct := coalesce((v_settings->>'red_chance_pct')::numeric, 5);
  v_cards_enabled := coalesce((v_settings->>'cards_enabled')::boolean, true);
  v_injuries_enabled := coalesce((v_settings->>'injuries_enabled')::boolean, true);

  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for simulation (status=%)', v_fixture.status;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_result_submissions s
    WHERE s.fixture_id = p_fixture_id AND s.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A result is already awaiting confirmation for this fixture';
  END IF;

  -- Same month unlock / holiday-early rules as manual result submit
  PERFORM public.competition_assert_fixture_month_unlocked(p_fixture_id, v_club);

  IF v_fixture.result_sim_lock_club IS NOT NULL
     AND v_fixture.result_sim_lock_club IS DISTINCT FROM v_club
     AND v_fixture.result_sim_lock_at IS NOT NULL
     AND v_fixture.result_sim_lock_at > now() - interval '30 seconds' THEN
    RAISE EXCEPTION
      'Opponent is already simulating this fixture - wait a moment or refresh';
  END IF;

  UPDATE public.competition_fixtures
  SET result_sim_lock_club = v_club,
      result_sim_lock_at = now()
  WHERE id = p_fixture_id;

  v_home := public.match_sim_load_club_side(v_fixture.home_club_short_name);
  v_away := public.match_sim_load_club_side(v_fixture.away_club_short_name);

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
  v_playback_sec := greatest(8, least(60, coalesce((v_settings->>'playback_seconds')::int, 20)));

  v_outcome := public.match_sim_pick_outcome_with_stars(
    v_home_str, v_away_str, v_home_star_pwr, v_away_star_pwr
  );
  v_odds := public.match_sim_nudge_odds_by_stars(
    public.match_sim_outcome_odds(v_home_str, v_away_str),
    v_home_star_pwr,
    v_away_star_pwr
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

  v_home_won := v_hg > v_ag;
  v_away_won := v_ag > v_hg;
  v_draw := v_hg = v_ag;
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

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by match simulation',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_inbox
  SET read_at = coalesce(read_at, now())
  WHERE fixture_id = p_fixture_id
    AND message_type = 'result_to_confirm';

  UPDATE public.competition_fixtures
  SET home_goals = v_hg::smallint,
      away_goals = v_ag::smallint,
      status = 'played',
      result_sim_lock_club = NULL,
      result_sim_lock_at = NULL
  WHERE id = p_fixture_id;

  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_fixture.home_club_short_name,
    v_home_stats,
    v_hg
  );
  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_fixture.away_club_short_name,
    v_away_stats,
    v_ag
  );

  IF v_cards_enabled THEN
    v_cards := public.match_sim_assign_match_cards(
      p_fixture_id, v_yellow_per_match, v_red_chance_pct
    );
  ELSE
    v_cards := jsonb_build_object('ok', true, 'skipped', true, 'reason', 'cards_disabled');
  END IF;

  IF v_injuries_enabled THEN
    BEGIN
      IF to_regprocedure('public.competition_injury_roll_for_fixture(bigint)') IS NOT NULL THEN
        v_injuries := public.competition_injury_roll_for_fixture(p_fixture_id);
      ELSIF to_regprocedure('public.competition_serve_injuries_for_fixture(bigint)') IS NOT NULL THEN
        PERFORM public.competition_serve_injuries_for_fixture(p_fixture_id);
        v_injuries := jsonb_build_object('ok', true, 'via', 'serve_injuries');
      ELSE
        v_injuries := jsonb_build_object('ok', false, 'reason', 'injury_engine_missing');
      END IF;
      -- Tick matchday injury counters after the roll
      IF to_regprocedure('public.competition_serve_injuries_for_fixture(bigint)') IS NOT NULL THEN
        BEGIN
          PERFORM public.competition_serve_injuries_for_fixture(p_fixture_id);
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_injuries := jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  ELSE
    v_injuries := jsonb_build_object('ok', true, 'skipped', true, 'reason', 'injuries_disabled');
  END IF;

  BEGIN
    PERFORM public.competition_settle_fixture_gates(p_fixture_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  IF v_fixture.competition_type = 'league' THEN
    BEGIN
      PERFORM public.competition_try_pay_league_division_prizes(
        v_fixture.season_id,
        v_fixture.division
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  ELSIF v_fixture.competition_type = 'cup' THEN
    BEGIN
      PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  SELECT "Club" INTO v_home_name FROM public."Clubs" WHERE "ShortName" = v_fixture.home_club_short_name;
  SELECT "Club" INTO v_away_name FROM public."Clubs" WHERE "ShortName" = v_fixture.away_club_short_name;

  PERFORM public.competition_inbox_notify(
    CASE
      WHEN v_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
      ELSE v_fixture.home_club_short_name
    END,
    'result_confirmed',
    p_fixture_id,
    NULL,
    format('Simulated result: %s vs %s', coalesce(v_home_name, 'Home'), coalesce(v_away_name, 'Away')),
    format(
      'Matchday %s 遯ｶ繝ｻ%s simulated the result %s遯ｶ繝ｻs (XI strength %s vs %s).',
      v_fixture.matchday,
      v_club,
      v_hg,
      v_ag,
      round(v_home_str)::text,
      round(v_away_str)::text
    )
  );

  v_playback := public.match_sim_build_playback(p_fixture_id, v_playback_sec);
  v_colours := public.match_sim_club_colours(
    v_fixture.home_club_short_name,
    v_fixture.away_club_short_name
  );

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'home_club', v_fixture.home_club_short_name,
    'away_club', v_fixture.away_club_short_name,
    'home_name', v_home_name,
    'away_name', v_away_name,
    'home_goals', v_hg,
    'away_goals', v_ag,
    'outcome', v_outcome,
    'home_xi_strength', round(v_home_str, 1),
    'away_xi_strength', round(v_away_str, 1),
    'strength_diff', round(v_diff, 1),
    'simulated_by', v_club,
    'settings', v_settings,
    'cards', v_cards,
    'injuries', v_injuries,
    'odds', v_odds,
    'stars', jsonb_build_object(
      'home', v_home_star_json,
      'away', v_away_star_json,
      'min_rating', coalesce((v_settings->>'star_min_rating')::int, 79)
    ),
    'colours', v_colours,
    'playback', v_playback
  );
EXCEPTION
  WHEN OTHERS THEN
    UPDATE public.competition_fixtures
    SET result_sim_lock_club = NULL,
        result_sim_lock_at = NULL
    WHERE id = p_fixture_id
      AND result_sim_lock_club = v_club;
    RAISE;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_star_min_rating() TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_star_quality(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_side_star_powers(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_nudge_odds_by_stars(jsonb, numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_pick_outcome_with_stars(numeric, numeric, numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_star_goal_mult(boolean, text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_star_assist_mult(boolean, text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_club_colours(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_build_playback(bigint, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_match_sim_settings(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_simulate_fixture_result(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';