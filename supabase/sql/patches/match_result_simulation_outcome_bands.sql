-- =============================================================================
-- Match sim: granular XI-strength outcome bands (human-readable)
-- UI: admin_match_sim.html
-- Run after match_result_simulation_settings.sql
-- =============================================================================

-- Default modular bands (gap = |home XI rating sum − away XI rating sum|)
-- mode 'sides' = Home / Draw / Away (home bias)
-- mode 'fav'   = Favourite / Draw / Upset (stronger XI is favourite)

CREATE OR REPLACE FUNCTION public.match_sim_default_outcome_bands()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_array(
    jsonb_build_object(
      'id', 'even',
      'title', 'Even contest',
      'blurb', 'XI strengths are almost identical. Small home lean; draws common.',
      'min_diff', 0,
      'mode', 'sides',
      'home_pct', 40,
      'draw_pct', 50,
      'away_pct', 10
    ),
    jsonb_build_object(
      'id', 'slight',
      'title', 'Slight edge',
      'blurb', 'One XI is a bit stronger. Favourite usually wins; upsets still happen.',
      'min_diff', 15,
      'mode', 'fav',
      'fav_pct', 55,
      'draw_pct', 25,
      'upset_pct', 20
    ),
    jsonb_build_object(
      'id', 'clear',
      'title', 'Clear favourite',
      'blurb', 'A clear gap on paper. Favourite wins most of the time.',
      'min_diff', 30,
      'mode', 'fav',
      'fav_pct', 65,
      'draw_pct', 20,
      'upset_pct', 15
    ),
    jsonb_build_object(
      'id', 'strong',
      'title', 'Strong favourite',
      'blurb', 'Big XI gap. Upsets are uncommon.',
      'min_diff', 50,
      'mode', 'fav',
      'fav_pct', 75,
      'draw_pct', 15,
      'upset_pct', 10
    ),
    jsonb_build_object(
      'id', 'mismatch',
      'title', 'Mismatch',
      'blurb', 'Huge gap — favourite almost always wins.',
      'min_diff', 80,
      'mode', 'fav',
      'fav_pct', 100,
      'draw_pct', 0,
      'upset_pct', 0
    )
  );
$$;

-- Seed 5 modular bands when missing, or when still on the old 3-threshold keys only.
UPDATE public.global_settings
SET match_result_simulation_settings =
  coalesce(match_result_simulation_settings, '{}'::jsonb)
  || CASE
    WHEN EXISTS (
      SELECT 1
      FROM jsonb_array_elements(
        CASE
          WHEN jsonb_typeof(match_result_simulation_settings->'outcome_bands') = 'array'
          THEN match_result_simulation_settings->'outcome_bands'
          ELSE '[]'::jsonb
        END
      ) b
      WHERE b->>'id' IN ('even', 'slight', 'clear', 'strong', 'mismatch')
    )
    THEN '{}'::jsonb
    ELSE jsonb_build_object('outcome_bands', public.match_sim_default_outcome_bands())
  END
WHERE id = 1;

