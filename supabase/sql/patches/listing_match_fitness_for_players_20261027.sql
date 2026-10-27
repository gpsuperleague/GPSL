-- =============================================================================
-- Transfer market: match fitness map by player id(s)
-- Safe re-run. Requires competition_player_match_fitness + label helper.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_match_fitness_for_players(
  p_player_ids text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_to_max int := 4;
  v_by jsonb := '{}'::jsonb;
BEGIN
  IF p_player_ids IS NULL OR coalesce(array_length(p_player_ids, 1), 0) = 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'matches_to_max', v_to_max,
      'by_player', '{}'::jsonb
    );
  END IF;

  BEGIN
    v_to_max := greatest(
      coalesce((public.competition_injury_settings_row()).fitness_matches_to_max, 4),
      1
    );
  EXCEPTION WHEN OTHERS THEN
    v_to_max := 4;
  END;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'matches_to_max', v_to_max,
      'by_player', '{}'::jsonb
    );
  END IF;

  SELECT coalesce(jsonb_object_agg(y.player_id, y.payload), '{}'::jsonb)
  INTO v_by
  FROM (
    SELECT DISTINCT ON (f.player_id)
      f.player_id,
      jsonb_build_object(
        'level', f.fitness_level,
        'label', public.competition_match_fitness_label(f.fitness_level),
        'consecutive', f.consecutive_appearances
      ) AS payload
    FROM public.competition_player_match_fitness f
    WHERE f.season_id = v_season
      AND f.player_id = ANY (p_player_ids)
    ORDER BY f.player_id, f.updated_at DESC NULLS LAST, f.id DESC
  ) y;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'matches_to_max', v_to_max,
    'by_player', coalesce(v_by, '{}'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_match_fitness_for_players(text[])
  TO authenticated;

NOTIFY pgrst, 'reload schema';
