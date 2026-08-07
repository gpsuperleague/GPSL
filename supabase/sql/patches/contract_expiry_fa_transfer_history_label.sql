-- =============================================================================
-- Relabel contract_expiry Transfer_History buyer display
-- Safe re-run (also included in contract_expiry_fa_central_bank.sql backfill).
-- =============================================================================

UPDATE public."Transfer_History" h
SET foreign_buyer_name = 'Contract Run Down - Central Bank Compensation'
WHERE h.transfer_sale_note = 'contract_expiry'
  AND h.buyer_club_id = 'FOREIGN'
  AND coalesce(h.foreign_buyer_name, '')
        IS DISTINCT FROM 'Contract Run Down - Central Bank Compensation';