CREATE OR REPLACE FUNCTION public.match_sim_normalize_outcome_bands(p_bands jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_defaults jsonb := public.match_sim_default_outcome_bands();
  v_in jsonb := CASE
    WHEN p_bands IS NOT NULL AND jsonb_typeof(p_bands) = 'array' AND jsonb_array_length(p_bands) > 0
    THEN p_bands
    ELSE v_defaults
  END;
  v_row jsonb;
  v_out jsonb := '[]'::jsonb;
  v_mode text;
  v_a int;
  v_b int;
  v_c int;
  v_min int;
  v_id text;
  v_title text;
  v_blurb text;
  v_prev_min int := -1;
BEGIN
  FOR v_row IN
    SELECT value
    FROM jsonb_array_elements(v_in) WITH ORDINALITY AS t(value, ord)
    ORDER BY coalesce((value->>'min_diff')::int, 0), ord
  LOOP
    v_mode := lower(coalesce(nullif(btrim(v_row->>'mode'), ''), 'fav'));
    IF v_mode NOT IN ('sides', 'fav') THEN
      v_mode := 'fav';
    END IF;

    v_min := greatest(0, least(500, coalesce((v_row->>'min_diff')::int, 0)));
    IF v_min < v_prev_min THEN
      v_min := v_prev_min;
    END IF;
    v_prev_min := v_min;

    v_id := coalesce(nullif(btrim(v_row->>'id'), ''), 'band_' || v_min::text);
    v_title := coalesce(nullif(btrim(v_row->>'title'), ''), 'Band from ' || v_min::text);
    v_blurb := coalesce(nullif(btrim(v_row->>'blurb'), ''), '');

    IF v_mode = 'sides' THEN
      v_a := greatest(0, least(100, coalesce((v_row->>'home_pct')::int, 40)));
      v_b := greatest(0, least(100 - v_a, coalesce((v_row->>'draw_pct')::int, 50)));
      v_c := greatest(0, 100 - v_a - v_b);
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', v_id,
        'title', v_title,
        'blurb', v_blurb,
        'min_diff', v_min,
        'mode', 'sides',
        'home_pct', v_a,
        'draw_pct', v_b,
        'away_pct', v_c
      ));
    ELSE
      v_a := greatest(0, least(100, coalesce((v_row->>'fav_pct')::int, 60)));
      v_b := greatest(0, least(100 - v_a, coalesce((v_row->>'draw_pct')::int, 20)));
      v_c := greatest(0, 100 - v_a - v_b);
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', v_id,
        'title', v_title,
        'blurb', v_blurb,
        'min_diff', v_min,
        'mode', 'fav',
        'fav_pct', v_a,
        'draw_pct', v_b,
        'upset_pct', v_c
      ));
    END IF;
  END LOOP;

  IF jsonb_array_length(v_out) = 0 THEN
    RETURN v_defaults;
  END IF;

  RETURN v_out;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_sim_settings()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'yellow_per_month', coalesce((s->>'yellow_per_month')::int, 15),
    'red_per_month', coalesce((s->>'red_per_month')::int, 1),
    'cards_enabled', coalesce((s->>'cards_enabled')::boolean, true),
    'injuries_enabled', coalesce((s->>'injuries_enabled')::boolean, true),
    'max_subs_on', greatest(0, least(5, coalesce((s->>'max_subs_on')::int, 5))),
    'outcome_bands', public.match_sim_normalize_outcome_bands(s->'outcome_bands')
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
  v_red int;
  v_max_subs int;
  v_bands jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_yellow := greatest(0, least(200, coalesce((v_in->>'yellow_per_month')::int, 15)));
  v_red := greatest(0, least(50, coalesce((v_in->>'red_per_month')::int, 1)));
  v_max_subs := greatest(0, least(5, coalesce((v_in->>'max_subs_on')::int, 5)));
  v_bands := public.match_sim_normalize_outcome_bands(v_in->'outcome_bands');

  v_out := jsonb_build_object(
    'yellow_per_month', v_yellow,
    'red_per_month', v_red,
    'cards_enabled', coalesce((v_in->>'cards_enabled')::boolean, true),
    'injuries_enabled', coalesce((v_in->>'injuries_enabled')::boolean, true),
    'max_subs_on', v_max_subs,
    'outcome_bands', v_bands
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

CREATE OR REPLACE FUNCTION public.match_sim_pick_band(p_abs_diff numeric, p_bands jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_bands jsonb := public.match_sim_normalize_outcome_bands(p_bands);
  v_row jsonb;
  v_best jsonb;
  v_min int;
BEGIN
  FOR v_row IN
    SELECT value
    FROM jsonb_array_elements(v_bands) WITH ORDINALITY AS t(value, ord)
    ORDER BY coalesce((value->>'min_diff')::int, 0), ord
  LOOP
    v_min := coalesce((v_row->>'min_diff')::int, 0);
    IF coalesce(p_abs_diff, 0) >= v_min THEN
      v_best := v_row;
    END IF;
  END LOOP;

  RETURN coalesce(v_best, v_bands->0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_sim_outcome_odds(
  p_home_str numeric,
  p_away_str numeric
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s jsonb := public.match_sim_settings();
  v_diff numeric := coalesce(p_home_str, 0) - coalesce(p_away_str, 0);
  v_abs numeric := abs(v_diff);
  v_home_fav boolean := v_diff >= 0;
  v_band jsonb;
  v_mode text;
  v_home numeric;
  v_draw numeric;
  v_away numeric;
  v_next_min int;
  v_range_text text;
  v_bands jsonb;
BEGIN
  v_bands := v_s->'outcome_bands';
  v_band := public.match_sim_pick_band(v_abs, v_bands);
  v_mode := coalesce(v_band->>'mode', 'fav');

  SELECT min((b->>'min_diff')::int)
  INTO v_next_min
  FROM jsonb_array_elements(v_bands) b
  WHERE (b->>'min_diff')::int > coalesce((v_band->>'min_diff')::int, 0);

  IF v_next_min IS NULL THEN
    v_range_text := format('%s+ rating points', coalesce((v_band->>'min_diff')::int, 0));
  ELSE
    v_range_text := format(
      '%s–%s rating points',
      coalesce((v_band->>'min_diff')::int, 0),
      v_next_min - 1
    );
  END IF;

  IF v_mode = 'sides' THEN
    v_home := coalesce((v_band->>'home_pct')::numeric, 40);
    v_draw := coalesce((v_band->>'draw_pct')::numeric, 50);
    v_away := coalesce((v_band->>'away_pct')::numeric, 10);
  ELSE
    IF v_home_fav THEN
      v_home := coalesce((v_band->>'fav_pct')::numeric, 60);
      v_draw := coalesce((v_band->>'draw_pct')::numeric, 20);
      v_away := coalesce((v_band->>'upset_pct')::numeric, 20);
    ELSE
      v_home := coalesce((v_band->>'upset_pct')::numeric, 20);
      v_draw := coalesce((v_band->>'draw_pct')::numeric, 20);
      v_away := coalesce((v_band->>'fav_pct')::numeric, 60);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'home_strength', coalesce(p_home_str, 0),
    'away_strength', coalesce(p_away_str, 0),
    'diff', round(v_diff, 1),
    'abs_diff', round(v_abs, 1),
    'home_fav', v_home_fav,
    'favourite', CASE
      WHEN v_mode = 'sides' THEN 'none'
      WHEN v_abs < 0.0001 THEN 'none'
      WHEN v_home_fav THEN 'home'
      ELSE 'away'
    END,
    'band', v_band,
    'gap_label', v_range_text,
    'home_pct', round(v_home, 1),
    'draw_pct', round(v_draw, 1),
    'away_pct', round(v_away, 1),
    'summary', format(
      '%s (%s): Home %s%% · Draw %s%% · Away %s%%',
      coalesce(v_band->>'title', 'Band'),
      v_range_text,
      round(v_home, 0)::text,
      round(v_draw, 0)::text,
      round(v_away, 0)::text
    ),
    'note', 'XI strength = sum of starting XI player ratings. Stars affect goals after the result is chosen, not these odds.'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_sim_pick_outcome(p_home_str numeric, p_away_str numeric)
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
  v_odds := public.match_sim_outcome_odds(p_home_str, p_away_str);
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

GRANT EXECUTE ON FUNCTION public.match_sim_default_outcome_bands() TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_normalize_outcome_bands(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_pick_band(numeric, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_outcome_odds(numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_pick_outcome(numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_match_sim_settings(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
