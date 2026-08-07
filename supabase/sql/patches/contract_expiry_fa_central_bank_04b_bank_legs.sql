-- =============================================================================
-- PART 4B — insert missing Central Bank legs + debit reserves
-- Run after 04a. Safe re-run (skips rows that already have bank_ledger).
-- =============================================================================

SET statement_timeout = '300s';

DO $bank$
DECLARE
  v_bank int := 0;
  v_bank_debit numeric := 0;
BEGIN
  WITH missing AS (
    SELECT
      l.id,
      l.entry_type,
      l.amount,
      l.description,
      l.club_short_name,
      coalesce(l.metadata, '{}'::jsonb) AS metadata
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'contract_expiry_compensation'
      AND coalesce(l.metadata->>'source', '') = 'contract_expiry_fa'
      AND NOT EXISTS (
        SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = l.id
      )
  ),
  inserted AS (
    INSERT INTO public.bank_ledger (
      entry_type,
      amount,
      description,
      club_short_name,
      club_ledger_id,
      metadata
    )
    SELECT
      m.entry_type,
      -m.amount,
      m.description,
      m.club_short_name,
      m.id,
      m.metadata
    FROM missing m
    RETURNING amount
  )
  SELECT
    count(*)::int,
    coalesce(sum(-amount), 0)
  INTO v_bank, v_bank_debit
  FROM inserted;

  IF v_bank_debit <> 0 THEN
    UPDATE public.gpsl_bank_account
    SET
      reserves = reserves - v_bank_debit,
      updated_at = now()
    WHERE id = 1;
  END IF;

  RAISE NOTICE 'PART 4B: bank legs=% debit=%', v_bank, v_bank_debit;
END;
$bank$;

SELECT 'PART 4B OK — bank legs' AS status;
