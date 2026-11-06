-- =============================================================================
-- Tariff catalogue: add a fine, and choose which fines are on the video report.
--
-- Adds competition_fine_tariff.on_video_report.
-- The match-video R button lists active fines with that tick.
-- The first run ticks the short video-report list. Later runs keep staff ticks.
-- Admin → Fines saves the tick through competition_admin_save_fine_tariff.
--
-- If formation_drag_forfeit_20261106.sql is run again after this, run this
-- file again so a report can only submit a ticked fine.
--
-- Safe re-run. Run in the Supabase SQL editor.
-- =============================================================================

ALTER TABLE public.competition_fine_tariff
  ADD COLUMN IF NOT EXISTS on_video_report boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.competition_fine_tariff.on_video_report IS
  'When true, an active fine is offered on the match-video R button.';

UPDATE public.competition_fine_tariff
SET label = 'Use of PA1, PA2 or SA', updated_at = now()
WHERE code = 'use_of_sa' AND label IS DISTINCT FROM 'Use of PA1, PA2 or SA';

UPDATE public.competition_fine_tariff
SET label = 'Ineligible Player Starts - off by 10 minutes no score', updated_at = now()
WHERE code = 'ineligible_starts_off_by_10'
  AND label IS DISTINCT FROM 'Ineligible Player Starts - off by 10 minutes no score';

UPDATE public.competition_fine_tariff
SET label = 'Ineligible Player Starts - plays more than 10 minutes', updated_at = now()
WHERE code = 'ineligible_starts_plays_10'
  AND label IS DISTINCT FROM 'Ineligible Player Starts - plays more than 10 minutes';

UPDATE public.competition_fine_tariff
SET label = 'Matchroom settings not cross check and displayed (Away)', updated_at = now()
WHERE code = 'matchroom_not_displayed_away'
  AND label IS DISTINCT FROM 'Matchroom settings not cross check and displayed (Away)';

UPDATE public.competition_fine_tariff
SET label = 'Dragged players off the default formation', updated_at = now()
WHERE code = 'formation_player_drag'
  AND label IS DISTINCT FROM 'Dragged players off the default formation';

DO $seed_video_report$
BEGIN
  IF EXISTS (SELECT 1 FROM public.competition_fine_tariff WHERE on_video_report) THEN
    RAISE NOTICE 'video-report ticks already set — left as they are';
    RETURN;
  END IF;

  UPDATE public.competition_fine_tariff
  SET on_video_report = true
  WHERE code IN (
    'ineligible_manager',
    'own_goal_scored',
    'own_goal_attempt',
    'engineer_opposition_chances',
    'refusing_to_participate',
    'non_display_pa_level',
    'use_of_sa',
    'time_wasting',
    'showboating',
    'playing_whilst_opponent_incapacitated',
    'ineligible_player_unused_sub',
    'ineligible_starts_off_by_10',
    'ineligible_starts_plays_10',
    'ineligible_player_sub_introduced',
    'deliberate_foul_play',
    'dogso',
    'form_manipulation',
    'matchroom_not_displayed_home',
    'matchroom_not_displayed_away',
    'incorrect_stadium_selection',
    'incorrect_season_selection',
    'incorrect_pitch_conditions',
    'incorrect_weather_conditions',
    'incorrect_club_selection',
    'incorrect_kit_selection',
    'incorrect_club_name_abbr',
    'incorrect_custom_stadium',
    'non_display_attack_defence',
    'non_display_scoreboard',
    'non_display_sub_tactic',
    'non_display_player_instructions',
    'red_blue_before_80',
    'double_red_blue',
    'no_gk_fine',
    'formation_player_drag',
    'illegal_match_termination'
  );
END;
$seed_video_report$;

DROP FUNCTION IF EXISTS public.match_video_breach_code_reportable(text);

CREATE FUNCTION public.match_video_breach_code_reportable(p_code text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce((
    SELECT t.on_video_report
      AND t.is_active
      AND t.direction = 'fine'
      AND t.code <> 'match_video_missing'
    FROM public.competition_fine_tariff t
    WHERE t.code = btrim(coalesce(p_code, ''))
  ), false);
$$;

COMMENT ON FUNCTION public.match_video_breach_code_reportable(text) IS
  'True when a fine tariff may be chosen on a match-video breach report.';

REVOKE ALL ON FUNCTION public.match_video_breach_code_reportable(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_breach_code_reportable(text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.match_video_report_breach_codes()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN coalesce((
    SELECT jsonb_agg(
      jsonb_build_object(
        'code', t.code,
        'label', t.label,
        'category', t.category,
        'amount', t.amount
      )
      ORDER BY t.category, t.sort_order, t.label
    )
    FROM public.competition_fine_tariff t
    WHERE t.is_active = true
      AND t.direction = 'fine'
      AND t.on_video_report
      AND t.code <> 'match_video_missing'
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_video_report_breach_codes() TO authenticated;

CREATE OR REPLACE FUNCTION public.competition_admin_save_fine_tariff(p_tariff jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_tariff IS NULL OR jsonb_typeof(p_tariff) <> 'object' THEN
    RAISE EXCEPTION 'tariff must be a JSON object';
  END IF;

  IF btrim(coalesce(p_tariff->>'code', '')) = '' OR btrim(coalesce(p_tariff->>'label', '')) = '' THEN
    RAISE EXCEPTION 'Code and label required';
  END IF;

  INSERT INTO public.competition_fine_tariff (
    code, label, category, direction, amount, amount_mode, is_active, sort_order, on_video_report
  )
  VALUES (
    btrim(p_tariff->>'code'),
    btrim(p_tariff->>'label'),
    coalesce(p_tariff->>'category', 'matchday'),
    coalesce(p_tariff->>'direction', 'fine'),
    nullif(p_tariff->>'amount', '')::numeric,
    coalesce(p_tariff->>'amount_mode', 'fixed'),
    coalesce((p_tariff->>'is_active')::boolean, true),
    coalesce((p_tariff->>'sort_order')::smallint, 0),
    coalesce((p_tariff->>'on_video_report')::boolean, false)
  )
  ON CONFLICT (code) DO UPDATE
  SET
    label = excluded.label,
    category = excluded.category,
    direction = excluded.direction,
    amount = excluded.amount,
    amount_mode = excluded.amount_mode,
    is_active = excluded.is_active,
    sort_order = excluded.sort_order,
    on_video_report = CASE
      WHEN p_tariff ? 'on_video_report'
        THEN coalesce((p_tariff->>'on_video_report')::boolean, false)
      ELSE public.competition_fine_tariff.on_video_report
    END,
    updated_at = now();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_save_fine_tariff(jsonb) TO authenticated;

-- A crafted report must name a ticked fine, not every matchday tariff.
DO $gate$
DECLARE
  v_oid oid;
  v_def text;
  v_old text := 'AND t.category IN (''matchday'', ''squad'', ''manager'')';
  v_new text := 'AND t.on_video_report';
BEGIN
  v_oid := to_regprocedure('public.match_video_submit_breach_report(bigint,text,jsonb)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'multi-breach submit missing — the R-button list is still filtered';
    RETURN;
  END IF;

  v_def := pg_get_functiondef(v_oid);
  IF position('t.on_video_report' IN v_def) > 0 THEN
    RAISE NOTICE 'submit already limited to ticked fines';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'submit category check not found — R-button list is filtered, submit gate was not';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'submit limited to ticked fines';
END;
$gate$;

NOTIFY pgrst, 'reload schema';
