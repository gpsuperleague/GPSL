-- =============================================================================
-- Transfer news ticker: drop redundant "Foreign sale — Club" suffix
-- Buyer already shows the foreign club name (e.g. Sporting Gijon).
--
-- Re-applies gpsl_transfer_news_feed with the one-line filter.
-- Prefer re-running discord_transfer_gossip.sql if you haven't yet; this patch
-- only replaces the feed function body via the same source of truth.
--
-- Safe re-run: paste/run discord_transfer_gossip.sql OR apply the feed
-- function from that file after pulling latest. This stub documents the rule:
--
--   IF method ILIKE 'Foreign sale%' OR buyer_club_id = 'FOREIGN'
--     THEN do not append method to ticker body
-- =============================================================================

-- Lightweight check: if gossip feed is installed, re-install from companion file.
-- Operators: run the latest discord_transfer_gossip.sql (includes this fix).
-- If you only want this change without re-running gossip, the rule is already
-- in discord_transfer_gossip.sql — re-run that file's gpsl_transfer_news_feed
-- section, or the whole file (safe re-run).

DO $$
BEGIN
  RAISE NOTICE 'Re-run supabase/sql/patches/discord_transfer_gossip.sql to apply the ticker foreign-sale suffix fix (safe re-run).';
END $$;
