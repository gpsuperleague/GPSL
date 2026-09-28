-- =============================================================================
-- Challenge templates: edit a saved template directly (name + targets)
-- without applying it to the live season.
--
-- Run after competition_challenge_templates.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_admin_update_challenge_template(
  p_template_id bigint,
  p_name text,
  p_targets jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_row jsonb;
  v_clean jsonb := '[]'::jsonb;
  v_i int := 0;
  v_phase text;
  v_title text;
  v_stat text;
  v_target int;
  v_prize numeric;
  v_max int;
  v_start int := 0;
  v_mid int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.competition_challenge_templates WHERE id = p_template_id) THEN
    RAISE EXCEPTION 'Template not found';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Template name required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_challenge_templates
    WHERE lower(btrim(name)) = lower(v_name) AND id <> p_template_id
  ) THEN
    RAISE EXCEPTION 'Another template is already called "%"', v_name;
  END IF;

  IF p_targets IS NULL OR jsonb_typeof(p_targets) <> 'array' OR jsonb_array_length(p_targets) = 0 THEN
    RAISE EXCEPTION 'Template needs at least one target';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_targets)
  LOOP
    v_i := v_i + 1;
    v_phase := lower(btrim(coalesce(v_row->>'window_phase', '')));
    v_title := nullif(btrim(coalesce(v_row->>'title', '')), '');
    v_stat := nullif(btrim(coalesce(v_row->>'stat_type', '')), '');
    BEGIN
      v_target := (v_row->>'target_value')::int;
      v_prize := nullif(v_row->>'prize_amount', '')::numeric;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Target %: invalid number', v_i;
    END;

    IF v_phase NOT IN ('start', 'mid') THEN
      RAISE EXCEPTION 'Target %: window must be Start or Mid', v_i;
    END IF;
    IF v_title IS NULL THEN
      RAISE EXCEPTION 'Target %: title required', v_i;
    END IF;
    IF v_stat IS NULL THEN
      RAISE EXCEPTION 'Target % (%): stat required', v_i, v_title;
    END IF;
    IF coalesce(v_target, 0) <= 0 THEN
      RAISE EXCEPTION 'Target % (%): target must be at least 1', v_i, v_title;
    END IF;

    IF coalesce((v_row->>'is_active')::boolean, true) THEN
      IF v_phase = 'start' THEN v_start := v_start + 1; ELSE v_mid := v_mid + 1; END IF;
    END IF;

    v_clean := v_clean || jsonb_build_array(jsonb_build_object(
      'title', v_title,
      'description', nullif(btrim(coalesce(v_row->>'description', '')), ''),
      'window_phase', v_phase,
      'gpsl_month_from', coalesce(nullif(v_row->>'gpsl_month_from', ''),
                                  CASE v_phase WHEN 'mid' THEN 'january' ELSE 'august' END),
      'gpsl_month_to', coalesce(nullif(v_row->>'gpsl_month_to', ''),
                                CASE v_phase WHEN 'mid' THEN 'may' ELSE 'december' END),
      'stat_type', v_stat,
      'stat_param', nullif(btrim(coalesce(v_row->>'stat_param', '')), ''),
      'target_value', v_target,
      'prize_amount', CASE WHEN v_prize IS NULL OR v_prize <= 0 THEN NULL ELSE v_prize END,
      'include_league', coalesce((v_row->>'include_league')::boolean, true),
      'include_cup', coalesce((v_row->>'include_cup')::boolean, false),
      'is_active', coalesce((v_row->>'is_active')::boolean, true),
      'sort_order', coalesce((v_row->>'sort_order')::int, v_i)
    ));
  END LOOP;

  SELECT coalesce(challenge_max_per_window, 10) INTO v_max
  FROM public.global_settings WHERE id = 1;
  v_max := coalesce(v_max, 10);
  IF v_start > v_max OR v_mid > v_max THEN
    RAISE EXCEPTION 'Max % active targets per window (Start %, Mid %)', v_max, v_start, v_mid;
  END IF;

  UPDATE public.competition_challenge_templates
  SET name = v_name,
      targets = v_clean,
      updated_at = now()
  WHERE id = p_template_id;

  RETURN jsonb_build_object(
    'ok', true,
    'id', p_template_id,
    'name', v_name,
    'target_count', jsonb_array_length(v_clean),
    'start_count', v_start,
    'mid_count', v_mid
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_update_challenge_template(bigint, text, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
