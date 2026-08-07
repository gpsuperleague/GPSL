-- =============================================================================
-- Fix: new deals shortened / everyone looks like final year after tick
--
-- Bugs:
--   1) Staged order was FA → contested assign (remaining=3) → decrement.
--      Decrement then hit brand-new deals: 3→2 in the same rollover.
--      Correct order: FA unrenewed → decrement mid-deal → THEN contested assign
--      so Season_Signed = new season keeps remaining=3 for the upcoming year.
--   2) Repair: anyone still at a club with Season_Signed = newest preseason
--      label should be on a fresh 3-season deal (not 1 or 2).
--
-- Run in Supabase SQL Editor, then hard-refresh Squad.
-- Safe re-run.
-- =============================================================================

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
    'note', 'Staged tick in progress: FA done (decrement next, then contested).'
  );

  IF to_regprocedure('public.contract_tick_log_merge(bigint,text,jsonb)') IS NOT NULL THEN
    v_log := public.contract_tick_log_merge(
      v_ctx.ledger_season_id, v_ctx.ledger_season_label, v_step
    );
  END IF;

  RETURN coalesce(v_log, v_step);
END;
$function$;

-- Decrement mid-deal ONLY (never touch Season_Signed = new ledger season)
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
  v_skipped_new_deals int := 0;
  v_prev jsonb := '{}'::jsonb;
  v_step jsonb;
  v_log jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();

  SELECT coalesce(l.result, '{}'::jsonb)
  INTO v_prev
  FROM public.competition_contract_tick_log l
  WHERE l.for_season_id = v_ctx.ledger_season_id
  ORDER BY l.ticked_at DESC, l.id DESC
  LIMIT 1;

  -- Count fresh deals we must not decrement (if any already stamped)
  SELECT count(*)::int INTO v_skipped_new_deals
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining >= 2
    AND nullif(btrim(p."Season_Signed"), '') IS NOT DISTINCT FROM v_ctx.ledger_season_label;

  UPDATE public."Players" p
  SET contract_seasons_remaining = contract_seasons_remaining - 1
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining >= 2
    -- New-season deals (contested assign / renew stamped with ledger label) stay at 3
    AND (
      nullif(btrim(p."Season_Signed"), '') IS DISTINCT FROM v_ctx.ledger_season_label
    );

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  SELECT count(*)::int
  INTO v_final
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  v_step := jsonb_build_object(
    'ok', true,
    'step', 'decrement',
    'steps_done', coalesce(v_prev -> 'steps_done', '[]'::jsonb) || jsonb_build_array('decrement'),
    'bid_season_label', v_ctx.bid_season_label,
    'ledger_season_id', v_ctx.ledger_season_id,
    'ledger_season_label', v_ctx.ledger_season_label,
    'players_contract_ended_unsigned',
      coalesce((v_prev ->> 'players_contract_ended_unsigned')::int, 0),
    'players_released_zero_years',
      coalesce((v_prev ->> 'players_released_zero_years')::int, 0),
    'expiry_resolved', coalesce(v_prev -> 'expiry_resolved', '{}'::jsonb),
    'players_decremented', v_updated,
    'players_decrement_skipped_new_deals', v_skipped_new_deals,
    'players_final_year', v_final,
    'decrement', jsonb_build_object(
      'players_decremented', v_updated,
      'players_decrement_skipped_new_deals', v_skipped_new_deals,
      'players_final_year', v_final
    ),
    'fa', coalesce(v_prev -> 'fa', '{}'::jsonb),
    'note', 'Staged tick in progress: FA + decrement done (contested next).'
  );

  IF to_regprocedure('public.contract_tick_log_merge(bigint,text,jsonb)') IS NOT NULL THEN
    v_log := public.contract_tick_log_merge(
      v_ctx.ledger_season_id, v_ctx.ledger_season_label, v_step
    );
  END IF;

  RETURN coalesce(v_log, v_step);
END;
$function$;

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

  -- Leftover final-year still at clubs (no successful assign) → FA
  UPDATE public."Players" p
  SET contract_seasons_remaining = 0
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  v_released := public.contract_release_zero_year_players(v_ctx.ledger_season_id);

  v_step := jsonb_build_object(
    'ok', true,
    'step', 'complete',
    'steps_done', jsonb_build_array('fa', 'decrement', 'contested'),
    'bid_season_label', v_ctx.bid_season_label,
    'ledger_season_id', v_ctx.ledger_season_id,
    'ledger_season_label', v_ctx.ledger_season_label,
    'expiry_resolved', v_resolve,
    'players_released_leftover', v_released,
    'players_released_zero_years', v_prev_fa + v_released,
    'players_contested_resolved',
      coalesce((v_resolve ->> 'players_resolved')::int, 0),
    'contested', jsonb_build_object(
      'expiry_resolved', v_resolve,
      'players_released_leftover', v_released
    ),
    'note', 'Staged tick complete: FA → decrement → contested (new deals keep 3 seasons).'
  );

  IF to_regprocedure('public.contract_tick_log_merge(bigint,text,jsonb)') IS NOT NULL THEN
    v_log := public.contract_tick_log_merge(
      v_ctx.ledger_season_id, v_ctx.ledger_season_label, v_step
    );
  END IF;

  RETURN coalesce(v_log, v_step);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_tick_rollover_step_fa() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_tick_rollover_step_decrement() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_tick_rollover_step_contested() TO authenticated;

-- ---------------------------------------------------------------------------
-- Repair: fresh season-4 deals stamped Season_Signed = ledger label → 3 years
-- ---------------------------------------------------------------------------
DO $repair$
DECLARE
  v_label text;
  v_fixed int;
BEGIN
  SELECT btrim(s.label) INTO v_label
  FROM public.competition_seasons s
  WHERE s.status IN ('preseason', 'setup')
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_label IS NULL THEN
    RAISE NOTICE 'No preseason/setup season — skip deal repair';
    RETURN;
  END IF;

  UPDATE public."Players" p
  SET contract_seasons_remaining = 3
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND nullif(btrim(p."Season_Signed"), '') IS NOT DISTINCT FROM v_label
    AND coalesce(p.contract_seasons_remaining, 0) <> 3;

  GET DIAGNOSTICS v_fixed = ROW_COUNT;

  RAISE NOTICE 'Repaired % player(s) to 3 seasons (Season_Signed = %)', v_fixed, v_label;
END;
$repair$;

NOTIFY pgrst, 'reload schema';

-- Show sample of repaired / new-season deals
SELECT
  p."Name",
  p."Contracted_Team",
  p."Season_Signed",
  p.contract_seasons_remaining,
  p.contract_wage
FROM public."Players" p
WHERE nullif(btrim(p."Season_Signed"), '') = (
  SELECT btrim(s.label)
  FROM public.competition_seasons s
  WHERE s.status IN ('preseason', 'setup')
  ORDER BY s.id DESC
  LIMIT 1
)
AND public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
ORDER BY p."Contracted_Team", p."Name"
LIMIT 50;
