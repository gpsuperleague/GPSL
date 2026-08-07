-- =============================================================================
-- Fix: rollover used the wrong season for expiry bids / FA pairing
--
-- Cause: contract_rollover_finance_context() took "previous season by id".
-- After Create Pre-Season succeeded but tick failed, retrying Create made
-- another preseason row. Newest preseason = ledger, previous id = another
-- empty preseason — NOT the completed year that holds wage bids.
-- Result: 0 contested resolved; FA only saw whoever was still remaining=1.
--
-- Fix:
--   ledger = newest preseason/setup (unchanged)
--   bid season = latest complete/active season before ledger
--               else fall back to previous id
--               and if open bids exist under another label, use that label
--
-- Run in Supabase SQL Editor, then run diagnose + re-tick contested if needed:
--   SELECT * FROM ... admin_contract_tick_diagnose.sql (whole file)
--   SELECT public.contract_tick_rollover_step_contested();
--   SELECT public.contract_tick_rollover_step_decrement();  -- if not logged yet
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.contract_rollover_finance_context()
RETURNS TABLE (
  ledger_season_id bigint,
  ledger_season_label text,
  bid_season_id bigint,
  bid_season_label text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ledger record;
  v_bid record;
  v_bid_label_from_bids text;
  v_bid_id_from_label bigint;
BEGIN
  SELECT s.id, s.label, s.status
  INTO v_ledger
  FROM public.competition_seasons s
  WHERE s.status IN ('preseason', 'setup')
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_ledger.id IS NULL THEN
    RAISE EXCEPTION
      'Create the next pre-season first — expiry transfers and FA releases must post to the new season (not the closed year).';
  END IF;

  -- Prefer last finished / live year before this preseason shell
  SELECT s.id, s.label
  INTO v_bid
  FROM public.competition_seasons s
  WHERE s.id < v_ledger.id
    AND s.status IN ('complete', 'active')
  ORDER BY s.id DESC
  LIMIT 1;

  -- Fallback: previous row by id (legacy)
  IF v_bid.id IS NULL THEN
    SELECT s.id, s.label
    INTO v_bid
    FROM public.competition_seasons s
    WHERE s.id < v_ledger.id
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  IF v_bid.id IS NULL THEN
    RAISE EXCEPTION
      'No prior season found to read expiry wage bids from (ledger season id %).',
      v_ledger.id;
  END IF;

  ledger_season_id := v_ledger.id;
  ledger_season_label := btrim(v_ledger.label);
  bid_season_id := v_bid.id;
  bid_season_label := btrim(v_bid.label);

  -- If open bids live under a different label, prefer that (audit script behaviour)
  SELECT b.season_label
  INTO v_bid_label_from_bids
  FROM public.contract_expiry_wage_bids b
  GROUP BY b.season_label
  ORDER BY count(*) DESC, max(b.created_at) DESC
  LIMIT 1;

  IF v_bid_label_from_bids IS NOT NULL
     AND btrim(v_bid_label_from_bids) <> ''
     AND btrim(v_bid_label_from_bids) IS DISTINCT FROM bid_season_label
  THEN
    SELECT s.id
    INTO v_bid_id_from_label
    FROM public.competition_seasons s
    WHERE lower(btrim(s.label)) = lower(btrim(v_bid_label_from_bids))
    ORDER BY s.id DESC
    LIMIT 1;

    bid_season_label := btrim(v_bid_label_from_bids);
    IF v_bid_id_from_label IS NOT NULL THEN
      bid_season_id := v_bid_id_from_label;
    END IF;
  END IF;

  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.contract_rollover_finance_context() IS
  'Expiry rollover: ledger = newest preseason/setup; bids = last complete/active (or open-bid label).';

GRANT EXECUTE ON FUNCTION public.contract_rollover_finance_context() TO authenticated;

NOTIFY pgrst, 'reload schema';
