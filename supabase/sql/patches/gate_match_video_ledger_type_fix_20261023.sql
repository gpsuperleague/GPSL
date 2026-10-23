-- =============================================================================
-- Fix: match video payout fails — gate_match_video missing from ledger CHECK
-- =============================================================================
-- Symptom: Discord ⚠️ on a correctly labelled video for an already-played
-- fixture. Ingest error:
--   new row for relation "competition_finance_ledger" violates check constraint
--   "competition_finance_ledger_entry_type_check"
--
-- Cause: later ledger-type rebuilds dropped gate_match_video when no such
-- rows existed yet. Pending holds never hit payout; played fixtures do.
-- Safe re-run.
-- =============================================================================

SELECT public.gpsl_ledger_ensure_entry_types(ARRAY['gate_match_video']);

DO $chk$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conname = 'competition_finance_ledger_entry_type_check'
    AND c.conrelid = 'public.competition_finance_ledger'::regclass;

  IF v_def IS NULL OR position('gate_match_video' IN v_def) = 0 THEN
    RAISE EXCEPTION 'gate_match_video still missing from ledger entry_type check: %', v_def;
  END IF;

  RAISE NOTICE 'OK — gate_match_video allowed on competition_finance_ledger';
END;
$chk$;
