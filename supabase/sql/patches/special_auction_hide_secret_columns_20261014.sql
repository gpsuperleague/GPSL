-- =============================================================================
-- Mystery auctions: stop owners reading the prize player / future clues /
-- secret snap finish straight from the special_auctions table.
--
-- Owner pages use special_auction_fetch_owner_active / _by_id (SECURITY
-- DEFINER), which already redact these until the right moment, so they are
-- unaffected. Admin pages only read safe columns from the table.
--
-- Column-level grants: every column except the secret ones stays readable.
-- If a column is added to special_auctions later, re-run this file.
-- Undo: GRANT SELECT ON public.special_auctions TO authenticated;
-- Safe re-run.
-- =============================================================================

DO $$
DECLARE
  v_hidden text[] := ARRAY[
    'prize_player_id', 'known_player_id',
    'clue_2', 'clue_3', 'clue_4',
    'snap_random_end_at'
  ];
  v_cols text;
BEGIN
  SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum)
  INTO v_cols
  FROM pg_attribute a
  WHERE a.attrelid = 'public.special_auctions'::regclass
    AND a.attnum > 0
    AND NOT a.attisdropped
    AND a.attname <> ALL (v_hidden);

  EXECUTE 'REVOKE SELECT ON public.special_auctions FROM PUBLIC, anon, authenticated';
  EXECUTE format('GRANT SELECT (%s) ON public.special_auctions TO authenticated', v_cols);
END $$;

NOTIFY pgrst, 'reload schema';

-- Report: hidden columns should show false
SELECT a.attname AS column_name,
       has_column_privilege('authenticated', 'public.special_auctions'::regclass, a.attname, 'SELECT') AS owners_can_read
FROM pg_attribute a
WHERE a.attrelid = 'public.special_auctions'::regclass
  AND a.attname IN ('id', 'title', 'status', 'prize_player_id', 'known_player_id',
                    'clue_1', 'clue_2', 'clue_3', 'clue_4', 'snap_random_end_at')
ORDER BY a.attnum;
