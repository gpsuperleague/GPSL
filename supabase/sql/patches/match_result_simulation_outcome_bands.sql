-- =============================================================================
-- Match sim: editable XI-strength outcome bands + win% helper
-- UI: admin_match_sim.html (Win % section)
-- Run after match_result_simulation_settings.sql
-- =============================================================================

-- Merge outcome-band defaults into existing settings
UPDATE public.global_settings
SET match_result_simulation_settings =
  coalesce(match_result_simulation_settings, '{}'::jsonb)
  || jsonb_build_object(
    'blowout_diff', coalesce((match_result_simulation_settings->>'blowout_diff')::int, 100),
    'strong_diff', coalesce((match_result_simulation_settings->>'strong_diff')::int, 50),
    'strong_fav_pct', coalesce((match_result_simulation_settings->>'strong_fav_pct')::int, 60),
    'strong_draw_pct', coalesce((match_result_simulation_settings->>'strong_draw_pct')::int, 20),
    'close_home_pct', coalesce((match_result_simulation_settings->>'close_home_pct')::int, 20),
    'close_away_pct', coalesce((match_result_simulation_settings->>'close_away_pct')::int, 20),
    'close_draw_pct', coalesce((match_result_simulation_settings->>'close_draw_pct')::int, 60)
  )
WHERE id = 1;

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
    'blowout_diff', greatest(1, coalesce((s->>'blowout_diff')::int, 100)),
    'strong_diff', greatest(0, coalesce((s->>'strong_diff')::int, 50)),
    'strong_fav_pct', greatest(0, least(100, coalesce((s->>'strong_fav_pct')::int, 60))),
    'strong_draw_pct', greatest(0, least(100, coalesce((s->>'strong_draw_pct')::int, 20))),
    'close_home_pct', greatest(0, least(100, coalesce((s->>'close_home_pct')::int, 20))),
    'close_away_pct', greatest(0, least(100, coalesce((s->>'close_away_pct')::int, 20))),
    'close_draw_pct', greatest(0, least(100, coalesce((s->>'close_draw_pct')::int, 60)))
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
  v_blowout int;
  v_strong int;
  v_sf int;
  v_sd int;
  v_ch int;
  v_ca int;
  v_cd int;
  v_strong_upset int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_yellow := greatest(0, least(200, coalesce((v_in->>'yellow_per_month')::int, 15)));
  v_red := greatest(0, least(50, coalesce((v_in->>'red_per_month')::int, 1)));
  v_max_subs := greatest(0, least(5, coalesce((v_in->>'max_subs_on')::int, 5)));
  v_blowout := greatest(1, least(500, coalesce((v_in->>'blowout_diff')::int, 100)));
  v_strong := greatest(0, least(v_blowout, coalesce((v_in->>'strong_diff')::int, 50)));
  v_sf := greatest(0, least(100, coalesce((v_in->>'strong_fav_pct')::int, 60)));
  v_sd := greatest(0, least(100 - v_sf, coalesce((v_in->>'strong_draw_pct')::int, 20)));
  v_strong_upset := greatest(0, 100 - v_sf - v_sd);
  v_ch := greatest(0, least(100, coalesce((v_in->>'close_home_pct')::int, 20)));
  v_ca := greatest(0, least(100 - v_ch, coalesce((v_in->>'close_away_pct')::int, 20)));
  v_cd := greatest(0, 100 - v_ch - v_ca);

  v_out := jsonb_build_object(
    'yellow_per_month', v_yellow,
    'red_per_month', v_red,
    'cards_enabled', coalesce((v_in->>'cards_enabled')::boolean, true),
    'injuries_enabled', coalesce((v_in->>'injuries_enabled')::boolean, true),
    'max_subs_on', v_max_subs,
    'blowout_diff', v_blowout,
    'strong_diff', v_strong,
    'strong_fav_pct', v_sf,
    'strong_draw_pct', v_sd,
    'strong_upset_pct', v_strong_upset,
    'close_home_pct', v_ch,
    'close_away_pct', v_ca,
    'close_draw_pct', v_cd
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

-- Win% for a given XI strength pair (same bands as pick_outcome)
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
  v_blowout int := coalesce((v_s->>'blowout_diff')::int, 100);
  v_strong int := coalesce((v_s->>'strong_diff')::int, 50);
  v_sf numeric := coalesce((v_s->>'strong_fav_pct')::numeric, 60);
  v_sd numeric := coalesce((v_s->>'strong_draw_pct')::numeric, 20);
  v_su numeric := greatest(0, 100 - v_sf - v_sd);
  v_ch numeric := coalesce((v_s->>'close_home_pct')::numeric, 20);
  v_ca numeric := coalesce((v_s->>'close_away_pct')::numeric, 20);
  v_cd numeric := greatest(0, 100 - v_ch - v_ca);
  v_home numeric;
  v_draw numeric;
  v_away numeric;
  v_band text;
BEGIN
  IF v_abs >= v_blowout THEN
    v_band := 'blowout';
    IF v_home_fav THEN
      v_home := 100; v_draw := 0; v_away := 0;
    ELSE
      v_home := 0; v_draw := 0; v_away := 100;
    END IF;
  ELSIF v_abs >= v_strong THEN
    v_band := 'strong';
    IF v_home_fav THEN
      v_home := v_sf; v_draw := v_sd; v_away := v_su;
    ELSE
      v_home := v_su; v_draw := v_sd; v_away := v_sf;
    END IF;
  ELSE
    v_band := 'close';
    v_home := v_ch; v_draw := v_cd; v_away := v_ca;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'home_strength', coalesce(p_home_str, 0),
    'away_strength', coalesce(p_away_str, 0),
    'diff', v_diff,
    'abs_diff', v_abs,
    'band', v_band,
    'home_fav', v_home_fav,
    'home_pct', round(v_home, 1),
    'draw_pct', round(v_draw, 1),
    'away_pct', round(v_away, 1),
    'thresholds', jsonb_build_object(
      'strong_diff', v_strong,
      'blowout_diff', v_blowout
    ),
    'note', 'Outcome from XI rating sum only. Stars nudge goal totals after the result is chosen.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_outcome_odds(numeric, numeric) TO authenticated;

-- Pick outcome using saved bands
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

GRANT EXECUTE ON FUNCTION public.match_sim_pick_outcome(numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_match_sim_settings(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
