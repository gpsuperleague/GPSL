-- Audit: duplicate GPDB players (same normalized Name + Nation)
-- Run in Supabase SQL Editor after patches/gpdb_player_deduplication.sql

SELECT
  dup_key,
  group_size,
  blocked_reason,
  keep_konami_id,
  keep_name,
  keep_rating,
  keep_club,
  drop_konami_id,
  drop_name,
  drop_rating,
  drop_club,
  drop_in_use,
  drop_refs
FROM public.gpdb_player_duplicate_audit()
ORDER BY group_size DESC, dup_key, drop_rating DESC NULLS LAST;

-- Summary
-- SELECT
--   count(DISTINCT dup_key)::integer AS duplicate_groups,
--   count(*) FILTER (WHERE blocked_reason IS NULL)::integer AS rows_to_drop,
--   count(*) FILTER (WHERE blocked_reason IS NOT NULL)::integer AS blocked_rows,
--   count(*) FILTER (WHERE drop_in_use)::integer AS drops_with_references
-- FROM public.gpdb_player_duplicate_audit();
