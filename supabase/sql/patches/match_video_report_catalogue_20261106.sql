-- =============================================================================
-- Video-report breach list
--
-- The R-button was offering every active matchday/squad/manager fine,
-- including no-shows and squad-registration fines that are not video breaches.
-- This keeps those fines active for the automatic paths and limits the
-- report form (and new submissions) to the video catalogue below.
--
-- Label tweaks:
--   Use of SA                         → Use of PA1, PA2 or SA
--   off by 10 no score                → off by 10 minutes no score
--   plays more than 10                → plays more than 10 minutes
--   Matchroom settings not displayed (Away)
--                                     → Matchroom settings not cross check and displayed (Away)
--   Dragged players… (long sanction)  → Dragged players off the default formation
--
-- Safe re-run. Run in the Supabase SQL editor.
-- =============================================================================

UPDATE public.competition_fine_tariff
SET label = 'Use of PA1, PA2 or SA', updated_at = now()
WHERE code = 'use_of_sa';

UPDATE public.competition_fine_tariff
SET label = 'Ineligible Player Starts - off by 10 minutes no score', updated_at = now()
WHERE code = 'ineligible_starts_off_by_10';

UPDATE public.competition_fine_tariff
SET label = 'Ineligible Player Starts - plays more than 10 minutes', updated_at = now()
WHERE code = 'ineligible_starts_plays_10';

UPDATE public.competition_fine_tariff
SET label = 'Matchroom settings not cross check and displayed (Away)', updated_at = now()
WHERE code = 'matchroom_not_displayed_away';

UPDATE public.competition_fine_tariff
SET label = 'Dragged players off the default formation', updated_at = now()
WHERE code = 'formation_player_drag';

CREATE OR REPLACE FUNCTION public.match_video_breach_code_reportable(p_code text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT btrim(coalesce(p_code, '')) IN (
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
      AND public.match_video_breach_code_reportable(t.code)
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_video_report_breach_codes() TO authenticated;

-- Reject a submission that still posts a code no longer on the form.
DO $gate$
DECLARE
  v_oid oid;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_oid := to_regprocedure('public.match_video_submit_breach_report(bigint,text,jsonb)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'multi-breach submit missing — catalogue filter still applies to the form';
    RETURN;
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('match_video_breach_code_reportable' IN v_def) > 0 THEN
    RAISE NOTICE 'submit already limited to the video catalogue';
    RETURN;
  END IF;

  v_old := replace($n$      AND t.category IN ('matchday', 'squad', 'manager')
      AND t.code <> 'match_video_missing';
$n$, E'\r\n', E'\n');

  v_new := replace($n$      AND t.category IN ('matchday', 'squad', 'manager')
      AND t.code <> 'match_video_missing'
      AND public.match_video_breach_code_reportable(t.code);
$n$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'submit validation needle not found — form list is filtered, submit gate was not';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'submit limited to the video catalogue';
END;
$gate$;

NOTIFY pgrst, 'reload schema';
