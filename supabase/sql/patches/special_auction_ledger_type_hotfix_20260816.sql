-- =============================================================================
-- Superseded by gpsl_ledger_ensure_entry_types_20260816.sql
--
-- This file only added special_auction_* on top of live rows. If that run
-- failed mid-way, or another patch rebuilt the CHECK afterwards, settle still
-- breaks. Prefer the durable helper patch instead.
-- =============================================================================

SELECT public.gpsl_ledger_ensure_entry_types(
  ARRAY['special_auction_fee', 'special_auction_prize']
);
