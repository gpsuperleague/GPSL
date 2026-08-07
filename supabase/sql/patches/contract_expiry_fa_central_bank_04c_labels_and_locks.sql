-- =============================================================================
-- PART 4C — Transfer_History buyer label + former-club expiry_fa locks
-- Run after 04a (04b optional if bank legs already done).
-- =============================================================================

SET statement_timeout = '300s';

UPDATE public."Transfer_History" h
SET foreign_buyer_name = 'Contract Run Down - Central Bank Compensation'
WHERE h.transfer_sale_note = 'contract_expiry'
  AND h.buyer_club_id = 'FOREIGN'
  AND coalesce(h.foreign_buyer_name, '')
        IS DISTINCT FROM 'Contract Run Down - Central Bank Compensation';

UPDATE public."Players" p
SET
  foreign_contract_club = h.seller_club_id,
  foreign_contract_sold_season_id = coalesce(
    public.gpsl_season_id_for_locks(),
    public.current_gpsl_season_id()
  ),
  foreign_contract_unlock_season_label = 'when signed by another club',
  foreign_contract_lock_kind = 'expiry_fa'
FROM (
  SELECT DISTINCT ON (h2.player_id)
    h2.player_id::text AS player_id,
    h2.seller_club_id
  FROM public."Transfer_History" h2
  WHERE h2.transfer_sale_note = 'contract_expiry'
    AND h2.seller_club_id IS NOT NULL
  ORDER BY h2.player_id, h2.transfer_time DESC, h2.id DESC
) h
WHERE p."Konami_ID"::text = h.player_id
  AND p."Contracted_Team" IS NULL
  AND coalesce(nullif(btrim(p.foreign_contract_lock_kind), ''), '')
        IS DISTINCT FROM 'foreign'
  AND coalesce(nullif(btrim(p.foreign_contract_lock_kind), ''), '')
        IS DISTINCT FROM 'paid_up';

SELECT 'PART 4C OK — labels + former-club locks' AS status,
       (
         SELECT count(*)::int
         FROM public."Players" p
         WHERE p.foreign_contract_lock_kind = 'expiry_fa'
           AND p."Contracted_Team" IS NULL
       ) AS expiry_fa_players;
