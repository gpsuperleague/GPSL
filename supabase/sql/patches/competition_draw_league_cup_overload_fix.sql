-- Fix ambiguous competition_draw_league_cup overloads.
--
-- Error: Could not choose the best candidate function between
--   competition_draw_league_cup(p_season_id => bigint, p_byes => smallint)
--   competition_draw_league_cup(p_season_id => bigint, p_player_order => text[], p_bye_match_nos => integer[])
--
-- Keep a single 3-arg version (optional player order / bye slots).
-- Safe re-run.

DROP FUNCTION IF EXISTS public.competition_draw_league_cup(bigint);
DROP FUNCTION IF EXISTS public.competition_draw_league_cup(bigint, smallint);
DROP FUNCTION IF EXISTS public.competition_draw_league_cup(bigint, text[]);
DROP FUNCTION IF EXISTS public.competition_draw_league_cup(bigint, text[], int[]);

CREATE OR REPLACE FUNCTION public.competition_draw_league_cup(
  p_season_id bigint,
  p_player_order text[] DEFAULT NULL,
  p_bye_match_nos int[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_clubs text[];
  v_byes text[];
  v_result jsonb;
  v_sync jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_clubs := public.competition_qualify_cup_clubs(p_season_id, 'league_cup');

  IF coalesce(array_length(v_clubs, 1), 0) < 8 THEN
    RAISE EXCEPTION 'Need at least 8 clubs in season for league cup';
  END IF;

  IF to_regprocedure('public.competition_cup_load_saved_byes(bigint, text)') IS NOT NULL THEN
    v_byes := public.competition_cup_load_saved_byes(p_season_id, 'league_cup');
  END IF;

  IF to_regprocedure(
    'public.competition_build_knockout_bracket(bigint, text, text[], text[], text[], int[])'
  ) IS NOT NULL THEN
    v_result := public.competition_build_knockout_bracket(
      p_season_id,
      'league_cup',
      v_clubs,
      CASE WHEN coalesce(array_length(v_byes, 1), 0) > 0 THEN v_byes ELSE NULL END,
      p_player_order,
      p_bye_match_nos
    );
  ELSIF to_regprocedure(
    'public.competition_build_knockout_bracket(bigint, text, text[], text[], text[])'
  ) IS NOT NULL THEN
    v_result := public.competition_build_knockout_bracket(
      p_season_id,
      'league_cup',
      v_clubs,
      CASE WHEN coalesce(array_length(v_byes, 1), 0) > 0 THEN v_byes ELSE NULL END,
      p_player_order
    );
  ELSE
    v_clubs := public.competition_shuffle_club_array(v_clubs);
    v_result := public.competition_build_knockout_bracket(
      p_season_id,
      'league_cup',
      v_clubs,
      CASE WHEN coalesce(array_length(v_byes, 1), 0) > 0 THEN v_byes ELSE NULL END
    );
  END IF;

  IF to_regprocedure('public.competition_cup_sync_all_scheduled_cup_fixtures(bigint, text)') IS NOT NULL THEN
    v_sync := public.competition_cup_sync_all_scheduled_cup_fixtures(p_season_id, 'league_cup');
    v_result := coalesce(v_result, '{}'::jsonb) || coalesce(v_sync, '{}'::jsonb);
  END IF;

  RETURN coalesce(v_result, '{}'::jsonb) || jsonb_build_object('cup_code', 'league_cup');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_draw_league_cup(bigint, text[], int[])
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
