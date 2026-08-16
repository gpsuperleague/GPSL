-- =============================================================================
-- Hotfix: allow special_auction_fee / special_auction_prize on finance ledger
--
-- Symptom (admin Special Auctions → Settle & charge fees):
--   new row for relation "competition_finance_ledger" violates check constraint
--   "competition_finance_ledger_entry_type_check"
--
-- Cause: a later patch (e.g. bookies) rebuilt the allow-list from live rows +
-- its own types only. If no special-auction fee rows existed yet, those types
-- were dropped from the CHECK.
--
-- Safe re-run: keeps every live entry_type and re-adds special auction types.
-- =============================================================================

DO $ledger_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT entry_type AS t
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL
    UNION
    SELECT unnest(ARRAY[
      'special_auction_fee',
      'special_auction_prize',
      'bookies_expenditure',
      'bookies_income'
    ])
  ) s;

  IF v_list IS NULL OR length(v_list) < 3 THEN
    RAISE EXCEPTION 'Could not build entry_type allow-list';
  END IF;

  ALTER TABLE public.competition_finance_ledger
    DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_finance_ledger
       ADD CONSTRAINT competition_finance_ledger_entry_type_check
       CHECK (entry_type IN (%s))',
    v_list
  );

  RAISE NOTICE 'competition_finance_ledger_entry_type_check now includes special_auction_fee / prize';
END;
$ledger_types$;

NOTIFY pgrst, 'reload schema';
