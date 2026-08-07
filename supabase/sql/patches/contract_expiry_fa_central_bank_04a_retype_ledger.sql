-- =============================================================================
-- PART 4/4 — backfill existing FA foreign-sale rows (HEAVY — run alone)
-- Run after parts 1–3.
--
-- If "Failed to fetch" still happens, run the 4 blocks below one at a time
-- (each ends with SELECT status).
-- =============================================================================

SET statement_timeout = '300s';

-- A) Retype ledger rows
UPDATE public.competition_finance_ledger l
SET
  entry_type = 'contract_expiry_compensation',
  description = regexp_replace(
    coalesce(l.description, ''),
    '^Contract expired \(free agent\)',
    'Contract ended (free agent)'
  ),
  metadata = (coalesce(l.metadata, '{}'::jsonb) - 'buyer')
    || jsonb_build_object('compensation_from', 'central_bank')
WHERE l.entry_type = 'transfer_foreign_sale'
  AND coalesce(l.metadata->>'source', '') = 'contract_expiry_fa';

SELECT 'PART 4A OK — ledger retyped' AS status,
       (
         SELECT count(*)::int
         FROM public.competition_finance_ledger l
         WHERE l.entry_type = 'contract_expiry_compensation'
           AND coalesce(l.metadata->>'source', '') = 'contract_expiry_fa'
       ) AS compensation_rows;
