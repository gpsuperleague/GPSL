SELECT pg_get_constraintdef(oid) AS def
FROM pg_constraint
WHERE conname = 'competition_finance_ledger_entry_type_check';
