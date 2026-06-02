-- =============================================================================
-- Repair foreign interest after a sale done before the counter existed
-- Run in Supabase SQL Editor (after sell_to_foreign_club.sql STEP 0).
--
-- Urawa Reds = ShortName URD. Max interest = 3; each FOREIGN sale uses 1 slot.
-- =============================================================================

-- Ensure column exists (same as sell_to_foreign_club.sql STEP 0)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Clubs'
      AND column_name = 'foreign_interest_remaining'
  ) THEN
    ALTER TABLE public."Clubs"
      ADD COLUMN foreign_interest_remaining smallint NOT NULL DEFAULT 3
      CHECK (
        foreign_interest_remaining >= 0
        AND foreign_interest_remaining <= 3
      );
  END IF;
END $$;

-- 1) See current URD state (run and check results)
SELECT
  c."ShortName",
  c."Club",
  c.foreign_interest_remaining,
  (
    SELECT count(*)::int
    FROM public."Transfer_History" h
    WHERE h.seller_club_id = c."ShortName"
      AND h.buyer_club_id = 'FOREIGN'
  ) AS foreign_sales_in_history
FROM public."Clubs" c
WHERE c."ShortName" = 'URD';

-- 2) Sync every club: remaining = 3 minus FOREIGN sales already in Transfer_History
UPDATE public."Clubs" c
SET foreign_interest_remaining = greatest(
  0,
  3 - coalesce((
    SELECT count(*)::int
    FROM public."Transfer_History" h
    WHERE h.seller_club_id = c."ShortName"
      AND h.buyer_club_id = 'FOREIGN'
  ), 0)
)
WHERE c."ShortName" <> 'FOREIGN';

-- 3) URD: if you already sold one but history has no FOREIGN row yet, force 2 remaining
--    (comment out if step 2 already shows foreign_sales_in_history = 1)
UPDATE public."Clubs"
SET foreign_interest_remaining = 2
WHERE "ShortName" = 'URD'
  AND (
    SELECT count(*)
    FROM public."Transfer_History" h
    WHERE h.seller_club_id = 'URD'
      AND h.buyer_club_id = 'FOREIGN'
  ) = 0;

-- 4) Optional — backdate the latest URD → FOREIGN transfer (edit the timestamp)
UPDATE public."Transfer_History" h
SET transfer_time = timestamptz '2026-05-01 12:00:00+00'
WHERE h.id = (
  SELECT h2.id
  FROM public."Transfer_History" h2
  WHERE h2.seller_club_id = 'URD'
    AND h2.buyer_club_id = 'FOREIGN'
  ORDER BY h2.transfer_time DESC NULLS LAST, h2.id DESC
  LIMIT 1
);

-- 5) Verify
SELECT
  c."ShortName",
  c.foreign_interest_remaining,
  h.id AS history_id,
  h.player_id,
  h.fee,
  h.transfer_time
FROM public."Clubs" c
LEFT JOIN public."Transfer_History" h
  ON h.seller_club_id = c."ShortName"
 AND h.buyer_club_id = 'FOREIGN'
WHERE c."ShortName" = 'URD'
ORDER BY h.transfer_time DESC NULLS LAST, h.id DESC;
