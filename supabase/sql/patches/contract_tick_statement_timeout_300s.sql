-- =============================================================================
-- Raise contract tick statement_timeout to 5 minutes
--
-- Symptom: canceling statement due to statement timeout on
--   competition_create_season_full / admin_catchup_player_contract_tick /
--   contract_tick_season_rollover (large FA + contested expiry market).
--
-- Admin UI now splits create vs tick into separate RPCs. This patch still
-- raises the tick budget for SQL Editor / catch-up.
--
-- Run in Supabase SQL Editor, then:
--   SELECT public.competition_create_season('Your Label');  -- if not created
--   SELECT public.admin_catchup_player_contract_tick(false);
-- Safe re-run (only replaces timeout lines inside these wrappers).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_catchup_player_contract_tick(
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_newest record;
  v_out jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.id, s.label, s.status INTO v_newest
  FROM public.competition_seasons s
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_newest.id IS NULL THEN
    RAISE EXCEPTION 'No competition seasons found';
  END IF;

  IF v_newest.status NOT IN ('preseason', 'setup') THEN
    RAISE EXCEPTION
      'Newest season "%" (%) is not preseason/setup. Create the next pre-season first so expiry money posts there.',
      v_newest.label, v_newest.status;
  END IF;

  IF NOT coalesce(p_force, false)
     AND EXISTS (
       SELECT 1 FROM public.competition_contract_tick_log l
       WHERE l.for_season_id = v_newest.id
     )
  THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'already_ticked',
      'for_season_id', v_newest.id,
      'for_season_label', v_newest.label,
      'hint', 'A player contract tick is already logged for this season. Pass p_force := true only if you are sure it never applied.'
    );
  END IF;

  PERFORM set_config('statement_timeout', '300s', true);

  v_out := public.contract_tick_season_rollover();

  IF coalesce(p_force, false) THEN
    INSERT INTO public.competition_contract_tick_log (for_season_id, for_season_label, result)
    VALUES (v_newest.id, v_newest.label, coalesce(v_out, '{}'::jsonb));
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'for_season_id', v_newest.id,
    'for_season_label', v_newest.label,
    'tick', v_out
  );
END;
$function$;

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

  -- Prefer Admin UI split create → tick; this path is for SQL Editor one-shot
  PERFORM set_config('statement_timeout', '300s', true);

  v_season_id := public.competition_create_season(p_label);

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

CREATE OR REPLACE FUNCTION public.contract_tick_season_rollover()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_resolve jsonb;
  v_updated int;
  v_ended   int;
  v_final   int;
  v_released int;
  v_out jsonb;
  v_ctx record;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '300s', true);

  SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();

  UPDATE public."Players" p
  SET contract_seasons_remaining = 0
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1
    AND NOT EXISTS (
      SELECT 1
      FROM public.contract_expiry_wage_bids b
      WHERE b.player_id = p."Konami_ID"::text
        AND (
          b.season_label = v_ctx.bid_season_label
          OR b.season_label IS NOT DISTINCT FROM v_ctx.bid_season_label
        )
    );

  GET DIAGNOSTICS v_ended = ROW_COUNT;

  v_released := public.contract_release_zero_year_players(v_ctx.ledger_season_id);

  v_resolve := public.contract_resolve_all_expiry_bids(
    v_ctx.ledger_season_id,
    v_ctx.bid_season_label
  );

  UPDATE public."Players" p
  SET contract_seasons_remaining = 0
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  v_released := v_released
    + public.contract_release_zero_year_players(v_ctx.ledger_season_id);

  UPDATE public."Players" p
  SET contract_seasons_remaining = contract_seasons_remaining - 1
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining >= 2;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  SELECT count(*)::int
  INTO v_final
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  v_out := jsonb_build_object(
    'ok', true,
    'bid_season_label', v_ctx.bid_season_label,
    'ledger_season_id', v_ctx.ledger_season_id,
    'ledger_season_label', v_ctx.ledger_season_label,
    'expiry_resolved', v_resolve,
    'players_contract_ended_unsigned', v_ended,
    'players_released_zero_years', v_released,
    'players_decremented', v_updated,
    'players_final_year', v_final,
    'note', 'FA unrenewed first (MV), then contested bid assigns, then multi-year decrement. Money on new preseason.'
  );

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_contract_tick_log l
    WHERE l.for_season_id = v_ctx.ledger_season_id
  ) THEN
    INSERT INTO public.competition_contract_tick_log (for_season_id, for_season_label, result)
    VALUES (v_ctx.ledger_season_id, v_ctx.ledger_season_label, v_out);
  END IF;

  RETURN v_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_catchup_player_contract_tick(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_create_season_full(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_tick_season_rollover() TO authenticated;

NOTIFY pgrst, 'reload schema';
