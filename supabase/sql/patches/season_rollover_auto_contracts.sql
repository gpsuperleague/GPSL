-- =============================================================================
-- Auto contract rollover for live seasons
--
-- Intent:
--   • End Season → process MANAGER contracts automatically (while season still
--     current), then summer-break.
--   • Create Pre-Season → create row + PLAYER contract tick + manager catch-up
--     if End Season was skipped.
--
-- Run AFTER: create_season_timeout_split_tick.sql
--            season_contract_tick_catchup.sql  (recommended)
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) End season: managers first, then summer break
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_end_season()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
  v_next bigint;
  v_mgr jsonb := NULL;
  v_mgr_existing int := 0;
  v_end_key text :=
    'end_of_season||End current season {summer break}|admin_season.html|wf-close-season';
  v_mgr_key text :=
    'end_of_season||Process manager contracts (season end)|admin_season.html|wf-close-season';
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    SELECT * INTO v_season
    FROM public.competition_seasons
    WHERE status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active current season to end';
  END IF;

  -- Managers MUST run while this season is still current
  SELECT count(*)::int INTO v_mgr_existing
  FROM public.manager_deal_season_results r
  WHERE r.season_id = v_season.id;

  IF v_mgr_existing = 0 THEN
    IF to_regprocedure('public.manager_process_season_end_with_inbox()') IS NOT NULL THEN
      v_mgr := public.manager_process_season_end_with_inbox();
    ELSIF to_regprocedure('public.manager_process_season_end()') IS NOT NULL THEN
      v_mgr := public.manager_process_season_end();
    ELSE
      RAISE EXCEPTION
        'Manager season-end RPC missing — run manager_two_season_deal_eval.sql before ending the season';
    END IF;

    IF to_regprocedure('public.admin_workflow_checklist_set(bigint,text,boolean,text)') IS NOT NULL THEN
      PERFORM public.admin_workflow_checklist_set(
        v_season.id, v_mgr_key, true, 'Auto-run by competition_end_season'
      );
    END IF;
  ELSE
    v_mgr := jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'already_processed',
      'existing_results', v_mgr_existing
    );
  END IF;

  UPDATE public.competition_seasons
  SET
    status = 'complete',
    is_current = false,
    ended_at = coalesce(ended_at, now())
  WHERE id = v_season.id;

  UPDATE public.competition_seasons
  SET is_current = false
  WHERE is_current = true
    AND id <> v_season.id;

  UPDATE public.global_settings
  SET league_phase = 'summer_break', updated_at = now()
  WHERE id = 1;

  IF to_regprocedure('public.admin_workflow_checklist_set(bigint,text,boolean,text)') IS NOT NULL THEN
    PERFORM public.admin_workflow_checklist_set(
      v_season.id, v_end_key, true, 'Auto-ticked by competition_end_season'
    );
  END IF;

  SELECT s.id INTO v_next
  FROM public.competition_seasons s
  WHERE s.status IN ('preseason', 'setup')
    AND s.id > v_season.id
  ORDER BY
    CASE s.status WHEN 'preseason' THEN 0 WHEN 'setup' THEN 1 ELSE 2 END,
    s.id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'season_id', v_season.id,
    'label', v_season.label,
    'league_phase', 'summer_break',
    'next_season_id', v_next,
    'manager_season_end', v_mgr,
    'checklist_note',
      CASE
        WHEN v_next IS NOT NULL THEN
          'Managers processed (or already done). Checklist should follow next preseason/setup.'
        ELSE
          'Managers processed (or already done). Create Pre-Season next.'
      END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_end_season() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) Create Pre-Season + player tick + manager safety-net (one admin RPC)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_create_season_full(p_label text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_tick jsonb;
  v_mgr jsonb := NULL;
  v_prev_complete bigint;
  v_mgr_existing int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  v_season_id := public.competition_create_season(p_label);

  -- Player contracts for N → N+1 (never double-tick)
  IF to_regprocedure('public.admin_catchup_player_contract_tick(boolean)') IS NOT NULL THEN
    v_tick := public.admin_catchup_player_contract_tick(false);
    IF coalesce((v_tick->>'ok')::boolean, false) IS NOT TRUE THEN
      IF coalesce(v_tick->>'reason', '') = 'already_ticked' THEN
        SELECT l.result INTO v_tick
        FROM public.competition_contract_tick_log l
        WHERE l.for_season_id = v_season_id
        ORDER BY l.ticked_at DESC
        LIMIT 1;
        v_tick := coalesce(v_tick, jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_ticked'));
      ELSE
        RAISE EXCEPTION
          'Player contract tick failed after create: %',
          coalesce(v_tick->>'reason', v_tick::text);
      END IF;
    END IF;
  ELSE
    v_tick := public.contract_tick_season_rollover();
  END IF;

  -- Safety net: if End Season never processed managers for last complete year
  SELECT s.id INTO v_prev_complete
  FROM public.competition_seasons s
  WHERE s.status = 'complete'
    AND s.id < v_season_id
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_prev_complete IS NOT NULL THEN
    SELECT count(*)::int INTO v_mgr_existing
    FROM public.manager_deal_season_results r
    WHERE r.season_id = v_prev_complete;

    IF v_mgr_existing = 0 THEN
      IF to_regprocedure('public.admin_catchup_manager_season_end(bigint,boolean)') IS NOT NULL THEN
        v_mgr := public.admin_catchup_manager_season_end(v_prev_complete, false);
      ELSE
        v_mgr := jsonb_build_object(
          'ok', false,
          'reason', 'catchup_rpc_missing',
          'hint', 'Run season_contract_tick_catchup.sql'
        );
      END IF;
    ELSE
      v_mgr := jsonb_build_object(
        'ok', true,
        'skipped', true,
        'reason', 'already_processed',
        'season_id', v_prev_complete,
        'existing_results', v_mgr_existing
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'player_tick', CASE
      WHEN v_tick ? 'tick' THEN v_tick->'tick'
      ELSE v_tick
    END,
    'manager_catchup', v_mgr,
    'note', 'Pre-season created; player contracts ticked; managers caught up if End Season skipped them.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_create_season_full(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
