-- =============================================================================
-- Fix: DELETE requires a WHERE clause (Create Pre-Season / FA release)
--
-- Symptom:
--   DELETE requires a WHERE clause
--   RPC: competition_create_season_full / contract_release_zero_year_players
--
-- Cause: temp batch clear used `DELETE FROM _contract_expire_batch;` with no
--   WHERE. Supabase SQL safety rejects that.
--
-- Fix: `DELETE FROM _contract_expire_batch WHERE true;`
--
-- Run in Supabase SQL Editor, then retry Create Pre-Season / Tick catch-up.
-- Safe re-run. Prefer after contract_tick_fa_before_contested.sql.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.contract_release_zero_year_players(
  p_ledger_season_id bigint DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count int := 0;
  v_ledger_id bigint := p_ledger_season_id;
  v_ledger_label text;
  v_ctx record;
BEGIN
  PERFORM public.ensure_foreign_buyer_club();

  IF v_ledger_id IS NULL THEN
    SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();
    v_ledger_id := v_ctx.ledger_season_id;
    v_ledger_label := v_ctx.ledger_season_label;
  ELSE
    SELECT btrim(s.label) INTO v_ledger_label
    FROM public.competition_seasons s
    WHERE s.id = v_ledger_id;
  END IF;

  IF v_ledger_id IS NULL THEN
    RAISE EXCEPTION 'No ledger season for contract FA releases';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _contract_expire_batch (
    player_id text PRIMARY KEY,
    club text NOT NULL,
    fee numeric NOT NULL DEFAULT 0,
    player_name text
  ) ON COMMIT DROP;

  DELETE FROM _contract_expire_batch WHERE true;

  INSERT INTO _contract_expire_batch (player_id, club, fee, player_name)
  SELECT
    p."Konami_ID"::text,
    public.player_contracted_club_key(p."Contracted_Team"),
    greatest(coalesce(p.market_value::numeric, 0), 0),
    p."Name"
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining <= 0;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    RETURN 0;
  END IF;

  INSERT INTO public.competition_finance_ledger (
    season_id,
    fixture_id,
    club_short_name,
    entry_type,
    amount,
    description,
    metadata
  )
  SELECT
    v_ledger_id,
    NULL,
    e.club,
    'transfer_foreign_sale',
    e.fee,
    'Contract expired (free agent): ' || coalesce(e.player_name, e.player_id),
    jsonb_build_object(
      'player_id', e.player_id,
      'player_name', e.player_name,
      'holding_club', e.club,
      'buyer', 'FOREIGN',
      'market_value', e.fee,
      'ledger_season_id', v_ledger_id,
      'ledger_season_label', v_ledger_label,
      'source', 'contract_expiry_fa'
    )
  FROM _contract_expire_batch e
  WHERE e.fee > 0;

  UPDATE public."Club_Finances" cf
  SET balance = cf.balance + x.total_fee
  FROM (
    SELECT club, sum(fee)::numeric AS total_fee
    FROM _contract_expire_batch
    GROUP BY club
  ) x
  WHERE cf.club_name = x.club
    AND x.total_fee <> 0;

  UPDATE public."Players" p
  SET
    "Contracted_Team" = NULL,
    "Season_Signed" = NULL,
    contract_seasons_remaining = NULL,
    contract_wage = NULL
  FROM _contract_expire_batch e
  WHERE p."Konami_ID"::text = e.player_id;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id,
    foreign_buyer_name,
    transfer_sale_note
  )
  SELECT
    e.player_id,
    e.club,
    'FOREIGN',
    e.fee,
    0,
    now(),
    NULL,
    'Contract expired (free agent)',
    'contract_expiry'
  FROM _contract_expire_batch e;

  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_release_zero_year_players(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
