-- =============================================================================
-- Owner scouting boards: save board metadata without touching player rows
--
-- Used for per-board target-view memory (active targets, plan nation) so these
-- updates cannot overwrite the planner lineup rows.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.scouting_set_board_meta(
  p_board_no smallint,
  p_pitch_layout jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_board smallint := coalesce(p_board_no, 1)::smallint;
  v_name text;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_board < 1 OR v_board > 4 THEN
    RAISE EXCEPTION 'Board must be 1–4';
  END IF;

  IF to_regprocedure('public.scouting_ensure_boards()') IS NOT NULL THEN
    PERFORM public.scouting_ensure_boards();
  END IF;

  SELECT name
  INTO v_name
  FROM public.owner_scouting_planner
  WHERE owner_id = v_owner
    AND board_no = v_board;

  INSERT INTO public.owner_scouting_planner (
    owner_id, board_no, name, pitch_layout, updated_at
  )
  VALUES (
    v_owner,
    v_board,
    coalesce(v_name, 'Board ' || v_board::text),
    coalesce(p_pitch_layout, '{}'::jsonb),
    now()
  )
  ON CONFLICT (owner_id, board_no) DO UPDATE
  SET pitch_layout = coalesce(p_pitch_layout, '{}'::jsonb),
      updated_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'board_no', v_board
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.scouting_set_board_meta(smallint, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
