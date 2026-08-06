-- =============================================================================
-- Contract tick order: FA unrenewed first, then contested expiry bids
--
-- Why: assigning bid winners before releasing unsigned final-year players
-- caused avoidable squad overflow (paid-up / foreign locks) during Create
-- Pre-Season, when clubs were about to free slots via FA releases.
--
-- New order:
--   1) Final-year with NO expiry wage bids → remaining=0 → FA + MV
--   2) Contested players (open bids) → resolve / assign
--   3) Safety FA for any leftover remaining=1
--   4) Multi-year contracts decrement
--
-- Requires: contract_expiry_rollover_new_season_ledger.sql (+ foreign lock
--   preseason fallback / assign overload fixes if you hit those earlier).
--
-- Run in Supabase SQL Editor BEFORE Create Pre-Season / Tick catch-up.
-- Safe re-run.
-- =============================================================================

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

  PERFORM set_config('statement_timeout', '180s', true);

  SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();

  -- 1) Unrenewed final-year first (no open expiry bids) → FA + MV.
  --    Frees squad slots before contested winners are assigned.
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

  -- 2) Contested expiry market (wage-bid winners) after FA releases
  v_resolve := public.contract_resolve_all_expiry_bids(
    v_ctx.ledger_season_id,
    v_ctx.bid_season_label
  );

  -- Safety: any leftover remaining=1 (e.g. bid row cleared without assign)
  UPDATE public."Players" p
  SET contract_seasons_remaining = 0
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  v_released := v_released
    + public.contract_release_zero_year_players(v_ctx.ledger_season_id);

  -- 3) Multi-year deals tick down into the new season
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

GRANT EXECUTE ON FUNCTION public.contract_tick_season_rollover() TO authenticated;

NOTIFY pgrst, 'reload schema';
