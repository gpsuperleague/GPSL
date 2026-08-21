-- =============================================================================
-- Scouting tactic board: 17 bench slots (12 subs + 5 squad fillers)
-- Pitch 11 + bench 17 = 28 planning squad. Match Day stays 11 + 12.
-- Safe re-run. Replaces prior max-16 check.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_save_scouting_planner(
  p_slots jsonb,
  p_pitch_layout jsonb DEFAULT NULL,
  p_board_no smallint DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_board smallint := coalesce(p_board_no, 1)::smallint;
  v_slot jsonb;
  v_pid text;
  v_kind text;
  v_pitch text;
  v_order smallint;
  v_pitch_count int := 0;
  v_bench_count int := 0;
  v_mirror_err text;
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

  IF p_pitch_layout IS NOT NULL
     AND to_regprocedure('public.validate_pitch_layout_mirroring(jsonb)') IS NOT NULL THEN
    v_mirror_err := public.validate_pitch_layout_mirroring(p_pitch_layout);
    IF v_mirror_err IS NOT NULL THEN
      RAISE EXCEPTION '%', v_mirror_err;
    END IF;
  END IF;

  IF jsonb_typeof(p_slots) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'p_slots must be a JSON array';
  END IF;

  FOR v_slot IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    v_pid := btrim(v_slot->>'player_id');
    v_kind := lower(btrim(v_slot->>'slot_kind'));
    v_pitch := nullif(btrim(v_slot->>'pitch_slot'), '');
    v_order := coalesce((v_slot->>'sort_order')::smallint, 0);

    IF v_pid IS NULL OR v_pid = '' THEN
      CONTINUE;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.owner_scouting_targets t
      WHERE t.owner_id = v_owner AND t.player_id = v_pid
    ) THEN
      RAISE EXCEPTION 'Player % is not on your scouting list', v_pid;
    END IF;

    IF v_kind = 'pitch' THEN
      v_pitch_count := v_pitch_count + 1;
      IF v_pitch IS NULL THEN
        RAISE EXCEPTION 'Pitch slot required for player %', v_pid;
      END IF;
    ELSIF v_kind = 'bench' THEN
      v_bench_count := v_bench_count + 1;
    ELSE
      RAISE EXCEPTION 'Invalid slot_kind %', v_kind;
    END IF;
  END LOOP;

  IF v_pitch_count > 11 THEN
    RAISE EXCEPTION 'Maximum 11 on pitch';
  END IF;
  IF v_bench_count > 17 THEN
    RAISE EXCEPTION 'Maximum 17 on bench (12 subs + 5 squad)';
  END IF;

  INSERT INTO public.owner_scouting_planner (
    owner_id, board_no, name, pitch_layout, updated_at
  )
  VALUES (
    v_owner,
    v_board,
    'Board ' || v_board::text,
    coalesce(p_pitch_layout, '{}'::jsonb),
    now()
  )
  ON CONFLICT (owner_id, board_no) DO UPDATE
  SET pitch_layout = coalesce(
        p_pitch_layout,
        owner_scouting_planner.pitch_layout
      ),
      updated_at = now();

  DELETE FROM public.owner_scouting_planner_player
  WHERE owner_id = v_owner
    AND board_no = v_board;

  FOR v_slot IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    v_pid := btrim(v_slot->>'player_id');
    v_kind := lower(btrim(v_slot->>'slot_kind'));
    v_pitch := nullif(btrim(v_slot->>'pitch_slot'), '');
    v_order := coalesce((v_slot->>'sort_order')::smallint, 0);

    IF v_pid IS NULL OR v_pid = '' THEN
      CONTINUE;
    END IF;

    INSERT INTO public.owner_scouting_planner_player (
      owner_id, board_no, player_id, slot_kind, pitch_slot, sort_order
    )
    VALUES (v_owner, v_board, v_pid, v_kind, v_pitch, v_order);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', v_owner,
    'board_no', v_board,
    'pitch_count', v_pitch_count,
    'bench_count', v_bench_count
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_save_scouting_planner(jsonb, jsonb, smallint) TO authenticated;

NOTIFY pgrst, 'reload schema';
