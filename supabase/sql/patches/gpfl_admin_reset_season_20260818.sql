-- =============================================================================
-- GPFL — admin reset for the current fantasy season (testing / restart).
-- Wipes entries, squads, transfers and month scores. Keeps the season row
-- and player prices so the pool stays open.
-- Play-money only. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_gpfl_reset_season(
  p_gpfl_season_id bigint DEFAULT NULL,
  p_confirm text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := p_gpfl_season_id;
  v_entries int := 0;
  v_squad int := 0;
  v_xfer int := 0;
  v_months int := 0;
  v_pfp int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF lower(btrim(coalesce(p_confirm, ''))) <> 'reset gpfl' THEN
    RAISE EXCEPTION 'Confirm by passing p_confirm := ''RESET GPFL''';
  END IF;

  IF v_gs_id IS NULL THEN
    v_gs_id := public.gpfl_current_season_id();
  END IF;
  IF v_gs_id IS NULL THEN
    RAISE EXCEPTION 'No GPFL season to reset';
  END IF;

  DELETE FROM public.gpfl_player_fixture_points
  WHERE gpfl_season_id = v_gs_id;
  GET DIAGNOSTICS v_pfp = ROW_COUNT;

  DELETE FROM public.gpfl_entry_month_points mp
  USING public.gpfl_entries e
  WHERE mp.entry_id = e.id
    AND e.gpfl_season_id = v_gs_id;
  GET DIAGNOSTICS v_months = ROW_COUNT;

  DELETE FROM public.gpfl_transfers
  WHERE gpfl_season_id = v_gs_id;
  GET DIAGNOSTICS v_xfer = ROW_COUNT;

  DELETE FROM public.gpfl_squad_players sp
  USING public.gpfl_entries e
  WHERE sp.entry_id = e.id
    AND e.gpfl_season_id = v_gs_id;
  GET DIAGNOSTICS v_squad = ROW_COUNT;

  DELETE FROM public.gpfl_entries
  WHERE gpfl_season_id = v_gs_id;
  GET DIAGNOSTICS v_entries = ROW_COUNT;

  UPDATE public.gpfl_seasons
  SET status = 'open'
  WHERE id = v_gs_id;

  RETURN jsonb_build_object(
    'ok', true,
    'gpfl_season_id', v_gs_id,
    'entries_deleted', v_entries,
    'squad_rows_deleted', v_squad,
    'transfers_deleted', v_xfer,
    'month_rows_deleted', v_months,
    'fixture_points_deleted', v_pfp,
    'note', 'Season + prices kept. Owners must join again.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_gpfl_reset_season(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
