-- =============================================================================
-- READ-ONLY: how did clubs end up with legacy cards? (2026-10-10)
-- =============================================================================
-- Part A — are the live legacy checks intact? (false = an older patch was
--          re-run over them and the hole was open)
-- Part B — every legacy card at a club: winning bid time vs when the card
--          went legacy, and how many bids were placed AFTER it went legacy.
--   went_legacy_mid_auction  → card flagged by a sync while its draft was open
--   bids_after_legacy > 0    → bids got past the checks (Part A false)
-- =============================================================================

SELECT 'A' AS part,
  'assert_player_transferable blocks legacy free agents' AS check_name,
  (position('IF coalesce(v_legacy, false)' IN d) > 0
   AND (position('IF v_club IS NULL THEN' IN d) = 0
        OR position('IF coalesce(v_legacy, false)' IN d) < position('IF v_club IS NULL THEN' IN d))) AS ok,
  NULL::text AS club, NULL::text AS player, NULL::timestamp AS legacy_since_uk,
  NULL::timestamp AS bought_uk, NULL::timestamp AS draft_opened_uk, NULL::int AS bids_after_legacy,
  NULL::text AS verdict
FROM (SELECT pg_get_functiondef('public.assert_player_transferable(text)'::regprocedure) AS d) f
UNION ALL
SELECT 'A', 'assert_player_available_for_signing blocks legacy',
  position('pesdb_unavailable' IN pg_get_functiondef('public.assert_player_available_for_signing(text)'::regprocedure)) > 0,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL
UNION ALL
SELECT 'A', 'player_draft_ensure_listing blocks legacy',
  position('pesdb_unavailable' IN pg_get_functiondef('public.player_draft_ensure_listing(text)'::regprocedure)) > 0,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL
UNION ALL
SELECT 'A', 'bid trigger calls assert_player_transferable',
  EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = 'public."Player_Transfer_Bids"'::regclass
          AND t.tgname = 'player_transfer_bids_same_season_block' AND NOT t.tgisinternal),
  NULL, NULL, NULL, NULL, NULL, NULL, NULL
UNION ALL
SELECT 'B', NULL, NULL,
  x.club, x.name,
  x.legacy_since AT TIME ZONE 'Europe/London',
  x.bought_at AT TIME ZONE 'Europe/London',
  x.opened_at AT TIME ZONE 'Europe/London',
  x.bids_after,
  CASE
    WHEN x.bought_at IS NULL THEN 'no purchase record (admin assign / start squad?)'
    WHEN x.bought_at < x.legacy_since THEN 'bought before it went legacy'
    WHEN x.opened_at IS NOT NULL AND x.opened_at < x.legacy_since AND x.bids_after = 0
      THEN 'went legacy mid-auction (no bids after) — settlement let it through'
    WHEN x.bids_after > 0 THEN 'bids placed after it went legacy — checks were not live'
    ELSE 'bought after it went legacy'
  END
FROM (
  SELECT
    public.player_contracted_club_key(p."Contracted_Team") AS club,
    p."Name" AS name,
    p.pesdb_unavailable_since AS legacy_since,
    h.transfer_time AS bought_at,
    l.created_at AS opened_at,
    (SELECT count(*)::int FROM public."Player_Transfer_Bids" b
     WHERE btrim(coalesce(b.player_id::text, b.direct_bid_id::text, '')) = p."Konami_ID"::text
       AND b.bid_time >= p.pesdb_unavailable_since) AS bids_after
  FROM public."Players" p
  LEFT JOIN LATERAL (
    SELECT th.transfer_time, th.listing_id
    FROM public."Transfer_History" th
    WHERE th.buyer_club_id = public.player_contracted_club_key(p."Contracted_Team")
      AND btrim(th.player_id::text) = p."Konami_ID"::text
    ORDER BY th.transfer_time DESC LIMIT 1
  ) h ON true
  LEFT JOIN public."Player_Transfer_Listings" l ON l.id = h.listing_id
  WHERE coalesce(p.pesdb_unavailable, false)
    AND public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
) x
ORDER BY part, club, player;
