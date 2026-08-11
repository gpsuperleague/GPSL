-- =============================================================================
-- Owner scouting: Active Targets flag (budget shortlist on scouting board)
-- Run after owner_scouting_persist.sql. Safe re-run.
-- =============================================================================

ALTER TABLE public.owner_scouting_targets
  ADD COLUMN IF NOT EXISTS is_active_target boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.owner_scouting_targets.is_active_target IS
  'Owner-marked active draft budget target; highlighted on scouting board.';

CREATE OR REPLACE FUNCTION public.scouting_set_active_target(
  p_player_id text,
  p_active boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_pid text;
  v_active boolean;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_pid := btrim(p_player_id);
  IF v_pid IS NULL OR v_pid = '' THEN
    RAISE EXCEPTION 'Player id is required';
  END IF;

  v_active := coalesce(p_active, false);

  UPDATE public.owner_scouting_targets
  SET is_active_target = v_active
  WHERE owner_id = v_owner AND player_id = v_pid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player is not on your scouting list';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'is_active_target', v_active
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.scouting_set_active_target(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.scouting_set_active_target(text, boolean) TO authenticated;
