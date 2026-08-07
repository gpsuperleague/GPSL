-- =============================================================================
-- Contract expiry FA → Central Bank compensation
--
-- DO NOT run this whole file in the SQL Editor — it is too large and often
-- fails with: Failed to fetch (api.supabase.com)
--
-- Run these smaller patches IN ORDER instead:
--
--   1) contract_expiry_fa_central_bank_01_types_and_locks.sql
--   2) contract_expiry_fa_central_bank_02_assign_and_release.sql
--   3) contract_expiry_fa_central_bank_03_history_classify.sql
--   4a) contract_expiry_fa_central_bank_04a_retype_ledger.sql
--   4b) contract_expiry_fa_central_bank_04b_bank_legs.sql
--   4c) contract_expiry_fa_central_bank_04c_labels_and_locks.sql
--
-- Optional tiny label-only fix:
--   contract_expiry_fa_transfer_history_label.sql
--
-- Full source of the combined patch is kept in the _01…_04c files above.
-- =============================================================================

DO $$
BEGIN
  RAISE EXCEPTION
    'Do not run this combined file. Use parts 01 → 02 → 03 → 04a → 04b → 04c (see header comments).';
END;
$$;
