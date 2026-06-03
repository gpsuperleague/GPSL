-- Backfill Transfer_History for URD squad-overflow release (already ran admin_enforce)
-- Run once after squad_overflow_enforcement.sql (transfer_sale_note column).

-- Latest URD sale where the player is no longer at URD (overflow / release)
UPDATE public."Transfer_History" h
SET
  transfer_sale_note = 'squad_overflow',
  foreign_buyer_name = CASE
    WHEN h.buyer_club_id = 'FOREIGN' AND coalesce(btrim(h.foreign_buyer_name), '') <> ''
      THEN h.foreign_buyer_name
    WHEN h.buyer_club_id = 'FOREIGN'
      THEN 'Foreign club (squad over 28)'
    ELSE coalesce(
      nullif(btrim(h.foreign_buyer_name), ''),
      'Market value (squad over 28)'
    )
  END
FROM (
  SELECT h2.ctid AS row_ctid
  FROM public."Transfer_History" h2
  WHERE h2.seller_club_id = 'URD'
  ORDER BY h2.transfer_time DESC NULLS LAST
  LIMIT 1
) latest
WHERE h.ctid = latest.row_ctid
  AND NOT EXISTS (
    SELECT 1
    FROM public."Players" p
    WHERE p."Konami_ID" = h.player_id
      AND p."Contracted_Team" = 'URD'
  );

SELECT
  h.transfer_time,
  p."Name",
  h.buyer_club_id,
  h.foreign_buyer_name,
  h.transfer_sale_note,
  h.fee
FROM public."Transfer_History" h
LEFT JOIN public."Players" p ON p."Konami_ID" = h.player_id
WHERE h.seller_club_id = 'URD'
ORDER BY h.transfer_time DESC NULLS LAST
LIMIT 5;
