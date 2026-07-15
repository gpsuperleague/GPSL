-- =============================================================================
-- Fix: ambiguous competition_draw_prestige_cup overloads
--
-- Error: Could not choose the best candidate function between
--   competition_draw_prestige_cup(bigint, text)
--   competition_draw_prestige_cup(bigint, text, text[], int[])
--
-- Keep a single 4-arg version (optional player order / bye slots).
-- Also accept cup_code 'bowl' (alias of legacy 'spoon').
-- Safe re-run.
-- =============================================================================

DROP FUNCTION IF EXISTS public.competition_draw_prestige_cup(bigint, text);
DROP FUNCTION IF EXISTS public.competition_draw_prestige_cup(bigint, text, text[]);
DROP FUNCTION IF EXISTS public.competition_draw_prestige_cup(bigint, text, text[], int[]);

CREATE OR REPLACE FUNCTION public.competition_draw_prestige_cup(
  p_season_id bigint,
  p_cup_code text,
  p_player_order text[] DEFAULT NULL,
  p_bye_match_nos int[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text := lower(btrim(coalesce(p_cup_code, '')));
  v_clubs text[];
  v_byes text[];
  v_result jsonb;
  v_sync jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_code NOT IN ('super8', 'plate', 'shield', 'spoon', 'bowl') THEN
    RAISE EXCEPTION 'Invalid prestige cup code';
  END IF;

  -- Qualify still uses legacy 'spoon'; draw/fixtures may use 'bowl' after rename
  IF v_code = 'bowl' THEN
    v_clubs := public.competition_qualify_cup_clubs(p_season_id, 'spoon');
    IF NOT EXISTS (
      SELECT 1
      FROM public.competition_cup_round_schedule s
      WHERE s.cup_code = 'bowl'
      LIMIT 1
    ) THEN
      v_code := 'spoon';
    END IF;
  ELSE
    v_clubs := public.competition_qualify_cup_clubs(p_season_id, v_code);
  END IF;

  IF coalesce(array_length(v_clubs, 1), 0) < 2 THEN
    RAISE EXCEPTION 'Not enough qualified clubs for % (% found)', v_code, coalesce(array_length(v_clubs, 1), 0);
  END IF;

  IF to_regprocedure('public.competition_cup_load_saved_byes(bigint, text)') IS NOT NULL THEN
    v_byes := public.competition_cup_load_saved_byes(p_season_id, v_code);
  END IF;

  v_result := public.competition_build_knockout_bracket(
    p_season_id,
    v_code,
    v_clubs,
    CASE WHEN coalesce(array_length(v_byes, 1), 0) > 0 THEN v_byes ELSE NULL END,
    p_player_order,
    p_bye_match_nos
  );

  IF to_regprocedure('public.competition_cup_sync_all_scheduled_cup_fixtures(bigint, text)') IS NOT NULL THEN
    v_sync := public.competition_cup_sync_all_scheduled_cup_fixtures(p_season_id, v_code);
    v_result := v_result || coalesce(v_sync, '{}'::jsonb);
  END IF;

  RETURN coalesce(v_result, '{}'::jsonb) || jsonb_build_object('cup_code', v_code);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_draw_prestige_cup(bigint, text, text[], int[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
