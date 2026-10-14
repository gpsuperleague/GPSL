-- =============================================================================
-- Why does special_auction_fetch_owner_by_id(12) still return the snap prize?
-- Read-only. Run the whole file; send back both result tables.
-- =============================================================================

-- 1) Auction 12 timings + what the hide helper decides
SELECT
  a.id,
  a.auction_type,
  a.status,
  a.start_time,
  a.end_time,
  a.snap_random_end_at IS NOT NULL                        AS has_random_end,
  now() < coalesce(a.snap_random_end_at, a.end_time)      AS before_finish,
  public.special_auction_snap_identity_hidden(a)          AS helper_says_hidden,
  public.is_gpsl_admin()                                  AS sql_editor_is_admin
FROM public.special_auctions a
WHERE a.id = 12;

-- 2) Live function bodies (look for is_gpsl_admin / missing redaction)
SELECT
  p.proname,
  position('is_gpsl_admin' IN pg_get_functiondef(p.oid)) > 0              AS mentions_admin,
  position('snap_identity_hidden' IN pg_get_functiondef(p.oid)) > 0       AS calls_hide_helper,
  pg_get_functiondef(p.oid)                                              AS definition
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'special_auction_snap_identity_hidden',
    'special_auction_owner_json',
    'special_auction_fetch_owner_by_id'
  )
ORDER BY p.proname;
