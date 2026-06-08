-- Fix: competition_active_gpsl_month returns text ('august', etc.) not smallint.
-- Run this if estimate_gate_for_club fails with: invalid input syntax for type smallint: "august"

CREATE OR REPLACE FUNCTION public.competition_stadium_sync_fill_state(
  p_club_short_name text,
  p_season_id bigint DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.global_settings;
  v_season_id bigint;
  v_metrics jsonb;
  v_display numeric;
  v_target numeric;
  v_prestige_base numeric;
  v_active_month_name text;
  v_active_month smallint;
  v_last_month smallint;
  v_stored_season bigint;
  v_drift numeric;
  v_steps int;
  v_i int;
BEGIN
  SELECT * INTO v_cfg FROM public.global_settings WHERE id = 1;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_metrics := public.competition_stadium_season_metrics(p_club_short_name, v_season_id);

  IF v_metrics ? 'error' THEN
    RETURN NULL;
  END IF;

  v_target := (v_metrics ->> 'season_target_fill_pct')::numeric;
  v_prestige_base := (v_metrics ->> 'prestige_base_fill_pct')::numeric;
  v_active_month_name := public.competition_active_gpsl_month(v_season_id, now());
  v_active_month := public.competition_gpsl_month_sort(v_active_month_name);
  v_drift := v_cfg.stadium_monthly_drift_pct;

  SELECT
    c.stadium_display_fill_pct,
    c.stadium_fill_last_month,
    c.stadium_fill_season_id
  INTO v_display, v_last_month, v_stored_season
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  IF v_display IS NULL THEN
    v_display := v_prestige_base;
  END IF;

  IF v_stored_season IS DISTINCT FROM v_season_id THEN
    UPDATE public."Clubs"
    SET
      stadium_season_start_fill_pct = round(v_display, 2),
      stadium_fill_season_id = v_season_id,
      stadium_fill_last_month = v_active_month
    WHERE "ShortName" = p_club_short_name;

    v_last_month := v_active_month;
    v_stored_season := v_season_id;
  END IF;

  IF v_last_month IS NULL AND v_active_month IS NOT NULL THEN
    v_last_month := v_active_month;
  END IF;

  v_steps := CASE
    WHEN v_active_month IS NULL OR v_last_month IS NULL THEN 0
    ELSE greatest(v_active_month - v_last_month, 0)
  END;

  FOR v_i IN 1..v_steps LOOP
    IF v_display < v_target THEN
      v_display := least(v_target, v_display + v_drift);
    ELSIF v_display > v_target THEN
      v_display := greatest(v_target, v_display - v_drift);
    END IF;
  END LOOP;

  v_display := greatest(
    v_cfg.stadium_min_fill_pct,
    least(v_cfg.stadium_max_display_fill_pct, round(v_display, 2))
  );

  UPDATE public."Clubs"
  SET
    stadium_display_fill_pct = v_display,
    stadium_fill_target_pct = round(v_target, 2),
    stadium_fill_last_month = coalesce(v_active_month, stadium_fill_last_month),
    stadium_fill_season_id = v_season_id,
    stadium_fill_updated_at = now()
  WHERE "ShortName" = p_club_short_name;

  RETURN v_display;
END;
$function$;

NOTIFY pgrst, 'reload schema';
