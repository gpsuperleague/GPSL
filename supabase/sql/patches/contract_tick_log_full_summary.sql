-- =============================================================================
-- Staged tick log: merge FA + contested + decrement into one summary
--
-- Before: only the decrement step wrote competition_contract_tick_log, so the
-- log looked like "91 final-year / 127 decremented" with no FA/contested counts.
--
-- After: each step merges into the same log row for the ledger season.
-- Final result includes players_released_zero_years, expiry_resolved, etc.
--
-- Also backfills season 4 (id 21) from Transfer_History + existing decrement log.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.contract_tick_log_merge(
  p_season_id bigint,
  p_season_label text,
  p_patch jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_result jsonb;
BEGIN
  IF p_season_id IS NULL THEN
    RAISE EXCEPTION 'contract_tick_log_merge: season_id required';
  END IF;

  SELECT l.id, l.result
  INTO v_id, v_result
  FROM public.competition_contract_tick_log l
  WHERE l.for_season_id = p_season_id
  ORDER BY l.ticked_at DESC, l.id DESC
  LIMIT 1;

  IF v_id IS NULL THEN
    v_result := coalesce(p_patch, '{}'::jsonb);
    INSERT INTO public.competition_contract_tick_log (
      for_season_id, for_season_label, result
    )
    VALUES (
      p_season_id,
      coalesce(nullif(btrim(p_season_label), ''), p_season_id::text),
      v_result
    )
    RETURNING result INTO v_result;
  ELSE
    v_result := coalesce(v_result, '{}'::jsonb) || coalesce(p_patch, '{}'::jsonb);
    UPDATE public.competition_contract_tick_log l
    SET
      result = v_result,
      for_season_label = coalesce(
        nullif(btrim(p_season_label), ''),
        l.for_season_label
      ),
      ticked_at = now()
    WHERE l.id = v_id;
  END IF;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_tick_log_merge(bigint, text, jsonb)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Step 1: FA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_tick_rollover_step_fa()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ctx record;
  v_ended int;
  v_released int;
  v_step jsonb;
  v_log jsonb;
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

  v_step := jsonb_build_object(
    'ok', true,
    'step', 'fa',
    'steps_done', jsonb_build_array('fa'),
    'bid_season_label', v_ctx.bid_season_label,
    'ledger_season_id', v_ctx.ledger_season_id,
    'ledger_season_label', v_ctx.ledger_season_label,
    'players_contract_ended_unsigned', v_ended,
    'players_released_zero_years', v_released,
    'fa', jsonb_build_object(
      'players_contract_ended_unsigned', v_ended,
      'players_released_zero_years', v_released
    ),
    'note', 'Staged tick in progress: FA done.'
  );

  v_log := public.contract_tick_log_merge(
    v_ctx.ledger_season_id,
    v_ctx.ledger_season_label,
    v_step
  );

  RETURN coalesce(v_log, v_step);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Step 2: contested
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_tick_rollover_step_contested()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ctx record;
  v_resolve jsonb;
  v_released int;
  v_prev_fa int := 0;
  v_step jsonb;
  v_log jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '300s', true);

  SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();

  SELECT coalesce((l.result ->> 'players_released_zero_years')::int, 0)
  INTO v_prev_fa
  FROM public.competition_contract_tick_log l
  WHERE l.for_season_id = v_ctx.ledger_season_id
  ORDER BY l.ticked_at DESC, l.id DESC
  LIMIT 1;

  v_resolve := public.contract_resolve_all_expiry_bids(
    v_ctx.ledger_season_id,
    v_ctx.bid_season_label
  );

  UPDATE public."Players" p
  SET contract_seasons_remaining = 0
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  v_released := public.contract_release_zero_year_players(v_ctx.ledger_season_id);

  v_step := jsonb_build_object(
    'ok', true,
    'step', 'contested',
    'steps_done', jsonb_build_array('fa', 'contested'),
    'bid_season_label', v_ctx.bid_season_label,
    'ledger_season_id', v_ctx.ledger_season_id,
    'ledger_season_label', v_ctx.ledger_season_label,
    'expiry_resolved', v_resolve,
    'players_released_leftover', v_released,
    'players_released_zero_years', v_prev_fa + v_released,
    'contested', jsonb_build_object(
      'expiry_resolved', v_resolve,
      'players_released_leftover', v_released
    ),
    'note', 'Staged tick in progress: FA + contested done.'
  );

  v_log := public.contract_tick_log_merge(
    v_ctx.ledger_season_id,
    v_ctx.ledger_season_label,
    v_step
  );

  RETURN coalesce(v_log, v_step);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Step 3: decrement + complete summary
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_tick_rollover_step_decrement()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ctx record;
  v_updated int;
  v_final int;
  v_open_bids int;
  v_prev jsonb := '{}'::jsonb;
  v_step jsonb;
  v_log jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();

  SELECT count(*)::int INTO v_open_bids
  FROM public.contract_expiry_wage_bids b
  WHERE b.season_label = v_ctx.bid_season_label
     OR b.season_label IS NOT DISTINCT FROM v_ctx.bid_season_label;

  IF v_open_bids > 0 THEN
    RAISE EXCEPTION
      'Still % open expiry wage bid(s) for %. Run contract_tick_rollover_step_contested() first.',
      v_open_bids, v_ctx.bid_season_label;
  END IF;

  SELECT coalesce(l.result, '{}'::jsonb)
  INTO v_prev
  FROM public.competition_contract_tick_log l
  WHERE l.for_season_id = v_ctx.ledger_season_id
  ORDER BY l.ticked_at DESC, l.id DESC
  LIMIT 1;

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

  v_step := jsonb_build_object(
    'ok', true,
    'step', 'complete',
    'steps_done', jsonb_build_array('fa', 'contested', 'decrement'),
    'bid_season_label', v_ctx.bid_season_label,
    'ledger_season_id', v_ctx.ledger_season_id,
    'ledger_season_label', v_ctx.ledger_season_label,
    'players_contract_ended_unsigned',
      coalesce((v_prev ->> 'players_contract_ended_unsigned')::int, 0),
    'players_released_zero_years',
      coalesce((v_prev ->> 'players_released_zero_years')::int, 0),
    'players_released_leftover',
      coalesce((v_prev ->> 'players_released_leftover')::int, 0),
    'expiry_resolved', coalesce(v_prev -> 'expiry_resolved', '{}'::jsonb),
    'players_contested_resolved',
      coalesce((v_prev #>> '{expiry_resolved,players_resolved}')::int, 0),
    'players_decremented', v_updated,
    'players_final_year', v_final,
    'decrement', jsonb_build_object(
      'players_decremented', v_updated,
      'players_final_year', v_final
    ),
    'fa', coalesce(v_prev -> 'fa', '{}'::jsonb),
    'contested', coalesce(v_prev -> 'contested', '{}'::jsonb),
    'note', 'Staged tick complete: FA → contested → decrement.'
  );

  v_log := public.contract_tick_log_merge(
    v_ctx.ledger_season_id,
    v_ctx.ledger_season_label,
    v_step
  );

  RETURN coalesce(v_log, v_step);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_tick_rollover_step_fa() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_tick_rollover_step_contested() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_tick_rollover_step_decrement() TO authenticated;

-- ---------------------------------------------------------------------------
-- Backfill season 4 (id 21) summary from history + existing decrement log
-- ---------------------------------------------------------------------------
DO $backfill$
DECLARE
  v_fa int := 0;
  v_club int := 0;
  v_id bigint;
  v_result jsonb;
BEGIN
  SELECT count(*)::int INTO v_fa
  FROM public."Transfer_History" th
  WHERE th.transfer_sale_note = 'contract_expiry'
    AND th.transfer_time > timestamptz '2026-08-06'
    AND (
      th.buyer_club_id = 'FOREIGN'
      OR th.foreign_buyer_name IS NOT NULL
    );

  SELECT count(*)::int INTO v_club
  FROM public."Transfer_History" th
  WHERE th.transfer_sale_note = 'contract_expiry'
    AND th.transfer_time > timestamptz '2026-08-06'
    AND th.buyer_club_id IS DISTINCT FROM 'FOREIGN'
    AND th.foreign_buyer_name IS NULL;

  SELECT l.id, l.result
  INTO v_id, v_result
  FROM public.competition_contract_tick_log l
  WHERE l.for_season_id = 21
  ORDER BY l.ticked_at DESC, l.id DESC
  LIMIT 1;

  IF v_id IS NULL THEN
    RAISE NOTICE 'No tick log for season 21 — skip backfill';
    RETURN;
  END IF;

  UPDATE public.competition_contract_tick_log l
  SET result = coalesce(l.result, '{}'::jsonb) || jsonb_build_object(
    'ok', true,
    'step', 'complete',
    'steps_done', jsonb_build_array('fa', 'contested', 'decrement'),
    'players_released_zero_years', v_fa,
    'players_contested_resolved', v_club,
    'expiry_resolved', jsonb_build_object(
      'ok', true,
      'players_resolved', v_club,
      'note', 'Backfilled from Transfer_History (club-to-club expiry rows)'
    ),
    'fa', jsonb_build_object(
      'players_released_zero_years', v_fa,
      'note', 'Backfilled from Transfer_History FA/FOREIGN expiry rows since 2026-08-06'
    ),
    'contested', jsonb_build_object(
      'players_resolved', v_club,
      'note', 'Backfilled from Transfer_History club-to-club expiry rows'
    ),
    'note', 'Staged tick complete (summary backfilled): FA → contested → decrement.',
    'backfilled_at', now()
  )
  WHERE l.id = v_id;

  RAISE NOTICE 'Backfilled season 21 tick log: FA=% contested_club_moves=%', v_fa, v_club;
END;
$backfill$;

NOTIFY pgrst, 'reload schema';

-- Show updated log
SELECT for_season_label, ticked_at, result
FROM public.competition_contract_tick_log
WHERE for_season_id = 21
ORDER BY ticked_at DESC
LIMIT 1;
