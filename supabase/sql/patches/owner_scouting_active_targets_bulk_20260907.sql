-- =============================================================================
-- Owner scouting: bulk active target replace for board/view switching
--
-- Sets the caller's active-target flags to exactly the supplied shortlist IDs.
-- Used by scouting.html when swapping "Show targets on" views.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.scouting_set_active_targets_bulk(
  p_player_ids text[] DEFAULT ARRAY[]::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_ids text[] := ARRAY(
    SELECT DISTINCT btrim(x)
    FROM unnest(coalesce(p_player_ids, ARRAY[]::text[])) AS x
    WHERE nullif(btrim(x), '') IS NOT NULL
  );
  v_updated int := 0;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  UPDATE public.owner_scouting_targets
  SET is_active_target = (player_id = ANY(v_ids))
  WHERE owner_id = v_owner;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'active_count', coalesce(array_length(v_ids, 1), 0),
    'updated_rows', v_updated
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.scouting_set_active_targets_bulk(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.scouting_set_active_targets_bulk(text[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
